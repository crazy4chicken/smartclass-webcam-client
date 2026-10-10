// Exercises the rate-calibration rules, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// What is being pinned here is a *criterion*, not a number: the shipped 1.5 s /
// 3 s meter defaults have no measurement behind them, and these checks are what
// makes a window choice arguable on evidence instead of taste.
//
// `check`, `eq` and `section` are the harness's, imported from there so every
// section lands in the one pass/fail count.
import 'package:webcam_client/src/capture/rate_calibration.dart';
import 'package:webcam_client/src/capture/sustained_rate.dart';

import 'verify_pure.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 10, 12);

/// Frames arriving [fps] times a second for [span], starting at [from].
List<DateTime> _steady({
  required int fps,
  required Duration span,
  Duration from = Duration.zero,
}) {
  final step = Duration(microseconds: Duration.microsecondsPerSecond ~/ fps);
  final out = <DateTime>[];
  for (var t = from; t <= from + span; t += step) {
    out.add(_t0.add(t));
  }
  return out;
}

void runRateCalibrationChecks() {
  // --- reading one window ---------------------------------------------------
  section('a window counts the frames inside it, half-open');
  {
    final arrivals = <DateTime>[
      _t0,
      _t0.add(const Duration(milliseconds: 100)),
      _t0.add(const Duration(milliseconds: 200)),
    ];
    eq(
      'the frame on the far edge belongs to the next window',
      rateInWindow(
        arrivals: arrivals,
        start: _t0,
        window: const Duration(milliseconds: 200),
      ),
      10,
    );
    eq(
      'a zero-length window is not a measurement',
      rateInWindow(arrivals: arrivals, start: _t0, window: Duration.zero),
      null,
    );
  }

  // --- the criterion --------------------------------------------------------
  section('a settled rate does not depend on where the window sits');
  {
    // A steady 20 fps pipeline: every placement reads the same thing.
    final steady = _steady(fps: 20, span: const Duration(seconds: 3));
    eq(
      'a steady trace has no spread',
      rateSpread(
        arrivals: steady,
        warmup: Duration.zero,
        window: const Duration(milliseconds: 500),
      ),
      0.0,
    );

    // The same pipeline sliding off a thermal cliff: early windows read fast,
    // late ones slow. This is the shape the criterion has to refuse.
    final degrading = <DateTime>[
      ..._steady(fps: 60, span: const Duration(seconds: 1)),
      ..._steady(
        fps: 30,
        span: const Duration(seconds: 1),
        from: const Duration(seconds: 1),
      ),
      ..._steady(
        fps: 15,
        span: const Duration(seconds: 1),
        from: const Duration(seconds: 2),
      ),
      ..._steady(
        fps: 8,
        span: const Duration(seconds: 1),
        from: const Duration(seconds: 3),
      ),
    ];
    final spread = rateSpread(
      arrivals: degrading,
      warmup: Duration.zero,
      window: const Duration(seconds: 1),
    );
    check('a degrading trace has a large spread', (spread ?? 0) > 0.5);

    eq(
      'and a trace too short to place the window twice reports nothing',
      rateSpread(
        arrivals: <DateTime>[_t0, _t0.add(const Duration(milliseconds: 5))],
        warmup: Duration.zero,
        window: const Duration(seconds: 1),
      ),
      null,
    );
  }

  // --- the algorithm --------------------------------------------------------
  section('calibration finds the shortest window that settles');
  {
    // One second of slow start (5 fps) and then a steady 20 fps for three.
    final trace = <DateTime>[
      ..._steady(fps: 5, span: const Duration(milliseconds: 800)),
      ..._steady(
        fps: 20,
        span: const Duration(seconds: 3),
        from: const Duration(seconds: 1),
      ),
    ];

    final result = calibrateRateWindow(arrivals: trace);
    check('it settles', result.settled);
    eq('on the steady rate', result.fps, 20);
    eq('skipping the slow start', result.warmup, const Duration(seconds: 1));
    eq(
      'and taking the shortest window that works',
      result.window,
      const Duration(milliseconds: 500),
    );
    eq('with placements that agree exactly', result.spread, 0.0);
    check('comparing more than two placements', result.placements >= 3);
    eq('and no note to explain', result.note, null);
  }

  {
    // A pipeline with no slow start should not be made to discard frames: the
    // warm-up ladder starts at zero precisely so this can come back as zero.
    final steady = _steady(fps: 30, span: const Duration(seconds: 2));
    final result = calibrateRateWindow(arrivals: steady);
    eq('a steady trace needs no warm-up', result.warmup, Duration.zero);
    eq('and the shortest window', result.window, kWindowLadder.first);
    eq('reading the real rate', result.fps, 30);
  }

  {
    // The thermal trace never settles at any window, and that is a result: the
    // answer is "the rate depends on when you look", not a number.
    final degrading = <DateTime>[
      ..._steady(fps: 60, span: const Duration(seconds: 1)),
      ..._steady(
        fps: 30,
        span: const Duration(seconds: 1),
        from: const Duration(seconds: 1),
      ),
      ..._steady(
        fps: 15,
        span: const Duration(seconds: 1),
        from: const Duration(seconds: 2),
      ),
      ..._steady(
        fps: 8,
        span: const Duration(seconds: 1),
        from: const Duration(seconds: 3),
      ),
    ];
    final result = calibrateRateWindow(arrivals: degrading);
    eq('a degrading trace never settles', result.settled, false);
    check('and says why', result.note != null);
    // `?? false` rather than `!`: a regression that makes this trace settle
    // must report a FAIL, not throw — an exception here aborts the whole gate
    // and hides every check after it.
    check(
      '  naming the placement dependence',
      result.note?.contains('placed') ?? false,
    );
    check(
      'while still reporting the steadiest window found',
      result.placements > 0,
    );
  }

  {
    final result = calibrateRateWindow(arrivals: <DateTime>[_t0]);
    eq('one frame is not a trace', result.settled, false);
    eq('and reads nothing', result.fps, 0);
    check('with a reason', result.note != null);
  }

  // --- the multi-run review -------------------------------------------------
  section('a series of runs is read as a trend, not a single number');
  {
    eq(
      'no runs is unknown',
      readRateSeries(const <int>[]).stability,
      RateStability.unknown,
    );
    eq('and holds nothing', readRateSeries(const <int>[]).plateauFps, 0);
    eq(
      'a single run cannot show a trend',
      readRateSeries(const <int>[30]).stability,
      RateStability.unknown,
    );
    eq(
      'a zero is not a rate at all',
      readRateSeries(const <int>[0, 0]).stability,
      RateStability.unknown,
    );

    final stable = readRateSeries(const <int>[30, 30, 30]);
    eq('three equal runs are stable', stable.stability, RateStability.stable);
    eq('with peak equal to plateau', stable.plateauFps, stable.peakFps);
    eq('and no overstatement', stable.peakOverstatesSustained, false);
  }

  section('a degrading series is where the peak stops being a promise');
  {
    // What thermal throttling looks like: the first run is the best one and the
    // device never gets back to it. `sustainableRates` takes the max, so today
    // this would be announced as 60 fps.
    final series = readRateSeries(const <int>[60, 60, 45, 30, 30]);
    eq('the trend is degrading', series.stability, RateStability.degrading);
    eq('the peak is the first run', series.peakFps, 60);
    eq('and the plateau is what it still holds', series.plateauFps, 30);
    eq(
      'so the peak overstates the sustained rate',
      series.peakOverstatesSustained,
      true,
    );
  }

  {
    // Warming up is the opposite risk — it under-declares, which is the safe
    // direction — and must not be reported as an overstatement.
    final series = readRateSeries(const <int>[10, 20, 30]);
    eq(
      'a rising series is improving',
      series.stability,
      RateStability.improving,
    );
    eq('its peak is its last run', series.peakFps, 30);
    eq('and it does not overstate', series.peakOverstatesSustained, false);
  }

  {
    // Neither monotone nor flat: something else is contending for the encoder,
    // and neither the peak nor the plateau describes the device.
    final series = readRateSeries(const <int>[60, 20, 60]);
    eq('a jumpy series is erratic', series.stability, RateStability.erratic);
  }

  section('the series reads straight off meter runs');
  {
    final series = readRateSeriesOf(<FrameRateMeasurement>[
      FrameRateMeasurement(
        fps: 60,
        newFrames: 120,
        duplicateFrames: 0,
        warmupFrames: 10,
        window: const Duration(seconds: 2),
      ),
      FrameRateMeasurement(
        fps: 30,
        newFrames: 60,
        duplicateFrames: 0,
        warmupFrames: 10,
        window: const Duration(seconds: 2),
      ),
    ]);
    eq('two runs is a trend', series.stability, RateStability.degrading);
    eq(
      'peak first, plateau last',
      '${series.peakFps}/${series.plateauFps}',
      '60/30',
    );
  }

  // --- the shipped defaults -------------------------------------------------
  section('the shipped window defaults can now be judged, not assumed');
  {
    // `SustainedRateMeter` ships 1.5 s / 3 s. This is the check a platform
    // probe runs against its own trace: if the spread at the defaults exceeds
    // the tolerance, those defaults are too short *for this hardware*, and
    // `calibrateRateWindow` says what to use instead.
    final steady = _steady(fps: 20, span: const Duration(seconds: 6));
    final spread = rateSpread(
      arrivals: steady,
      warmup: SustainedRateMeter().warmup,
      window: SustainedRateMeter().window,
    );
    check(
      'the defaults are adequate for a steady pipeline',
      spread != null && spread <= kSettledSpread,
    );

    final slowStart = <DateTime>[
      ..._steady(fps: 4, span: const Duration(seconds: 1)),
      ..._steady(
        fps: 20,
        span: const Duration(seconds: 5),
        from: const Duration(seconds: 1),
      ),
    ];
    final slowSpread = rateSpread(
      arrivals: slowStart,
      warmup: Duration.zero,
      window: SustainedRateMeter().window,
    );
    check(
      'and a one-second slow start would have poisoned a window with no warm-up',
      (slowSpread ?? 0) > kSettledSpread,
    );
  }
}
