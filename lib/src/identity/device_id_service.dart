import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persists a stable UUIDv4 that identifies this installation to the backend.
class DeviceIdService {
  DeviceIdService({Uuid? uuid, SharedPreferences? preferences})
    : _uuid = uuid ?? const Uuid(),
      _preferences = preferences;

  static const String storageKey = 'device_id';

  final Uuid _uuid;
  SharedPreferences? _preferences;
  String? _cached;

  Future<String> getOrCreateDeviceId() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = _preferences ??= await SharedPreferences.getInstance();
    final existing = prefs.getString(storageKey);
    if (existing != null && existing.isNotEmpty) {
      _cached = existing;
      return existing;
    }

    final generated = _uuid.v4();
    await prefs.setString(storageKey, generated);
    _cached = generated;
    return generated;
  }
}
