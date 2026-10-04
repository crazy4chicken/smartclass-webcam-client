import '../capture/camera_resolution.dart';
import '../capture/stream_settings.dart';
import 'protocol/envelope.dart';

/// One camera as announced to the server on `GET /ws/register`.
///
/// The server validates this hard and rejects the whole registration on the
/// first problem, so the rules are enforced here instead:
///
/// - `camera_enum` must equal the element's index in the array,
/// - `resolution` must be a non-empty string (`WIDTHxHEIGHT` by convention),
/// - `fps` must be a positive **integer** — `29.97` is a decode error, not a
///   rounded value,
/// - `supported_codec` must be non-empty, drawn from the closed
///   [WireCodec] set, and free of duplicates.
///
/// `attrs` is free-form and never persisted; a label is a useful convention.
class CameraAnnouncement {
  const CameraAnnouncement({
    required this.cameraEnum,
    required this.resolution,
    required this.fps,
    required this.supportedCodec,
    this.attrs = const <String, Object?>{},
  });

  final int cameraEnum;

  /// `WIDTHxHEIGHT` in pixels. The server never parses it; it snapshots the
  /// string into the stream's `metadata.resolution`.
  final String resolution;

  /// Positive integer. Snapshotted into `metadata.fps` and used to estimate
  /// segment durations, so declaring a rate the device cannot hold makes the
  /// server overstate how long a segment lasted.
  final int fps;

  final List<WireCodec> supportedCodec;

  final Map<String, Object?> attrs;

  Map<String, Object?> toJson() => {
    'camera_enum': cameraEnum,
    'resolution': resolution,
    'fps': fps,
    'supported_codec': [for (final codec in supportedCodec) codec.wireName],
    if (attrs.isNotEmpty) 'attrs': attrs,
  };

  @override
  String toString() =>
      'CameraAnnouncement($cameraEnum, $resolution, ${fps}fps, '
      '${supportedCodec.map((c) => c.wireName).join('/')})';
}

/// Lowest rate the server accepts; anything below is clamped up to it.
const int minAnnounceableFps = 1;

/// Translates capture-layer codecs into the wire vocabulary.
///
/// The two enums are deliberately separate — the capture layer must not depend
/// on the wire protocol — so the only thing keeping them honest is that their
/// names are identical. This is the single place that assumes it, which is why
/// it is a function with its own test rather than a cast buried in bootstrap.
///
/// Order follows [CaptureCodec.preference]; anything the probe found that is
/// not in the preference list is appended so a capability is never silently
/// dropped from the announcement.
List<WireCodec> wireCodecsFor(Set<CaptureCodec> available) {
  final ordered = <CaptureCodec>[
    for (final codec in CaptureCodec.preference)
      if (available.contains(codec)) codec,
    for (final codec in CaptureCodec.values)
      if (available.contains(codec) && !CaptureCodec.preference.contains(codec))
        codec,
  ];

  return <WireCodec>[
    for (final codec in ordered)
      WireCodec.values.firstWhere((wire) => wire.wireName == codec.wireName),
  ];
}

/// Builds the camera list for one registration.
///
/// [cameraNames] and [resolutions] are positional: entry `i` describes camera
/// `i`, and `camera_enum` is always the index. A short [resolutions] list
/// falls back to the last known resolution rather than inventing one.
///
/// The camera name always travels in `attrs.label`: it is the only way the
/// platform camera name reaches an operator, and `attrs` is exactly what the
/// protocol reserves for device-specific data.
List<CameraAnnouncement> buildAnnouncements({
  required List<String> cameraNames,
  required List<CameraResolution> resolutions,
  required int fps,
  required List<WireCodec> codecs,
  Map<String, Object?> attrs = const <String, Object?>{},
}) {
  final safeFps = fps < minAnnounceableFps ? minAnnounceableFps : fps;
  final safeCodecs = codecs.isEmpty
      ? const <WireCodec>[WireCodec.mjpeg]
      : codecs;
  final fallback = resolutions.isNotEmpty
      ? resolutions.last
      : const CameraResolution(width: 1280, height: 720);

  return <CameraAnnouncement>[
    for (var i = 0; i < cameraNames.length; i++)
      CameraAnnouncement(
        cameraEnum: i,
        resolution: (i < resolutions.length ? resolutions[i] : fallback).label,
        fps: safeFps,
        supportedCodec: List<WireCodec>.unmodifiable(safeCodecs),
        attrs: <String, Object?>{...attrs, 'label': cameraNames[i]},
      ),
  ];
}

/// The exact JSON body `GET /ws/register` expects.
Map<String, Object?> buildRegisterBody(
  String deviceId,
  List<CameraAnnouncement> cameras,
) => {
  'device_id': deviceId,
  'cameras': [for (final camera in cameras) camera.toJson()],
};
