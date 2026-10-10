import 'camera_capabilities.dart';
import 'camera_resolution.dart';
import 'encode_budget.dart';
import 'stream_settings.dart';

/// The resolution a device **opens** at: 1080p, even on a 4K camera.
///
/// Not the highest the camera can do. A 4K camera is still *declared* as
/// supporting 4K — an operator can switch to it — but the default is the
/// largest picture this client can actually sustain end to end, and the
/// encoder's ceiling moves with the pixel rate. Opening at a geometry the
/// device cannot hold is worse than opening lower: the server snapshots the
/// mode into the stream's `metadata` and trusts it, so a recording made at 4K
/// and delivered at a fraction of that rate is a recording nobody can reason
/// about afterwards.
const CameraResolution kTargetResolution = CameraResolution(
  width: 1920,
  height: 1080,
);

/// The frame rate a device aims for: 60, and only when it was measured.
const int kTargetFramerate = 60;

/// What a device declares when it has **no measurement** of what it delivers.
///
/// The lowest rung on [kCommonFramerates], and deliberately not
/// [kTargetFramerate]. The server snapshots `fps` into the stream's `metadata`
/// and estimates segment durations from it, so a declared rate that is not the
/// delivered rate makes every segment's length wrong; the honest value is one
/// the device is known to hold.
///
/// **Why the floor and not the target.** Until an [EncodeBudgetProbe] reports
/// what the pipeline really sustains, the only defensible number is the one
/// that is certainly reachable. Declaring 60 while the still-picture path
/// delivers 5-10 makes the declaration wrong by an order of magnitude in a
/// direction nobody can see from the device; declaring the floor is wrong by a
/// much smaller factor in the safe direction, and the measurement replaces it
/// with the real number as soon as one exists.
///
/// This is a **placeholder, not a policy** — the goal is for it to stop being
/// used. It is a named constant rather than a literal so the one place that has
/// to change is obvious.
const int kFpsWithoutEvidence = 5;

/// True when [resolution] fits inside [limit] **in both dimensions**.
///
/// Compared per axis rather than by pixel count, because a pixel count says
/// nothing about geometry: 2560x1080 and 1920x1440 have the same area and
/// completely different shapes, and only one of them fits inside 1920x1080.
/// Guessing geometry from a total is how a device ends up asking a camera for
/// a shape it does not produce.
bool fitsWithin(CameraResolution resolution, CameraResolution limit) =>
    resolution.width <= limit.width && resolution.height <= limit.height;

/// True when two resolutions have the same shape.
///
/// Cross-multiplied rather than divided: no floating point, no rounding, and
/// 1280x720 and 1920x1080 come out equal exactly as they should.
bool sameAspectRatio(CameraResolution a, CameraResolution b) =>
    a.width * b.height == b.width * a.height;

/// The resolution to open [measured] at, capped at [target].
///
/// Picks the largest measured resolution that fits inside [target] **and has
/// the camera's own shape**. The shape test matters because the ladder in
/// [kCommonResolutions] is mostly 16:9 and 4:3, and a camera whose native
/// geometry is neither — a 5:4 sensor, a 21:9 conferencing bar — would
/// otherwise be opened at a shape it does not produce, which surfaces as a
/// stretched picture rather than as an error. "Largest by pixel count" is only
/// used *within* one shape, where it is a real ordering.
///
/// The camera's shape is taken from [CameraCapabilities.highestResolution],
/// the geometry it was actually measured producing. That is evidence, not an
/// assumption about what cameras usually are.
///
/// [fallback] — the geometry the pipeline was configured with — is used when
/// the measurement yields nothing openable: nothing measured at all, or every
/// measured geometry larger than [target]. It is deliberately **not** a
/// candidate alongside the measurements, because a configured default must not
/// outrank what the camera was actually seen producing: a 720p camera with a
/// 1080p default has to open at 720p.
CameraResolution defaultResolutionFor({
  required CameraCapabilities measured,
  required CameraResolution fallback,
  CameraResolution target = kTargetResolution,
}) {
  if (measured.resolutions.isEmpty) return fallback;

  // Descending by pixel count, so the first member of any subset below is the
  // largest member of that subset.
  final measured_ = <CameraResolution>{...measured.resolutions}.toList()
    ..sort((a, b) => b.pixelCount.compareTo(a.pixelCount));

  final fitting = <CameraResolution>[
    for (final candidate in measured_)
      if (fitsWithin(candidate, target)) candidate,
  ];
  if (fitting.isEmpty) {
    // Nothing measured fits: either every geometry the camera produced is
    // larger than the target, or the fallback is the only openable one. The
    // fallback wins when it fits, because asking for a geometry this camera was
    // never seen producing is a guess; otherwise the least oversized measured
    // one is the closest thing to an honest default.
    if (fitsWithin(fallback, target)) return fallback;
    return measured_.reduce((a, b) => a.pixelCount <= b.pixelCount ? a : b);
  }

  final native = measured.highestResolution!;
  final sameShape = <CameraResolution>[
    for (final candidate in fitting)
      if (sameAspectRatio(candidate, native)) candidate,
  ];
  final pool = sameShape.isEmpty ? fitting : sameShape;
  return pool.first;
}

/// The frame rate to announce at [resolution].
///
/// Highest ladder rung the device measurably held, capped at [maxFps]. The cap
/// is a ceiling, not a target: a device that held 120 announces 60, because
/// that is the rate this client aims to serve, and announcing more than is
/// delivered makes the server overstate segment durations.
///
/// [unmeasuredFps] is what is announced when **nothing was measured**, and it
/// is required rather than defaulted on purpose. There is no honest number to
/// infer here: a rate is a measurement, and inventing one is exactly the bug
/// this function exists to prevent — a device that declares 60 on the strength
/// of nothing mis-states every segment it records. Callers pass
/// [kFpsWithoutEvidence], and the two situations that reach this branch are
/// deliberately answered the same way:
///
/// * **never measured** — no probe has run yet;
/// * **measured and held nothing** — a real result whose only honest reading is
///   that no rate above the floor is supported.
///
/// They coincide because the fallback *is* the floor. What neither may ever be
/// answered with is the target rate: "we have no evidence" is not evidence for
/// 60.
int defaultFpsFor({
  required CameraResolution resolution,
  required List<EncodeSample> samples,
  required int unmeasuredFps,
  int maxFps = kTargetFramerate,
  List<int> candidates = kCommonFramerates,
  Iterable<CaptureCodec> codecs = CaptureCodec.preference,
}) {
  int? best;
  for (final codec in codecs) {
    final held = maxSustainableFps(
      samples: samples,
      resolution: resolution,
      codec: codec,
    );
    if (held != null && (best == null || held > best)) best = held;
  }

  if (best == null) {
    // A rate below the floor is not a rate the server will accept, and the
    // floor is the same number the announcement uses.
    return unmeasuredFps < kMinDeclaredFramerate
        ? kMinDeclaredFramerate
        : unmeasuredFps;
  }

  final ceiling = best < maxFps ? best : maxFps;
  // The *highest* rung that fits, which is not the first one found: the ladder
  // is written low to high, and taking the first match would announce 5 for a
  // device that measurably held 60 — understating the device by an order of
  // magnitude, which is its own way of making segment durations wrong.
  var chosen = 0;
  for (final candidate in candidates) {
    if (candidate <= ceiling && candidate > chosen) chosen = candidate;
  }
  // Held something, but below every rung on the ladder: announce the floor
  // rather than nothing, since the server rejects a non-positive rate and
  // rejects a registration whose list omits the current one.
  return chosen < kMinDeclaredFramerate ? kMinDeclaredFramerate : chosen;
}

/// The mode one camera opens at: [defaultResolutionFor] and [defaultFpsFor].
///
/// One function rather than two call sites picking a resolution and a rate
/// independently, because the two are only meaningful together — a rate is
/// sustained *at a geometry*, and a "default mode" assembled from a resolution
/// chosen here and a rate chosen there describes a combination nobody measured.
///
/// The caller still has to make the pipeline run at this mode; see
/// `defaultResolutionFor` on why the resolution is capped and `defaultFpsFor`
/// on why [unmeasuredFps] is a required argument.
CameraMode defaultModeFor({
  required CameraCapabilities measured,
  required List<EncodeSample> samples,
  required CameraResolution fallbackResolution,
  required int unmeasuredFps,
  CameraResolution target = kTargetResolution,
  int maxFps = kTargetFramerate,
  List<int> candidates = kCommonFramerates,
  Iterable<CaptureCodec> codecs = CaptureCodec.preference,
}) {
  final resolution = defaultResolutionFor(
    measured: measured,
    fallback: fallbackResolution,
    target: target,
  );
  return CameraMode(
    resolution: resolution,
    fps: defaultFpsFor(
      resolution: resolution,
      samples: samples,
      unmeasuredFps: unmeasuredFps,
      maxFps: maxFps,
      candidates: candidates,
      codecs: codecs,
    ),
  );
}
