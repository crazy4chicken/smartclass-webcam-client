import 'camera_resolution.dart';

/// Lowest frame rate worth declaring.
///
/// The server rejects a non-positive `fps`, and it rejects a registration whose
/// `supported_framerates` does not contain the camera's *current* rate — so the
/// floor has to be the same number in both places. `minAnnounceableFps` in the
/// backend layer is defined from this constant rather than repeating it.
const int kMinDeclaredFramerate = 1;

/// Ladder of resolutions worth offering an operator even when the probe did
/// not surface them.
///
/// These are **candidates, not claims**: [CameraCapabilities.withCommonBaseline]
/// caps the list at the highest resolution the camera actually produced, so a
/// 480p webcam is never advertised as 4K. Declaring something the hardware
/// cannot do is worse than declaring less — the server accepts the
/// registration and then records the mismatch into `metadata.resolution`.
const List<CameraResolution> kCommonResolutions = <CameraResolution>[
  CameraResolution(width: 320, height: 240),
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 800, height: 600),
  CameraResolution(width: 1024, height: 768),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1920, height: 1080),
  CameraResolution(width: 2560, height: 1440),
  CameraResolution(width: 3840, height: 2160),
];

/// Frame rates worth offering an operator, same reasoning as
/// [kCommonResolutions].
///
/// Includes 60 because that is `AppConfig.defaultFps`, so the rate a device
/// seeds at is published by the ladder itself rather than only folded in by
/// [withCurrent]. 5 stays as a legitimate low rung: an operator who wants long
/// segments and small uploads picks it on purpose, not as a fallback.
const List<int> kCommonFramerates = <int>[5, 10, 15, 20, 24, 25, 30, 50, 60];

/// What one camera can do, as **measured** rather than assumed.
///
/// The plugin stack exposes no enumeration API on any of the five platforms, so
/// "supported" can only ever mean "we asked and it produced". Everything in
/// here comes from a real open, and everything announced to the server is
/// derived from it.
///
/// Invariants, enforced by [CameraCapabilities.of] rather than by convention:
///
/// * no duplicates — the server answers `400 … must not contain duplicates`,
///   and two presets resolving to the same real size is the normal case, not
///   the exception,
/// * resolutions sorted by pixel count descending, frame rates descending, so
///   "the highest measured resolution" is simply `resolutions.first`.
///
/// Pure Dart: no `package:flutter`, so `tool/verify_pure.dart` can exercise it.
class CameraCapabilities {
  const CameraCapabilities({
    required this.resolutions,
    required this.framerates,
  });

  final List<CameraResolution> resolutions;
  final List<int> framerates;

  /// What a camera that could not be probed at all knows about itself: nothing.
  static const CameraCapabilities empty = CameraCapabilities(
    resolutions: <CameraResolution>[],
    framerates: <int>[],
  );

  bool get isEmpty => resolutions.isEmpty && framerates.isEmpty;

  /// The highest resolution the camera really produced, or null.
  CameraResolution? get highestResolution =>
      resolutions.isEmpty ? null : resolutions.first;

  /// Dedupes and sorts.
  ///
  /// This is the only constructor for measured values, because both rules are
  /// hard requirements on the wire and a caller that forgot one would produce a
  /// registration the server refuses.
  factory CameraCapabilities.of({
    required Iterable<CameraResolution> resolutions,
    required Iterable<int> framerates,
  }) {
    final uniqueResolutions = <CameraResolution>{
      for (final resolution in resolutions)
        if (resolution.width > 0 && resolution.height > 0) resolution,
    }.toList()..sort((a, b) => b.pixelCount.compareTo(a.pixelCount));

    final uniqueFramerates = <int>{
      for (final fps in framerates)
        if (fps >= kMinDeclaredFramerate) fps,
    }.toList()..sort((a, b) => b.compareTo(a));

    return CameraCapabilities(
      resolutions: List<CameraResolution>.unmodifiable(uniqueResolutions),
      framerates: List<int>.unmodifiable(uniqueFramerates),
    );
  }

  /// Union with the common ladder, capped at what was measured **and at the
  /// shapes the camera was measured producing**.
  ///
  /// Empty resolutions in, the same out: with nothing measured there is no
  /// ceiling to cap against, and inventing one would mean guessing what the
  /// hardware can do — which is the mistake this whole class exists to avoid.
  ///
  /// A ladder rung is merged only when the camera measurably produced that
  /// shape. The ladder's job is to fill gaps in the operator's menu for
  /// geometries the camera *can* produce; a rung of a shape it never produced
  /// is a mode that opens to a stretched or refused picture — and, once the
  /// declared list is what `defaultResolutionFor` trusts, a shape the device
  /// could be opened at. A 5:4 sensor therefore keeps 5:4 and is not advertised
  /// 16:9 or 4:3.
  CameraCapabilities withCommonBaseline() {
    final ceiling = highestResolution;
    if (ceiling == null) return this;

    return CameraCapabilities.of(
      resolutions: <CameraResolution>[
        ...resolutions,
        for (final common in kCommonResolutions)
          if (common.pixelCount <= ceiling.pixelCount &&
              resolutions.any((measured) => sameShape(measured, common)))
            common,
      ],
      framerates: <int>[...framerates, ...kCommonFramerates],
    );
  }

  /// Declares the camera's current mode.
  ///
  /// Applied **last**, always: the server rejects a registration that does not
  /// list the camera's current `resolution` / `fps`, and a probe can legitimately
  /// never surface either one — the ladder is coarse, and a camera that could
  /// not be measured at all gets no ladder, because [withCommonBaseline] has no
  /// ceiling to cap against. Without this, the device would be unable to
  /// register at the mode it is actually running in.
  CameraCapabilities withCurrent({
    required CameraResolution resolution,
    required int fps,
  }) => CameraCapabilities.of(
    resolutions: <CameraResolution>[...resolutions, resolution],
    framerates: <int>[
      ...framerates,
      fps < kMinDeclaredFramerate ? kMinDeclaredFramerate : fps,
    ],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'resolutions': <String>[for (final r in resolutions) r.label],
    'framerates': <int>[...framerates],
  };

  /// Never throws. Anything unusable in the payload is dropped rather than
  /// propagated: this reads a cache, and a corrupt cache must degrade to "probe
  /// again", not to a crash on the kiosk.
  static CameraCapabilities fromJson(Object? raw) {
    if (raw is! Map) return empty;

    final resolutions = <CameraResolution>[];
    final rawResolutions = raw['resolutions'];
    if (rawResolutions is List) {
      for (final entry in rawResolutions) {
        final parsed = parseResolutionLabel(entry);
        if (parsed != null) resolutions.add(parsed);
      }
    }

    final framerates = <int>[];
    final rawFramerates = raw['framerates'];
    if (rawFramerates is List) {
      for (final entry in rawFramerates) {
        if (entry is int) {
          framerates.add(entry);
        } else if (entry is num) {
          framerates.add(entry.toInt());
        }
      }
    }

    return CameraCapabilities.of(
      resolutions: resolutions,
      framerates: framerates,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraCapabilities &&
          _listEquals(resolutions, other.resolutions) &&
          _listEquals(framerates, other.framerates);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(resolutions), Object.hashAll(framerates));

  @override
  String toString() =>
      'CameraCapabilities(${resolutions.map((r) => r.label).join('/')} @ '
      '${framerates.join('/')})';
}

/// The mode one camera is currently at: what it captures at right now.
///
/// Separate from [CameraCapabilities], which is what it *accepts*. The server
/// stores nothing on `switch_camera`, so the device is the only place this
/// lives — and it has to survive until the next registration carries it.
class CameraMode {
  const CameraMode({required this.resolution, required this.fps});

  final CameraResolution resolution;
  final int fps;

  CameraMode copyWith({CameraResolution? resolution, int? fps}) => CameraMode(
    resolution: resolution ?? this.resolution,
    fps: fps ?? this.fps,
  );

  /// True when a `switch_camera` would have to re-register to stay honest:
  /// the server snapshots the registration's `resolution` / `fps` into the
  /// stream's `metadata` at `recording/start`, so a local-only change leaves
  /// that snapshot describing a mode the device is no longer in.
  bool differsFrom(CameraMode other) =>
      resolution != other.resolution || fps != other.fps;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraMode && resolution == other.resolution && fps == other.fps;

  @override
  int get hashCode => Object.hash(resolution, fps);

  @override
  String toString() => 'CameraMode(${resolution.label} @ ${fps}fps)';
}

/// What one camera will be announced as accepting: the measured set, the common
/// ladder below its ceiling, and the mode it is at now.
///
/// **One function rather than two call sites computing it.** The registration
/// and the `switch_camera` validator have to agree exactly — a device that
/// declares 1024x768 and then refuses it is worse than one that declares less,
/// because the operator picked from a list the device itself published.
CameraCapabilities declaredCapabilities({
  required CameraCapabilities measured,
  required CameraResolution currentResolution,
  required int currentFps,
}) => measured.withCommonBaseline().withCurrent(
  resolution: currentResolution,
  fps: currentFps,
);

/// Reads a `WIDTHxHEIGHT` label, or null.
///
/// Shared by the announcement path and the capability cache so both agree on
/// what a label means; the wire format is a string by convention only — the
/// server never parses it.
CameraResolution? parseResolutionLabel(Object? raw) {
  if (raw is! String) return null;
  final parts = raw.trim().split('x');
  if (parts.length != 2) return null;
  final width = int.tryParse(parts[0]);
  final height = int.tryParse(parts[1]);
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return CameraResolution(width: width, height: height);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
