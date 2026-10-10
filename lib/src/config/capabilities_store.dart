import '../capture/camera_capabilities.dart';

/// Identifies a camera **set**, independent of order.
///
/// Order-insensitive on purpose. The canonical order is itself part of what
/// gets cached, so the key cannot be derived from it — that would be circular:
/// building the key would require ranking the cameras, and ranking is exactly
/// the work the cache exists to skip.
///
/// Sorting first is what makes `[a, b]` and `[b, a]` one set. They are: the same
/// hardware enumerated in a different order, which happens whenever a USB
/// camera is replugged.
///
/// Length-prefixed rather than joined on a separator, because names come from
/// the platform and can contain anything: `['a|b']` and `['a', 'b']` must not
/// collide. A plain encoding rather than a hash — it is short, it has no
/// collision risk at all, and it is readable in `shared_preferences` when
/// someone is debugging a device by hand.
String cameraFingerprint(List<String> cameraNames) {
  final sorted = List<String>.of(cameraNames)..sort();
  final buffer = StringBuffer();
  for (final name in sorted) {
    buffer
      ..write(name.length)
      ..write(':')
      ..write(name)
      ..write(';');
  }
  return buffer.toString();
}

/// The capability cache payload version, bumped whenever a stored declared
/// list changes meaning.
///
/// The declared list is **built**, not measured: `withCommonBaseline` folds the
/// common ladder into it under a rule that can change. A cache written by the
/// old rule must not be trusted by the new code — otherwise a device keeps its
/// old declared list (and possibly its old, wrong default) until someone
/// presses "re-detect". Bumping this turns every payload of the previous
/// generation into a miss in one place. Same precedent as
/// `kEncodeEvidenceVersion` in `encode_budget.dart`: a named constant, bumped
/// when the meaning of the stored value changes.
const int kCapabilitiesCacheVersion = 1;

/// One camera set's cached measurement.
///
/// **The order is part of the payload, and that is the point.** The device
/// announces `camera_enum` positionally, so a cache hit has to reproduce both
/// *which* cameras are present and *what order* they were ranked into. Caching
/// only the capabilities would still leave the order to be worked out, and
/// working it out means opening every camera once.
class CachedCapabilities {
  const CachedCapabilities({
    this.version = kCapabilitiesCacheVersion,
    required this.order,
    required this.byEnum,
  });

  /// The rule that built the declared lists in [byEnum]. A payload whose
  /// version is not [kCapabilitiesCacheVersion] is a miss — see
  /// [kCapabilitiesCacheVersion].
  final int version;

  /// Camera names in canonical order — the position *is* `camera_enum`.
  final List<String> order;

  /// What each camera accepts, indexed by `camera_enum`.
  final List<CameraCapabilities> byEnum;

  static const CachedCapabilities empty = CachedCapabilities(
    order: <String>[],
    byEnum: <CameraCapabilities>[],
  );

  /// Nothing worth using: a payload that would not parse, or one that is
  /// self-inconsistent. The caller treats this as a miss.
  bool get isEmpty => order.isEmpty || order.length != byEnum.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'order': order,
    'cameras': <Object?>[for (final camera in byEnum) camera.toJson()],
  };

  /// Reads a payload, answering [empty] rather than throwing.
  ///
  /// A malformed cache is a miss, not a crash: the next launch re-probes and
  /// overwrites it. The order and the per-camera list must agree in length —
  /// a payload where they disagree describes a camera set that does not exist,
  /// and acting on it would map capabilities onto the wrong enums.
  ///
  /// A payload without the current [version] tag is a miss, never a crash.
  /// This is a kiosk boot path: an older cache is not corrupt, it is simply
  /// built by a rule that no longer exists, and re-probing is the only honest
  /// answer.
  static CachedCapabilities fromJson(Object? raw) {
    if (raw is! Map) return empty;

    final version = raw['version'];
    if (version is! int || version != kCapabilitiesCacheVersion) return empty;

    final rawOrder = raw['order'];
    if (rawOrder is! List) return empty;
    final order = <String>[
      for (final name in rawOrder)
        if (name is String) name,
    ];
    if (order.length != rawOrder.length) return empty;

    final rawCameras = raw['cameras'];
    if (rawCameras is! List) return empty;
    if (rawCameras.length != order.length) return empty;

    return CachedCapabilities(
      order: List<String>.unmodifiable(order),
      byEnum: List<CameraCapabilities>.unmodifiable(<CameraCapabilities>[
        for (final camera in rawCameras) CameraCapabilities.fromJson(camera),
      ]),
    );
  }

  @override
  String toString() =>
      'CachedCapabilities(${order.join(' → ')} | '
      '${byEnum.map((c) => c.resolutions.length).join('/')})';
}

/// Where measured capabilities are cached between launches.
///
/// **Deliberately not part of `SettingsStore`.** `save()` there means *replace*,
/// and `credentials == null` deletes the stored pair; routing capabilities
/// through `ConnectionSettings` would therefore delete a working device's
/// identity every time a probe finished. Capabilities are also a different kind
/// of fact — derived from hardware, invalidated by hardware — so they get their
/// own key and their own lifecycle.
///
/// **One value per camera set, not one per camera.** An earlier version keyed
/// each camera separately while the `shared_preferences` implementation kept a
/// single entry, so every save overwrote the previous camera's — on a
/// two-camera device the first camera missed the cache on every launch and was
/// re-probed forever, which is precisely the "it probes every time" symptom the
/// cache exists to prevent. The whole set is one value now, so that cannot be
/// represented.
///
/// Pure Dart, in its own file, so the harness can import it without pulling in
/// `shared_preferences`.
abstract interface class CapabilitiesStore {
  /// The cached measurement for [fingerprint], or null.
  ///
  /// Null means **re-probe**, and it is returned for all three of: nothing
  /// stored, a stored fingerprint for a different camera set, and a payload
  /// that will not parse. A corrupt cache is a miss rather than an empty
  /// answer — treating it as a hit would announce "only what I am doing right
  /// now" for a device that could have declared more, and it would never
  /// self-heal, because the hit would keep coming back.
  Future<CachedCapabilities?> load(String fingerprint);

  Future<void> save(String fingerprint, CachedCapabilities value);

  Future<void> clear();
}
