import 'package:camera/camera.dart';

import 'camera_order.dart';
import 'camera_plugin_backend.dart';
import 'camera_service.dart';

/// Builds a controller for one ranking open.
///
/// Injectable so the pass can be exercised without hardware. Separate from
/// [CameraControllerFactory] because ranking always asks for the top preset —
/// it is trying to learn a ceiling, not to honour a requested geometry.
typedef RankControllerFactory = CameraController Function(
  CameraDescription description,
);

/// Opens each camera once at the top preset to learn its real ceiling.
///
/// **One open per camera is the whole point.** Ranking runs before the ordering
/// exists, so it cannot yet know which cameras matter; a full probe here would
/// cost `n × 9` opens, and on Windows every one of those is a multi-hundred-
/// millisecond Media Foundation negotiation. The full probe runs afterwards,
/// once, on the cameras that survived the ordering.
///
/// The measured value is `previewSize`, which is what the plugin reports for
/// the surface it actually configured — not what was asked for. It is a
/// *ranking* signal only: the authoritative per-camera format list comes from
/// the capability probe, which reads real stills.
class PluginCameraRanker implements CameraRanker {
  PluginCameraRanker({
    CameraLister? listCameras,
    RankControllerFactory? controllerFactory,
  }) : _listCameras = listCameras ?? availableCameras,
       _controllerFactory = controllerFactory ?? _defaultRankControllerFactory;

  final CameraLister _listCameras;
  final RankControllerFactory _controllerFactory;

  /// Never throws, whatever the platform does.
  @override
  Future<List<RankedCamera>> rank(List<CameraDescriptor> devices) async {
    List<CameraDescription> descriptions;
    try {
      descriptions = await _listCameras();
    } catch (_) {
      // Without the plugin's own list there is nothing to open, so every
      // camera is unmeasured. The order then falls back to the physical index,
      // which is still a valid permutation and still lets the device register.
      descriptions = const <CameraDescription>[];
    }

    final ranked = <RankedCamera>[];
    for (final device in devices) {
      final index = device.index;
      final measured = index >= 0 && index < descriptions.length
          ? await _ceiling(descriptions[index])
          : 0;

      ranked.add(
        RankedCamera(
          index: index,
          group: cameraGroupFor(device.lensDirection),
          maxPixels: measured,
        ),
      );
    }
    return ranked;
  }

  /// Pixel count of the largest format the camera will open at, or 0.
  ///
  /// Every failure mode collapses to 0: a busy camera, a denied permission, a
  /// null preview size. None of them is worth aborting the ranking for, and 0
  /// has a defined meaning downstream — "unknown", sorted last.
  Future<int> _ceiling(CameraDescription description) async {
    CameraController? controller;
    try {
      controller = _controllerFactory(description);
      await controller.initialize();

      final size = controller.value.previewSize;
      if (size == null) return 0;

      final width = size.width.round();
      final height = size.height.round();
      if (width <= 0 || height <= 0) return 0;

      // Orientation-independent on purpose: pixel count is the ranking key, so
      // a portrait sensor ranks the same either way up.
      return width * height;
    } catch (_) {
      return 0;
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {
        // A controller that failed to open may also fail to close. The next
        // camera's open is what matters, and it is not blocked by this.
      }
    }
  }
}

CameraController _defaultRankControllerFactory(CameraDescription description) =>
    CameraController(
      description,
      // The ceiling is the question, so ask for the top of the ladder.
      ResolutionPreset.max,
      // Same reasoning as the capture path: the server needs video, not sound,
      // and skipping audio removes a whole permission and failure class.
      enableAudio: false,
    );
