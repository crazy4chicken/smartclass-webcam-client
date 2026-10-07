import '../capture/camera_capabilities.dart';
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
/// - `supported_resolutions` must be non-empty, free of duplicates, and must
///   contain `resolution`; `supported_framerates` the same with `fps`,
/// - `supported_codec` must be non-empty, drawn from the closed [WireCodec]
///   set, and free of duplicates.
///
/// Since v0.3.0 the first three are not optional extras: a registration without
/// `supported_resolutions` / `supported_framerates` is a `400`, which means the
/// device cannot connect at all rather than merely losing a feature.
///
/// `attrs` is free-form and never persisted; a label is a useful convention.
class CameraAnnouncement {
  const CameraAnnouncement({
    required this.cameraEnum,
    required this.resolution,
    required this.fps,
    required this.supportedCodec,
    this.supportedResolutions = const <CameraResolution>[],
    this.supportedFramerates = const <int>[],
    this.attrs = const <String, Object?>{},
  });

  final int cameraEnum;

  /// `WIDTHxHEIGHT` in pixels — the mode this camera is at **now**. The server
  /// never parses it; it snapshots the string into the stream's
  /// `metadata.resolution`.
  final String resolution;

  /// Positive integer, the rate this camera is at now. Snapshotted into
  /// `metadata.fps` and used to estimate segment durations, so declaring a rate
  /// the device cannot hold makes the server overstate how long a segment
  /// lasted.
  final int fps;

  final List<WireCodec> supportedCodec;

  /// Everything this camera accepts, not just what it is doing.
  ///
  /// This is what an operator picks a mode from, so it has to be **measured**
  /// rather than guessed: a value declared here and then refused at
  /// `switch_camera` leaves the server's stream row `active` while the device
  /// feeds nothing.
  final List<CameraResolution> supportedResolutions;

  final List<int> supportedFramerates;

  final Map<String, Object?> attrs;

  Map<String, Object?> toJson() => {
    'camera_enum': cameraEnum,
    'resolution': resolution,
    'fps': fps,
    'supported_codec': [for (final codec in supportedCodec) codec.wireName],
    // Always present, even when empty: the server requires the keys, so
    // omitting them would be a different `400` from an empty list. Nothing
    // builds one of these by hand outside tests — `buildAnnouncements`
    // guarantees both are non-empty.
    'supported_resolutions': [
      for (final resolution in supportedResolutions) resolution.label,
    ],
    'supported_framerates': <int>[...supportedFramerates],
    if (attrs.isNotEmpty) 'attrs': attrs,
  };

  @override
  String toString() =>
      'CameraAnnouncement($cameraEnum, $resolution, ${fps}fps, '
      '${supportedResolutions.length}res/${supportedFramerates.length}fps, '
      '${supportedCodec.map((c) => c.wireName).join('/')})';
}

/// Lowest rate the server accepts; anything below is clamped up to it.
///
/// Defined from the capture layer's floor rather than repeated, because the two
/// have to agree: the announcement clamps this field *and* declares the frame
/// rate list, and the server rejects a registration whose list does not contain
/// the current rate.
const int minAnnounceableFps = kMinDeclaredFramerate;

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

/// One camera's entry in the registration: what it is called, what it is doing,
/// and what it will accept.
///
/// One object per camera rather than four positional lists. The old signature
/// took `cameraNames` and `resolutions` as parallel arrays, which is exactly how
/// camera 0 once ended up announcing the *lowest* rung of the capability ladder
/// — a positional mistake with no compile-time signal, and one the server
/// faithfully snapshotted into `metadata.resolution`. Bundling the fields makes
/// that class of error unrepresentable.
class CameraDeclaration {
  const CameraDeclaration({
    required this.name,
    required this.resolution,
    required this.fps,
    this.capabilities = CameraCapabilities.empty,
  });

  final String name;

  /// The mode this camera is at **now**. Always declared, whatever the probe
  /// found: the server rejects a registration that omits it.
  final CameraResolution resolution;

  final int fps;

  /// What the probe measured. Empty is allowed and expected on a device where
  /// the probe failed — the fallback below covers it.
  final CameraCapabilities capabilities;

  @override
  String toString() =>
      'CameraDeclaration($name, ${resolution.label} @ ${fps}fps, '
      '${capabilities.resolutions.length} measured)';
}

/// Builds the camera list for one registration.
///
/// [cameras] must already be in **canonical order**: `camera_enum` is the index
/// in this list, and the same order is what `CameraPluginBackend` resolves
/// `switch_camera` through. Two different orders would mean the server asking
/// for one camera and the device opening another.
///
/// The camera name always travels in `attrs.label`: it is the only way the
/// platform camera name reaches an operator, and `attrs` is exactly what the
/// protocol reserves for device-specific data.
List<CameraAnnouncement> buildAnnouncements({
  required List<CameraDeclaration> cameras,
  required List<WireCodec> codecs,
  Map<String, Object?> attrs = const <String, Object?>{},
}) {
  final safeCodecs = codecs.isEmpty
      ? const <WireCodec>[WireCodec.mjpeg]
      : codecs;

  return <CameraAnnouncement>[
    for (var cameraEnum = 0; cameraEnum < cameras.length; cameraEnum++)
      _announcementFor(cameraEnum, cameras[cameraEnum], safeCodecs, attrs),
  ];
}

CameraAnnouncement _announcementFor(
  int cameraEnum,
  CameraDeclaration camera,
  List<WireCodec> codecs,
  Map<String, Object?> attrs,
) {
  final safeFps = camera.fps < minAnnounceableFps
      ? minAnnounceableFps
      : camera.fps;

  // The common ladder first, then the current mode — in that order, and the
  // order matters: `withCurrent` is what guarantees the pair the server insists
  // on, and applying it first would let the ladder mask a mismatch.
  final declared = camera.capabilities.withCommonBaseline().withCurrent(
    resolution: camera.resolution,
    fps: safeFps,
  );

  // The server hard-rejects an empty list, and a kiosk that cannot register is
  // worse than one that declares only what it is doing right now. Reachable
  // only when the current resolution is degenerate, since `withCurrent` always
  // contributes a usable pair otherwise — but the cost of being wrong here is
  // that the device never connects.
  final resolutions = declared.resolutions.isEmpty
      ? <CameraResolution>[camera.resolution]
      : declared.resolutions;
  final framerates = declared.framerates.isEmpty
      ? <int>[safeFps]
      : declared.framerates;

  return CameraAnnouncement(
    cameraEnum: cameraEnum,
    resolution: camera.resolution.label,
    fps: safeFps,
    supportedCodec: List<WireCodec>.unmodifiable(codecs),
    supportedResolutions: List<CameraResolution>.unmodifiable(resolutions),
    supportedFramerates: List<int>.unmodifiable(framerates),
    attrs: <String, Object?>{...attrs, 'label': camera.name},
  );
}

/// The exact JSON body `GET /ws/register` expects.
Map<String, Object?> buildRegisterBody(
  String deviceId,
  List<CameraAnnouncement> cameras,
) => {
  'device_id': deviceId,
  'cameras': [for (final camera in cameras) camera.toJson()],
};
