import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../capture/camera_capabilities.dart';
import 'capabilities_store.dart';

/// [CapabilitiesStore] backed by `shared_preferences`.
///
/// **One key holding both halves**, not a fingerprint key and a payload key.
/// `SharedPreferences.setString` rewrites the whole backing store, so two calls
/// are two writes and a power cut between them leaves the new fingerprint
/// paired with the old capabilities — a cache hit that describes a camera set
/// this device no longer has. Writing a single JSON object makes the pair
/// inseparable, which is the only way to keep the promise the interface makes.
///
/// The one key it owns is new; nothing here touches `device_id` /
/// `device_token` / `base_url`, so an install's identity cannot be affected by
/// a probe finishing.
class SharedPrefsCapabilitiesStore implements CapabilitiesStore {
  SharedPrefsCapabilitiesStore({SharedPreferences? preferences})
    : _preferences = preferences;

  /// The single key this class owns.
  static const String key = 'camera_capabilities';

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<CameraCapabilities?> load(String fingerprint) async {
    final prefs = await _prefs;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Unparseable: a miss, so the next launch re-probes and overwrites it.
      return null;
    }
    if (decoded is! Map) return null;

    if (decoded['fingerprint'] != fingerprint) return null;

    final capabilities = CameraCapabilities.fromJson(decoded['capabilities']);
    // Parsed but empty is the same story as unparseable: a camera that can do
    // nothing is not a fact worth caching, and the server refuses an empty
    // list outright.
    if (capabilities.isEmpty) return null;

    return capabilities;
  }

  @override
  Future<void> save(String fingerprint, CameraCapabilities capabilities) async {
    final prefs = await _prefs;
    await prefs.setString(
      key,
      jsonEncode(<String, Object?>{
        'fingerprint': fingerprint,
        'capabilities': capabilities.toJson(),
      }),
    );
  }

  @override
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(key);
  }
}
