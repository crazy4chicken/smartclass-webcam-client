import 'connection_settings.dart';

/// Where the operator-supplied connection settings live between launches.
///
/// Pure Dart, in its own file, so the harness can import it without pulling in
/// `shared_preferences`.
abstract interface class SettingsStore {
  /// Returns null when **no address has ever been written**.
  ///
  /// That condition is deliberately narrower than "nothing is stored". A build
  /// from before this store existed wrote `device_id` / `device_token` and
  /// nothing else; if that returned a settings object carrying the default
  /// address, bootstrap would conclude it had already been seeded and never
  /// write `base_url` at all — so changing the `BASE_URL` build value would
  /// silently stop having any effect on such an install. Returning null lets
  /// them go through seeding exactly once.
  Future<ConnectionSettings?> load();

  Future<void> save(ConnectionSettings settings);

  Future<void> clear();
}
