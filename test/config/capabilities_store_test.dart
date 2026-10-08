import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webcam_client/src/backend/credential_store.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/config/capabilities_store.dart';
import 'package:webcam_client/src/config/shared_prefs_capabilities_store.dart';

import '../support/doubles.dart';

const CameraResolution _vga = CameraResolution(width: 640, height: 480);
const CameraResolution _hd = CameraResolution(width: 1280, height: 720);

final CameraCapabilities _measured = CameraCapabilities.of(
  resolutions: const [_hd, _vga],
  framerates: const [30, 15],
);

/// A cache entry for two cameras with deliberately different capabilities, so a
/// mix-up between the two is visible.
CachedCapabilities _twoCameras() => CachedCapabilities(
  order: const ['Rear', 'Front'],
  byEnum: [
    CameraCapabilities.of(resolutions: const [_hd], framerates: const [30]),
    CameraCapabilities.of(resolutions: const [_vga], framerates: const [5]),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('cameraFingerprint', () {
    test('is stable for the same camera list', () {
      expect(
        cameraFingerprint(const ['front', 'back']),
        cameraFingerprint(const ['front', 'back']),
      );
    });

    test('changes when a camera is added', () {
      expect(
        cameraFingerprint(const ['front']),
        isNot(cameraFingerprint(const ['front', 'back'])),
      );
    });

    test('is order-insensitive', () {
      // The canonical order is part of the cached payload, so the key cannot
      // depend on it — deriving the key would require ranking the cameras,
      // which is the work the cache exists to skip. Two orderings of the same
      // names are the same hardware: a USB camera replugged into another port
      // enumerates differently and must still hit.
      expect(
        cameraFingerprint(const ['front', 'back']),
        cameraFingerprint(const ['back', 'front']),
      );
    });

    test('cannot be fooled by a name containing the separator', () {
      // Names come from the platform and can contain anything, so the encoding
      // is length-prefixed rather than joined on a separator.
      expect(
        cameraFingerprint(const ['a|b']),
        isNot(cameraFingerprint(const ['a', 'b'])),
      );
      expect(
        cameraFingerprint(const ['a;1:b;']),
        isNot(cameraFingerprint(const ['a', 'b'])),
      );
      expect(cameraFingerprint(const []), isEmpty);
    });
  });

  group('CachedCapabilities', () {
    test('round-trips both halves', () {
      final restored = CachedCapabilities.fromJson(_twoCameras().toJson());

      expect(restored.order, const ['Rear', 'Front']);
      expect(restored.byEnum, hasLength(2));
      expect(restored.byEnum.first.framerates, const [30]);
      expect(restored.byEnum.last.framerates, const [5]);
      expect(restored.isEmpty, isFalse);
    });

    test('rejects a payload whose halves disagree', () {
      // Such a payload describes a camera set that does not exist, and acting
      // on it would put capabilities on the wrong enums.
      expect(
        CachedCapabilities.fromJson(<String, Object?>{
          'order': <String>['Rear', 'Front'],
          'cameras': <Object?>[
            <String, Object?>{'resolutions': <String>[], 'framerates': <int>[]},
          ],
        }).isEmpty,
        isTrue,
      );
    });

    test('rejects anything that is not a map', () {
      for (final bad in <Object?>[null, 'text', 42, <Object?>[]]) {
        expect(
          CachedCapabilities.fromJson(bad).isEmpty,
          isTrue,
          reason: 'payload: $bad',
        );
      }
    });
  });

  group('SharedPrefsCapabilitiesStore', () {
    test('load returns null when nothing was stored', () async {
      expect(await SharedPrefsCapabilitiesStore().load('anything'), isNull);
    });

    test('load returns null when the stored fingerprint differs', () async {
      final store = SharedPrefsCapabilitiesStore();
      await store.save(cameraFingerprint(const ['front']), _twoCameras());

      expect(await store.load(cameraFingerprint(const ['front'])), isNotNull);
      expect(
        await store.load(cameraFingerprint(const ['front', 'back'])),
        isNull,
      );
      expect(await store.load(cameraFingerprint(const [])), isNull);
    });

    test('save then load round-trips the order and every camera', () async {
      final store = SharedPrefsCapabilitiesStore();
      final fingerprint = cameraFingerprint(const ['Rear', 'Front']);

      await store.save(fingerprint, _twoCameras());

      final loaded = await store.load(fingerprint);
      expect(loaded, isNotNull);
      expect(loaded!.order, const ['Rear', 'Front']);
      expect(loaded.byEnum, hasLength(2));
      expect(loaded.byEnum.first.resolutions, const [_hd]);
      expect(loaded.byEnum.last.resolutions, const [_vga]);
      expect(loaded.byEnum.last.framerates, const [5]);
    });

    test('**every camera survives a second write**', () async {
      // The regression this whole shape exists for. The store kept a single
      // entry while the caller saved once per camera, so on a two-camera device
      // the second save overwrote the first: camera 0 missed the cache on every
      // launch and was re-probed forever — the exact "it detects every time"
      // symptom the cache is supposed to remove.
      final store = SharedPrefsCapabilitiesStore();
      final fingerprint = cameraFingerprint(const ['Rear', 'Front']);

      await store.save(fingerprint, _twoCameras());
      final loaded = await store.load(fingerprint);

      expect(
        loaded?.byEnum,
        hasLength(2),
        reason: 'a per-camera save must not evict its neighbour',
      );
      expect(loaded?.order, hasLength(2));
    });

    test('clear removes the entry', () async {
      final store = SharedPrefsCapabilitiesStore();
      final fingerprint = cameraFingerprint(const ['front']);
      await store.save(fingerprint, _twoCameras());

      await store.clear();

      expect(await store.load(fingerprint), isNull);
    });

    test('save does not touch the stored device credentials', () async {
      // The regression guard for the whole reason this store exists separately
      // from `SettingsStore`: `save()` there means *replace*, so routing
      // capabilities through `ConnectionSettings` would delete a working
      // device's identity every time a probe finished.
      final credentials = SharedPrefsCredentialStore();
      await credentials.save(testCredentials);

      final store = SharedPrefsCapabilitiesStore();
      await store.save(cameraFingerprint(const ['front']), _twoCameras());
      await store.save(cameraFingerprint(const ['back']), _twoCameras());
      await store.clear();

      expect(await credentials.load(), testCredentials);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(SharedPrefsCredentialStore.deviceTokenKey),
        testCredentials.deviceToken,
      );
    });

    test('load returns null rather than throwing on corrupt JSON', () async {
      // Null means "re-probe", which is the only answer that self-heals.
      // Answering empty would announce "only what I am doing right now" for a
      // device that could declare more, and the hit would keep coming back.
      for (final corrupt in <String>[
        'not json at all',
        '{"fingerprint":', // truncated
        '[]', // right shape, wrong type
        '"a string"',
        'null',
      ]) {
        SharedPreferences.setMockInitialValues({
          SharedPrefsCapabilitiesStore.key: corrupt,
        });

        expect(
          await SharedPrefsCapabilitiesStore().load('fp'),
          isNull,
          reason: 'payload: $corrupt',
        );
      }
    });

    test('a payload that parses to nothing is a miss, not a hit', () async {
      // A camera set that describes nothing is not a fact worth caching, and
      // the server refuses an empty list outright.
      for (final payload in <Object?>[
        <String, Object?>{'order': <String>[], 'cameras': <Object?>[]},
        <String, Object?>{
          'resolutions': <Object?>['nonsense'],
        },
        <String, Object?>{
          'order': <String>['Rear'],
        },
      ]) {
        SharedPreferences.setMockInitialValues({
          SharedPrefsCapabilitiesStore.key: jsonEncode(<String, Object?>{
            'fingerprint': 'fp',
            'capabilities': payload,
          }),
        });

        expect(
          await SharedPrefsCapabilitiesStore().load('fp'),
          isNull,
          reason: 'payload: $payload',
        );
      }
    });

    test('the fingerprint and the payload are stored together', () async {
      // One key, one object. A second key would mean a second write, and a
      // power cut between them would pair the new fingerprint with the old
      // capabilities — a hit describing a camera set this device no longer has.
      final store = SharedPrefsCapabilitiesStore();
      await store.save('fp', _twoCameras());

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SharedPrefsCapabilitiesStore.key);
      expect(raw, isNotNull);

      final decoded = jsonDecode(raw!) as Map;
      expect(decoded['fingerprint'], 'fp');

      final payload = decoded['capabilities']! as Map;
      expect(payload['order'], ['Rear', 'Front']);
      expect((payload['cameras']! as List), hasLength(2));
      expect(((payload['cameras']! as List).first as Map)['resolutions'], [
        '1280x720',
      ]);
    });
  });
}
