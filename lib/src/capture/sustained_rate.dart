import 'dart:async';

import 'camera_capabilities.dart';
import 'camera_resolution.dart';
import 'encode_budget.dart';
import 'stream_settings.dart';
import 'video_encoder.dart';

/// What a pipeline actually delivered during one measurement window.
///
/// The number that matters is [fps]: frames the pipeline **handed over**, not
/// frames it was asked for. Everything else is here so an operator can tell
/// *why* a rate came out low — a slow camera, a padded stream, or a window that
/// never really started.
class FrameRateMeasurement {
  const FrameRateMeasurement({
    required this.fps,
    required this.newFrames,
    required this.duplicateFrames,
    required this.warmupFrames,
    required this.window,
  });

  /// New frames per second over [window], rounded **down**.
  ///
  /// Floored, never rounded to nearest, for the same reason
  /// [sustainableRates] floors: a rate is a ceiling that was demonstrated, and
  /// 58.7 frames a second is evidence for 58, not for 59.
  final int fps;

  /// Frames whose source sequence advanced — the only ones that count.
  final int newFrames;

  /// Frames that repeated a sequence already seen.
  ///
  /// Impossible on the still-picture path, where every capture is a fresh
  /// `takePicture()`, and the whole reason this counter exists on the encoded
  /// path: a GStreamer pipeline with `videorate` will happily hand out 60
  /// frames a second by repeating the last one, and counting those as delivery
  /// is how a device comes to announce a rate nothing is producing.
  final int duplicateFrames;

  /// Frames discarded as warm-up. Reported, not counted.
  final int warmupFrames;

  /// How long the counted part lasted, excluding warm-up.
  final Duration window;

  bool get heldAnything => fps > 0;

  @override
  String toString() =>
      'FrameRateMeasurement($fps fps over ${window.inMilliseconds}ms, '
      '$newFrames new, $duplicateFrames dup, $warmupFrames warmup)';
}

/// Counts what a running pipeline really delivers, from its own frame stream.
///
/// **This is the only honest source of a frame rate.** The capability probe
/// cannot supply one: it opens a camera with `fps: 60` and calls the request
/// accepted when `initialize()` returns, which says the plugin did not refuse
/// the number, not that anything will be produced at it. The delivery ceiling
/// is set by the capture path — one `takePicture()` per frame, roughly 5-10 fps
/// at 1080p — and nothing in the plugin API reports it. So it has to be
/// measured by running.
///
/// Three rules, each closing a specific way of getting a number that is too
/// high:
///
/// * **Warm-up is discarded.** The first frames after a start are the slowest:
///   the sensor is still settling and the first `takePicture()` pays for a
///   pipeline that later ones reuse. Counting them drags the average down;
///   counting the *rest* and calling it the rate is the point.
/// * **Only new frames count.** A repeated frame is not delivery. See
///   [FrameRateMeasurement.duplicateFrames].
/// * **The window is fixed, not "however long it took".** A meter that stops
///   when it feels like it will report the rate of its best burst.
///
/// Pure Dart and clock-injected, so the gate can drive it without a camera.
class SustainedRateMeter {
  SustainedRateMeter({
    this.warmup = const Duration(milliseconds: 1500),
    this.window = const Duration(seconds: 3),
  });

  /// Frames at the start that are measured but not counted.
  final Duration warmup;

  /// How long the counted part runs.
  final Duration window;

  DateTime? _startedAt;
  int _lastSourceSeq = -1;
  int _newFrames = 0;
  int _duplicateFrames = 0;
  int _warmupFrames = 0;
  FrameRateMeasurement? _measurement;

  bool get isComplete => _measurement != null;

  /// The result, or null while the window is still open.
  FrameRateMeasurement? get measurement => _measurement;

  /// Feeds one delivered frame, and returns the measurement on the first frame
  /// that lands at or after the end of the window.
  ///
  /// That frame is **not counted** — the window is `[warmupEnd, windowEnd)`, so
  /// a frame exactly on the boundary belongs to the next window, not this one.
  /// Counting it would make the rate depend on the sampling phase.
  ///
  /// Frames arriving after the window closes are ignored: the first window's
  /// answer is the one that gets cached, and letting a later burst overwrite it
  /// would mean the number depends on when the caller happened to stop.
  FrameRateMeasurement? onFrame({
    required int sourceSeq,
    required DateTime at,
  }) {
    if (_measurement != null) return _measurement;

    final started = _startedAt ??= at;
    final warmupEnds = started.add(warmup);
    final windowEnds = warmupEnds.add(window);

    if (!at.isBefore(windowEnds)) return close(at: at);

    // The sequence is tracked even during warm-up, so a frame counted as
    // warm-up can never be counted again as new.
    final isNew = sourceSeq > _lastSourceSeq;
    if (isNew) _lastSourceSeq = sourceSeq;

    if (at.isBefore(warmupEnds)) {
      _warmupFrames++;
    } else if (isNew) {
      _newFrames++;
    } else {
      _duplicateFrames++;
    }
    return null;
  }

  /// Ends the window early, at [at], and returns the measurement.
  ///
  /// Needed because the meter is driven by frames: a pipeline that delivers two
  /// frames and then stalls would otherwise never close its window, and "the
  /// device held nothing" would be indistinguishable from "nobody looked". A
  /// probe owns a real timer and calls this when it expires, which is what
  /// makes a zero result expressible — and a zero result is a **measurement**,
  /// not an absence of one.
  FrameRateMeasurement? close({required DateTime at}) {
    if (_measurement != null) return _measurement;

    final started = _startedAt;
    // Nothing ever arrived: the window never opened, so there is no rate to
    // report and no window to divide by. Null, not zero — the caller has to be
    // able to tell "not measured" from "measured, held nothing".
    if (started == null) return null;

    // Measured over the counted window, not over `at - started`: the latter
    // would include the warm-up and quietly divide by a longer time, which
    // reads as a lower rate the longer the warm-up is.
    final seconds = window.inMicroseconds / Duration.microsecondsPerSecond;
    _measurement = FrameRateMeasurement(
      fps: seconds <= 0 ? 0 : (_newFrames / seconds).floor(),
      newFrames: _newFrames,
      duplicateFrames: _duplicateFrames,
      warmupFrames: _warmupFrames,
      window: window,
    );
    return _measurement;
  }

  void reset() {
    _startedAt = null;
    _lastSourceSeq = -1;
    _newFrames = 0;
    _duplicateFrames = 0;
    _warmupFrames = 0;
    _measurement = null;
  }
}

/// Measures what a device can actually sustain, and returns it as evidence.
///
/// The seam between the rules and the hardware. Everything above this line —
/// [EncodeEvidence], [sustainableRates], [canServeMode], the default-mode
/// selector — is pure Dart and already tested; what is missing is an
/// implementation per platform, and that is the whole of the remaining work on
/// the "declared 60, delivered 5-10" gap.
///
/// An implementation runs the real pipeline for a bounded window and reports
/// what came out. It must **never throw** and must return [EncodeEvidence.empty]
/// when it cannot measure: a probe that fails is not a licence to guess, and
/// the caller's fallback — not the probe — decides what an unmeasured device
/// declares.
///
/// It must also not report a rate it did not see. The temptation is to fill in
/// a codec's row from the capability probe's accepted rates; that is exactly
/// the substitution this interface exists to prevent.
abstract interface class EncodeBudgetProbe {
  /// Measures [cameraEnum] at [resolution], trying each of [codecs].
  ///
  /// [cameraFingerprint] and [encoderIdentity] are carried through into the
  /// returned evidence so a cached result can be invalidated when either
  /// changes.
  Future<EncodeEvidence> measure({
    required int cameraEnum,
    required CameraResolution resolution,
    required List<CaptureCodec> codecs,
    required String cameraFingerprint,
    required String encoderIdentity,
  });
}

/// Drives [meter] from a running [encoder], so the rate comes from what a real
/// producer delivered.
///
/// This is the seam that was missing. The meter's rules were tested from the
/// start, but nothing in the app fed it, so the one thing it exists to catch —
/// a producer padding its output with the last picture again — could neither
/// happen nor be seen. Feeding [EncodedFrame.sourceSeq] rather than counting
/// arrivals is what makes a repeat a repeat: [EncodedFrame.seq] advances for
/// every frame handed over, so counting that would report the padded rate.
///
/// The clock is injected and is deliberately **not** [EncodedFrame.ts]: a
/// repeated picture still arrives at a new moment, so the window has to
/// advance even when the sequence does not. Feeding the frame's own timestamp
/// would stall the window on exactly the stream the meter is there to unmask.
///
/// Returns the subscription; cancel it to stop measuring. Every platform's
/// `EncodeBudgetProbe` is expected to be this plus a bounded wait on [meter]
/// and a call to [SustainedRateMeter.close] when its timer expires.
StreamSubscription<EncodedFrame> measureDeliveredRate({
  required VideoEncoder encoder,
  required SustainedRateMeter meter,
  DateTime Function()? clock,
}) {
  final now = clock ?? DateTime.now;
  return encoder.frames.listen(
    (frame) => meter.onFrame(sourceSeq: frame.sourceSeq, at: now()),
  );
}

/// Builds [EncodeEvidence] from measurements, in one place.
///
/// A codec that held nothing is **omitted**, not recorded as zero: a zero
/// sample is skipped by [sustainableRates] anyway, and recording it would make
/// "measured and held nothing" look like "has a sample" to anything that counts
/// entries rather than rates.
EncodeEvidence evidenceFromMeasurements({
  required String cameraFingerprint,
  required String encoderIdentity,
  required Map<CaptureCodec, FrameRateMeasurement> measurements,
  required CameraResolution resolution,
}) => EncodeEvidence(
  version: kEncodeEvidenceVersion,
  cameraFingerprint: cameraFingerprint,
  encoderIdentity: encoderIdentity,
  samples: List<EncodeSample>.unmodifiable(<EncodeSample>[
    for (final entry in measurements.entries)
      if (entry.value.heldAnything)
        EncodeSample(
          codec: entry.key,
          resolution: resolution,
          measuredFps: entry.value.fps,
        ),
  ]),
);
