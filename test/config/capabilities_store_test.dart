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

    test('changes when two cameras swap places', () {
      // `camera_enum` is positional, so swapping two cameras changes what index
      // 0 means just as much as swapping the hardware does.
      expect(
        cameraFingerprint(const ['front', 'back']),
        isNot(cameraFingerprint(const ['back', 'front'])),
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

  group('SharedPrefsCapabilitiesStore', () {
    test('load returns null when nothing was stored', () async {
      expect(await SharedPrefsCapabilitiesStore().load('anything'), isNull);
    });

    test('load returns null when the stored fingerprint differs', () async {
      final store = SharedPrefsCapabilitiesStore();
      await store.save(cameraFingerprint(const ['front']), _measured);

      expect(await store.load(cameraFingerprint(const ['front'])), _measured);
      // A camera added, removed or reordered invalidates the cache.
      expect(
        await store.load(cameraFingerprint(const ['front', 'back'])),
        isNull,
      );
      expect(
        await store.load(cameraFingerprint(const ['back', 'front'])),
        isNull,
      );
      expect(await store.load(cameraFingerprint(const [])), isNull);
    });

    test('save then load round-trips the capabilities', () async {
      final store = SharedPrefsCapabilitiesStore();
      final fingerprint = cameraFingerprint(const ['front', 'back']);

      await store.save(fingerprint, _measured);

      final loaded = await store.load(fingerprint);
      expect(loaded, _measured);
      expect(loaded!.resolutions, const [_hd, _vga]);
      expect(loaded.framerates, const [30, 15]);
    });

    test('clear removes the entry', () async {
      final store = SharedPrefsCapabilitiesStore();
      final fingerprint = cameraFingerprint(const ['front']);
      await store.save(fingerprint, _measured);

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
      await store.save(cameraFingerprint(const ['front']), _measured);
      await store.save(cameraFingerprint(const ['back']), _measured);
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
      // A camera that can do nothing is not a fact worth caching, and the
      // server refuses an empty list outright.
      SharedPreferences.setMockInitialValues({
        SharedPrefsCapabilitiesStore.key: jsonEncode(<String, Object?>{
          'fingerprint': 'fp',
          'capabilities': <String, Object?>{
            'resolutions': <Object?>['nonsense'],
            'framerates': <Object?>[-1],
          },
        }),
      });

      expect(await SharedPrefsCapabilitiesStore().load('fp'), isNull);
    });

    test('the fingerprint and the payload are stored together', () async {
      // Two keys would mean two writes, and a power cut between them would pair
      // the new fingerprint with the old capabilities — a hit describing a
      // camera set this device no longer has.
      final store = SharedPrefsCapabilitiesStore();
      await store.save('fp', _measured);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SharedPrefsCapabilitiesStore.key);
      expect(raw, isNotNull);

      final decoded = jsonDecode(raw!) as Map;
      expect(decoded['fingerprint'], 'fp');
      expect((decoded['capabilities']! as Map)['resolutions'], [
        '1280x720',
        '640x480',
      ]);
    });
  });
}
