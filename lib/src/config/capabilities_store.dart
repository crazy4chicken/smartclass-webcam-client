import '../capture/camera_capabilities.dart';

/// Identifies a camera set.
///
/// **Order-sensitive**, because `camera_enum` is positional: swapping two
/// cameras changes what index 0 means just as much as swapping the hardware
/// does, and a cache that survived it would announce one camera's capabilities
/// under another camera's enum.
///
/// Length-prefixed rather than joined on a separator: `['a|b']` and
/// `['a', 'b']` are different camera sets and must not collide. Names come from
/// the platform and can contain anything, so no single separator is safe.
///
/// A plain encoding rather than a hash: it is short, it has no collision risk
/// at all, and it is readable in `shared_preferences` when someone is debugging
/// a device by hand.
String cameraFingerprint(List<String> cameraNames) {
  final buffer = StringBuffer();
  for (final name in cameraNames) {
    buffer
      ..write(name.length)
      ..write(':')
      ..write(name)
      ..write(';');
  }
  return buffer.toString();
}

/// Where measured capabilities are cached between launches.
///
/// **Deliberately not part of `SettingsStore`.** `save()` there means *replace*,
/// and `credentials == null` deletes the stored pair; routing capabilities
/// through `ConnectionSettings` would therefore delete a working device's
/// identity every time a probe finished. Capabilities are also a different kind
/// of fact — derived from hardware, invalidated by hardware — so they get their
/// own key and their own lifecycle.
///
/// Pure Dart, in its own file, so the harness can import it without pulling in
/// `shared_preferences`.
abstract interface class CapabilitiesStore {
  /// The cached capabilities for [fingerprint], or null.
  ///
  /// Null means **re-probe**, and it is returned for all three of: nothing
  /// stored, a stored fingerprint for a different camera set, and a payload
  /// that will not parse. A corrupt cache is a miss rather than an empty
  /// answer — treating it as a hit would announce "only what I am doing right
  /// now" for a device that could have declared more, and it would never
  /// self-heal, because the hit would keep coming back.
  Future<CameraCapabilities?> load(String fingerprint);

  Future<void> save(String fingerprint, CameraCapabilities capabilities);

  Future<void> clear();
}
