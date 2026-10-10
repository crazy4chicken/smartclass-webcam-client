import 'camera_capabilities.dart';
import 'camera_resolution.dart';
import 'stream_settings.dart';

/// One measurement: the encoder held [measuredFps] for [codec] at [resolution].
///
/// A sample is evidence, not a claim: it records what the encoder actually
/// sustained during one probe run. Two runs at the same geometry disagree
/// routinely (thermal state, other consumers of the same encoder), which is why
/// the fastest run is taken as the better evidence rather than the slowest
/// being taken as the safer one — the slowest run's number is still honest
/// evidence *of that run*, and picking it would understate the device.
class EncodeSample {
  const EncodeSample({
    required this.codec,
    required this.resolution,
    required this.measuredFps,
  });

  final CaptureCodec codec;
  final CameraResolution resolution;

  /// Frames per second the encoder actually sustained, not the target rate.
  final int measuredFps;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EncodeSample &&
          other.codec == codec &&
          other.resolution == resolution &&
          other.measuredFps == measuredFps;

  @override
  int get hashCode => Object.hash(codec, resolution, measuredFps);

  @override
  String toString() =>
      'EncodeSample(${codec.wireName}, ${resolution.label} @ '
      '${measuredFps}fps)';
}

/// Frame rates the device can actually hold, per codec, at [resolution].
///
/// A candidate is declared only when the encoder measurably held it. Rates are
/// rounded DOWN — never up — and a codec that held nothing at this geometry is
/// omitted entirely rather than listed with an empty array.
///
/// The server applies **no pairwise restriction**: anything in
/// `supported_resolutions` may be combined with anything in
/// `supported_framerates`, and `start_recording` may name any codec in
/// `supported_codec`. So the device cannot declare "H.265 up to 1080p30" —
/// listing 1080p, 60 and h265 is exactly an offer to serve 1080p60 H.265.
/// Under-declaring costs an operator a setting; over-declaring costs them every
/// recording made at the rate that was not real, because the server trusts
/// `fps` to estimate segment durations.
///
/// Pure Dart: no `package:flutter`, so `tool/verify_pure.dart` can exercise it.
Map<CaptureCodec, List<int>> sustainableRates({
  required List<EncodeSample> samples,
  required CameraResolution resolution,
  required List<int> candidates,
}) {
  // Best measurement per codec at this geometry. A non-positive rate is not a
  // rate at all — it is a probe that never got going — so it contributes
  // nothing instead of poisoning the maximum.
  final best = <CaptureCodec, int>{};
  for (final sample in samples) {
    if (sample.resolution != resolution) continue;
    if (sample.measuredFps <= 0) continue;
    final current = best[sample.codec];
    if (current == null || sample.measuredFps > current) {
      best[sample.codec] = sample.measuredFps;
    }
  }

  // Built in `CaptureCodec.values` order so the map has one canonical shape
  // regardless of the order the probe happened to report in.
  final result = <CaptureCodec, List<int>>{};
  for (final codec in CaptureCodec.values) {
    final held = best[codec];
    if (held == null) continue;

    final rates = <int>{
      for (final candidate in candidates)
        if (candidate > 0 && candidate <= held) candidate,
    }.toList()..sort((a, b) => b.compareTo(a));

    // "Cannot do this at all" is absence, not an empty list: an empty
    // `supported_codec` entry is a 400 on the wire, and a caller cannot read
    // `rates[codec]` to tell the two apart if both are empty lists.
    if (rates.isEmpty) continue;
    result[codec] = List<int>.unmodifiable(rates);
  }
  return result;
}

/// Codecs worth announcing at this geometry: those with at least one
/// sustainable rate. This is the per-mode `supported_codec` list.
///
/// Ordered by `CaptureCodec.values`, not by speed or by probe order, so the
/// list the server stores is stable across runs — two registrations from the
/// same hardware must not differ merely because the probe finished in a
/// different order.
List<CaptureCodec> sustainableCodecs(Map<CaptureCodec, List<int>> rates) =>
    List<CaptureCodec>.unmodifiable(<CaptureCodec>[
      for (final codec in CaptureCodec.values)
        if (rates[codec]?.isNotEmpty ?? false) codec,
    ]);

/// The fastest rate [codec] held at [resolution], or null.
///
/// Null means "no usable measurement", which covers both an absent sample and a
/// sample that never sustained anything: neither is a rate the device may
/// declare.
int? maxSustainableFps({
  required List<EncodeSample> samples,
  required CameraResolution resolution,
  required CaptureCodec codec,
}) {
  var best = 0;
  var found = false;
  for (final sample in samples) {
    if (sample.codec != codec || sample.resolution != resolution) continue;
    if (sample.measuredFps <= 0) continue;
    if (!found || sample.measuredFps > best) {
      best = sample.measuredFps;
      found = true;
    }
  }
  return found ? best : null;
}

/// Whether [codec] measurably held [fps] at [resolution].
///
/// **Mode-scoped, and that is the whole point.** A codec that held 30 says
/// nothing about 60: encoders are configured per mode and the hardware's
/// ceiling moves with the pixel rate, so "H.265 works on this device" is not an
/// answerable question — "H.265 works at 1080p60" is. Answering the first one
/// from evidence for the second is how a device ends up announcing a codec
/// that produces a stream nobody can decode.
bool canServeMode({
  required List<EncodeSample> samples,
  required CaptureCodec codec,
  required CameraResolution resolution,
  required int fps,
}) {
  if (fps <= 0) return false;
  final held = maxSustainableFps(
    samples: samples,
    resolution: resolution,
    codec: codec,
  );
  // No measurement is not a yes. Absence has to read as "unknown, so no",
  // because the caller's alternative is a codec it does have evidence for —
  // and guessing in the other direction is what puts an unusable codec first
  // in a list the server treats as a promise.
  return held != null && held >= fps;
}

/// The codecs that measurably serve [resolution] at [fps], best first.
///
/// Ordered by [candidates] — [CaptureCodec.preference] by default, so H.265
/// wins when it holds the mode and H.264 is next — rather than by how fast
/// each codec measured. Preference is a policy; the measurement is only the
/// filter that decides who is eligible.
///
/// This is the per-mode `supported_codec` list, and it is deliberately stricter
/// than [sustainableCodecs]: that one answers "does this codec hold *any* rate
/// here", which is the question for a capability page. This one answers "does
/// it hold *this* rate", which is the question behind an ack.
List<CaptureCodec> sustainableCodecsAt({
  required List<EncodeSample> samples,
  required CameraResolution resolution,
  required int fps,
  Iterable<CaptureCodec> candidates = CaptureCodec.preference,
}) => List<CaptureCodec>.unmodifiable(<CaptureCodec>[
  for (final codec in candidates)
    if (canServeMode(
      samples: samples,
      codec: codec,
      resolution: resolution,
      fps: fps,
    ))
      codec,
]);

/// The cache format version, bumped whenever a stored sample changes meaning.
///
/// Not a nicety: a sample is a claim about a rate, and a change in how rates
/// are measured or what counts as evidence silently invalidates every stored
/// one. Bumping this turns an entire generation of stale evidence into misses
/// in one place, rather than trusting numbers produced by a rule that no
/// longer exists.
const int kEncodeEvidenceVersion = 1;

/// One camera set's measured encoding evidence, as cached between launches.
///
/// The three things it is keyed by are the three things that can invalidate a
/// sample:
///
/// * [version] — the meaning of a sample changed (see
///   [kEncodeEvidenceVersion]);
/// * [cameraFingerprint] — the hardware changed, so a rate measured on a
///   different camera says nothing about this one;
/// * [encoderIdentity] — the encoder changed. What a hardware H.265 encoder
///   holds and what a software fallback holds are different numbers, and a
///   platform is free to move between them after an OS or driver update.
///
/// A mismatch on any of the three is a **miss**, never a partial hit. There is
/// no "close enough" here: the whole reason this exists is that a rate a
/// device cannot hold is worse than no rate at all, because the server trusts
/// `fps` to estimate segment durations.
///
/// Pure Dart, for the same reason [EncodeSample] is: the rules about what
/// counts as evidence are the part worth exercising on a plain VM.
class EncodeEvidence {
  const EncodeEvidence({
    required this.version,
    required this.cameraFingerprint,
    required this.encoderIdentity,
    required this.samples,
  });

  final int version;
  final String cameraFingerprint;

  /// What produced the samples, as the platform named it.
  ///
  /// Empty when the platform did not say — which is a legitimate answer and
  /// weaker evidence, not a disqualification: it still identifies *a* run, it
  /// just cannot tell two different encoders apart.
  final String encoderIdentity;

  final List<EncodeSample> samples;

  /// Nothing measured, as a **result**: the device was asked and held nothing.
  ///
  /// Worth caching rather than re-measuring, because "this device has no
  /// hardware encoder" is a stable fact and probing for one costs a launch. It
  /// is still invalidated by [matches] like any other evidence, so a driver or
  /// OS update that brings an encoder with it produces a miss.
  static const EncodeEvidence empty = EncodeEvidence(
    version: kEncodeEvidenceVersion,
    cameraFingerprint: '',
    encoderIdentity: '',
    samples: <EncodeSample>[],
  );

  /// A payload that could not be trusted, which is not the same as [empty].
  ///
  /// Conflating the two would make a corrupt cache indistinguishable from a
  /// device that genuinely has no encoder — and the difference is a whole
  /// re-measure on every launch versus none.
  static const EncodeEvidence invalid = EncodeEvidence(
    version: -1,
    cameraFingerprint: '',
    encoderIdentity: '',
    samples: <EncodeSample>[],
  );

  bool get isEmpty => samples.isEmpty;

  /// True for a payload [fromJson] could not trust. Callers treat this as a
  /// miss and re-measure.
  bool get isInvalid => version < 0;

  /// Whether this evidence still describes the device as it is now.
  bool matches({
    required String cameraFingerprint,
    required String encoderIdentity,
  }) =>
      version == kEncodeEvidenceVersion &&
      this.cameraFingerprint == cameraFingerprint &&
      this.encoderIdentity == encoderIdentity;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'camera_fingerprint': cameraFingerprint,
    'encoder': encoderIdentity,
    'samples': <Object?>[
      for (final sample in samples)
        <String, Object?>{
          'codec': sample.codec.wireName,
          'resolution': sample.resolution.label,
          'fps': sample.measuredFps,
        },
    ],
  };

  /// Reads a payload, answering [invalid] rather than throwing.
  ///
  /// A corrupt cache must never keep a kiosk from starting, and it must never
  /// be *partly* trusted: a payload with one good sample and one garbage entry
  /// has unknown provenance, so the whole thing is dropped. Half-trusting it is
  /// how a rate that was never measured ends up in a registration.
  ///
  /// No samples is a **valid** answer, not a corrupt one — see [empty].
  static EncodeEvidence fromJson(Object? raw) {
    if (raw is! Map) return invalid;

    final version = raw['version'];
    if (version is! int || version != kEncodeEvidenceVersion) return invalid;

    final samples = <EncodeSample>[];
    final rawSamples = raw['samples'];
    if (rawSamples is! List) return invalid;
    for (final entry in rawSamples) {
      if (entry is! Map) return invalid;
      final codec = CaptureCodec.tryParse(entry['codec']);
      final resolution = parseResolutionLabel(entry['resolution']);
      final fps = entry['fps'];
      // One unreadable entry invalidates the payload: a set of samples is only
      // as trustworthy as its weakest member, and the cost of dropping them is
      // a re-measure, which is cheap next to a wrong rate.
      if (codec == null || resolution == null || fps is! int) return invalid;
      samples.add(
        EncodeSample(codec: codec, resolution: resolution, measuredFps: fps),
      );
    }

    return EncodeEvidence(
      version: version,
      cameraFingerprint: raw['camera_fingerprint'] is String
          ? raw['camera_fingerprint'] as String
          : '',
      encoderIdentity: raw['encoder'] is String ? raw['encoder'] as String : '',
      samples: List<EncodeSample>.unmodifiable(samples),
    );
  }

  @override
  String toString() =>
      'EncodeEvidence(v$version, ${encoderIdentity.isEmpty ? 'encoder?' : encoderIdentity}, '
      '${samples.length} samples)';
}

/// Where measured encoding evidence is cached between launches.
///
/// **Not part of `SettingsStore`, and not part of `CapabilitiesStore` either.**
/// Same reason as the capability cache — `save()` there means *replace*, and
/// routing evidence through connection settings would delete a working
/// device's credentials — but also a different lifecycle: capability probing is
/// invalidated by hardware, encoding evidence by hardware *and* by the encoder,
/// so a re-probe of one must not silently clear the other.
abstract interface class EncodeEvidenceStore {
  /// The cached evidence for [cameraFingerprint], or null.
  ///
  /// Null means **measure again**, for all of: nothing stored, a different
  /// camera set, a different encoder, an older format version, and a payload
  /// that will not parse. Corrupt is a miss rather than an empty answer,
  /// because a hit that keeps coming back never self-heals.
  Future<EncodeEvidence?> load({
    required String cameraFingerprint,
    required String encoderIdentity,
  });

  Future<void> save(EncodeEvidence value);

  Future<void> clear();
}

/// [EncodeEvidenceStore] that keeps one value in memory.
///
/// The harness uses this to exercise the rules without `shared_preferences`,
/// and a platform with no encoder uses it to answer "no evidence" honestly.
class InMemoryEncodeEvidenceStore implements EncodeEvidenceStore {
  EncodeEvidence? value;

  @override
  Future<EncodeEvidence?> load({
    required String cameraFingerprint,
    required String encoderIdentity,
  }) async {
    final stored = value;
    if (stored == null || stored.isInvalid) return null;
    // Stored under one key on purpose: there is exactly one camera set and one
    // encoder per device, so a mismatch on either is a miss, not a lookup that
    // returns another device's evidence.
    if (!stored.matches(
      cameraFingerprint: cameraFingerprint,
      encoderIdentity: encoderIdentity,
    )) {
      return null;
    }
    return stored;
  }

  @override
  Future<void> save(EncodeEvidence value) async {
    this.value = value;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}
