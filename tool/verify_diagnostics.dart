// Exercises the diagnostics rules, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// The coordinator's wiring is checked next to the coordinator; what is here is
// the part an operator reads: which stage gets named, and what a rolling window
// does when the events stop.
//
// `check`, `eq` and `section` are the harness's, imported from there so every
// section lands in the one pass/fail count.
import 'package:webcam_client/src/agent/stream_diagnostics.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

import 'verify_pure.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 10, 12);

void runDiagnosticsChecks() {
  // --- the rolling window ---------------------------------------------------
  section('a rolling window counts what is inside it');
  {
    final rate = RollingRate(window: const Duration(seconds: 2));
    for (var i = 0; i < 10; i++) {
      rate.record(_t0.add(Duration(milliseconds: i * 200)));
    }
    eq('ten events over two seconds is five a second', rate.rateAt(_t0), 5);
    eq('and the window holds them all', rate.count, 10);
  }

  section('events age out of the window');
  {
    final rate = RollingRate(window: const Duration(seconds: 2));
    // Ten events in the first second, then the pipeline stalls.
    for (var i = 0; i < 10; i++) {
      rate.record(_t0.add(Duration(milliseconds: i * 100)));
    }
    eq(
      'ten events in a two-second window is five a second',
      rate.rateAt(_t0),
      5,
    );
    // Two seconds after the last event, none of them are still in the window.
    final later = _t0.add(const Duration(seconds: 4));
    eq('a stall decays to zero', rate.rateAt(later), 0);
    eq('and the window is empty', rate.count, 0);
  }

  section('an event can stand for more than one frame');
  {
    // How the camera is measured: the producer's own sequence jumped, which is
    // how it says several pictures happened.
    final rate = RollingRate(window: const Duration(seconds: 2));
    rate.record(_t0, weight: 20);
    eq('a weight of twenty counts as twenty', rate.count, 20);
    eq('so the rate is ten a second', rate.rateAt(_t0), 10);
    rate.record(_t0.add(const Duration(seconds: 1)), weight: 0);
    eq('a zero weight records nothing', rate.count, 20);
    rate.record(_t0.add(const Duration(seconds: 1)), weight: -5);
    eq('and neither does a negative one', rate.count, 20);
  }

  section('a rolling rate rounds down');
  {
    final rate = RollingRate(window: const Duration(seconds: 2));
    for (var i = 0; i < 5; i++) {
      rate.record(_t0);
    }
    // 2.5 a second is evidence for 2.
    eq('two and a half a second is two', rate.rateAt(_t0), 2);
    rate.clear();
    eq('clearing empties the window', rate.count, 0);
    eq('and the rate with it', rate.rateAt(_t0), 0);
  }

  // --- naming the stage -----------------------------------------------------
  section('the stage is named from the rates');
  {
    PipelineBottleneck at({
      bool recording = true,
      int targetFps = 30,
      int? capturedFps = 30,
      int? encodedFps = 30,
      int? sentFps = 30,
    }) => classifyBottleneck(
      recording: recording,
      targetFps: targetFps,
      capturedFps: capturedFps,
      encodedFps: encodedFps,
      sentFps: sentFps,
    );

    eq(
      'idle is not a bottleneck',
      at(recording: false),
      PipelineBottleneck.idle,
    );
    eq(
      'nothing measured yet is unknown, not slow',
      at(capturedFps: null),
      PipelineBottleneck.unknown,
    );
    eq('a camera that kept up is healthy', at(), PipelineBottleneck.healthy);
    eq(
      'a camera below the target is the camera',
      at(capturedFps: 10),
      PipelineBottleneck.camera,
    );
    eq(
      'an encoder below the camera is the encoder',
      at(capturedFps: 30, encodedFps: 10),
      PipelineBottleneck.encoder,
    );
    eq(
      'a wire below the encoder is the wire',
      at(capturedFps: 30, encodedFps: 30, sentFps: 10),
      PipelineBottleneck.network,
    );
  }

  section('the first shortfall in the chain wins');
  {
    // An upstream bottleneck drags every downstream number down with it, so
    // blaming the last stage would send an operator to the network for a
    // problem in the sensor. All three are short here; the camera is the cause.
    eq(
      'the camera outranks the encoder and the wire',
      classifyBottleneck(
        recording: true,
        targetFps: 30,
        capturedFps: 5,
        encodedFps: 2,
        sentFps: 1,
      ),
      PipelineBottleneck.camera,
    );
    eq(
      'and the encoder outranks the wire',
      classifyBottleneck(
        recording: true,
        targetFps: 30,
        capturedFps: 30,
        encodedFps: 5,
        sentFps: 1,
      ),
      PipelineBottleneck.encoder,
    );
  }

  section('the tolerance keeps a healthy pipeline from being blamed');
  {
    // Rates are sampled over separate rolling windows and floored, so two
    // stages that are keeping up still disagree by a frame or two. A strict
    // comparison would report a bottleneck on every read.
    eq(
      'a frame of disagreement is not a bottleneck',
      classifyBottleneck(
        recording: true,
        targetFps: 30,
        capturedFps: 30,
        encodedFps: 29,
        sentFps: 29,
      ),
      PipelineBottleneck.healthy,
    );
    // The threshold is 24 for a 30 fps target. The values here stay clear of it
    // rather than sitting on it: `30 * 0.8` is not exactly 24 in binary, and a
    // boundary case would be pinning the float, not the rule.
    eq(
      'twenty-five against a threshold of twenty-four is healthy',
      classifyBottleneck(
        recording: true,
        targetFps: 30,
        capturedFps: 30,
        encodedFps: 25,
        sentFps: 25,
      ),
      PipelineBottleneck.healthy,
    );
    eq(
      'twenty is below the threshold and is named',
      classifyBottleneck(
        recording: true,
        targetFps: 30,
        capturedFps: 30,
        encodedFps: 20,
        sentFps: 20,
      ),
      PipelineBottleneck.encoder,
    );
  }

  section('an unmeasured stage does not excuse the ones after it');
  {
    // Only capture is measured: the camera is still judgeable, and the stages
    // that have no number cannot be blamed.
    eq(
      'a camera below target is named even with nothing else measured',
      classifyBottleneck(
        recording: true,
        targetFps: 30,
        capturedFps: 3,
        encodedFps: null,
        sentFps: null,
      ),
      PipelineBottleneck.camera,
    );
    eq(
      'and a camera that kept up is healthy even then',
      classifyBottleneck(
        recording: true,
        targetFps: 30,
        capturedFps: 30,
        encodedFps: null,
        sentFps: null,
      ),
      PipelineBottleneck.healthy,
    );
  }

  // --- the snapshot ---------------------------------------------------------
  section('the diagnostics snapshot names its own bottleneck');
  {
    const diagnostics = StreamDiagnostics(
      recording: true,
      targetFps: 30,
      selectedFps: 5,
      capturedFps: 30,
      encodedFps: 30,
      sentFps: 4,
      codec: CaptureCodec.mjpeg,
      width: 1920,
      height: 1080,
      droppedFrames: 7,
      repeatedFrames: 2,
    );
    eq(
      'the snapshot classifies itself',
      diagnostics.bottleneck,
      PipelineBottleneck.network,
    );
    eq('and reports the declared rate', diagnostics.selectedFps, 5);
    eq(
      'an idle snapshot is idle',
      StreamDiagnostics.idle.bottleneck,
      PipelineBottleneck.idle,
    );
    eq('with no rates at all', StreamDiagnostics.idle.capturedFps, null);
  }
}
