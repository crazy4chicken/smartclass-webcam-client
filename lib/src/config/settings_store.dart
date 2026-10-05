import '../backend/device_credentials.dart';
import 'connection_settings.dart';

/// Where the operator-supplied connection settings live between launches.
///
/// The address and the credentials are **two separate questions**, and that is
/// not incidental. They are written by different things at different times: a
/// build from before this store existed wrote `device_id` / `device_token` and
/// no address at all. If the two were loaded as one value, bootstrap would see
/// "nothing usable stored" on such an install, resolve a fresh settings object
/// from the build defaults — with no credentials, because none were passed on
/// the command line — and save it. `save` means *replace*, so that would delete
/// a working device's identity on first launch after an upgrade.
///
/// Pure Dart, in its own file, so the harness can import it without pulling in
/// `shared_preferences`.
abstract interface class SettingsStore {
  /// The address an operator saved, or null when **none was ever written**.
  ///
  /// Null is the trigger for seeding, and it is deliberately narrower than
  /// "nothing is stored": an install that only ever stored credentials still
  /// has to get `base_url` written once, or changing the `BASE_URL` build value
  /// would silently stop having any effect on it. Because this is its own
  /// question, seeding can write the address without touching the credentials.
  ///
  /// A stored value that no longer validates also answers null: falling back to
  /// the build-time address beats dialling something unusable on every retry.
  Future<Uri?> loadBaseUrl();

  /// The credential pair an operator saved, or null.
  Future<DeviceCredentials?> loadCredentials();

  /// Makes the store match [settings] exactly.
  ///
  /// Note the contract: `credentials == null` means **delete the stored pair**,
  /// not "leave it alone". Callers that only mean to add something must resolve
  /// against what is already stored first — see `resolveConnectionSettings`.
  Future<void> save(ConnectionSettings settings);

  Future<void> clear();
}
