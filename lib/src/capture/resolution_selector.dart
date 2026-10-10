// **Not the live selector.** Nothing in `lib/` calls `selectClosestResolution`;
// the selector that decides what a camera opens at is `defaultResolutionFor` in
// `default_mode.dart`, which is orientation-insensitive and prefers the
// camera's own geometry. This one still compares per axis against the target as
// written, so reaching for it from production would reintroduce the
// portrait-geometry bug it predates. It is kept only for its own tests.
import 'camera_resolution.dart';

/// Picks the closest camera format that does **not** exceed [target].
///
/// Rules:
/// 1. Never upscale — a format wider or taller than the target is discarded.
/// 2. Among the formats that fit, take the one with the most pixels.
/// 3. If nothing fits (target smaller than every format), take the smallest
///    format available, because some pixels beat no pixels.
///
/// [available] must not be empty.
CameraResolution selectClosestResolution(
  List<CameraResolution> available,
  CameraResolution target,
) {
  assert(available.isNotEmpty, 'cannot select from an empty format list');

  final fitting = available
      .where((r) => r.width <= target.width && r.height <= target.height)
      .toList();

  if (fitting.isNotEmpty) {
    return fitting.reduce((a, b) => b.pixelCount > a.pixelCount ? b : a);
  }

  return available.reduce((a, b) => b.pixelCount < a.pixelCount ? b : a);
}
