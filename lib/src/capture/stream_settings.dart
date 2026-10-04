import '../config/app_config.dart';

/// The codecs this client can produce, named exactly as the wire expects.
///
/// The vocabulary is a closed set shared with the server: `h264`, `h265`,
/// `mjpeg`, `mpeg4`, `vp8`, `vp9`, `av1`, all exact lowercase. There is no
/// alias handling anywhere — `hevc` is H.265's other name but is **rejected**
/// by the server, so [wireName] must never produce it.
///
/// This is deliberately a separate enum from the backend layer's `WireCodec`:
/// the capture layer must not depend on the wire protocol, and the two are
/// only kept honest by asserting that their names match.
enum CaptureCodec {
  h265,
  h264,
  mjpeg,
  mpeg4,
  vp8,
  vp9,
  av1;

  /// The exact string that must appear on the wire.
  String get wireName => name;

  /// Selection order, best first.
  ///
  /// `mjpeg` is the guaranteed floor rather than a compromise: `takePicture()`
  /// already produces JPEG, so one `recording.frame` per picture is exactly
  /// what the server's `mjpeg` definition asks for. The two video codecs above
  /// it need an encoder this client does not ship yet.
  static const List<CaptureCodec> preference = <CaptureCodec>[
    CaptureCodec.h265,
    CaptureCodec.h264,
    CaptureCodec.mjpeg,
  ];

  /// True for codecs whose output is one self-contained picture per frame.
  bool get isIntraOnly => this == CaptureCodec.mjpeg;

  static CaptureCodec? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final codec in CaptureCodec.values) {
      if (codec.wireName == raw) return codec;
    }
    return null;
  }
}

/// The capture configuration agreed with the server.
///
/// There is no stream *mode* any more: the server has exactly one media shape
/// (one encoded frame per `recording.frame`), and the choice between stills
/// and video is expressed by the codec, not by a separate mode flag.
class StreamSettings {
  const StreamSettings({
    required this.codec,
    required this.fps,
    required this.quality,
    required this.previewEnabled,
  });

  /// What the client will actually encode.
  final CaptureCodec codec;

  /// Declared frame rate. Must be a positive **integer**: the server rejects a
  /// JSON fraction like `29.97` outright, and snapshots this value into the
  /// stream's `metadata.fps` to estimate segment durations.
  final int fps;

  /// JPEG quality (1-100). Advisory only — the camera plugin encodes the JPEG
  /// itself and exposes no quality knob.
  final int quality;

  /// Preview is a purely local concern; the server has no command for it.
  final bool previewEnabled;

  /// Defaults assume the floor: `mjpeg` is available on every platform, so the
  /// pipeline works before any codec probe has run.
  factory StreamSettings.defaults() => const StreamSettings(
    codec: CaptureCodec.mjpeg,
    fps: AppConfig.defaultFps,
    quality: AppConfig.defaultQuality,
    previewEnabled: AppConfig.defaultPreviewEnabled,
  );

  StreamSettings copyWith({
    CaptureCodec? codec,
    int? fps,
    int? quality,
    bool? previewEnabled,
  }) => StreamSettings(
    codec: codec ?? this.codec,
    fps: fps ?? this.fps,
    quality: quality ?? this.quality,
    previewEnabled: previewEnabled ?? this.previewEnabled,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamSettings &&
          other.codec == codec &&
          other.fps == fps &&
          other.quality == quality &&
          other.previewEnabled == previewEnabled;

  @override
  int get hashCode => Object.hash(codec, fps, quality, previewEnabled);

  @override
  String toString() =>
      'StreamSettings(${codec.wireName}, ${fps}fps, q$quality, '
      'preview=$previewEnabled)';
}
