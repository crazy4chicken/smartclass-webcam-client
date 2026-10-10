// Exercises the sustained-rate measurement rules, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// `check`, `eq` and `section` are the harness's, imported from there so every
// section lands in the one pass/fail count.
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/encode_budget.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/sustained_rate.dart';

import 'verify_pure.dart';

// --- fixtures ---------------------------------------------------------------

const _p1080 = CameraResolution(width: 1920, height: 1080);
final DateTime _t0 = DateTime.utc(2026, 10, 10);

/// Feeds [count] frames [stepMillis] apart, sequence advancing by one each
/// time, starting at [from]. Returns whatever the last feed produced.
FrameRateMeasurement? _feed(
  SustainedRateMeter meter, {
  required int count,
  required int stepMillis,
  int from = 0,
  int seqFrom = 0,
}) {
  FrameRateMeasurement? last;
  for (var i = 0; i < count; i++) {
    final at = _t0.add(Duration(milliseconds: (from + i) * stepMillis));
    last = meter.onFrame(sourceSeq: seqFrom + i, at: at);
  }
  return last;
}

void runSustainedRateChecks() {
  // --- the rate is what came out, over the counted window -------------------
  section('the measured rate is what the pipeline delivered');
  {
    // 100 ms apart is 10 fps. Warm-up 1 s, window 2 s: frames at 0..900 ms are
    // warm-up (10 of them), 1000..2900 ms are counted (20 of them), and the
    // frame at 3000 ms closes the window without being counted.
    final meter = SustainedRateMeter(
      warmup: const Duration(seconds: 1),
      window: const Duration(seconds: 2),
    );
    final result = _feed(meter, count: 31, stepMillis: 100);

    check('the window closes', result != null);
    eq('at 10 fps', result?.fps, 10);
    eq('from 20 counted frames', result?.newFrames, 20);
    eq('with the 10 warm-up frames set aside', result?.warmupFrames, 10);
    eq('and nothing duplicated', result?.duplicateFrames, 0);
    eq('over the counted window only', result?.window.inSeconds, 2);
    check('and it held something', result!.heldAnything);
  }

  // --- warm-up is excluded, and exclusion is not re-counting ---------------
  section('warm-up is set aside, not averaged in');
  {
    // Same 10 fps steady state, but the first second is slow (one frame at
    // 500 ms). Averaging the warm-up in would drag the number down; excluding
    // it is the whole point of having a warm-up at all.
    final meter = SustainedRateMeter(
      warmup: const Duration(seconds: 1),
      window: const Duration(seconds: 2),
    );
    // The meter's clock starts at the first frame, so warm-up is [500, 1500)
    // and the counted window is [1500, 3500). Feeding on to 4900 ms is what
    // gets a frame past the end of the window.
    meter.onFrame(sourceSeq: 0, at: _t0.add(const Duration(milliseconds: 500)));
    final result = _feed(
      meter,
      count: 40,
      stepMillis: 100,
      from: 10,
      seqFrom: 1,
    );
    eq('the slow start does not lower the rate', result?.fps, 10);
    eq('it is reported as warm-up', result?.warmupFrames, 6);
  }

  // --- a repeated frame is not delivery -------------------------------------
  section('a repeated frame is not a delivered frame');
  {
    // What a `videorate` pipeline does: it keeps ticking and repeats the last
    // picture. 40 ticks land in the 2 s window and half of them are repeats,
    // so counting ticks reports 20 fps while counting *new frames* reports 10.
    // Reporting the tick rate is how a device comes to announce a rate nothing
    // is producing.
    final meter = SustainedRateMeter(
      warmup: Duration.zero,
      window: const Duration(seconds: 2),
    );
    FrameRateMeasurement? result;
    var seq = 0;
    for (var i = 0; i < 60; i++) {
      final at = _t0.add(Duration(milliseconds: i * 50));
      // Every other tick repeats the previous sequence number.
      final sourceSeq = i.isEven ? seq++ : seq - 1;
      result = meter.onFrame(sourceSeq: sourceSeq, at: at);
      if (result != null) break;
    }
    eq('half the ticks are repeats, so the rate halves', result?.fps, 10);
    eq('the repeats are counted', result?.duplicateFrames, 20);
    eq('and only the new frames count', result?.newFrames, 20);
  }

  // --- a repeated frame during warm-up cannot become new later -------------
  section('warm-up cannot be re-counted as delivery');
  {
    final meter = SustainedRateMeter(
      warmup: const Duration(seconds: 1),
      window: const Duration(seconds: 1),
    );
    // One frame during warm-up, then the same sequence number again after it.
    meter.onFrame(sourceSeq: 7, at: _t0.add(const Duration(milliseconds: 500)));
    final repeated = meter.onFrame(
      sourceSeq: 7,
      at: _t0.add(const Duration(milliseconds: 1500)),
    );
    eq('the repeat alone does not close the window', repeated, null);
    final result = meter.close(at: _t0.add(const Duration(milliseconds: 2500)));
    eq('the warm-up frame is not counted as new', result?.newFrames, 0);
    eq('it is counted as a repeat', result?.duplicateFrames, 1);
    eq('so the rate is zero', result?.fps, 0);
    check('and nothing was held', !result!.heldAnything);
  }

  // --- a stall still produces a measurement --------------------------------
  section('a stalled pipeline still produces a measurement');
  {
    // Two frames and then nothing. Without an explicit close the window never
    // ends, and "the device held nothing" would be indistinguishable from
    // "nobody measured".
    final meter = SustainedRateMeter(
      warmup: const Duration(seconds: 1),
      window: const Duration(seconds: 2),
    );
    meter.onFrame(sourceSeq: 0, at: _t0);
    eq('no result before the window ends', meter.measurement, null);
    final result = meter.close(at: _t0.add(const Duration(seconds: 3)));
    eq('closing yields a rate of zero', result?.fps, 0);
    eq('with no new frames', result?.newFrames, 0);
    check('which is a measurement, not an absence', result != null);
  }

  {
    // A close with no frames at all is the one case that is *not* a
    // measurement: the window never opened, so there is nothing to divide by.
    final meter = SustainedRateMeter(
      warmup: Duration.zero,
      window: const Duration(seconds: 2),
    );
    eq(
      'closing a meter that never saw a frame measures nothing',
      meter.close(at: _t0.add(const Duration(seconds: 5))),
      null,
    );
  }

  // --- the window closes once ----------------------------------------------
  section('the first window is the answer');
  {
    final meter = SustainedRateMeter(
      warmup: Duration.zero,
      window: const Duration(seconds: 1),
    );
    // 4 fps for the first second (the fifth frame lands on the boundary and
    // closes the window without being counted), then a 60 fps burst.
    final first = _feed(meter, count: 5, stepMillis: 250);
    eq('the first window measures 4 fps', first?.fps, 4);
    final second = _feed(
      meter,
      count: 60,
      stepMillis: 16,
      from: 1000,
      seqFrom: 4,
    );
    eq('a later burst does not overwrite it', second?.fps, 4);
    check('and the meter reports complete', meter.isComplete);
  }

  // --- reset ----------------------------------------------------------------
  section('reset starts a new measurement');
  {
    final meter = SustainedRateMeter(
      warmup: Duration.zero,
      window: const Duration(seconds: 1),
    );
    eq('a first window', _feed(meter, count: 5, stepMillis: 250)?.fps, 4);
    meter.reset();
    eq('after reset, nothing yet', meter.measurement, null);
    eq(
      'and a fresh window measures the new rate',
      _feed(meter, count: 21, stepMillis: 50)?.fps,
      20,
    );
  }

  // --- rounding is down, never up ------------------------------------------
  section('a measured rate rounds down');
  {
    // 59 frames over 2 s is 29.5 fps — evidence for 29, not 30.
    final meter = SustainedRateMeter(
      warmup: Duration.zero,
      window: const Duration(seconds: 2),
    );
    final result = _feed(meter, count: 60, stepMillis: 34);
    eq('29.5 fps is reported as 29', result?.fps, 29);
  }

  // --- evidence carries the three keys that can invalidate it --------------
  section('measurements become evidence');
  {
    final evidence = evidenceFromMeasurements(
      cameraFingerprint: 'cam-A',
      encoderIdentity: 'c2.qcom.hevc',
      resolution: _p1080,
      measurements: <CaptureCodec, FrameRateMeasurement>{
        CaptureCodec.h265: FrameRateMeasurement(
          fps: 60,
          newFrames: 120,
          duplicateFrames: 0,
          warmupFrames: 10,
          window: const Duration(seconds: 2),
        ),
        // Held nothing: omitted rather than recorded as a zero sample.
        CaptureCodec.h264: FrameRateMeasurement(
          fps: 0,
          newFrames: 0,
          duplicateFrames: 0,
          warmupFrames: 0,
          window: const Duration(seconds: 2),
        ),
      },
    );
    eq(
      'only the codec that held something is recorded',
      evidence.samples.length,
      1,
    );
    eq(
      'and it is the one that held 60',
      evidence.samples.first.codec,
      CaptureCodec.h265,
    );
    eq(
      'at the geometry it was measured at',
      evidence.samples.first.resolution,
      _p1080,
    );
    check(
      'the evidence survives a round trip through the cache',
      !EncodeEvidence.fromJson(evidence.toJson()).isInvalid,
    );
    eq(
      'and still answers the mode question afterwards',
      canServeMode(
        samples: EncodeEvidence.fromJson(evidence.toJson()).samples,
        codec: CaptureCodec.h265,
        resolution: _p1080,
        fps: 60,
      ),
      true,
    );
    eq(
      'while the codec that held nothing is not offered',
      sustainableCodecsAt(
        samples: evidence.samples,
        resolution: _p1080,
        fps: 30,
      ).map((c) => c.wireName).join(','),
      'h265',
    );
  }
}
