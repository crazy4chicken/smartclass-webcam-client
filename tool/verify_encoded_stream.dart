// Exercises the encoded-stream adapter, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// What is pinned here is the contract between the plugin's raw event maps and
// the encoder above it: claim-before-start, the stale-generation filter, and
// the `sourceSeq` derivation that is the only way a padded stream can be told
// from a real one. None of it needs a camera or a Flutter binding.
//
// `check`, `eq`, `eqBytes`, `section` and `guard` are the harness's, imported
// from there so every section lands in the one pass/fail count.
import 'dart:async';
import 'dart:typed_data';

import 'package:webcam_client/src/capture/codec_probe.dart';
import 'package:webcam_client/src/capture/encoded_stream_transport.dart';
import 'package:webcam_client/src/capture/native_video_encoder.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

import 'verify_pure.dart';

// --- fixtures ---------------------------------------------------------------

/// A marker for "this key is absent", so a test can tell an omitted field from
/// one explicitly set to null.
const Object _absent = Object();

/// One raw event in the frozen protocol shape.
///
/// `bytes` defaults to a valid three-byte payload; every other key is omitted
/// unless a test sets it, which is what lets the "missing pictures / eos / pts"
/// rules be exercised.
Map<String, Object?> _event({
  Object? bytes = _absent,
  Object? pictures = _absent,
  Object? ptsUs = _absent,
  Object? generation = _absent,
  Object? eos = _absent,
}) => <String, Object?>{
  'bytes': identical(bytes, _absent) ? _bytes() : bytes,
  if (!identical(pictures, _absent)) 'pictures': pictures,
  if (!identical(ptsUs, _absent)) 'ptsUs': ptsUs,
  if (!identical(generation, _absent)) 'generation': generation,
  if (!identical(eos, _absent)) 'eos': eos,
};

Uint8List _bytes([int value = 1]) => Uint8List.fromList(<int>[value, 2, 3]);

/// A transport whose events the test drives by hand.
class _FakeTransport implements EncodedStreamTransport {
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast();

  int openCalls = 0;
  int closeCalls = 0;
  int? lastCameraId;
  int? lastWidth;
  int? lastHeight;
  int? lastFps;
  int? lastQuality;
  CaptureCodec? lastCodec;
  int? lastSessionGeneration;

  /// Events emitted from inside [open], before it completes.
  List<Object?> eventsOnOpen = const <Object?>[];

  /// Events emitted from inside [close], before it resolves.
  List<Object?> eventsOnClose = const <Object?>[];

  /// When set, [open] fails the way a plugin with no encoder does.
  Object? openError;

  /// When set, [encoders] fails the way a dead binder does.
  Object? encodersError;

  List<EncoderClaim> claims = const <EncoderClaim>[];

  /// Whether anything is subscribed to [events]. A channel that failed to open
  /// must leave this false.
  bool get hasListeners => _events.hasListener;

  @override
  Stream<Object?> get events => _events.stream;

  @override
  Future<void> open({
    required int cameraId,
    required int width,
    required int height,
    required int fps,
    required int quality,
    required CaptureCodec codec,
    required int sessionGeneration,
  }) async {
    openCalls++;
    lastCameraId = cameraId;
    lastWidth = width;
    lastHeight = height;
    lastFps = fps;
    lastQuality = quality;
    lastCodec = codec;
    lastSessionGeneration = sessionGeneration;

    final error = openError;
    if (error != null) throw error;
    for (final event in eventsOnOpen) {
      _events.add(event);
    }
  }

  @override
  Future<void> close() async {
    closeCalls++;
    for (final event in eventsOnClose) {
      _events.add(event);
    }
  }

  @override
  Future<List<EncoderClaim>> encoders() async {
    final error = encodersError;
    if (error != null) throw error;
    return claims;
  }

  /// Pushes one raw event, the way a live event channel would.
  void emit(Object? event) => _events.add(event);
}

/// Opens a channel over [fake] and returns the packets it will deliver.
Future<List<EncodedPacket>> _openChannel(
  _FakeTransport fake, {
  int cameraEnum = 0,
  int cameraId = 0,
  CaptureCodec codec = CaptureCodec.h264,
  int sessionGeneration = 1,
}) async {
  final channel = AndroidEncodedStreamChannel(
    transport: fake,
    cameraEnum: cameraEnum,
    cameraId: cameraId,
    codec: codec,
  );
  final received = <EncodedPacket>[];
  final stream = await channel.open(
    cameraEnum: cameraEnum,
    width: 1920,
    height: 1080,
    fps: 60,
    quality: 80,
    sessionGeneration: sessionGeneration,
  );
  stream.listen(received.add);
  return received;
}

// --- checks -----------------------------------------------------------------

Future<void> runEncodedStreamChecks() async {
  await guard('encoded stream: claim before start', () async {
    section('encoded stream: claim before start');
    {
      // The first frame of the run can be emitted from inside
      // `transport.open`. On a broadcast event stream it is lost unless the
      // channel has already subscribed, so subscribing after the await drops
      // the opening frame of every recording.
      final fake = _FakeTransport();
      fake.eventsOnOpen = <Object?>[_event(generation: 1, ptsUs: 0)];
      final received = await _openChannel(fake, cameraId: 3);
      await settle();

      eq('the packet emitted during open is not lost', received.length, 1);
      eq('the transport was opened once', fake.openCalls, 1);
      eq('with the physical camera id, not the enum', fake.lastCameraId, 3);
      eq(
        'and the codec the channel was built for',
        fake.lastCodec,
        CaptureCodec.h264,
      );
      eq(
        'at the requested geometry',
        '${fake.lastWidth}x${fake.lastHeight}',
        '1920x1080',
      );
      eq('and the run generation', fake.lastSessionGeneration, 1);
    }

    {
      // The failure must reach the caller so `NativeVideoEncoder` can roll its
      // `_running` flag back, and it must not leave a subscription behind: one
      // that stayed would keep feeding a controller nobody listens to.
      final fake = _FakeTransport()..openError = StateError('no encoder');
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );

      Object? error;
      try {
        await channel.open(
          cameraEnum: 0,
          width: 640,
          height: 480,
          fps: 15,
          quality: 60,
          sessionGeneration: 1,
        );
      } catch (e) {
        error = e;
      }
      await settle();

      eq('an open failure propagates to the caller', error is StateError, true);
      eq('and leaves no subscription behind', fake.hasListeners, false);
    }
  });

  await guard('encoded stream: event conversion', () async {
    section('encoded stream: event conversion');

    {
      // The platform owns its buffer and may reuse it as soon as the callback
      // returns, so the packet has to own a copy.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(received.add);

      final source = _bytes();
      fake.emit(_event(bytes: source, generation: 1, ptsUs: 100));
      await settle();

      eq('one packet is delivered', received.length, 1);
      source[0] = 99;
      eqBytes('the packet owns a copy of the bytes', received.single.bytes, [
        1,
        2,
        3,
      ]);
      eq('and nothing was counted malformed', channel.malformedEvents, 0);
    }

    {
      // Anything that is not a `Uint8List` is dropped and counted, never
      // handed onward as if it were bytes.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(received.add);

      fake.emit(_event(bytes: 'not bytes', generation: 1, ptsUs: 100));
      // A plain `List<int>` is not a `Uint8List` either.
      fake.emit(_event(bytes: <int>[1, 2, 3], generation: 1, ptsUs: 200));
      fake.emit('not a map at all');
      fake.emit(_event(bytes: null, generation: 1, ptsUs: 300));
      await settle();

      eq('no malformed event is delivered', received.length, 0);
      eq('and each one is counted', channel.malformedEvents, 4);
    }

    {
      // The plugin is a process-wide singleton: a packet from the run before
      // must be dropped rather than filed under this stream's id.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 7,
      )).listen(received.add);

      fake.emit(_event(generation: 6, ptsUs: 100));
      await settle();
      eq('a packet from another run is dropped', received.length, 0);
      eq('and counted as stale', channel.staleEvents, 1);

      fake.emit(_event(generation: 7, ptsUs: 100));
      await settle();
      eq('a packet from this run is delivered', received.length, 1);
      eq('and the stale count does not move', channel.staleEvents, 1);
    }

    {
      // The core rule: a repeated PTS is the same picture again, and the
      // sequence must not advance for it — that is what lets a rate meter see
      // a producer padding its output.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(received.add);

      fake.emit(_event(generation: 1, ptsUs: 100));
      fake.emit(_event(generation: 1, ptsUs: 200));
      fake.emit(_event(generation: 1, ptsUs: 200)); // the picture before, again
      fake.emit(_event(generation: 1, ptsUs: 300));
      await settle();

      eq('every event is delivered', received.length, 4);
      eq('the sequence starts at one', received[0].sourceSeq, 1);
      eq(
        'a new timestamp advances the sequence',
        '${received[1].sourceSeq},${received[3].sourceSeq}',
        '2,3',
      );
      eq('a repeated timestamp does not', received[2].sourceSeq, 2);
      eq('and nothing was unsequenced', channel.unsequencedEvents, 0);
    }

    {
      // No timestamp is no evidence of a repeat, so every event counts as a
      // new picture — and is counted as such, so "the producer stopped sending
      // timestamps" stays visible instead of silently inflating the rate.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(received.add);

      fake.emit(_event(generation: 1));
      fake.emit(_event(generation: 1));
      fake.emit(_event(generation: 1));
      await settle();

      eq('every unsequenced event is delivered', received.length, 3);
      eq(
        'and each counts as a new picture',
        received.map((p) => p.sourceSeq).join(','),
        '1,2,3',
      );
      eq('the unsequenced count is exposed', channel.unsequencedEvents, 3);
    }

    {
      // `pictures` and `eos` pass through; a missing field is not an error.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(received.add);

      fake.emit(_event(generation: 1, ptsUs: 10, pictures: 3, eos: true));
      // No `pictures`, `eos` or `ptsUs` at all.
      fake.emit(_event(generation: 1));
      await settle();

      eq('pictures pass through unchanged', received[0].pictures, 3);
      eq('eos passes through unchanged', received[0].isEos, true);
      eq('a missing pictures reads as zero', received[1].pictures, 0);
      eq('a missing eos reads as false', received[1].isEos, false);
      eq(
        'the pts travels through as the source timestamp',
        received[0].sourcePts,
        const Duration(microseconds: 10),
      );
      eq('and a missing pts stays null', received[1].sourcePts, null);
      eq(
        'the run generation is stamped on every packet',
        received[1].sessionGeneration,
        1,
      );
    }
  });

  await guard('encoded stream: close', () async {
    section('encoded stream: close');

    {
      // The tail is flushed after `close` resolves: the plugin has not pushed
      // its last picture yet and the event channel delivers it on a later
      // turn. Cancelling the subscription in `close` would throw it away.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(received.add);

      fake.emit(_event(generation: 1, ptsUs: 100));
      await settle();
      eq('a packet before close arrives', received.length, 1);

      await channel.close();
      eq('close reached the transport', fake.closeCalls, 1);

      fake.emit(_event(generation: 1, ptsUs: 200, eos: true));
      await settle();
      eq('the tail after close still arrives', received.length, 2);
      eq('and it is the end of stream', received.last.isEos, true);
    }

    {
      // The same rule for a tail flushed from inside the close call itself.
      final fake = _FakeTransport();
      fake.eventsOnClose = <Object?>[
        _event(generation: 1, ptsUs: 200, eos: true),
      ];
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final received = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(received.add);

      fake.emit(_event(generation: 1, ptsUs: 100));
      await settle();
      await channel.close();
      await settle();

      eq('the tail flushed during close arrives', received.length, 2);
      eq('and closes the stream', received.last.isEos, true);
    }
  });

  await guard('encoded stream: platform codec probe', () async {
    section('encoded stream: platform codec probe');

    {
      // A software encoder cannot hold 1080p60, and the announced list is a
      // promise the server stores verbatim — so it must not be announced.
      final fake = _FakeTransport()
        ..claims = const <EncoderClaim>[
          EncoderClaim(
            codec: CaptureCodec.h265,
            name: 'c2.android.hevc.encoder',
            hardware: false,
          ),
          EncoderClaim(
            codec: CaptureCodec.h264,
            name: 'c2.mtk.avc.encoder',
            hardware: true,
          ),
        ];
      final logs = <String>[];
      final probe = PlatformCodecProbe(transport: fake, log: logs.add);
      final codecs = await probe.availableCodecs();

      eq('only the hardware codec is announced', codecs.length, 1);
      check(
        'and it is the one that was hardware',
        codecs.contains(CaptureCodec.h264),
      );
      check(
        'the software codec is not announced',
        !codecs.contains(CaptureCodec.h265),
      );
      eq(
        'the skipped software encoder is recorded',
        probe.skippedSoftware.join(','),
        'c2.android.hevc.encoder',
      );
      check(
        'and logged',
        logs.any((l) => l.contains('c2.android.hevc.encoder')),
      );
    }

    {
      // A device with only software encoders honestly announces nothing here;
      // `CompositeCodecProbe` supplies the mjpeg floor.
      final fake = _FakeTransport()
        ..claims = const <EncoderClaim>[
          EncoderClaim(
            codec: CaptureCodec.h264,
            name: 'c2.android.avc.encoder',
            hardware: false,
          ),
        ];
      final probe = PlatformCodecProbe(transport: fake);
      eq(
        'a software-only device announces nothing',
        (await probe.availableCodecs()).isEmpty,
        true,
      );
    }

    {
      // `CodecProbe` must never throw: a dead binder contributes nothing.
      final fake = _FakeTransport()..encodersError = StateError('binder dead');
      final probe = PlatformCodecProbe(transport: fake);

      Set<CaptureCodec>? codecs;
      Object? error;
      try {
        codecs = await probe.availableCodecs();
      } catch (e) {
        error = e;
      }

      eq('a throwing encoders() does not escape the probe', error, null);
      eq('and contributes nothing', codecs?.isEmpty, true);
    }

    {
      // The probe runs at start-up and again on every re-detect. `skipped
      // Software` is a report of *this* call, not a running tally: a list that
      // only ever grew would name every software encoder ever seen as if the
      // latest call had skipped it, and a diagnostic built on it would blame
      // the wrong re-detect. Each call must start from empty.
      final fake = _FakeTransport()
        ..claims = const <EncoderClaim>[
          EncoderClaim(
            codec: CaptureCodec.h265,
            name: 'c2.android.hevc.encoder',
            hardware: false,
          ),
        ];
      final probe = PlatformCodecProbe(transport: fake);
      await probe.availableCodecs();
      eq(
        'the first call records the skip',
        probe.skippedSoftware.join(','),
        'c2.android.hevc.encoder',
      );

      // A re-detect that now finds only hardware must not repeat the earlier
      // skip: the software encoder is gone from the platform, so reporting it
      // again would be stale.
      fake.claims = const <EncoderClaim>[
        EncoderClaim(
          codec: CaptureCodec.h264,
          name: 'c2.mtk.avc.encoder',
          hardware: true,
        ),
      ];
      await probe.availableCodecs();
      eq(
        'a later call does not accumulate earlier skips',
        probe.skippedSoftware.isEmpty,
        true,
      );
    }
  });

  await guard('encoded stream: subscription release', () async {
    section('encoded stream: subscription release');

    {
      // The adapter must stop being a live subscription once the consumer
      // stops listening. `NativeVideoEncoder` cancels its listener right after
      // `close()` resolves, and if nothing releases the transport subscription
      // then the adapter keeps adding packets to a controller nobody listens to
      // — once per recording, forever, on a kiosk that runs for weeks. The
      // cancel is therefore the signal that the tail has landed and the run is
      // over.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final stream = await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      );
      final subscription = stream.listen((_) {});
      await settle();
      eq(
        'the transport is subscribed while a consumer listens',
        fake.hasListeners,
        true,
      );

      await subscription.cancel();
      await settle();
      eq(
        'cancelling the consumer releases the transport subscription',
        fake.hasListeners,
        false,
      );
    }
  });

  await guard('encoded stream: reopen', () async {
    section('encoded stream: reopen');

    {
      // A second `open` on the same channel must replace the first run, not
      // add to it. Overwriting `_subscription` without cancelling the old one
      // would leave two live subscriptions on the plugin's broadcast stream,
      // and every event would be delivered twice — once into each stream.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 0,
        codec: CaptureCodec.h264,
      );
      final first = <EncodedPacket>[];
      final second = <EncodedPacket>[];
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(first.add);
      (await channel.open(
        cameraEnum: 0,
        width: 640,
        height: 480,
        fps: 30,
        quality: 80,
        sessionGeneration: 1,
      )).listen(second.add);
      await settle();

      fake.emit(_event(generation: 1, ptsUs: 100));
      await settle();

      eq('the replaced stream receives nothing', first.length, 0);
      eq(
        'the current stream receives the event exactly once',
        second.length,
        1,
      );
    }
  });

  await guard('encoded stream: camera enum check', () async {
    section('encoded stream: camera enum check');

    {
      // The announced `camera_enum` and the plugin's physical id are two
      // numbering schemes that this project has confused twice. A channel is
      // built against one announced camera; opening it for another would
      // stream one sensor while the registration described a different one,
      // silently. That is a construction bug, so it fails loud — before the
      // transport is touched — and the encoder above rolls its `_running` flag
      // back, making the device ack `ok:false` rather than record the wrong
      // camera.
      final fake = _FakeTransport();
      final channel = AndroidEncodedStreamChannel(
        transport: fake,
        cameraEnum: 0,
        cameraId: 2,
        codec: CaptureCodec.h264,
      );

      Object? error;
      try {
        await channel.open(
          cameraEnum: 1,
          width: 640,
          height: 480,
          fps: 30,
          quality: 80,
          sessionGeneration: 1,
        );
      } catch (e) {
        error = e;
      }
      await settle();

      eq('opening for a different camera throws', error is StateError, true);
      check(
        'and the message names both enums',
        error.toString().contains('0') && error.toString().contains('1'),
      );
      eq('and the transport was never opened', fake.openCalls, 0);
      eq('and nothing was subscribed', fake.hasListeners, false);
    }
  });
}
