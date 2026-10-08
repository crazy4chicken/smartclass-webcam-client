import 'camera_capabilities.dart';
import 'camera_resolution.dart';
import 'camera_service.dart';

/// One camera's capabilities, shaped for a screen to render.
///
/// **Read-only by design.** Everything here is what the device *published* at
/// registration — the same set `switch_camera` validates against — so an
/// operator reading this page and an operator reading the server's camera list
/// are looking at the same facts. Nothing on this page changes a mode: a mode
/// change is the server's call through `switch_camera`, which is what keeps one
/// source of truth.
///
/// Pure Dart, so the assembly below is exercised by `tool/verify_pure.dart`
/// rather than only by a widget test.
class CameraCapabilityReport {
  const CameraCapabilityReport({
    required this.cameraEnum,
    required this.name,
    required this.lensDirection,
    required this.current,
    required this.declared,
    required this.isActive,
  });

  /// The announced `camera_enum`, which is this camera's position in the
  /// canonical order.
  final int cameraEnum;

  /// The platform's name for the camera, as carried in `attrs.label`.
  final String name;

  /// `front` / `back` / `external` / `unknown`. Diagnostics only, and worth
  /// showing: on Windows and Linux every camera reports `front` / `external`
  /// respectively, so seeing it here is how an installer finds that out.
  final String lensDirection;

  /// The mode this camera is at now, or null when nothing has recorded one.
  ///
  /// Nullable rather than defaulted: inventing a mode would put a number on
  /// screen that the device is not actually using.
  final CameraMode? current;

  /// Exactly what registration announces for this camera, and therefore exactly
  /// what `switch_camera` will accept.
  final CameraCapabilities declared;

  /// Whether this is the camera currently capturing.
  final bool isActive;

  List<CameraResolution> get resolutions => declared.resolutions;

  List<int> get framerates => declared.framerates;

  /// True when nothing has been measured for this camera.
  ///
  /// Not a failure state: it is what a device whose probe found nothing looks
  /// like, and it still registers — declaring only the mode it is in.
  bool get isEmpty => declared.isEmpty;

  @override
  String toString() =>
      'CameraCapabilityReport($cameraEnum, $name, $current, '
      '${resolutions.length} resolutions)';
}

/// One entry per announced camera, in canonical order.
///
/// Indexed by position, which **is** `camera_enum` for a list in canonical
/// order — the invariant `CameraInventory.descriptors` documents and the
/// harness checks. [declared] and [modes] are index-aligned with [cameras];
/// a short list degrades rather than throwing, because a screen that fails to
/// build is worse than one that says "unknown".
List<CameraCapabilityReport> buildCapabilityReport({
  required List<CameraDescriptor> cameras,
  required List<CameraMode> modes,
  required List<CameraCapabilities> declared,
  required int activeCameraEnum,
}) => <CameraCapabilityReport>[
  for (var i = 0; i < cameras.length; i++)
    CameraCapabilityReport(
      cameraEnum: i,
      name: cameras[i].name,
      lensDirection: cameras[i].lensDirection,
      current: i < modes.length ? modes[i] : null,
      declared: i < declared.length ? declared[i] : CameraCapabilities.empty,
      isActive: i == activeCameraEnum,
    ),
];
