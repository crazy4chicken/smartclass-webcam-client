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

    expect((await store.loadBaseUrl()).toString(), 'http://10.0.0.9:9000');
    expect(await store.loadCredentials(), _creds);
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

  test('a build that only stored credentials still yields them', () async {
    // The upgrade case, and the reason the two halves are separate questions.
    // `loadBaseUrl()` has to say "nothing" so seeding runs once — but
    // `loadCredentials()` has to hand back the pair, or bootstrap would resolve
    // a settings object with no credentials and *save* it, deleting a working
    // device's identity.
    SharedPreferences.setMockInitialValues({
      SharedPrefsCredentialStore.deviceIdKey: _creds.deviceId,
      SharedPrefsCredentialStore.deviceTokenKey: _creds.deviceToken,
    });
    final store = SharedPrefsSettingsStore();

    expect(await store.loadBaseUrl(), isNull);
    expect(await store.loadCredentials(), _creds);
  });

  test('a stored address that no longer validates reads as absent', () async {
    // Better to fall back to the build-time address than to dial something
    // unusable on every retry.
    SharedPreferences.setMockInitialValues({
      SharedPrefsSettingsStore.baseUrlKey: 'http://',
    });

    expect(await SharedPrefsSettingsStore().loadBaseUrl(), isNull);
  });

  test('saving without credentials clears the stored pair', () async {
    // The contract is replace, not merge — the settings screen's "clear
    // credentials" button depends on it. Callers that only mean to add must
    // resolve against what is stored first.
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsSettingsStore();
    await store.save(
      ConnectionSettings(
        baseUrl: Uri.parse(defaultBaseUrl),
        credentials: _creds,
      ),
    );

    await store.save(ConnectionSettings(baseUrl: Uri.parse(defaultBaseUrl)));

    expect(await store.loadCredentials(), isNull);
    expect(await store.loadBaseUrl(), isNotNull);
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

    expect(await store.loadBaseUrl(), isNull);
    expect(await store.loadCredentials(), isNull);
  });
}
