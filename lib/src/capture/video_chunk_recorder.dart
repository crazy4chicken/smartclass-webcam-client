import 'dart:async';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import 'camera_resolution.dart';
import 'frame_store.dart';
import 'stream_settings.dart';

/// One self-contained video segment.
///
/// Every chunk is a standalone mp4 with its own `moov` box, so the backend can
/// decode each one independently. The cost is that latency equals the chunk
/// length.
class VideoChunk {
  const VideoChunk({
    required this.bytes,
    required this.codec,
    this.requestedCodec,
    required this.sequence,
    required this.durationMs,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;

  /// The codec actually produced.
  final VideoCodec codec;

  /// The codec the backend asked for, when it differs from [codec].
  final VideoCodec? requestedCodec;

  final int sequence;
  final int durationMs;
  final int width;
  final int height;

  /// True when the backend asked for something we could not deliver.
  ///
  /// Silent degradation is forbidden, so the caller turns this into a
  /// `capability_mismatch` signal.
  bool get isCodecMismatch => requestedCodec != null && requestedCodec != codec;
}

/// The recorder methods the chunk recorder needs from a camera.
///
/// A thin seam over `CameraController`, so the recording loop can be tested
/// without a camera.
abstract interface class RecorderHost {
  Future<void> startRecording();

  Future<XFile> stopRecording();

  Future<Uint8List> readFile(String path);
}

/// Records the capture stream as a sequence of timed chunks.
abstract interface class VideoChunkRecorder {
  Future<void> start({
    required VideoCodec codec,
    required int chunkSeconds,
    required CaptureConfig config,
  });

  Future<void> stop();

  Stream<VideoChunk> get chunks;

  /// What this recorder can actually encode.
  Set<VideoCodec> get supportedCodecs;
}

/// [VideoChunkRecorder] built on the camera plugin's own recorder.
///
/// The three plugin implementations (`camera_desktop`, `camera_avfoundation`,
/// `camera_android_camerax`) all hardcode H.264 and expose no codec parameter,
/// so [supportedCodecs] is `{avc}`. Requesting HEVC still records AVC, and the
/// mismatch travels with the chunk instead of being silently swallowed.
///
/// Adding real HEVC later means adding another [VideoChunkRecorder]
/// implementation and listing its codecs — nothing here changes.
class CameraPluginVideoChunkRecorder implements VideoChunkRecorder {
  CameraPluginVideoChunkRecorder({
    RecorderHost? host,
    FrameStore fileStore = const IoFrameStore(),
  }) : _host = host,
       _fileStore = fileStore;

  final FrameStore _fileStore;

  RecorderHost? _host;

  /// Late-bound: the camera only exists after the backend opens it.
  set host(RecorderHost? value) => _host = value;

  final StreamController<VideoChunk> _chunks =
      StreamController<VideoChunk>.broadcast();

  Timer? _timer;
  bool _running = false;
  bool _recording = false;
  bool _rotating = false;
  int _sequence = 0;
  VideoCodec _requestedCodec = VideoCodec.avc;
  int _chunkSeconds = 3;
  CaptureConfig _config = const CaptureConfig(
    width: 1280,
    height: 720,
    quality: 80,
  );
  DateTime? _segmentStartedAt;

  @override
  Stream<VideoChunk> get chunks => _chunks.stream;

  @override
  Set<VideoCodec> get supportedCodecs => const <VideoCodec>{VideoCodec.avc};

  @override
  Future<void> start({
    required VideoCodec codec,
    required int chunkSeconds,
    required CaptureConfig config,
  }) async {
    if (_running) {
      await stop();
    }
    _requestedCodec = codec;
    _chunkSeconds = chunkSeconds > 0 ? chunkSeconds : 3;
    _config = config;
    _sequence = 0;
    _running = true;

    await _openSegment();
    if (!_running) return;

    _timer = Timer.periodic(Duration(seconds: _chunkSeconds), (_) => _rotate());
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    // Flush whatever is in flight so the tail of the session is not lost.
    await _closeSegment();
  }

  Future<void> _rotate() async {
    // A tick that lands while the previous rotation is still running is
    // dropped rather than queued.
    if (!_running || _rotating) return;
    _rotating = true;
    try {
      await _closeSegment();
      if (_running) {
        await _openSegment();
      }
    } finally {
      _rotating = false;
    }
  }

  Future<void> _openSegment() async {
    final host = _host;
    if (host == null) return;
    try {
      await host.startRecording();
      _recording = true;
      _segmentStartedAt = DateTime.now();
    } catch (_) {
      _recording = false;
    }
  }

  Future<void> _closeSegment() async {
    final host = _host;
    if (host == null || !_recording) return;
    _recording = false;

    try {
      final file = await host.stopRecording();
      final bytes = await host.readFile(file.path);
      await _fileStore.delete(file.path);

      final startedAt = _segmentStartedAt;
      final durationMs = startedAt == null
          ? _chunkSeconds * 1000
          : DateTime.now().difference(startedAt).inMilliseconds;

      if (bytes.isEmpty || _chunks.isClosed) return;
      _chunks.add(
        VideoChunk(
          bytes: bytes,
          // The plugin can only ever produce AVC; report what really ran.
          codec: VideoCodec.avc,
          requestedCodec: _requestedCodec,
          sequence: _sequence++,
          durationMs: durationMs,
          width: _config.width,
          height: _config.height,
        ),
      );
    } catch (_) {
      // A lost segment must not kill the recording loop.
    }
  }
}
