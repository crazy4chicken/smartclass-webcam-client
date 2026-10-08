import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/app/capability_bootstrap.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_order.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/capability_probe.dart';
import 'package:webcam_client/src/config/capabilities_store.dart';

const CameraResolution _vga = CameraResolution(width: 640, height: 480);
const CameraResolution _hd = CameraResolution(width: 1280, height: 720);
const CameraResolution _fhd = CameraResolution(width: 1920, height: 1080);

/// Three physical cameras, deliberately listed front-first: the ordering pass
/// has to be what puts the rear ones at the front of the announced list.
const List<CameraDescriptor> _physical = [
  CameraDescriptor(name: 'Laptop Front', index: 0, lensDirection: 'front'),
  CameraDescriptor(name: 'USB Back A', index: 1, lensDirection: 'back'),
  CameraDescriptor(name: 'USB Back B', index: 2, lensDirection: 'back'),
];

const Map<int, int> _ceilings = {0: 1280 * 720, 1: 640 * 480, 2: 1920 * 1080};

/// What the probe reports, by **physical** index.
final Map<int, CameraCapabilities> _measured = {
  2: CameraCapabilities.of(
    resolutions: const [_fhd, _hd],
    framerates: const [60, 30],
  ),
  1: CameraCapabilities.of(resolutions: const [_vga], framerates: const [30]),
  0: CameraCapabilities.of(resolutions: const [_hd], framerates: const [30]),
};

/// An in-memory [CapabilitiesStore].
class _FakeStore implements CapabilitiesStore {
  _FakeStore([Map<String, CachedCapabilities>? seed])
    : entries = <String, CachedCapabilities>{...?seed};

  final Map<String, CachedCapabilities> entries;
  final List<String> loads = <String>[];
  final List<String> saves = <String>[];

  @override
  Future<CachedCapabilities?> load(String fingerprint) async {
    loads.add(fingerprint);
    return entries[fingerprint];
  }

  @override
  Future<void> save(String fingerprint, CachedCapabilities value) async {
    saves.add(fingerprint);
    entries[fingerprint] = value;
  }

  @override
  Future<void> clear() async => entries.clear();
}

class _Harness {
  _Harness({
    this.physical = _physical,
    Map<int, CameraCapabilities>? measured,
    _FakeStore? store,
    this.rankThrows = false,
    this.enumerateThrows = false,
  }) : measured = measured ?? _measured,
       store = store ?? _FakeStore();

  final List<CameraDescriptor> physical;
  final Map<int, CameraCapabilities> measured;
  final _FakeStore store;
  final bool rankThrows;
  final bool enumerateThrows;

  int enumerateCalls = 0;
  int rankCalls = 0;
  final List<int> rankedIndices = <int>[];
  final List<int> probedIndices = <int>[];
  final List<String> log = <String>[];

  /// When set, the ranker silently omits this many cameras — the malformed
  /// result the permutation check exists for.
  int dropFromRank = 0;

  Future<CameraInventory> run({
    bool forceReprobe = false,
    CameraResolution fallbackResolution = _hd,
    int fallbackFps = 5,
  }) => ensureInventory(
    enumerate: () async {
      enumerateCalls++;
      if (enumerateThrows) throw StateError('no enumeration');
      return physical;
    },
    ranker: _Ranker(this),
    probe: _Probe(this),
    store: store,
    fallbackResolution: fallbackResolution,
    fallbackFps: fallbackFps,
    forceReprobe: forceReprobe,
    log: log.add,
  );
}

class _Ranker implements CameraRanker {
  _Ranker(this.harness);
  final _Harness harness;

  @override
  Future<List<RankedCamera>> rank(List<CameraDescriptor> devices) async {
    harness.rankCalls++;
    harness.rankedIndices.addAll(devices.map((d) => d.index));
    if (harness.rankThrows) throw StateError('rank exploded');

    final considered = harness.dropFromRank > 0
        ? devices.sublist(0, devices.length - harness.dropFromRank)
        : devices;

    return <RankedCamera>[
      for (final device in considered)
        RankedCamera(
          index: device.index,
          group: cameraGroupFor(device.lensDirection),
          maxPixels: _ceilings[device.index] ?? 0,
        ),
    ];
  }
}

class _Probe implements CapabilityProbe {
  _Probe(this.harness);
  final _Harness harness;

  @override
  Future<CapabilityProbeResult> probe(int physicalCameraIndex) async {
    harness.probedIndices.add(physicalCameraIndex);
    final capabilities =
        harness.measured[physicalCameraIndex] ?? CameraCapabilities.empty;
    return CapabilityProbeResult(
      capabilities: capabilities,
      detail: 'physical $physicalCameraIndex',
    );
  }
}

/// The fingerprint a successful run produces: one value for the whole set.
String _expectedFingerprint() =>
    cameraFingerprint(const ['USB Back B', 'USB Back A', 'Laptop Front']);

/// A cache entry for the default camera set, in the canonical order a run
/// produces.
CachedCapabilities _cachedSet({CameraCapabilities? each}) {
  final capabilities =
      each ??
      CameraCapabilities.of(resolutions: const [_vga], framerates: const [15]);
  return CachedCapabilities(
    order: const ['USB Back B', 'USB Back A', 'Laptop Front'],
    byEnum: <CameraCapabilities>[for (var i = 0; i < 3; i++) capabilities],
  );
}

void main() {
  test('ranks, orders and then probes, in that order', () async {
    final h = _Harness();

    final inventory = await h.run();

    // Enumerate once, cheap, no opens.
    expect(h.enumerateCalls, 1);
    // Rank once, over the physical list — it cannot know which cameras matter
    // yet, because the ordering is what decides that.
    expect(h.rankCalls, 1);
    expect(h.rankedIndices, [0, 1, 2]);

    // Probed in *canonical* order: the two rear cameras by resolution, then the
    // front one.
    expect(h.probedIndices, [2, 1, 0]);
    expect(inventory.order, [2, 1, 0]);
  });

  test('the announced camera list is in canonical order', () async {
    final inventory = await _Harness().run();

    // Rear before front, highest resolution first within the group — the
    // physical list was front-first, so this is the ordering pass working.
    expect(inventory.descriptors.map((d) => d.name).toList(), [
      'USB Back B',
      'USB Back A',
      'Laptop Front',
    ]);
    expect(inventory.descriptors.map((d) => d.lensDirection).toList(), [
      'back',
      'back',
      'front',
    ]);
    // The position in the list *is* camera_enum.
    expect(inventory.descriptors.map((d) => d.index).toList(), [0, 1, 2]);
    expect(inventory.capabilities, hasLength(3));
  });

  test('the whole set is stored as one entry, order included', () async {
    final h = _Harness();

    await h.run();

    // One save for the set. Saving per camera is what broke this: the store
    // keeps one value, so the second camera's save evicted the first camera's.
    expect(h.store.saves, [_expectedFingerprint()]);
    expect(h.store.entries.keys, [_expectedFingerprint()]);

    final entry = h.store.entries[_expectedFingerprint()]!;
    expect(entry.order, ['USB Back B', 'USB Back A', 'Laptop Front']);
    expect(entry.byEnum, hasLength(3));

    // Each entry is the *declared* form: the common ladder below the ceiling,
    // with the current mode folded in.
    expect(entry.byEnum.first.resolutions.first, _fhd);
    expect(entry.byEnum.first.resolutions, contains(_vga));
    expect(entry.byEnum.first.framerates, contains(5));
  });

  test('a cached set opens nothing at all', () async {
    // The whole point of the feature: the second launch of a kiosk must not
    // flash its camera LED. The order travels inside the cached value, so
    // neither the ranking pass nor the probe is needed.
    final store = _FakeStore({_expectedFingerprint(): _cachedSet()});

    final h = _Harness(store: store);
    final inventory = await h.run();

    expect(h.store.loads, [_expectedFingerprint()]);
    expect(h.rankCalls, 0, reason: 'ranking opens every camera once');
    expect(h.probedIndices, isEmpty, reason: 'the probe opens them nine times');
    expect(h.store.saves, isEmpty, reason: 'nothing to rewrite');
    expect(inventory.order, [2, 1, 0]);
    expect(inventory.capabilities, hasLength(3));
    expect(
      inventory.capabilities.every((c) => c.framerates.contains(15)),
      isTrue,
    );
  });

  test('a cached order that names an absent camera is a miss', () async {
    // The fingerprint matches because the *set* matches, so this is the guard
    // that catches a payload that cannot be applied to the hardware present.
    final store = _FakeStore({
      _expectedFingerprint(): CachedCapabilities(
        order: const ['USB Back B', 'Ghost Camera', 'Laptop Front'],
        byEnum: <CameraCapabilities>[
          for (var i = 0; i < 3; i++) CameraCapabilities.empty,
        ],
      ),
    });

    final h = _Harness(store: store);
    await h.run();

    expect(h.rankCalls, 1);
    expect(h.probedIndices, [2, 1, 0]);
    expect(h.store.saves, [_expectedFingerprint()]);
  });

  test('a different fingerprint re-ranks, re-orders and re-probes', () async {
    // A cache written for a different camera set. The extra camera is not even
    // present any more, which is the "USB webcam unplugged" case.
    final store = _FakeStore({
      cameraFingerprint(const ['Only Camera']): CachedCapabilities(
        order: const ['Only Camera'],
        byEnum: [
          CameraCapabilities.of(
            resolutions: const [_vga],
            framerates: const [5],
          ),
        ],
      ),
    });

    final h = _Harness(store: store);
    await h.run();

    expect(h.probedIndices, [2, 1, 0]);
    expect(h.store.saves, [_expectedFingerprint()]);
  });

  test('forceReprobe ignores the cache but still writes it', () async {
    // What the settings screen's re-detect button needs: measure again *and*
    // leave the next launch with the fresh answer.
    final store = _FakeStore({_expectedFingerprint(): _cachedSet()});

    final h = _Harness(store: store);
    await h.run(forceReprobe: true);

    expect(
      h.store.loads,
      isEmpty,
      reason: 'the cache is deliberately not read',
    );
    expect(h.probedIndices, [2, 1, 0]);
    expect(h.store.saves, [_expectedFingerprint()]);
    // The stored value is now the measurement, not the stale entry.
    expect(
      h.store.entries[_expectedFingerprint()]!.byEnum.first.resolutions.first,
      _fhd,
    );
  });

  test('an empty probe result still yields a usable fallback for registration', () async {
    // No camera could be opened. `supported_resolutions: []` is a `400`, so the
    // device must degrade to "only what I am doing" rather than nothing — a
    // kiosk that cannot register is worse than one that declares less.
    final h = _Harness(measured: const {});
    final inventory = await h.run();

    expect(inventory.capabilities, hasLength(3));
    for (final capabilities in inventory.capabilities) {
      expect(capabilities.isEmpty, isFalse);
      expect(capabilities.resolutions, isNotEmpty);
      expect(capabilities.framerates, isNotEmpty);
    }
  });

  test('the fallback declares the current resolution and fps, never an empty '
      'list', () async {
    final h = _Harness(measured: const {});
    final inventory = await h.run(fallbackResolution: _vga, fallbackFps: 15);

    for (final capabilities in inventory.capabilities) {
      expect(capabilities.resolutions, contains(_vga));
      expect(capabilities.framerates, contains(15));
    }
  });

  test(
    'no camera at all yields an empty inventory rather than a throw',
    () async {
      final h = _Harness(physical: const []);
      final inventory = await h.run();

      expect(inventory.isEmpty, isTrue);
      expect(inventory.descriptors, isEmpty);
      expect(inventory.capabilities, isEmpty);
      expect(h.rankCalls, 0, reason: 'nothing to rank');
      expect(h.probedIndices, isEmpty);
    },
  );

  test('an enumeration that throws is treated as no camera', () async {
    final h = _Harness(enumerateThrows: true);

    final inventory = await h.run();

    expect(inventory.isEmpty, isTrue);
    expect(h.log.any((l) => l.contains('enumeration failed')), isTrue);
  });

  test('two cameras sharing a name keep their own measurements', () async {
    // A pair of the same USB webcam enumerates under one name on Windows. They
    // share one cache entry — they are one camera set — but the entry has to
    // hold a distinct measurement per enum, or camera 1 would get camera 0's.
    const twins = [
      CameraDescriptor(name: 'USB Camera', index: 0, lensDirection: 'back'),
      CameraDescriptor(name: 'USB Camera', index: 1, lensDirection: 'back'),
    ];
    final h = _Harness(
      physical: twins,
      measured: {
        0: CameraCapabilities.of(
          resolutions: const [_fhd],
          framerates: const [30],
        ),
        1: CameraCapabilities.of(
          resolutions: const [_vga],
          framerates: const [15],
        ),
      },
    );

    final inventory = await h.run(
      // Below both ceilings, so the current-mode fold-in does not mask which
      // camera each entry came from.
      fallbackResolution: _vga,
    );

    // Both are `back` with different ceilings, so the stronger one is first.
    expect(inventory.order, [0, 1]);
    expect(h.store.saves, hasLength(1));
    expect(h.store.entries.values.single.byEnum, hasLength(2));
    expect(inventory.capabilities[0].resolutions.first, _fhd);
    expect(inventory.capabilities[1].resolutions.first, _vga);

    // And the next launch is a hit for both of them. This is the case that was
    // broken: one entry, two saves, so camera 0 was re-probed forever.
    final again = _Harness(physical: twins, store: h.store);
    final restored = await again.run();

    expect(again.rankCalls, 0);
    expect(again.probedIndices, isEmpty);
    expect(restored.capabilities[0].resolutions.first, _fhd);
    expect(restored.capabilities[1].resolutions.first, _vga);
  });

  test('a ranker that throws still yields a usable order', () async {
    // The ranker is documented as never throwing. If it ever does, the device
    // must still get an order to work with rather than a stuck start-up — and
    // the order it falls back to is still rear-then-front.
    final h = _Harness(rankThrows: true);

    final inventory = await h.run();

    expect(inventory.descriptors, hasLength(3));
    expect(inventory.descriptors.map((d) => d.name).toList(), [
      'USB Back A',
      'USB Back B',
      'Laptop Front',
    ]);
    expect(inventory.order, [1, 2, 0]);
    expect(h.log.any((l) => l.contains('ranking failed')), isTrue);
  });

  test(
    'a ranker that drops a camera falls back to the enumeration order',
    () async {
      // A short result would leave a camera unreachable — and `physical[order[i]]`
      // would not even be safe. Identity is always a valid answer.
      final h = _Harness()..dropFromRank = 1;

      final inventory = await h.run();

      expect(inventory.descriptors, hasLength(3));
      expect(inventory.order, [1, 2, 0]);
      expect(h.log.any((l) => l.contains('falling back')), isTrue);
    },
  );
}
