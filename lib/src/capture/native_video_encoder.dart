import 'dart:async';
import 'dart:typed_data';

import 'annexb.dart';
import 'stream_settings.dart';
import 'video_encoder.dart';

/// One packet handed over by a native encoder.
///
/// The native side works in the encoder's units, not the wire's: a packet may
/// be a parameter set on its own, a whole key frame with its parameter sets in
/// front of it, or — during a flush — several pictures at once. What Dart
/// needs from it is therefore two things, not one: the bytes, and how many
/// whole pictures the encoder believes those bytes carry.
class EncodedPacket {
  const EncodedPacket({required this.bytes, required this.pictures});

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

  @override
  String toString() => 'EncodedPacket(${bytes.length}B, ${pictures}p)';
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
  Future<Stream<EncodedPacket>> open({
    required int cameraEnum,
    required int width,
    required int height,
    required int fps,
    required int quality,
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

  int _seq = 0;

  /// Packets whose unit count did not match, and the units they were dropped
  /// for. Both are diagnostic: neither is ever emitted.
  int _droppedPackets = 0;
  int _droppedUnits = 0;

  /// Packets rejected because the stream was already closed, or because the
  /// plugin reported an error.
  int _latePackets = 0;

  @override
  Stream<EncodedFrame> get frames => _frames.stream;

  int get droppedPackets => _droppedPackets;
  int get droppedUnits => _droppedUnits;
  int get latePackets => _latePackets;

  @override
  Future<void> start({
    required int width,
    required int height,
    required int fps,
    required int quality,
  }) async {
    await stop();
    _seq = 0;
    _splitter = AnnexBSplitter(codec: codec);

    // Claimed before the producer is started: a packet must never arrive at an
    // encoder that does not yet consider itself running.
    _running = true;
    final stream = await _channel.open(
      cameraEnum: cameraEnum,
      width: width,
      height: height,
      fps: fps,
      quality: quality,
    );
    _opened = true;
    _subscription = stream.listen(
      _onPacket,
      onError: (_) {
        // A dead pipeline is not a reason to tear down the recording's Dart
        // side: the coordinator stops the stream itself, and a late error must
        // not turn into an unhandled one.
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

    for (final unit in units) {
      _frames.add(
        EncodedFrame(
          seq: _seq++,
          ts: _clock(),
          bytes: unit.bytes,
          isKeyFrame: unit.isKeyFrame,
        ),
      );
    }
  }

  @override
  Future<void> stop() async {
    if (!_opened) return;
    _opened = false;

    // Closing before cancelling is what lets the flush through: the plugin
    // pushes its buffered pictures and only then closes the stream, and this
    // awaits that before the subscription — and with it the tail of the
    // recording — is thrown away. Staying `_running` until the close resolves
    // is what makes those last packets owned rather than late.
    await _channel.close();
    _running = false;
    await _subscription?.cancel();
    _subscription = null;
    _splitter = null;
  }

  /// Releases the frame stream. The encoder cannot be restarted afterwards.
  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
