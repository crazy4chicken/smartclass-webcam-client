import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webcam_client/src/backend/credential_store.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';

const _creds = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an empty store reports nothing rather than blank strings', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SharedPrefsCredentialStore().load(), isNull);
  });

  test('a half-written store also reports nothing', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsCredentialStore.deviceIdKey: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
    });
    expect(await SharedPrefsCredentialStore().load(), isNull);
  });

  test('credentials round-trip through the store', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsCredentialStore();

    await store.save(_creds);
    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.deviceId, _creds.deviceId);
    expect(loaded.deviceToken, _creds.deviceToken);
  });

  test('a stale non-ULID id is treated as nothing stored', () async {
    // The previous client stored a UUIDv4 here. Leaving it in place would
    // produce a stream of unexplained 401s.
    SharedPreferences.setMockInitialValues({
      SharedPrefsCredentialStore.deviceIdKey:
          '3f1a4b2c-9d8e-4f7a-8b6c-1e2d3f4a5b6c',
      SharedPrefsCredentialStore.deviceTokenKey:
          'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    });
    expect(await SharedPrefsCredentialStore().load(), isNull);
  });

  test('clear removes both halves', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsCredentialStore();
    await store.save(_creds);
    await store.clear();
    expect(await store.load(), isNull);
  });

  group('DeviceCredentials', () {
    test('accepts a server-shaped pair', () {
      expect(_creds.looksValid, isTrue);
      expect(_creds.hasValidDeviceId, isTrue);
      expect(_creds.hasValidDeviceToken, isTrue);
    });

    test('rejects a short id, a short token and a non-wdt token', () {
      expect(
        const DeviceCredentials(
          deviceId: 'abc',
          deviceToken: _token,
        ).looksValid,
        isFalse,
      );
      expect(
        const DeviceCredentials(
          deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
          deviceToken: 'wdt_short',
        ).looksValid,
        isFalse,
      );
      expect(
        // Right length, but missing the literal `wdt_` prefix.
        const DeviceCredentials(
          deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
          deviceToken: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ).looksValid,
        isFalse,
      );
    });

    test('isConfigured only checks presence', () {
      expect(
        const DeviceCredentials(deviceId: 'x', deviceToken: 'y').isConfigured,
        isTrue,
      );
      expect(
        const DeviceCredentials(deviceId: '', deviceToken: '').isConfigured,
        isFalse,
      );
    });

    test('validate names what is wrong', () {
      expect(
        () => const DeviceCredentials(deviceId: '', deviceToken: '').validate(),
        throwsStateError,
      );
      expect(
        () => const DeviceCredentials(
          deviceId: 'not-a-ulid',
          deviceToken: _token,
        ).validate(),
        throwsStateError,
      );
      expect(() => _creds.validate(), returnsNormally);
    });

    test('toString never leaks the token', () {
      expect(_creds.toString(), isNot(contains('wdt_')));
      expect(_creds.toString(), contains('***'));
    });
  });
}

const String _token = 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
