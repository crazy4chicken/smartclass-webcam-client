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
