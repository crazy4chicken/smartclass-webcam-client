import 'dart:async';
import 'dart:typed_data';

import 'annexb.dart';
import 'serial_lock.dart';
import 'stream_settings.dart';
import 'video_encoder.dart';

/// One packet handed over by a native encoder.
///
/// The native side works in the encoder's units, not the wire's: a packet may
/// be a parameter set on its own, a whole key frame with its parameter sets in
/// front of it, or — during a flush — several pictures at once. What Dart
/// needs from it is therefore four things, not one: the bytes, how many whole
/// pictures the encoder believes those bytes carry, where in the capture those
/// pictures came from, and which recording they belong to.
class EncodedPacket {
  const EncodedPacket({
    required this.bytes,
    required this.pictures,
    required this.sourceSeq,
    required this.sessionGeneration,
    this.sourcePts,
    this.isEos = false,
  });

  /// The bytes exactly as the encoder produced them, start codes included.
  final Uint8List bytes;

  /// Whole pictures the encoder says [bytes] contains.
  ///
  /// Zero is a legitimate answer and not an error: a packet carrying only
  /// VPS/SPS/PPS or SEI holds no picture. It is still part of the stream —
  /// what it carries belongs in front of the next picture — so it must be
  /// delivered, not skipped.
  ///
  /// This is the count the splitter's output is checked against, which is the
  /// whole reason it travels with the bytes. Annex B has no length prefix, so
  /// nothing in the bytes themselves says how many pictures they were supposed
  /// to hold; without a second opinion a stream that lost a NAL in transit
  /// looks exactly like one that was always short.
  final int pictures;

  /// The capture-side sequence number of the **first** picture in [bytes].
  ///
  /// Not this encoder's own counter, and not a re-numbering done on the Dart
  /// side: it has to come from the capture path, because the only thing that
  /// can tell a delivered picture from a repeated one is whether this number
  /// moved. A channel that numbered its own packets would never repeat one,
  /// and a rate meter fed from it would report the tick rate — the number a
  /// `videorate` pipeline pads its output up to — as the delivery rate.
  ///
  /// A packet holding several pictures numbers them [sourceSeq],
  /// [sourceSeq] + 1, and so on: a flush emits pictures that really were
  /// consecutive, and the packet only says where that run starts.
  final int sourceSeq;

  /// The capture-side presentation timestamp of the first picture, when the
  /// producer knows one.
  ///
  /// Null is a legitimate answer and not a defect: not every plugin API
  /// exposes a PTS, and a fabricated one would be worse than an absent one.
  /// Carried through to [EncodedFrame.sourcePts] for the measurement path;
  /// the encoder itself does not consume it.
  final Duration? sourcePts;

  /// The recording this packet belongs to, as [EncodedStreamChannel.open] was
  /// told when it was opened.
  ///
  /// A native plugin is a process-wide singleton whose capture callback can
  /// still fire after Dart has torn the previous recording down. Without this
  /// there is no way to tell such a packet from one belonging to the stream
  /// being started, and it would be filed under the new stream's id — the tail
  /// of the last recording surfacing inside the next one.
  final int sessionGeneration;

  /// True on the producer's last packet: the tail it was still holding when it
  /// was told to stop.
  ///
  /// Optional in-band evidence that the flush reached Dart. `close()` resolving
  /// is still the authority on the stream being over; this is what says the
  /// producer *declared* it, which is the difference between a recording that
  /// ended and one that was cut short.
  final bool isEos;

  @override
  String toString() =>
      'EncodedPacket(${bytes.length}B, ${pictures}p, src#$sourceSeq, '
      'gen$sessionGeneration${isEos ? ', eos' : ''})';
}

/// The plugin-facing half of an encoded stream.
///
/// Everything native lives behind this interface, so the encoder below is pure
/// Dart and `tool/verify_pure.dart` can exercise it with a fake. An
/// implementation opens one stream per recording: the server mints a stream id
/// per `start_recording`, so nothing here outlives a single recording.
abstract interface class EncodedStreamChannel {
  /// Opens the encoded stream for [cameraEnum] at [width]x[height] and [fps].
  ///
  /// Resolves once the pipeline is producing; every packet after that arrives
  /// on the returned stream. [width] / [height] are absolute pixels, never a
  /// `ResolutionPreset`.
  ///
  /// [sessionGeneration] names this run. The producer must echo it on every
  /// packet, and must not let a packet from an earlier run carry the current
  /// value — see [EncodedPacket.sessionGeneration].
  Future<Stream<EncodedPacket>> open({
    required int cameraEnum,
    required int width,
    required int height,
    required int fps,
    required int quality,
    required int sessionGeneration,
  });

  /// Stops the pipeline, after flushing whatever the encoder still holds.
  ///
  /// A native encoder buffers: pictures it has accepted but not yet emitted
  /// are stuck inside it until it is told to flush. So [close] is not a
  /// request to stop *now* — packets may still arrive after it resolves, and
  /// the caller keeps consuming until the stream is done. Cancelling a
  /// subscription before the flush lands throws away the tail of the
  /// recording, and the server has no way to notice a recording that ends
  /// a few frames early.
  Future<void> close();
}

/// A [VideoEncoder] fed by a native encoded stream.
///
/// The bytes arriving here are already compressed: capture and encoding happen
/// inside the plugin, and only access units cross into Dart. That is the point
/// of the whole native path — the still-picture pump it can replace is capped
/// at roughly 5-10 fps at 1080p by the cost of `takePicture()`, and no encoder
/// attached downstream of that can lift the ceiling.
///
/// What this class adds on top of the plugin is the shaping the wire needs.
/// [AnnexBSplitter] turns the packet stream into access units — attaching each
/// picture to the parameter sets that precede it, even when a chunk boundary
/// falls between the two — and each unit becomes one [EncodedFrame].
///
/// Two rules decide what is emitted:
///
/// * **A packet is all or nothing.** If cutting a packet yields a different
///   number of units than [EncodedPacket.pictures] claims, every unit from it
///   is dropped. The bytes are then not what the encoder said they were, and
///   an access unit that cannot be decoded is worse than a frame that never
///   arrived: the server stores `recording.frame` bodies verbatim with no
///   container and cannot tell the two apart.
/// * **A packet must not end inside a picture NAL.** The splitter takes the
///   last NAL of a chunk as complete, so the remainder of a picture split
///   across two packets would arrive with no start code in front of it and be
///   dropped. Non-VCL NALs are exempt — they are held — which is exactly why
///   parameter sets may travel on their own.
///
/// Two rules decide what is *not* emitted:
///
/// * **A packet from a previous run is dropped.** See
///   [EncodedPacket.sessionGeneration] and [stalePackets].
/// * **A packet arriving after the stream is closed is dropped.** See
///   [latePackets].
///
/// Only [CaptureCodec.h264] and [CaptureCodec.h265] are encodable here: they
/// are the only two codecs with an Annex B form. `mjpeg` needs no encoder at
/// all — a JPEG *is* an mjpeg frame — and is served by [MjpegEncoder].
class NativeVideoEncoder implements VideoEncoder {
  NativeVideoEncoder({
    required this.codec,
    required this.cameraEnum,
    required this.streamId,
    required EncodedStreamChannel channel,
    DateTime Function()? clock,
  }) : _channel = channel,
       _clock = clock ?? DateTime.now {
    if (codec != CaptureCodec.h264 && codec != CaptureCodec.h265) {
      throw ArgumentError.value(
        codec,
        'codec',
        'only h264 and h265 have an Annex B form',
      );
    }
  }

  @override
  final CaptureCodec codec;

  @override
  final int cameraEnum;

  @override
  final String streamId;

  final EncodedStreamChannel _channel;
  final DateTime Function() _clock;

  final StreamController<EncodedFrame> _frames =
      StreamController<EncodedFrame>.broadcast();

  StreamSubscription<EncodedPacket>? _subscription;

  /// Cutting across packet boundaries. Replaced on every [start].
  AnnexBSplitter? _splitter;

  /// Serialises [start] and [stop].
  ///
  /// Both tear the channel down and build a new one, and the plugin call
  /// underneath cannot overlap with itself. Unserialised, a `start` racing a
  /// `stop` can close a channel the other call has just opened, or leave the
  /// encoder subscribed to a stream nobody is feeding.
  final SerialLock _lifecycle = SerialLock();

  /// Which run the packets on the current subscription belong to.
  ///
  /// Bumped on every [start], so a packet from the run before is identifiable
  /// rather than indistinguishable from a current one.
  int _generation = 0;

  /// Set before the producer is started and kept true until the channel's
  /// close has resolved, so a packet arriving during the flush that [stop]
  /// triggers is still one this encoder owns rather than a late one.
  bool _running = false;

  /// Whether [EncodedStreamChannel.open] has been called for this run.
  ///
  /// [start] calls [stop] first to reset, and a channel that was never opened
  /// has nothing to flush and no subscription to cancel — closing it anyway
  /// would tell a plugin that was never asked to produce anything to stop.
  bool _opened = false;

  /// Whether the producer marked a packet [EncodedPacket.isEos] during the run
  /// that just ended.
  ///
  /// False after a recording means the flush never announced itself: the tail
  /// may be short and the server cannot tell. Reported rather than acted on —
  /// `close()` resolving is what ends the stream, and *requiring* an EOS would
  /// break every producer that does not send one.
  bool _sawEos = false;

  int _seq = 0;

  /// Packets whose unit count did not match, and the units they were dropped
  /// for. Both are diagnostic: neither is ever emitted.
  int _droppedPackets = 0;
  int _droppedUnits = 0;

  /// Packets rejected because the stream was already closed, or because the
  /// plugin reported an error.
  int _latePackets = 0;

  /// Packets rejected because they belonged to a previous run. See
  /// [EncodedPacket.sessionGeneration].
  int _stalePackets = 0;

  @override
  Stream<EncodedFrame> get frames => _frames.stream;

  int get droppedPackets => _droppedPackets;
  int get droppedUnits => _droppedUnits;
  int get latePackets => _latePackets;
  int get stalePackets => _stalePackets;

  /// Whether the producer declared the end of the last completed run.
  bool get sawEos => _sawEos;

  /// Whether a run is currently claimed — that is, whether a producer has been
  /// asked to start and has not been flushed out yet.
  bool get isRunning => _running;

  @override
  Future<void> start({
    required int width,
    required int height,
    required int fps,
    required int quality,
  }) => _lifecycle.run(
    () =>
        _startLocked(width: width, height: height, fps: fps, quality: quality),
  );

  Future<void> _startLocked({
    required int width,
    required int height,
    required int fps,
    required int quality,
  }) async {
    await _stopLocked();
    _seq = 0;
    _splitter = AnnexBSplitter(codec: codec);
    // A new run gets a new generation, so a packet still in flight from the
    // last one is rejected instead of being filed under this stream's id.
    _generation++;
    _sawEos = false;

    // Claimed before the producer is started: a packet must never arrive at an
    // encoder that does not yet consider itself running.
    _running = true;
    final Stream<EncodedPacket> stream;
    try {
      stream = await _channel.open(
        cameraEnum: cameraEnum,
        width: width,
        height: height,
        fps: fps,
        quality: quality,
        sessionGeneration: _generation,
      );
    } catch (_) {
      // Nothing is producing, so nothing may stay claimed: leaving `_running`
      // set would make a later `stop` believe there is a live pipeline to
      // flush and a subscription to cancel.
      _running = false;
      _splitter = null;
      rethrow;
    }
    _opened = true;
    _subscription = stream.listen(
      _onPacket,
      onError: (_) {
        // A dead pipeline is not a reason to tear down the recording's Dart
        // side: the coordinator stops the stream itself, and a late error must
        // not turn into an unhandled one. Counted, so "the plugin went quiet
        // and then failed" stays visible instead of silent.
        _latePackets++;
      },
      cancelOnError: false,
    );
  }

  void _onPacket(EncodedPacket packet) {
    if (!_running || _frames.isClosed) {
      _latePackets++;
      return;
    }

    // A packet from a previous run. Its bytes are real, but they belong to a
    // stream that has already been stopped and accounted for, so emitting them
    // would put the tail of the last recording into this one.
    if (packet.sessionGeneration != _generation) {
      _stalePackets++;
      return;
    }

    if (packet.isEos) _sawEos = true;

    final units = _splitter!.add(packet.bytes);

    // The one cross-check Annex B allows. Equal means the bytes cut into
    // exactly the pictures the encoder said it wrote; anything else means the
    // two disagree about what was produced, and there is no way to tell which
    // side is wrong from here — so nothing from this packet is emitted.
    if (units.length != packet.pictures) {
      _droppedPackets++;
      _droppedUnits += units.length;
      return;
    }

    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      _frames.add(
        EncodedFrame(
          seq: _seq++,
          ts: _clock(),
          bytes: unit.bytes,
          isKeyFrame: unit.isKeyFrame,
          // Pictures in one packet were consecutive in the capture, so the
          // run starts at the packet's own sequence and advances by one.
          sourceSeq: packet.sourceSeq + i,
          // Only the first picture of a packet can be placed in time: the
          // packet says where its run starts and nothing about the spacing
          // inside it, and inventing an interval would fabricate timestamps.
          sourcePts: i == 0 ? packet.sourcePts : null,
        ),
      );
    }
  }

  @override
  Future<void> stop() => _lifecycle.run(_stopLocked);

  Future<void> _stopLocked() async {
    if (!_opened) return;
    _opened = false;

    // Closing before cancelling is what lets the flush through: the plugin
    // pushes its buffered pictures and only then closes the stream, and this
    // awaits that before the subscription — and with it the tail of the
    // recording — is thrown away. Staying `_running` until the close resolves
    // is what makes those last packets owned rather than late.
    try {
      await _channel.close();
    } finally {
      // Reset even if the close failed: the run is over either way, and an
      // encoder left claiming a pipeline it no longer has would accept the
      // next run's packets as if they were this one's.
      _running = false;
      _splitter = null;
      final subscription = _subscription;
      _subscription = null;
      // **Deliberately not awaited**, and this is the whole ordering rule:
      // `close` resolving is what guarantees the tail, because the producer
      // has flushed and the stream is done by then. Cancelling is therefore
      // housekeeping rather than the thing that preserves the recording, and
      // a single-subscription stream only completes its cancel on a later
      // turn — awaiting it would make the next `start` wait on the teardown
      // of a stream that can no longer deliver anything.
      unawaited(subscription?.cancel());
    }
  }

  /// Releases the frame stream. The encoder cannot be restarted afterwards.
  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
