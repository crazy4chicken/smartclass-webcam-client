import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webcam_client/src/backend/credential_store.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/config/connection_settings.dart';
import 'package:webcam_client/src/config/shared_prefs_settings_store.dart';

const _creds = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an address and a credential pair round-trip', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsSettingsStore();

    await store.save(
      ConnectionSettings(
        baseUrl: Uri.parse('http://10.0.0.9:9000'),
        credentials: _creds,
      ),
    );

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.baseUrl.toString(), 'http://10.0.0.9:9000');
    expect(loaded.credentials?.deviceId, _creds.deviceId);
    expect(loaded.credentials?.deviceToken, _creds.deviceToken);
  });

  test('the stored address is normalised, not copied verbatim', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsSettingsStore();

    await store.save(
      ConnectionSettings(baseUrl: Uri.parse('http://Host:8080/')),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(SharedPrefsSettingsStore.baseUrlKey),
      'http://host:8080',
    );
  });

  test('credentials keep the keys older builds wrote', () async {
    // The whole reason this store delegates to `CredentialStore` instead of
    // owning its own keys: an install upgrading in place must keep working
    // without a migration step.
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsSettingsStore();

    await store.save(
      ConnectionSettings(
        baseUrl: Uri.parse(defaultBaseUrl),
        credentials: _creds,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(SharedPrefsCredentialStore.deviceIdKey),
      _creds.deviceId,
    );
    expect(
      prefs.getString(SharedPrefsCredentialStore.deviceTokenKey),
      _creds.deviceToken,
    );
  });

  test('a build that only stored credentials reports nothing stored', () async {
    // The upgrade case that has to keep working: `base_url` was never written,
    // so load() must return null or bootstrap will think it has already been
    // seeded and the build-time address can never take effect again.
    SharedPreferences.setMockInitialValues({
      SharedPrefsCredentialStore.deviceIdKey: _creds.deviceId,
      SharedPrefsCredentialStore.deviceTokenKey: _creds.deviceToken,
    });

    expect(await SharedPrefsSettingsStore().load(), isNull);
  });

  test(
    'a stored address that no longer validates is treated as absent',
    () async {
      // Better to fall back to the build-time address than to dial something
      // unusable on every retry.
      SharedPreferences.setMockInitialValues({
        SharedPrefsSettingsStore.baseUrlKey: 'http://',
      });

      expect(await SharedPrefsSettingsStore().load(), isNull);
    },
  );

  test('saving without credentials clears the stored pair', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsSettingsStore();
    await store.save(
      ConnectionSettings(
        baseUrl: Uri.parse(defaultBaseUrl),
        credentials: _creds,
      ),
    );

    await store.save(ConnectionSettings(baseUrl: Uri.parse(defaultBaseUrl)));

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.credentials, isNull);
    expect(loaded.isProvisioned, isFalse);
  });

  test('clear removes both halves', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsSettingsStore();
    await store.save(
      ConnectionSettings(
        baseUrl: Uri.parse(defaultBaseUrl),
        credentials: _creds,
      ),
    );

    await store.clear();

    expect(await store.load(), isNull);
    expect(await SharedPrefsCredentialStore().load(), isNull);
  });
}
