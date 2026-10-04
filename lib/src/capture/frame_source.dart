import 'dart:typed_data';

import 'camera_resolution.dart';
import 'frame_store.dart';

/// Produces the bytes of one still frame.
abstract interface class FrameSource {
  Future<void> start(CaptureConfig config);

  Future<void> stop();

  /// Returns the frame bytes, or null when the frame could not be produced.
  Future<Uint8List?> nextFrame(int quality);
}

/// Asks the platform to write a picture to a temp path.
typedef PicturePathTaker = Future<String> Function();

/// [FrameSource] that captures via the platform's still-picture API.
///
/// The file is read and deleted in one step, so no temp files accumulate.
class TakePictureFrameSource implements FrameSource {
  TakePictureFrameSource({
    required PicturePathTaker takePicture,
    FrameStore frameStore = const IoFrameStore(),
  }) : _takePicture = takePicture,
       _frameStore = frameStore;

  final PicturePathTaker _takePicture;
  final FrameStore _frameStore;

  bool _running = false;

  @override
  Future<void> start(CaptureConfig config) async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  /// [quality] is advisory only.
  ///
  /// The camera plugin encodes the JPEG itself and exposes no quality knob, so
  /// the value is carried for protocol symmetry but cannot be applied here.
  @override
  Future<Uint8List?> nextFrame(int quality) async {
    if (!_running) return null;
    try {
      final path = await _takePicture();
      return await _frameStore.readAndDelete(path);
    } catch (_) {
      // A dropped frame is normal; never queue, never rethrow into the loop.
      return null;
    }
  }
}

/// Frame source that would tap the platform's raw image stream.
///
/// **Not implemented in v1.** Continuous frame delivery is already covered by
/// [TakePictureFrameSource] polling and by the video chunk recorder, and raw
/// image streams have per-platform format differences (BGRA / YUV420 / NV21)
/// that would need a converter. The interface is left in place so it can be
/// added later without touching the coordinator.
class ImageStreamFrameSource implements FrameSource {
  @override
  Future<void> start(CaptureConfig config) async {
    throw UnimplementedError('ImageStreamFrameSource is not implemented in v1');
  }

  @override
  Future<void> stop() async {
    throw UnimplementedError('ImageStreamFrameSource is not implemented in v1');
  }

  @override
  Future<Uint8List?> nextFrame(int quality) async {
    throw UnimplementedError('ImageStreamFrameSource is not implemented in v1');
  }
}
