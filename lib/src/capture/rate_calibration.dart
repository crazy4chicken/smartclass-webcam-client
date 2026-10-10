/// Turns a recorded trace of frame arrivals into a **measured** choice of
/// measurement window.
///
/// `SustainedRateMeter` ships with a 1.5 s warm-up and a 3 s window, and those
/// two numbers have no measurement behind them — they were picked to be
/// "clearly long enough". That is fine as a default and wrong as a claim: a
/// window that is too short reports whichever burst it happened to catch, and
/// one that is too long averages a thermal ramp into a number that describes no
/// moment of the recording at all. The window length is a property of the
/// **hardware**, not of this repository, so what belongs here is the criterion
/// that decides it and the algorithm that applies the criterion — not a
/// constant.
///
/// Pure Dart and clock-free: the caller supplies the trace, so a gate can drive
/// this with a synthetic one and real hardware supplies a real one.
library;

import 'sustained_rate.dart';

/// A window choice derived from a trace, with the evidence for it.
class RateWindowCalibration {
  const RateWindowCalibration({
    required this.warmup,
    required this.window,
    required this.fps,
    required this.settled,
    required this.spread,
    required this.placements,
    this.note,
  });

  /// Frames at the start to discard before measuring.
  final Duration warmup;

  /// How long the counted part runs.
  final Duration window;

  /// The rate the settled window read, floored.
  final int fps;

  /// Whether any window in the search space settled.
  ///
  /// False is a **result**, not a failure: a trace that never settles is a
  /// pipeline whose rate depends on when you look, and the honest answer is to
  /// say so rather than to quote a number. See [note].
  final bool settled;

  /// Worst relative deviation between placements at the chosen window.
  ///
  /// Zero means every placement agreed exactly. Anything at or below the
  /// tolerance is what "settled" means.
  final double spread;

  /// How many placements were compared.
  final int placements;

  /// Why no window settled, when [settled] is false.
  final String? note;

  @override
  String toString() =>
      'RateWindowCalibration(${settled ? '$fps fps' : 'unsettled'}, '
      'warmup ${warmup.inMilliseconds}ms, window ${window.inMilliseconds}ms, '
      'spread ${(spread * 100).toStringAsFixed(1)}%, $placements placements'
      '${note == null ? '' : ', $note'})';
}

/// How much the reading may move between placements and still count as settled.
///
/// A judgement, not a measurement — but a *stated* one, which the old constant
/// pair was not. 10% is looser than the jitter a healthy pipeline shows and
/// tighter than the gap between two frame rates an operator would consider
/// different (15 vs 30, 30 vs 60).
const double kSettledSpread = 0.10;

/// The window ladder searched, coarse enough to terminate and fine enough to
/// bracket a real answer. Powers of two from 0.5 s to 8 s.
const List<Duration> kWindowLadder = <Duration>[
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

/// The warm-up ladder searched. Zero is included on purpose: a pipeline with no
/// measurable slow start should not be made to discard frames it delivered.
const List<Duration> kWarmupLadder = <Duration>[
  Duration.zero,
  Duration(milliseconds: 250),
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// The rate read over `[start, start + window)`, floored, or null when the
/// window does not fit inside the trace.
int? rateInWindow({
  required List<DateTime> arrivals,
  required DateTime start,
  required Duration window,
}) {
  if (window <= Duration.zero) return null;
  final end = start.add(window);
  var count = 0;
  for (final at in arrivals) {
    // Half-open on both ends: a frame exactly on `start` belongs to this
    // window, one exactly on `end` belongs to the next. Otherwise a frame would
    // be counted twice when placements overlap, and the rate would depend on
    // the overlap.
    if (at.isBefore(start)) continue;
    if (!at.isBefore(end)) break;
    count++;
  }
  final seconds = window.inMicroseconds / Duration.microsecondsPerSecond;
  return (count / seconds).floor();
}

/// How far apart the readings are when the window is slid across the trace.
///
/// This is the criterion, exposed on its own so a platform probe can ask the
/// pointed question — **"are the shipped 1.5 s / 3 s good enough for this
/// device?"** — without going through the full search. Null when the trace is
/// too short to place the window twice, which is not a deviation of zero.
double? rateSpread({
  required List<DateTime> arrivals,
  required Duration warmup,
  required Duration window,
}) {
  final readings = _readings(
    arrivals: arrivals,
    warmup: warmup,
    window: window,
  );
  if (readings.length < 2) return null;
  return _relativeSpread(readings);
}

/// Finds the shortest warm-up and window for which the reading stops depending
/// on where the window is placed.
///
/// **The criterion is placement-independence, and that is the whole idea.** A
/// frame rate is a property of the pipeline; if the number you get depends on
/// which three seconds you looked at, you have not measured the pipeline, you
/// have sampled it. So: slide the window across the trace, and accept the
/// shortest one whose readings agree within [tolerance]. Warm-up falls out of
/// the same search — a warm-up is exactly the prefix you must skip to make the
/// remaining windows agree.
///
/// The search walks both ladders smallest-first and returns the first pair that
/// settles, so the answer is the *cheapest* adequate measurement rather than
/// the most flattering one.
RateWindowCalibration calibrateRateWindow({
  required List<DateTime> arrivals,
  double tolerance = kSettledSpread,
  List<Duration> windows = kWindowLadder,
  List<Duration> warmups = kWarmupLadder,
  int minPlacements = 3,
}) {
  if (arrivals.length < 2) {
    return RateWindowCalibration(
      warmup: Duration.zero,
      window: Duration.zero,
      fps: 0,
      settled: false,
      spread: 0,
      placements: 0,
      note: 'trace has fewer than two frames',
    );
  }

  final span = arrivals.last.difference(arrivals.first);
  // The last pair that settles is remembered, so an unsettled answer can still
  // report the best window it found instead of nothing.
  RateWindowCalibration? best;
  var sawAnyPlacement = false;

  for (final warmup in warmups) {
    if (warmup >= span) break;
    for (final window in windows) {
      final readings = _readings(
        arrivals: arrivals,
        warmup: warmup,
        window: window,
      );
      if (readings.length < minPlacements) continue;
      sawAnyPlacement = true;
      final spread = _relativeSpread(readings);
      final median = _median(readings);
      final candidate = RateWindowCalibration(
        warmup: warmup,
        window: window,
        fps: median,
        settled: spread <= tolerance,
        spread: spread,
        placements: readings.length,
      );
      if (best == null || spread < best.spread) best = candidate;
      if (candidate.settled) return candidate;
    }
  }

  if (best == null) {
    return RateWindowCalibration(
      warmup: Duration.zero,
      window: Duration.zero,
      fps: 0,
      settled: false,
      spread: 0,
      placements: 0,
      note: 'trace too short for $minPlacements placements at any window',
    );
  }

  // No window settled. Report the steadiest one found, and say what that means
  // rather than leaving the caller to read a `false` as "no data".
  return RateWindowCalibration(
    warmup: best.warmup,
    window: best.window,
    fps: best.fps,
    settled: false,
    spread: best.spread,
    placements: best.placements,
    note: sawAnyPlacement
        ? 'rate never settled within ${(tolerance * 100).toStringAsFixed(0)}%: '
              'it depends on where the window is placed'
        : 'no window fitted the trace',
  );
}

/// Reads [readings] as a **series of probe runs over time**, not as one run.
///
/// This is the answer to the open question `EncodeSample` records but does not
/// settle: *"the fastest run is taken as the better evidence rather than the
/// slowest"*. That is a defensible reading of "what has this device been seen
/// to hold", and an unsound reading of "what can this device be trusted to
/// hold" — two runs at the same geometry disagree routinely, and the usual
/// reason they disagree in that direction is thermal throttling. A device that
/// held 60 fps cold and 30 fps hot will hold 30 fps for a long recording, and
/// `sustainableRates`' `max` will announce 60.
///
/// So the peak and the plateau are reported **separately**, and the gap between
/// them is a fact rather than an opinion. Which one belongs in a registration
/// is a policy call this function deliberately does not make — see
/// `docs/adr/0001-dual-mode-capture-decisions.md` §4.1.
RateSeries readRateSeries(
  List<int> fpsInTimeOrder, {
  double tolerance = kStabilityTolerance,
}) {
  final runs = <int>[
    for (final fps in fpsInTimeOrder)
      if (fps > 0) fps,
  ];
  if (runs.isEmpty) {
    return RateSeries(
      peakFps: 0,
      plateauFps: 0,
      stability: RateStability.unknown,
      tolerance: tolerance,
    );
  }

  final peak = runs.reduce((a, b) => a > b ? a : b);
  // The plateau is the tail: what the device was still holding by the end of
  // the series, which is the part that matters for a recording that runs for
  // minutes rather than seconds.
  final tailLength = (runs.length / 3).ceil().clamp(1, runs.length);
  final plateau = _median(runs.sublist(runs.length - tailLength));

  return RateSeries(
    peakFps: peak,
    plateauFps: plateau,
    stability: _classify(runs, tolerance),
    tolerance: tolerance,
  );
}

/// Reads a series straight from meter runs, in the order they were taken.
///
/// The seam a platform probe actually has: each run produces a
/// [FrameRateMeasurement], and the series is what says whether the device is
/// holding the rate or sliding off it.
RateSeries readRateSeriesOf(
  List<FrameRateMeasurement> measurements, {
  double tolerance = kStabilityTolerance,
}) => readRateSeries(<int>[
  for (final m in measurements) m.fps,
], tolerance: tolerance);

/// How much two runs may differ before it is a trend rather than jitter.
///
/// A judgement like [kSettledSpread], and stated for the same reason. 15% is
/// wider than the run-to-run spread a healthy encoder shows and narrower than
/// one step of any real frame-rate ladder (15/30/60), so a ladder step change
/// always reads as a trend and ordinary jitter never does.
const double kStabilityTolerance = 0.15;

/// What an ordered series of runs looks like.
enum RateStability {
  /// Fewer than two usable runs: a single run cannot show a trend.
  unknown,

  /// Every run within [RateSeries.tolerance] of the others.
  stable,

  /// Later runs are faster — warm-up still in progress, or the device was busy
  /// during the early ones. Under-declaring, which is the safe direction.
  improving,

  /// Later runs are slower. The usual cause is thermal throttling, and it is
  /// the case where the peak is not a sustained rate.
  degrading,

  /// Neither monotone nor within tolerance: something else is contending for
  /// the encoder, and neither the peak nor the plateau describes the device.
  erratic,
}

/// A device's runs for one codec at one geometry, read as peak *and* plateau.
class RateSeries {
  const RateSeries({
    required this.peakFps,
    required this.plateauFps,
    required this.stability,
    required this.tolerance,
  });

  /// The fastest run — what `sustainableRates` uses today.
  final int peakFps;

  /// What the tail of the series still held.
  final int plateauFps;

  final RateStability stability;
  final double tolerance;

  /// True when the peak is materially above what the device still holds.
  ///
  /// The review's finding, as a boolean: this is the case where a
  /// peak-based declaration promises a rate the device stopped delivering.
  bool get peakOverstatesSustained =>
      plateauFps <= 0 ? peakFps > 0 : peakFps > plateauFps * (1 + tolerance);

  @override
  String toString() =>
      'RateSeries(${stability.name}, peak=$peakFps, plateau=$plateauFps'
      '${peakOverstatesSustained ? ', peak overstates' : ''})';
}

// --- internals --------------------------------------------------------------

List<int> _readings({
  required List<DateTime> arrivals,
  required Duration warmup,
  required Duration window,
}) {
  final first = arrivals.first.add(warmup);
  final lastStart = arrivals.last.subtract(window);
  // Half a window apart: enough overlap that a single unlucky burst cannot
  // hide, little enough that the placements are genuinely different windows.
  final step = Duration(microseconds: window.inMicroseconds ~/ 2);
  if (step <= Duration.zero || lastStart.isBefore(first)) return const <int>[];

  final readings = <int>[];
  for (var start = first; !start.isAfter(lastStart); start = start.add(step)) {
    final rate = rateInWindow(arrivals: arrivals, start: start, window: window);
    if (rate != null) readings.add(rate);
  }
  return readings;
}

/// Worst relative deviation from the median, or 0 when everything agrees.
///
/// Relative rather than absolute on purpose: 1 fps of spread is noise at 60 and
/// a third of the signal at 3.
double _relativeSpread(List<int> readings) {
  if (readings.length < 2) return 0;
  final median = _median(readings);
  if (median <= 0) return readings.every((r) => r == 0) ? 0 : 1;
  var worst = 0.0;
  for (final reading in readings) {
    final deviation = (reading - median).abs() / median;
    if (deviation > worst) worst = deviation;
  }
  return worst;
}

/// Median of an unordered list, floored. Even counts take the lower middle.
int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.of(values)..sort();
  return sorted[(sorted.length - 1) ~/ 2];
}

RateStability _classify(List<int> runs, double tolerance) {
  if (runs.length < 2) return RateStability.unknown;

  final peak = runs.reduce((a, b) => a > b ? a : b);
  final low = runs.reduce((a, b) => a < b ? a : b);
  // Within tolerance of each other, measured against the peak so a series of
  // zeroes cannot divide by nothing.
  if (peak <= 0) return RateStability.stable;
  if (peak - low <= peak * tolerance) return RateStability.stable;

  var nonDecreasing = true;
  var nonIncreasing = true;
  for (var i = 1; i < runs.length; i++) {
    final previous = runs[i - 1];
    final current = runs[i];
    if (previous <= 0 || current <= 0) return RateStability.erratic;
    if (current < previous * (1 - tolerance)) nonDecreasing = false;
    if (current > previous * (1 + tolerance)) nonIncreasing = false;
  }

  if (nonDecreasing) return RateStability.improving;
  if (nonIncreasing) return RateStability.degrading;
  return RateStability.erratic;
}
