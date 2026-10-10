import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../capture/encode_budget.dart';

/// [EncodeEvidenceStore] backed by `shared_preferences`.
///
/// **One key, one write**, for the same reason as the capability cache:
/// `SharedPreferences.setString` rewrites the whole backing store, so a
/// fingerprint and a payload written separately can be separated by a power
/// cut — leaving evidence from one camera set presented as another's. The
/// fingerprint lives *inside* the object here so the two cannot drift.
///
/// Its key is its own and nothing here touches `device_id` / `device_token` /
/// `base_url`, so a measurement finishing can never affect a device's identity
/// or its backend address.
class SharedPrefsEncodeEvidenceStore implements EncodeEvidenceStore {
  SharedPrefsEncodeEvidenceStore({SharedPreferences? preferences})
    : _preferences = preferences;

  /// The single key this class owns.
  static const String key = 'encode_evidence';

  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<EncodeEvidence?> load({
    required String cameraFingerprint,
    required String encoderIdentity,
  }) async {
    final prefs = await _prefs;
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Unparseable is a miss, so the next launch re-measures and overwrites.
      return null;
    }

    final evidence = EncodeEvidence.fromJson(decoded);
    // Parsed but untrustworthy is the same story: `fromJson` answers `invalid`
    // for a payload it cannot rely on. An *empty* payload is different and is
    // kept — "this device measurably has no encoder" is worth not re-measuring.
    if (evidence.isInvalid) return null;
    if (!evidence.matches(
      cameraFingerprint: cameraFingerprint,
      encoderIdentity: encoderIdentity,
    )) {
      return null;
    }
    return evidence;
  }

  @override
  Future<void> save(EncodeEvidence value) async {
    final prefs = await _prefs;
    await prefs.setString(key, jsonEncode(value.toJson()));
  }

  @override
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(key);
  }
}
