import 'camera_service.dart';

/// Sort key for the canonical camera order.
///
/// **Declaration order is the group order**: rear first, then external, then
/// front. [canonicalCameraOrder] sorts on `index`, so reordering these members
/// silently reorders what camera 0 means — which is the one thing the whole
/// `camera_enum` contract rests on.
///
/// Two of the five platforms cannot fill these groups honestly, and the code
/// has to work anyway:
///
/// * **Windows** reports every camera as `front` — `camera_desktop`'s
///   `windows/camera_desktop_plugin.cpp` sends the literal `0`.
/// * **Linux** reports every camera as `external` — `device_enumerator.cc` and
///   `pipewire_portal.cc` send `2`.
///
/// Only macOS and Android report a real direction. So on Windows and Linux the
/// grouping collapses to a single bucket and the order degenerates to "highest
/// resolution first" — camera 0 is simply the strongest camera, not a rear one.
/// Nothing downstream may assume a rear camera exists.
enum CameraGroup { back, external, front }

/// Maps the plugin's `lensDirection.name` onto a group.
///
/// `back` → [CameraGroup.back]; `front` → [CameraGroup.front]; anything else —
/// including `external` and `unknown` — → [CameraGroup.external].
///
/// Unknown is deliberately *not* its own group: it has to land somewhere, and
/// the middle bucket is the one that keeps a rear camera in front of it and a
/// front camera behind it, which is the least surprising place for "we do not
/// know".
CameraGroup cameraGroupFor(String lensDirectionName) {
  switch (lensDirectionName) {
    case 'back':
      return CameraGroup.back;
    case 'front':
      return CameraGroup.front;
    default:
      return CameraGroup.external;
  }
}

/// One camera as the ranking pass measured it.
class RankedCamera {
  const RankedCamera({
    required this.index,
    required this.group,
    this.maxPixels = 0,
  });

  /// Index into the platform's own camera list — the *physical* index.
  final int index;

  final CameraGroup group;

  /// Pixel count of the largest format the ranking pass could open, or 0 when
  /// it could not measure one. Zero sorts last within its group, which is the
  /// honest place for "we do not know": a camera we failed to rank must never
  /// displace one we measured.
  final int maxPixels;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RankedCamera &&
          other.index == index &&
          other.group == group &&
          other.maxPixels == maxPixels;

  @override
  int get hashCode => Object.hash(index, group, maxPixels);

  @override
  String toString() => 'RankedCamera($index, ${group.name}, $maxPixels px)';
}

/// Physical camera indices in canonical (announced) order.
///
/// Always a permutation of the input indices — never a subset, never with a
/// duplicate. Everything downstream treats the position in this list as
/// `camera_enum`, so a dropped or repeated entry would silently redefine which
/// camera the server is talking about.
///
/// The trailing `index` in the sort key is what keeps the result stable for
/// ties, and that is exactly what lets an all-`front` Windows box or an
/// all-`external` Linux box collapse to plain resolution order without a
/// special case for either platform.
List<int> canonicalCameraOrder(List<RankedCamera> cameras) {
  final sorted = List<RankedCamera>.of(cameras)
    ..sort((a, b) {
      final byGroup = a.group.index.compareTo(b.group.index);
      if (byGroup != 0) return byGroup;
      final byPixels = b.maxPixels.compareTo(a.maxPixels);
      if (byPixels != 0) return byPixels;
      return a.index.compareTo(b.index);
    });

  return <int>[for (final camera in sorted) camera.index];
}

/// Measures each camera's ceiling, so the ordering has something to sort on.
///
/// The interface lives here, next to [RankedCamera], rather than in the plugin
/// implementation: `capability_bootstrap.dart` orchestrates ranking and has to
/// stay Flutter-free so `tool/verify_pure.dart` can exercise it. Only the
/// implementation touches `package:camera`.
abstract interface class CameraRanker {
  /// Never throws.
  ///
  /// A camera that cannot be opened reports `maxPixels: 0` — "unknown", which
  /// sorts last within its group — rather than taking the whole ranking down.
  /// A device with one broken camera must still register.
  Future<List<RankedCamera>> rank(List<CameraDescriptor> devices);
}
