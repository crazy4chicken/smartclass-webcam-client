import 'dart:async';
import 'dart:typed_data';

import 'camera_service.dart';

/// One picture produced by a [FramePump].
class CapturedFrame {
  const CapturedFrame({
    required this.seq,
    required this.ts,
    required this.bytes,
  });

  /// Monotonic counter for the stream this frame belongs to, starting at 0.
  ///
  /// It counts **capture attempts**, not successes, so a gap is exactly what a
  /// consumer needs to see: a frame that was attempted and did not make it.
  /// Ticks shed by the single-flight lock are not counted — the pump
  /// deliberately dropped those, they were never attempted.
  final int seq;

  final DateTime ts;

  /// One encoded picture. For `mjpeg` this is the JPEG file itself.
  final Uint8List bytes;

  int get byteLength => bytes.length;

  @override
  String toString() => 'CapturedFrame(#$seq, ${bytes.length}B)';
}

/// Drives a camera at a fixed rate and hands out the frames it produces.
///
/// Abstracted because the pump is the one place that has to change when a real
/// encoder (H.265/H.264) arrives: everything above it consumes [CapturedFrame]s
/// and does not care how they were produced.
abstract interface class FramePump {
  /// Starts producing frames. Calling it while running restarts the pump and
  /// resets the sequence.
  Future<void> start({
    required int cameraEnum,
    required String streamId,
    required int fps,
    required int quality,
  });

  /// Stops producing frames. Idempotent.
  Future<void> stop();

  Stream<CapturedFrame> get frames;
}

/// A [FramePump] built on the camera's still-picture path.
///
/// `takePicture()` is the only frame source that works on all five platforms
/// today, and its JPEG output *is* an `mjpeg` frame, so this pump is not a
/// stopgap — it is the codec the server calls `mjpeg`.
///
/// Two rules it must never break:
///
/// - **Never queue.** A tick that lands while the previous capture is still in
///   flight is dropped, not deferred. The lock is claimed before the first
///   `await` and released in `finally`.
/// - **Never stall.** A failed capture is skipped; the timer keeps ticking.
class TakePictureFramePump implements FramePump {
  TakePictureFramePump({
    required CameraService camera,
    DateTime Function()? clock,
  }) : _camera = camera,
       _clock = clock ?? DateTime.now;

  final CameraService _camera;
  final DateTime Function() _clock;

  final StreamController<CapturedFrame> _frames =
      StreamController<CapturedFrame>.broadcast();

  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;
  int _seq = 0;

  /// Frames the pump attempted and could not deliver.
  int _dropped = 0;

  /// The camera index this pump was started for.
  int _cameraEnum = 0;

  /// The stream this pump is feeding.
  String? _streamId;

  @override
  Stream<CapturedFrame> get frames => _frames.stream;

  int get cameraEnum => _cameraEnum;

  String? get streamId => _streamId;

  int get droppedFrames => _dropped;

  bool get isRunning => _running;

  @override
  Future<void> start({
    required int cameraEnum,
    required String streamId,
    required int fps,
    required int quality,
  }) async {
    await stop();
    if (fps < 1) {
      throw ArgumentError.value(fps, 'fps', 'must be a positive integer');
    }

    _cameraEnum = cameraEnum;
    _streamId = streamId;
    _seq = 0;
    _dropped = 0;
    _running = true;

    final intervalMs = (1000 / fps).round().clamp(1, 60000);
    _timer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _tick(quality),
    );
  }

  @override
  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _streamId = null;
  }

  Future<void> _tick(int quality) async {
    // Claim the lock before the first await, so a tick arriving during the
    // capture is shed instead of queued behind it.
    if (!_running || _inFlight) return;
    if (!_camera.isInitialized) return;

    _inFlight = true;
    final seq = _seq++;
    try {
      final bytes = await _camera.captureFrame(quality);
      if (bytes == null || bytes.isEmpty) {
        _dropped++;
        return;
      }
      if (!_running || _frames.isClosed) return;

      _frames.add(CapturedFrame(seq: seq, ts: _clock(), bytes: bytes));
    } catch (_) {
      // A failed capture is expected — a busy sensor, a transient driver
      // error — and must never stop the pump.
      _dropped++;
    } finally {
      // Must release on every path, including the early returns above.
      _inFlight = false;
    }
  }

  /// Releases the frame stream. The pump cannot be restarted afterwards.
  Future<void> dispose() async {
    await stop();
    await _frames.close();
  }
}
