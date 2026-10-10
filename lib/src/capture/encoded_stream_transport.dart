import 'dart:async';
import 'dart:typed_data';

import 'codec_probe.dart';
import 'native_video_encoder.dart';
import 'stream_settings.dart';

/// What one of the platform's encoders claims to be.
///
/// A claim, not a measurement: [hardware] is the platform saying which
/// implementation it is, and [name] is what it calls itself — the value that
/// has to travel into `EncodeEvidence` so a driver change invalidates a cached
/// rate. Nothing here says the encoder can hold any given mode; that is what
/// `EncodeBudgetProbe` measures separately.
class EncoderClaim {
  const EncoderClaim({
    required this.codec,
    required this.name,
    required this.hardware,
  });

  final CaptureCodec codec;
  final String name;
  final bool hardware;

  @override
  String toString() =>
      'EncoderClaim(${codec.wireName}, $name, '
      '${hardware ? 'hardware' : 'software'})';
}

/// The raw plugin seam an [AndroidEncodedStreamChannel] is built on.
///
/// Everything native lives behind this interface, so the parsing below is pure
/// Dart and the gate can exercise it with a fake. It is deliberately thinner
/// than [EncodedStreamChannel]: it speaks the platform's words — an integer
/// camera id, a codec, raw event maps — and knows nothing about how those maps
/// become [EncodedPacket]s. Keeping the translation here is what lets the one
/// automated gate pin the `sourceSeq` rules, which is where a padded stream is
/// unmasked.
abstract interface class EncodedStreamTransport {
  /// Starts the pipeline for the plugin's [cameraId] at [width]x[height].
  ///
  /// [cameraId] is the physical camera the plugin opened, not the announced
  /// `camera_enum`. [sessionGeneration] names this run and is echoed back on
  /// every event.
  Future<void> open({
    required int cameraId,
    required int width,
    required int height,
    required int fps,
    required int quality,
    required CaptureCodec codec,
    required int sessionGeneration,
  });

  /// Stops the pipeline, after flushing whatever the encoder still holds.
  Future<void> close();

  /// The encoders the platform reports, hardware and software alike.
  Future<List<EncoderClaim>> encoders();

  /// The platform's raw event maps, one per encoded buffer.
  ///
  /// A broadcast stream, because the plugin underneath is a process-wide
  /// singleton: whatever subscribes is the only listener that run has, and a
  /// packet with no listener is dropped.
  Stream<Object?> get events;
}

/// Adapts the plugin's raw event maps onto [EncodedStreamChannel].
///
/// This layer turns the platform's words into the encoder's: `bytes` into an
/// owned [Uint8List], `generation` into a stale-packet filter, and `ptsUs` into
/// [EncodedPacket.sourceSeq]. The last is the expensive one — it is the only
/// thing that lets `SustainedRateMeter` see a producer padding its output by
/// repeating the last picture, and a channel that numbered its own packets
/// would never report a repeat.
class AndroidEncodedStreamChannel implements EncodedStreamChannel {
  AndroidEncodedStreamChannel({
    required EncodedStreamTransport transport,
    required int cameraEnum,
    required int cameraId,
    required CaptureCodec codec,
  }) : _transport = transport,
       _cameraEnum = cameraEnum,
       _cameraId = cameraId,
       _codec = codec;

  final EncodedStreamTransport _transport;

  /// The announced `camera_enum` this channel was built for.
  ///
  /// Held so [open] can refuse a run that names a different camera. The
  /// announced enum and the physical [cameraId] are two separate numbering
  /// schemes, and the one thing that must never happen is a channel built for
  /// one camera quietly streaming another: the registration would describe the
  /// camera the operator chose while the bytes came from a different sensor.
  final int _cameraEnum;

  /// The plugin's physical camera id — not the announced `camera_enum`.
  final int _cameraId;

  final CaptureCodec _codec;

  StreamSubscription<Object?>? _subscription;
  StreamController<EncodedPacket>? _packets;

  int _sessionGeneration = 0;

  /// The presentation timestamp of the last event that carried one.
  ///
  /// Null until the first timestamped event, and never updated by an event
  /// without a timestamp: a producer that omits `ptsUs` says nothing about
  /// whether the next picture repeats the one before it.
  int? _lastPtsUs;

  /// The next capture-side sequence number to hand out.
  int _sourceSeq = 0;

  int _malformedEvents = 0;
  int _staleEvents = 0;
  int _unsequencedEvents = 0;

  /// Events dropped because `bytes` was not a [Uint8List], or the event was
  /// not a map at all.
  int get malformedEvents => _malformedEvents;

  /// Events dropped because their `generation` was not this run's.
  int get staleEvents => _staleEvents;

  /// Events that carried no `ptsUs`; each was counted as a new picture.
  int get unsequencedEvents => _unsequencedEvents;

  @override
  Future<Stream<EncodedPacket>> open({
    required int cameraEnum,
    required int width,
    required int height,
    required int fps,
    required int quality,
    required int sessionGeneration,
  }) async {
    // A mismatch is a construction bug, not a runtime condition: the channel
    // was built against one announced camera and is being opened for another.
    // The two numbering schemes are never interchangeable, so this fails loud
    // and early — before the transport is touched — rather than streaming one
    // sensor while the registration describes a different one. `NativeVideo
    // Encoder` propagates the failure and rolls its `_running` flag back, so
    // the device acks `ok:false` instead of recording the wrong camera.
    if (cameraEnum != _cameraEnum) {
      throw StateError(
        'encoded stream channel was built for camera_enum $_cameraEnum but '
        'opened for camera_enum $cameraEnum; the announced enum and the '
        'physical index are not interchangeable',
      );
    }

    // A second `open` on the same channel would otherwise overwrite
    // `_subscription` without cancelling the first, and every event would be
    // delivered twice — once through each subscription. Release whatever the
    // previous run left behind before claiming anew.
    await _release();

    _sessionGeneration = sessionGeneration;
    _lastPtsUs = null;
    _sourceSeq = 0;
    _malformedEvents = 0;
    _staleEvents = 0;
    _unsequencedEvents = 0;

    // `onCancel` is the teardown this adapter used to lack entirely. The
    // consumer (`NativeVideoEncoder`) cancels its listener once `close()` has
    // resolved, and from that moment the adapter must stop being a live
    // subscription on the plugin's broadcast stream: otherwise it feeds a
    // controller nobody listens to once per recording, forever, on a kiosk
    // that runs for weeks. Cancelling the consumer is the signal that the tail
    // has landed, so that is where the release belongs.
    //
    // Bound to this controller rather than to the channel: a replaced run's
    // controller closes on a later turn, and its `onCancel` must not tear down
    // the run that replaced it.
    late final StreamController<EncodedPacket> controller;
    controller = StreamController<EncodedPacket>(
      onCancel: () => _releaseIfCurrent(controller),
    );
    _packets = controller;

    // Claimed before the producer is started, and that ordering is
    // load-bearing: the first frame of the run can be emitted from inside
    // `transport.open`, and it arrives on a broadcast stream that drops
    // whatever has no listener. Subscribing after the await would lose it.
    _subscription = _transport.events.listen(
      _onEvent,
      onError: (Object error, StackTrace stack) {
        if (!controller.isClosed) controller.addError(error, stack);
      },
    );

    try {
      await _transport.open(
        cameraId: _cameraId,
        width: width,
        height: height,
        fps: fps,
        quality: quality,
        codec: _codec,
        sessionGeneration: sessionGeneration,
      );
    } catch (_) {
      // Nothing is producing, so nothing may stay claimed: a subscription left
      // behind would keep feeding a controller no caller will ever listen to,
      // and the next run's packets would land in a dead stream. The failure
      // itself propagates, so the encoder above can roll its `_running` flag
      // back rather than believe a pipeline it does not have is live.
      await _release();
      rethrow;
    }

    return controller.stream;
  }

  /// Releases the channel only if [controller] is still the current run.
  ///
  /// A controller closed by a later [open] fires `onCancel` on a later turn,
  /// after the new run is already installed. Releasing unconditionally there
  /// would cancel the replacement's transport subscription and close its
  /// controller — a reopen would silently kill the stream it just started.
  Future<void> _releaseIfCurrent(StreamController<EncodedPacket> controller) {
    if (!identical(_packets, controller)) return Future<void>.value();
    return _release();
  }

  /// Drops the run's transport subscription and packet controller.
  ///
  /// Idempotent, and that matters: it is both the [StreamController.onCancel]
  /// teardown and the cleanup path for a failed [open], and a controller
  /// closing fires `onCancel` in turn. The fields are nulled before the first
  /// await so a re-entrant call sees nothing left to release.
  ///
  /// The transport subscription is cancelled here — but **only** here. [close]
  /// still does not cancel it: the tail of the recording arrives after
  /// `close()` resolves, and this runs only once the consumer has stopped
  /// listening, which is exactly when the tail is known to have landed.
  Future<void> _release() async {
    final subscription = _subscription;
    final controller = _packets;
    _subscription = null;
    _packets = null;
    await subscription?.cancel();
    if (controller != null && !controller.isClosed) {
      // Not awaited: a single-subscription controller that was never listened
      // to only completes its done future once someone subscribes, so awaiting
      // this would hang a failed `open` forever.
      unawaited(controller.close());
    }
  }

  void _onEvent(Object? event) {
    final controller = _packets;
    if (controller == null || controller.isClosed) return;

    if (event is! Map) {
      _malformedEvents++;
      return;
    }

    // The plugin is a process-wide singleton: after a camera switch or a
    // background round trip its capture callback can still fire with the run
    // before's generation. Filing those bytes under this stream's id would put
    // the last recording's tail inside this one.
    if (event['generation'] != _sessionGeneration) {
      _staleEvents++;
      return;
    }

    final rawBytes = event['bytes'];
    if (rawBytes is! Uint8List) {
      _malformedEvents++;
      return;
    }
    // Copied, never handed onward: the platform owns its buffer and may reuse
    // it the moment this callback returns.
    final bytes = Uint8List.fromList(rawBytes);

    final rawPts = event['ptsUs'];
    final int? ptsUs = rawPts is int ? rawPts : null;

    // `sourceSeq` is derived here, and this is the whole reason the layer
    // exists. A producer that cannot keep up pads its output by repeating the
    // last picture; the only way to see that is for a repeated PTS to leave
    // the sequence where it was. Numbering every packet here would make each
    // one look new, and a rate meter would report the tick rate as delivery.
    final int sourceSeq;
    if (ptsUs == null) {
      _unsequencedEvents++;
      sourceSeq = ++_sourceSeq;
    } else if (ptsUs != _lastPtsUs) {
      _lastPtsUs = ptsUs;
      sourceSeq = ++_sourceSeq;
    } else {
      // Same timestamp as the picture before: this is that picture again, so
      // it keeps the sequence number the previous packet was given.
      sourceSeq = _sourceSeq;
    }

    final rawPictures = event['pictures'];

    controller.add(
      EncodedPacket(
        bytes: bytes,
        // Zero is a legitimate answer — a parameter-set-only packet holds no
        // picture — so a missing field reads as zero rather than dropping it.
        pictures: rawPictures is int ? rawPictures : 0,
        sourceSeq: sourceSeq,
        sourcePts: ptsUs == null ? null : Duration(microseconds: ptsUs),
        sessionGeneration: _sessionGeneration,
        isEos: event['eos'] == true,
      ),
    );
  }

  /// Stops the producer, after flushing whatever it still holds.
  ///
  /// Only the transport is closed; the subscription is **deliberately not
  /// cancelled**. The tail of the recording is still on its way — the plugin
  /// flushes it and the event channel delivers it on a later turn — and
  /// cancelling here would throw those bytes away with no way for the server
  /// to notice a recording that ends a few frames early. The teardown belongs
  /// to the consumer: `NativeVideoEncoder` cancels its own subscription once
  /// `close()` has resolved, and that cancel fires the controller's `onCancel`
  /// ([_release]), which is where the transport subscription is finally let go.
  @override
  Future<void> close() => _transport.close();
}

/// Reports the codecs the platform's **hardware** encoders can produce.
///
/// Only `hardware == true` claims are kept. A software encoder cannot hold
/// 1080p60, and the announced codec list is a promise the server stores
/// verbatim — putting `c2.android.*` in it would announce a codec this device
/// cannot actually serve. A device with only software encoders honestly
/// announces the mjpeg floor, which `CompositeCodecProbe` supplies. The
/// skipped ones are recorded so a diagnostic can say which they were.
///
/// Never throws: that is [CodecProbe]'s contract, and the reason is that an
/// unusable probe source must contribute nothing rather than take the whole
/// selection down with it.
class PlatformCodecProbe implements CodecProbe {
  PlatformCodecProbe({required EncodedStreamTransport transport, this.log})
    : _transport = transport;

  final EncodedStreamTransport _transport;

  /// Called with a line naming each software encoder that was skipped.
  final void Function(String message)? log;

  final List<String> _skippedSoftware = <String>[];

  /// The names of the software encoders that were not announced.
  List<String> get skippedSoftware =>
      List<String>.unmodifiable(_skippedSoftware);

  @override
  Future<Set<CaptureCodec>> availableCodecs() async {
    // Cleared per call, not accumulated: the probe is consulted at start-up
    // and again on every re-detect, and a list that only ever grew would report
    // every earlier skip again as if it were new.
    _skippedSoftware.clear();
    try {
      final claims = await _transport.encoders();
      final found = <CaptureCodec>{};
      for (final claim in claims) {
        if (claim.hardware) {
          found.add(claim.codec);
        } else {
          _skippedSoftware.add(claim.name);
          log?.call('skipped software encoder ${claim.name}');
        }
      }
      return found;
    } catch (_) {
      // Any failure contributes nothing rather than propagating: the composite
      // probe falls back to the baseline floor.
      return <CaptureCodec>{};
    }
  }
}
