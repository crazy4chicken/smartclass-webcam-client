import 'dart:async';
import 'dart:typed_data';

import 'camera_service.dart';
import 'frame_pump.dart';
import 'stream_settings.dart';

/// One encoded video frame, ready to become a `recording.frame` payload.
class EncodedFrame {
  const EncodedFrame({
    required this.seq,
    required this.ts,
    required this.bytes,
    required this.isKeyFrame,
  });

  final int seq;
  final DateTime ts;

  /// One encoded access unit. For `mjpeg`, one JPEG picture.
  final Uint8List bytes;

  /// True when the frame can be decoded on its own.
  ///
  /// Every `mjpeg` frame is a key frame. For a predictive codec this is the
  /// frame that must carry VPS/SPS/PPS, because the server stores bare frames
  /// concatenated with no container — a downstream consumer that starts
  /// mid-stream has nothing else to sync on.
  final bool isKeyFrame;

  @override
  String toString() => 'EncodedFrame(#$seq, ${bytes.length}B, key=$isKeyFrame)';
}

/// Turns camera frames into encoded frames of one [codec].
///
/// Two implementations, and the difference between them is where the encoding
/// happens. [MjpegEncoder] takes JPEGs off the still-picture path — not a
/// placeholder, since a JPEG *is* an mjpeg frame — and is capped by the cost of
/// `takePicture()` at roughly 5-10 fps at 1080p. [NativeVideoEncoder] receives
/// bytes a native plugin has already encoded, which is the only way past that
/// ceiling, because the limit is in the capture path and not in the codec.
///
/// Which one a recording gets is the coordinator's choice, made per stream
/// from the codec the server asked for and what the device measurably holds.
abstract interface class VideoEncoder {
  CaptureCodec get codec;

  /// The camera this encoder is bound to.
  int get cameraEnum;

  /// The stream the encoder is feeding.
  String get streamId;

  /// [width] / [height] are absolute pixels, never a `ResolutionPreset`.
  Future<void> start({
    required int width,
    required int height,
    required int fps,
    required int quality,
  });

  Future<void> stop();

  Stream<EncodedFrame> get frames;
}

/// [VideoEncoder] that passes JPEG frames straight through.
///
/// No transcoding happens, and none is needed: a JPEG *is* an mjpeg frame. The
/// camera index and stream id are fixed at construction because the server
/// mints a stream per recording, so an encoder never outlives its stream.
class MjpegEncoder implements VideoEncoder {
  MjpegEncoder({
    required CameraService camera,
    required this.cameraEnum,
    required this.streamId,
    FramePump? pump,
  }) : _pump = pump ?? TakePictureFramePump(camera: camera);

  final FramePump _pump;
  StreamSubscription<CapturedFrame>? _subscription;

  final StreamController<EncodedFrame> _frames =
      StreamController<EncodedFrame>.broadcast();

  @override
  final int cameraEnum;

  @override
  final String streamId;

  @override
  CaptureCodec get codec => CaptureCodec.mjpeg;

  @override
  Stream<EncodedFrame> get frames => _frames.stream;

  @override
  Future<void> start({
    required int width,
    required int height,
    required int fps,
    required int quality,
  }) async {
    await _subscription?.cancel();
    _subscription = _pump.frames.listen(_onCaptured);
    await _pump.start(
      cameraEnum: cameraEnum,
      streamId: streamId,
      fps: fps,
      quality: quality,
    );
  }

  void _onCaptured(CapturedFrame frame) {
    if (_frames.isClosed) return;
    _frames.add(
      EncodedFrame(
        seq: frame.seq,
        ts: frame.ts,
        bytes: frame.bytes,
        // A JPEG carries everything needed to decode it, so every frame is a
        // key frame and a consumer can start anywhere.
        isKeyFrame: true,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _pump.stop();
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
