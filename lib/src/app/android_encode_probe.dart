import 'dart:async';

import '../capture/camera_resolution.dart';
import '../capture/encode_budget.dart';
import '../capture/stream_settings.dart';
import '../capture/sustained_rate.dart';
// `EncodedFrame` lives here. Importing `sustained_rate.dart` is not enough: it
// *uses* the type in `measureDeliveredRate`'s signature but does not re-export
// the file that defines it, so the name was simply missing from this scope.
import '../capture/video_encoder.dart';
import '../config/app_config.dart';
import 'android_encoded_stream.dart';

/// Measures what the Android encoder chain really delivers, so the device can
/// stop announcing the mjpeg floor.
///
/// This is the missing link, not a nicety. `announcedCodecsFor` intersects what
/// the platform *claims* with what was *measured*, and until something
/// implements [EncodeBudgetProbe] the measured set is empty on every platform —
/// so the announced list is `mjpeg`, the server never names `h265`, and the
/// native encoder that was wired up in Task 4 is unreachable no matter how well
/// it works. A claim is not evidence; this produces the evidence.
///
/// **It never invents a number.** A codec whose encoder refuses to be built, or
/// that delivers nothing, contributes no sample. Zero-delivered is a legitimate
/// measurement and an absent sample is not the same thing — `AGENTS.md` forbids
/// constant-zero filler outright, and a fabricated rate would end up in a
/// registration the server divides by.
///
/// **It announces nothing.** What may be published, and at what rate, is
/// decided by `planCapture` and `defaultFpsFor` from the evidence returned
/// here. This class has no opinion about either.
///
/// Cost: one bounded run per codec on the first launch, and nothing afterwards
/// while the cache still describes this camera and this encoder. The windows
/// are [SustainedRateMeter]'s shipped defaults; `rate_calibration.dart` exists
/// to test whether they are long enough for *this* hardware, and shortening
/// them is a follow-up, not a guess to make here.
class AndroidEncodeBudgetProbe implements EncodeBudgetProbe {
  AndroidEncodeBudgetProbe({
    required AndroidEncodedStreamFactory factory,
    this.requestFps = AppConfig.defaultFps,
    this.quality = AppConfig.defaultQuality,
    this.warmup = const Duration(milliseconds: 1500),
    this.window = const Duration(seconds: 3),
    this.slack = const Duration(milliseconds: 1500),
    DateTime Function()? clock,
    this.log,
  }) : _factory = factory,
       _clock = clock ?? DateTime.now;

  final AndroidEncodedStreamFactory _factory;

  /// The frame rate the pipeline is *asked* for.
  ///
  /// Asking for 60 is the whole point: the request is the ceiling the pump is
  /// built to reach, and what comes back is what the device delivered. Nothing
  /// here treats 60 as an answer.
  final int requestFps;

  /// The encoder quality knob for the measured runs.
  final int quality;

  /// Frames at the start of a run that are measured but not counted.
  final Duration warmup;

  /// How long the counted part of a run lasts.
  final Duration window;

  /// Extra time a run is given beyond [warmup] + [window].
  ///
  /// A pipeline that dies mid-run never delivers the frame that would close the
  /// meter's window, so the run needs its own timer. This is that timer's
  /// margin: without it, a stalled encoder would hold start-up open forever.
  final Duration slack;

  final DateTime Function() _clock;
  final void Function(String message)? log;

  @override
  Future<EncodeEvidence> measure({
    required int cameraEnum,
    required CameraResolution resolution,
    required List<CaptureCodec> codecs,
    required String cameraFingerprint,
    required String encoderIdentity,
  }) async {
    final measurements = <CaptureCodec, FrameRateMeasurement>{};

    for (final codec in codecs) {
      final measurement = await _measureCodec(
        codec: codec,
        cameraEnum: cameraEnum,
        resolution: resolution,
      );
      if (measurement != null) measurements[codec] = measurement;
    }

    // The identity is echoed, never derived: `ensureEncodeEvidence` throws away
    // evidence that answers for a different encoder, and a probe that named
    // itself differently from its caller would be discarded on every launch —
    // measuring for minutes and publishing nothing.
    return evidenceFromMeasurements(
      cameraFingerprint: cameraFingerprint,
      encoderIdentity: encoderIdentity,
      measurements: measurements,
      resolution: resolution,
    );
  }

  /// Runs one codec once and reports what it delivered, or null for no sample.
  Future<FrameRateMeasurement?> _measureCodec({
    required CaptureCodec codec,
    required int cameraEnum,
    required CameraResolution resolution,
  }) async {
    // A stream id per codec, because the plugin binds one use case per open and
    // two runs sharing an id would be indistinguishable in a native log.
    final encoder = _factory.encoderFor(
      codec: codec,
      cameraEnum: cameraEnum,
      streamId: 'encode-probe-${codec.wireName}',
    );
    if (encoder == null) {
      // A refusal, not a failure: this codec has no encoder behind it on this
      // device, so it contributes no sample. Nothing is recorded as zero.
      log?.call('[probe] ${codec.wireName}: no encoder, not measured');
      return null;
    }

    final meter = SustainedRateMeter(warmup: warmup, window: window);
    StreamSubscription<EncodedFrame>? subscription;
    try {
      await encoder.start(
        width: resolution.width,
        height: resolution.height,
        fps: requestFps,
        quality: quality,
      );
      subscription = measureDeliveredRate(
        encoder: encoder,
        meter: meter,
        clock: _clock,
      );
      // Bounded: the meter closes itself on the first frame at or after its
      // window ends, and this wait is what ends a run that stopped delivering
      // before that frame ever arrived.
      await Future<void>.delayed(warmup + window + slack);
    } catch (error) {
      log?.call('[probe] ${codec.wireName}: run failed: $error');
      return null;
    } finally {
      await subscription?.cancel();
      try {
        // Stops the producer and waits for the flushed tail. A failure here
        // costs the sample, not the launch.
        await encoder.stop();
      } catch (error) {
        log?.call('[probe] ${codec.wireName}: stop failed: $error');
      }
    }

    // `close` is what makes a zero expressible: frames that arrived but stopped
    // before the counted window produce a real zero, while a run that never
    // delivered a single frame produces null — "not measured" rather than
    // "measured and held nothing".
    final measurement = meter.measurement ?? meter.close(at: _clock());
    if (measurement == null) {
      log?.call('[probe] ${codec.wireName}: nothing was delivered');
      return null;
    }
    log?.call('[probe] ${codec.wireName} @ ${resolution.label}: $measurement');
    return measurement;
  }
}
