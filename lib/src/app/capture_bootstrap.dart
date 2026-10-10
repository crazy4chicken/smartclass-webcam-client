import '../capture/camera_capabilities.dart';
import '../capture/camera_resolution.dart';
import '../capture/default_mode.dart';
import '../capture/encode_budget.dart';
import '../capture/stream_settings.dart';
import '../capture/sustained_rate.dart';

/// What the start-up path decided, and the measurement it came from.
///
/// One value rather than four loose locals because the four have to agree: the
/// geometry the pipeline opens at, the rate the registration declares, the
/// codecs the registration publishes, and the evidence behind all three. A
/// device that opens at 1080p, declares 60 and publishes H.265 because three
/// different places picked those numbers is the "declared ≠ delivered" bug in
/// its most expensive form — the server snapshots the mode into
/// `metadata` and trusts it.
class CapturePlan {
  const CapturePlan({
    required this.resolution,
    required this.fps,
    required this.codecs,
    required this.evidence,
  });

  /// The geometry the pipeline is **opened** at. See [defaultResolutionFor]:
  /// capped at 1080p, and taken from what the camera was measured producing.
  final CameraResolution resolution;

  /// The rate the registration **declares**.
  ///
  /// Not the rate the pump is asked for. The request is
  /// `AppConfig.defaultFps` and stays there — it is a ceiling on how often the
  /// pump ticks, not a promise. This number is what the server divides by to
  /// estimate segment durations, so it must be one the device was measured
  /// holding.
  final int fps;

  /// The codecs the registration publishes, in preference order: the first is
  /// what an unnamed `start_recording.codec` gets.
  final List<CaptureCodec> codecs;

  /// What the device was measured holding. Empty when nothing was measured,
  /// which is a legitimate answer and not a failure.
  final EncodeEvidence evidence;

  List<EncodeSample> get samples => evidence.samples;

  @override
  String toString() =>
      'CapturePlan(${resolution.label} @ ${fps}fps, '
      '${codecs.map((c) => c.wireName).join('/')}, $evidence)';
}

/// The device's measured encoding evidence, resolved once per launch.
///
/// Three ways out, and only one of them measures anything:
///
/// * **cache hit** — the stored evidence still describes this camera *and*
///   this encoder, so nothing is opened and nothing is measured. A kiosk's
///   second launch costs the same as its first boot whether or not it has a
///   hardware encoder.
/// * **no probe** — nothing can be measured, so [EncodeEvidence.empty] is
///   returned and **nothing is stored**: an unanswered question is not the same
///   as the answer "held nothing", and caching the first would keep a device
///   from ever noticing that an encoder arrived with a driver update. This is
///   today's state on every platform, and it is why the floor is what gets
///   announced.
/// * **measured** — the probe runs and its answer is stored, but only when it
///   describes *this* camera and *this* encoder. Evidence for a different
///   fingerprint is a miss, never a partial hit: see [EncodeEvidence.matches].
///
/// Must never throw. A start-up that dies because a cache or a probe misbehaved
/// is a kiosk that never comes up.
Future<EncodeEvidence> ensureEncodeEvidence({
  required EncodeEvidenceStore store,
  required EncodeBudgetProbe? probe,
  required String cameraFingerprint,
  required String encoderIdentity,
  required CameraResolution resolution,
  required List<CaptureCodec> candidates,
  int cameraEnum = 0,
  bool forceRemeasure = false,
  void Function(String message)? log,
}) async {
  if (!forceRemeasure) {
    EncodeEvidence? cached;
    try {
      cached = await store.load(
        cameraFingerprint: cameraFingerprint,
        encoderIdentity: encoderIdentity,
      );
    } catch (error) {
      // A cache that cannot be read is a miss, not a failure: the worst
      // outcome here is a device that will not start.
      log?.call('[evidence] the cache could not be read: $error');
    }
    if (cached != null) {
      log?.call('[evidence] cached: $cached (nothing measured)');
      return cached;
    }
  }

  if (probe == null) {
    log?.call('[evidence] no platform probe: nothing was measured');
    return EncodeEvidence.empty;
  }

  EncodeEvidence measured;
  try {
    measured = await probe.measure(
      cameraEnum: cameraEnum,
      resolution: resolution,
      codecs: candidates,
      cameraFingerprint: cameraFingerprint,
      encoderIdentity: encoderIdentity,
    );
  } catch (error) {
    // A probe that throws measured nothing. It must not be allowed to take the
    // start-up down with it, and its failure is not a licence to guess.
    log?.call('[evidence] measurement failed: $error');
    return EncodeEvidence.empty;
  }

  if (measured.isInvalid ||
      !measured.matches(
        cameraFingerprint: cameraFingerprint,
        encoderIdentity: encoderIdentity,
      )) {
    // Answered for a different camera or a different encoder. Its numbers are
    // real but they are not about this device, and using them would put a rate
    // nothing here ever held into the registration.
    log?.call('[evidence] the probe answered for something else: $measured');
    return EncodeEvidence.empty;
  }

  try {
    await store.save(measured);
  } catch (error) {
    // A result that could not be cached is still a result: the only cost is
    // measuring again next launch.
    log?.call('[evidence] the result could not be cached: $error');
  }
  log?.call('[evidence] measured: $measured');
  return measured;
}

/// The codecs [available] claims, in preference order.
///
/// One definition for the three places that have to agree about which codecs
/// are even in question: what the probe is asked to measure, what the mode is
/// seeded from, and what may be published. Two of them computing it differently
/// is how a device ends up declaring a rate derived from a codec it cannot
/// produce.
List<CaptureCodec> claimedCodecs(Set<CaptureCodec> available) =>
    List<CaptureCodec>.unmodifiable(<CaptureCodec>[
      for (final codec in CaptureCodec.preference)
        if (available.contains(codec)) codec,
      // Appended rather than dropped: a claimed codec outside the preference
      // list is still one the device can produce.
      for (final codec in CaptureCodec.values)
        if (available.contains(codec) &&
            !CaptureCodec.preference.contains(codec))
          codec,
    ]);

/// Whether [codec] may be published at [resolution] @ [fps].
///
/// Mode-scoped, and that is the point: [canServeMode] answers "did this codec
/// hold *this* rate at *this* geometry", so an encoder that held 1080p30 is not
/// available at 1080p60. With nothing measured it answers no for everything,
/// which is why the floor is carried by [announcedCodecsFor]'s fallback rather
/// than by a special case here.
bool _mayAnnounce({
  required CaptureCodec codec,
  required EncodeEvidence evidence,
  required CameraResolution resolution,
  required int fps,
}) => canServeMode(
  samples: evidence.samples,
  codec: codec,
  resolution: resolution,
  fps: fps,
);

/// The codecs this device may publish at [resolution] @ [fps].
///
/// Two filters, and both are needed:
///
/// * **claim** — [available] is what the platform says it can produce. A codec
///   nobody claims is not one a probe can be asked for.
/// * **evidence** — a claimed codec is published only when it was *measured
///   holding this rate at this geometry*. That the platform **has** an encoder
///   says nothing about the rate it holds, and publishing it on the strength of
///   its existence is how a device comes to offer a stream it cannot deliver.
///
/// The result is never empty: an empty `supported_codec` is a `400`, and a
/// device that cannot register is worse than one that publishes only the floor.
/// Same reasoning, and the same answer, as `CodecSelector.select` and
/// `buildAnnouncements`. `mjpeg` is a defensible floor rather than a guess —
/// `takePicture()` returns a JPEG on all five platforms — which is also why a
/// device with no probe still has a working preview, photos and stream.
List<CaptureCodec> announcedCodecsFor({
  required Set<CaptureCodec> available,
  required EncodeEvidence evidence,
  required CameraResolution resolution,
  required int fps,
  Iterable<CaptureCodec> candidates = CaptureCodec.preference,
}) {
  final announced = <CaptureCodec>[
    for (final codec in candidates)
      if (available.contains(codec) &&
          _mayAnnounce(
            codec: codec,
            evidence: evidence,
            resolution: resolution,
            fps: fps,
          ))
        codec,
    // Appended rather than dropped: a claimed codec outside the preference list
    // is still one the device can produce, and silently omitting it would make
    // the published list narrower than the platform's own answer.
    for (final codec in CaptureCodec.values)
      if (available.contains(codec) &&
          !candidates.contains(codec) &&
          _mayAnnounce(
            codec: codec,
            evidence: evidence,
            resolution: resolution,
            fps: fps,
          ))
        codec,
  ];

  if (announced.isEmpty) return const <CaptureCodec>[CaptureCodec.mjpeg];
  return List<CaptureCodec>.unmodifiable(announced);
}

/// Decides what to open, what to declare and what to publish, in that order.
///
/// **The order is the point**, and it is the whole of task #14's "先 inventory /
/// 实测证据，再默认模式，再打开管线，再同源注册":
///
/// 1. The geometry comes from the inventory alone. [defaultResolutionFor] needs
///    no samples — a camera's ceiling is measured by opening it, and 1080p is
///    the cap — so the resolution is known before anything is measured.
/// 2. Evidence is measured **at that geometry**. A rate is only ever sustained
///    at a geometry, so measuring first and choosing the geometry afterwards
///    would produce a number for a mode the device is not in.
/// 3. The declared rate comes from the evidence, never from the request.
/// 4. The published codecs come from the evidence *and* the rate, so the list
///    describes what the device will actually deliver in this mode.
///
/// A platform with no [probe] gets the floor: `mjpeg` at
/// [kFpsWithoutEvidence], which is exactly what such a device can honour —
/// preview, photos and an mjpeg stream all still work.
Future<CapturePlan> planCapture({
  required CameraCapabilities measured,
  required Set<CaptureCodec> available,
  required EncodeEvidenceStore store,
  required EncodeBudgetProbe? probe,
  required String cameraFingerprint,
  required String encoderIdentity,
  required CameraResolution fallbackResolution,
  int cameraEnum = 0,
  bool forceRemeasure = false,
  void Function(String message)? log,
}) async {
  final resolution = defaultResolutionFor(
    measured: measured,
    fallback: fallbackResolution,
  );

  final candidates = claimedCodecs(available);

  final evidence = await ensureEncodeEvidence(
    store: store,
    probe: probe,
    cameraFingerprint: cameraFingerprint,
    encoderIdentity: encoderIdentity,
    resolution: resolution,
    candidates: candidates,
    cameraEnum: cameraEnum,
    forceRemeasure: forceRemeasure,
    log: log,
  );

  // [candidates] rather than every codec with a sample: a rate only counts if
  // the device can produce the codec that held it. Without this, a sample for
  // a codec the platform does not have would declare a rate nothing here can
  // deliver — and the published list, which is filtered by [available], would
  // then describe a different device from the declared rate.
  final fps = defaultFpsFor(
    resolution: resolution,
    samples: evidence.samples,
    unmeasuredFps: kFpsWithoutEvidence,
    codecs: candidates,
  );

  return CapturePlan(
    resolution: resolution,
    fps: fps,
    codecs: announcedCodecsFor(
      available: available,
      evidence: evidence,
      resolution: resolution,
      fps: fps,
    ),
    evidence: evidence,
  );
}
