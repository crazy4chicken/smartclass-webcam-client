import '../config/app_config.dart';

/// How the client feeds the backend: discrete still frames or timed video
/// chunks. Decided by the backend via `cmd_set_stream_mode`, never assumed.
enum StreamMode {
  still,
  video;

  static StreamMode? tryParse(String? raw) {
    switch (raw) {
      case 'still':
        return StreamMode.still;
      case 'video':
        return StreamMode.video;
      default:
        return null;
    }
  }

  String get wireName => name;
}

/// Video container codec.
///
/// v1 can only *encode* [avc] because every camera plugin implementation
/// hardcodes H.264. [hevc] exists so the capability bit and the degradation
/// path are already in place; requesting it yields `capability_mismatch`.
enum VideoCodec {
  avc,
  hevc;

  static VideoCodec? tryParse(String? raw) {
    switch (raw) {
      case 'avc':
        return VideoCodec.avc;
      case 'hevc':
        return VideoCodec.hevc;
      default:
        return null;
    }
  }

  String get wireName => name;
}

/// The full mutable capture configuration agreed with the backend.
class StreamSettings {
  const StreamSettings({
    required this.mode,
    required this.codec,
    required this.chunkSeconds,
    required this.previewEnabled,
  });

  final StreamMode mode;
  final VideoCodec codec;
  final int chunkSeconds;
  final bool previewEnabled;

  /// Defaults are chosen for maximum cross-platform support: AVC is the only
  /// codec all three camera plugin implementations can produce.
  factory StreamSettings.defaults() => const StreamSettings(
    mode: StreamMode.video,
    codec: VideoCodec.avc,
    chunkSeconds: AppConfig.defaultChunkSeconds,
    previewEnabled: AppConfig.defaultPreviewEnabled,
  );

  StreamSettings copyWith({
    StreamMode? mode,
    VideoCodec? codec,
    int? chunkSeconds,
    bool? previewEnabled,
  }) => StreamSettings(
    mode: mode ?? this.mode,
    codec: codec ?? this.codec,
    chunkSeconds: chunkSeconds ?? this.chunkSeconds,
    previewEnabled: previewEnabled ?? this.previewEnabled,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamSettings &&
          other.mode == mode &&
          other.codec == codec &&
          other.chunkSeconds == chunkSeconds &&
          other.previewEnabled == previewEnabled;

  @override
  int get hashCode => Object.hash(mode, codec, chunkSeconds, previewEnabled);

  @override
  String toString() =>
      'StreamSettings(${mode.name}/${codec.name}, ${chunkSeconds}s, '
      'preview=$previewEnabled)';
}
