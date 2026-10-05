import 'package:shared_preferences/shared_preferences.dart';

import '../backend/credential_store.dart';
import 'connection_settings.dart';
import 'settings_store.dart';

/// [SettingsStore] backed by `shared_preferences`.
///
/// Only **one** new key is introduced (`base_url`). The credential half is
/// delegated to the existing [CredentialStore], so an install upgrading from a
/// build that stored credentials still reads them under the same
/// `device_id` / `device_token` keys — no migration step, and no change to
/// `CredentialStore` or its tests.
class SharedPrefsSettingsStore implements SettingsStore {
  SharedPrefsSettingsStore({
    CredentialStore? credentials,
    SharedPreferences? preferences,
  }) : _credentials = credentials ?? SharedPrefsCredentialStore(),
       _preferences = preferences;

  /// The single key this class owns.
  static const String baseUrlKey = 'base_url';

  final CredentialStore _credentials;
  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<ConnectionSettings?> load() async {
    final prefs = await _prefs;
    final raw = prefs.getString(baseUrlKey);
    if (raw == null || raw.isEmpty) return null;

    // A value that no longer validates is treated as absent: falling back to
    // the build-time address beats dialling something unusable on every retry.
    final validated = validateBaseUrl(raw);
    if (!validated.isOk) return null;

    return ConnectionSettings(
      baseUrl: validated.uri!,
      credentials: await _credentials.load(),
    );
  }

  @override
  Future<void> save(ConnectionSettings settings) async {
    final prefs = await _prefs;
    // Normalise on the way in, so what is written is exactly what a comparison
    // produces — otherwise `http://Host:8080/` and `http://host:8080` would
    // look like different endpoints forever after.
    await prefs.setString(
      baseUrlKey,
      normalizeBaseUri(settings.baseUrl).toString(),
    );

    final credentials = settings.credentials;
    if (credentials == null) {
      await _credentials.clear();
    } else {
      await _credentials.save(credentials);
    }
  }

  @override
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(baseUrlKey);
    await _credentials.clear();
  }
}
