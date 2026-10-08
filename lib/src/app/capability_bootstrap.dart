import '../capture/camera_capabilities.dart';
import '../capture/camera_order.dart';
import '../capture/camera_resolution.dart';
import '../capture/camera_service.dart';
import '../capture/capability_probe.dart';
import '../config/capabilities_store.dart';

/// The ordered camera list plus what each camera can do.
class CameraInventory {
  const CameraInventory({
    required this.descriptors,
    required this.order,
    required this.capabilities,
  });

  /// A device with no camera at all.
  static const CameraInventory empty = CameraInventory(
    descriptors: <CameraDescriptor>[],
    order: <int>[],
    capabilities: <CameraCapabilities>[],
  );

  /// The cameras in **canonical order**, so `descriptors[i].index == i` and the
  /// position in this list *is* `camera_enum`.
  final List<CameraDescriptor> descriptors;

  /// Announced enum → physical index.
  ///
  /// Carried explicitly because it is the only record of which physical camera
  /// each `camera_enum` means; `descriptors` deliberately does not expose one.
  /// `CameraPluginBackend` is the only thing that consumes it.
  final List<int> order;

  /// What each camera was measured to accept, indexed by `camera_enum`.
  ///
  /// Already in its **declared** form — the common ladder applied, the current
  /// mode folded in. Applying that again is idempotent, which is what lets the
  /// announcement path and the coordinator both do it without special-casing a
  /// cached value.
  final List<CameraCapabilities> capabilities;

  bool get isEmpty => descriptors.isEmpty;

  @override
  String toString() =>
      'CameraInventory(${descriptors.map((d) => d.name).join(', ')} | '
      '${capabilities.map((c) => c.resolutions.length).join('/')})';
}

/// Produces the ordered camera list and its capabilities, from cache when it
/// can.
///
/// **A cache hit opens nothing.** The fingerprint is over the camera *set*, so
/// it can be computed from the enumeration alone; the canonical order travels
/// inside the cached value rather than being derived from it. That is what
/// makes the second launch of a kiosk cheap: no ranking open per camera and no
/// probe, so the camera LED does not flash at boot and the device is up in
/// about the time `availableCameras()` takes.
///
/// Anything that would make the cached answer wrong is a miss, not a guess: a
/// different set of names, a payload that will not parse, or an order that no
/// longer matches the cameras actually present (see [_fromCache]). A miss
/// re-probes everything.
///
/// [forceReprobe] skips the cache read but still writes it, which is what the
/// settings screen's "re-detect" button needs: it must measure again *and*
/// leave the next launch with the fresh answer.
Future<CameraInventory> ensureInventory({
  required CameraEnumerator enumerate,
  required CameraRanker ranker,
  required CapabilityProbe probe,
  required CapabilitiesStore store,
  required CameraResolution fallbackResolution,
  required int fallbackFps,
  bool forceReprobe = false,
  void Function(String message)? log,
}) async {
  final physical = await _enumerate(enumerate, log);
  if (physical.isEmpty) {
    log?.call('[probe] no camera is present');
    return CameraInventory.empty;
  }

  final fingerprint = cameraFingerprint(<String>[
    for (final camera in physical) camera.name,
  ]);

  // 1. The cache, before anything is opened. A hit returns here.
  if (!forceReprobe) {
    final cached = await store.load(fingerprint);
    if (cached != null) {
      // A cache that cannot be applied degrades to a re-probe, never to a
      // failed start. This is a kiosk's boot path, and the worst outcome
      // available here is a device that does not come up because of a stale
      // preference — so anything unexpected is treated as a miss and logged.
      CameraInventory? restored;
      try {
        restored = _fromCache(cached: cached, physical: physical, log: log);
      } catch (error) {
        log?.call('[probe] cached entry could not be applied: $error');
        restored = null;
      }
      if (restored != null) return restored;
      log?.call('[probe] cached entry does not match the cameras present');
    }
  }

  // 2. One open per camera, to learn each ceiling.
  final ranked = await _rank(ranker, physical, log);
  final order = canonicalCameraOrder(ranked);
  final descriptors = <CameraDescriptor>[
    for (var announced = 0; announced < order.length; announced++)
      CameraDescriptor(
        // `index` is the *announced* enum here, not the physical one: this list
        // is what everything downstream reads, and a second numbering scheme is
        // the mistake the whole ordering pass exists to prevent.
        name: physical[order[announced]].name,
        index: announced,
        lensDirection: physical[order[announced]].lensDirection,
      ),
  ];
  log?.call('[probe] order: ${descriptors.map((d) => d.name).join(' → ')}');

  // 3. The full probe, in canonical order.
  final capabilities = <CameraCapabilities>[];
  for (var announced = 0; announced < descriptors.length; announced++) {
    final result = await probe.probe(order[announced]);
    log?.call(
      '[probe] $announced ${descriptors[announced].name}: '
      '${result.detail ?? result.capabilities}',
    );

    // The server rejects an empty list outright, so a probe that found nothing
    // must become "only what I am doing", never nothing. A kiosk that cannot
    // register is worse than one that declares less.
    capabilities.add(
      declaredCapabilities(
        measured: result.capabilities,
        currentResolution: fallbackResolution,
        currentFps: fallbackFps,
      ),
    );
  }

  // 4. Stored in its declared form. Re-applying the ladder on a later launch is
  // idempotent — the ceiling is already in the list — so a cache hit and a
  // fresh probe produce the same answer.
  //
  // One write for the whole set. Writing per camera against a store that keeps
  // one entry is how the first camera came to be re-probed on every launch.
  await store.save(
    fingerprint,
    CachedCapabilities(
      order: <String>[for (final descriptor in descriptors) descriptor.name],
      byEnum: capabilities,
    ),
  );

  return CameraInventory(
    descriptors: List<CameraDescriptor>.unmodifiable(descriptors),
    order: List<int>.unmodifiable(order),
    capabilities: List<CameraCapabilities>.unmodifiable(capabilities),
  );
}

/// Rebuilds an inventory from a cache entry, or null when it cannot be trusted.
///
/// The check that matters is the last one: the cached order is matched **by
/// name** against the cameras actually present, and every camera must be
/// accounted for exactly once. A cached order is a list of names, and the
/// permutation it implies is only valid for the enumeration it was measured
/// against — a USB camera replugged into a different port comes back at a
/// different index, and reusing the old permutation would point `camera_enum 0`
/// at a different physical device.
///
/// Names, not indices, is what makes a reordered enumeration safe: the same two
/// cameras in the opposite order still match, and the permutation is rebuilt
/// against the new order.
///
/// Two cameras sharing a name are paired in enumeration order. That is the best
/// available answer — they are indistinguishable to the platform — and it is
/// stable, which is what matters for `camera_enum`.
CameraInventory? _fromCache({
  required CachedCapabilities cached,
  required List<CameraDescriptor> physical,
  void Function(String message)? log,
}) {
  if (cached.order.length != physical.length) return null;

  final remaining = <int>[for (var i = 0; i < physical.length; i++) i];
  final order = <int>[];
  for (final name in cached.order) {
    final at = remaining.indexWhere((i) => physical[i].name == name);
    if (at < 0) return null;
    order.add(remaining.removeAt(at));
  }
  if (remaining.isNotEmpty) return null;

  log?.call(
    '[probe] cached: ${cached.order.join(' → ')} '
    '(nothing opened)',
  );

  return CameraInventory(
    descriptors: List<CameraDescriptor>.unmodifiable(<CameraDescriptor>[
      for (var announced = 0; announced < order.length; announced++)
        CameraDescriptor(
          name: physical[order[announced]].name,
          index: announced,
          lensDirection: physical[order[announced]].lensDirection,
        ),
    ]),
    order: List<int>.unmodifiable(order),
    // Wrapped rather than passed through: `CachedCapabilities` can be built by
    // hand with a growable list, and `CameraInventory` promises its lists are
    // unmodifiable.
    capabilities: List<CameraCapabilities>.unmodifiable(cached.byEnum),
  );
}

/// Enumerating needs no permission on any platform, but it can still fail —
/// a missing plugin, a driver that throws. An empty list is the honest answer
/// and the caller degrades from there.
Future<List<CameraDescriptor>> _enumerate(
  CameraEnumerator enumerate,
  void Function(String message)? log,
) async {
  try {
    return await enumerate();
  } catch (error) {
    log?.call('[probe] enumeration failed: $error');
    return const <CameraDescriptor>[];
  }
}

/// Ranks, falling back to the enumeration order.
///
/// The ranker is documented as never throwing, and a result that is not a
/// genuine permutation of the physical indices is treated the same way: it
/// would leave a camera unreachable, or two announced enums pointing at one
/// device. Identity is always a valid answer, and it still groups by lens
/// direction — a device whose cameras could not be measured gets rear-then-front
/// by enumeration order rather than nothing.
Future<List<RankedCamera>> _rank(
  CameraRanker ranker,
  List<CameraDescriptor> physical,
  void Function(String message)? log,
) async {
  try {
    final ranked = await ranker.rank(physical);
    if (_isPermutation(ranked, physical)) return ranked;
    log?.call(
      '[probe] the ranker returned ${ranked.length} of ${physical.length} '
      'cameras; falling back to the enumeration order',
    );
  } catch (error) {
    log?.call('[probe] ranking failed: $error; using the enumeration order');
  }

  return <RankedCamera>[
    for (final device in physical)
      RankedCamera(
        index: device.index,
        group: cameraGroupFor(device.lensDirection),
      ),
  ];
}

bool _isPermutation(
  List<RankedCamera> ranked,
  List<CameraDescriptor> physical,
) {
  if (ranked.length != physical.length) return false;
  final seen = <int>{};
  for (final camera in ranked) {
    if (!seen.add(camera.index)) return false;
  }
  for (final device in physical) {
    if (!seen.contains(device.index)) return false;
  }
  return true;
}
