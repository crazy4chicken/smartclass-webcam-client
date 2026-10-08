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

/// The cache key for one camera: the ordered camera set, plus its enum.
///
/// The set half is what makes adding or re-ordering a camera invalidate the
/// cache — `camera_enum` is positional, so a different set means a different
/// meaning for index 0. The index half is what keeps two identical cameras
/// apart: a pair of the same USB webcam enumerates under one name on Windows,
/// and sharing a cache entry would give camera 1 camera 0's capabilities.
String capabilityCacheKey(String setFingerprint, int cameraEnum) =>
    '$setFingerprint#$cameraEnum';

/// Produces the ordered camera list and its capabilities, from cache when it
/// can.
///
/// **Ranking always runs.** The cache key is the *ordered* camera set and the
/// order comes out of the ranking pass, so there is nothing to key on until it
/// has finished. What the cache saves is the probe: nine camera opens per
/// camera against the ranker's one. That is still the difference between a
/// kiosk that starts in a second and one that spends ten seconds flashing its
/// camera LED at every boot.
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

  // 1. One open per camera, to learn each ceiling.
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

  // 2. The cache, keyed by the ordered set.
  final setFingerprint = cameraFingerprint(<String>[
    for (final descriptor in descriptors) descriptor.name,
  ]);

  final capabilities = <CameraCapabilities>[];
  for (var announced = 0; announced < descriptors.length; announced++) {
    final key = capabilityCacheKey(setFingerprint, announced);

    if (!forceReprobe) {
      final cached = await store.load(key);
      if (cached != null) {
        log?.call('[probe] $announced ${descriptors[announced].name}: cached');
        capabilities.add(cached);
        continue;
      }
    }

    final result = await probe.probe(order[announced]);
    log?.call(
      '[probe] $announced ${descriptors[announced].name}: '
      '${result.detail ?? result.capabilities}',
    );

    // The server rejects an empty list outright, so a probe that found nothing
    // must become "only what I am doing", never nothing. A kiosk that cannot
    // register is worse than one that declares less.
    final declared = declaredCapabilities(
      measured: result.capabilities,
      currentResolution: fallbackResolution,
      currentFps: fallbackFps,
    );

    // Saved in its declared form. Re-applying the ladder on a later launch is
    // idempotent — the ceiling is already in the list — so a cache hit and a
    // fresh probe produce the same answer.
    await store.save(key, declared);
    capabilities.add(declared);
  }

  return CameraInventory(
    descriptors: List<CameraDescriptor>.unmodifiable(descriptors),
    order: List<int>.unmodifiable(order),
    capabilities: List<CameraCapabilities>.unmodifiable(capabilities),
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
