import 'package:camera/camera.dart';

import 'camera_capabilities.dart';
import 'camera_plugin_backend.dart';
import 'camera_resolution.dart';
import 'capability_probe.dart';
import 'frame_store.dart';
import 'jpeg.dart';

/// The preset ladder walked for one camera, cheapest first.
///
/// Lives here rather than in `capability_probe.dart` because `ResolutionPreset`
/// comes from `package:camera`, and importing it into the pure contract would
/// break `tool/verify_pure.dart` for every module downstream of it.
///
/// All six rungs are tried. That looks wasteful next to the nominal ladder in
/// `kNominalResolutions`, but the presets are *relative*: on a 1080p webcam
/// `high` and `veryHigh` regularly resolve to the same real size, and on a
/// 480p one `veryHigh` and `max` both land on 640x480. Only asking every rung
/// and reading what came back produces an honest list.
const List<ResolutionPreset> kProbePresets = <ResolutionPreset>[
  ResolutionPreset.low,
  ResolutionPreset.medium,
  ResolutionPreset.high,
  ResolutionPreset.veryHigh,
  ResolutionPreset.ultraHigh,
  ResolutionPreset.max,
];

/// Builds a probe controller for one open.
///
/// Injectable so the probe can be exercised without hardware. [fps] is null for
/// the resolution sweep — the frame rate is a separate question asked once the
/// resolution ceiling is known.
typedef ProbeControllerFactory = CameraController Function(
  CameraDescription description,
  ResolutionPreset preset,
  int? fps,
);

/// Measures what a camera really produces, by opening it and taking a picture.
///
/// **A still picture is the only honest source.** The plugin stack exposes no
/// enumeration API on any of the five platforms, so there is nothing to ask;
/// `ResolutionPreset` is documented as a relative tier that guarantees no pixel
/// dimensions; and `controller.value.previewSize` describes the preview surface
/// rather than the still. So the probe takes a picture at each rung and reads
/// the dimensions out of the JPEG itself.
///
/// Writing a temporary file per rung is acceptable here and nowhere else: this
/// runs a handful of times at bootstrap, never in the frame path. The
/// no-disk capture pipeline is a separate piece of work.
class PluginCapabilityProbe implements CapabilityProbe {
  PluginCapabilityProbe({
    CameraLister? listCameras,
    ProbeControllerFactory? controllerFactory,
    FrameStore frameStore = const IoFrameStore(),
  }) : _listCameras = listCameras ?? availableCameras,
       _controllerFactory = controllerFactory ?? _defaultProbeControllerFactory,
       _frameStore = frameStore;

  final CameraLister _listCameras;
  final ProbeControllerFactory _controllerFactory;
  final FrameStore _frameStore;

  /// Never throws.
  @override
  Future<CapabilityProbeResult> probe(int physicalCameraIndex) async {
    final List<CameraDescription> cameras;
    try {
      cameras = await _listCameras();
    } catch (error) {
      return CapabilityProbeResult(
        capabilities: CameraCapabilities.empty,
        detail: '枚举摄像头失败：$error',
      );
    }

    if (cameras.isEmpty) {
      return const CapabilityProbeResult(
        capabilities: CameraCapabilities.empty,
        detail: '未检测到摄像头',
      );
    }

    if (physicalCameraIndex < 0 || physicalCameraIndex >= cameras.length) {
      return CapabilityProbeResult(
        capabilities: CameraCapabilities.empty,
        detail:
            '摄像头 $physicalCameraIndex 不在设备列表里'
            '（共 ${cameras.length} 个）',
      );
    }

    final description = cameras[physicalCameraIndex];

    // 1. Every rung of the resolution ladder, each isolated: one preset that
    //    will not open must not cost the others their turn.
    final measured = <CameraResolution>[];
    for (final preset in kProbePresets) {
      final size = await _measureStill(description, preset);
      if (size != null) measured.add(size);
    }

    final resolutions = CameraCapabilities.of(
      resolutions: measured,
      framerates: const <int>[],
    );
    if (resolutions.isEmpty) {
      return CapabilityProbeResult(
        capabilities: resolutions,
        detail: '${description.name} 在所有档位都没有产出可读的画面',
      );
    }

    // 2. Frame rates, but only at the top measured resolution. Asking at every
    //    rung would multiply the opens by six for an answer nobody uses: the
    //    device captures at one resolution at a time, and the interesting
    //    question is whether the ceiling can be held.
    final top = resolutions.highestResolution!;
    final framerates = <int>[];
    for (final fps in kProbeFramerates) {
      if (await _acceptsFramerate(description, top, fps)) framerates.add(fps);
    }

    final capabilities = CameraCapabilities.of(
      resolutions: measured,
      framerates: framerates,
    );

    return CapabilityProbeResult(
      capabilities: capabilities,
      detail:
          '${description.name}: '
          '${capabilities.resolutions.length} 个分辨率 / '
          '${capabilities.framerates.length} 个帧率',
    );
  }

  /// Opens one rung, takes one picture, and reads its real pixel size.
  ///
  /// Null for every failure mode: a preset the camera refuses, a picture that
  /// cannot be written, bytes that are not a readable JPEG. None of them is
  /// worth aborting the sweep for.
  Future<CameraResolution?> _measureStill(
    CameraDescription description,
    ResolutionPreset preset,
  ) async {
    CameraController? controller;
    try {
      controller = _controllerFactory(description, preset, null);
      await controller.initialize();

      final path = (await controller.takePicture()).path;
      // Read and delete while the camera is still open: on Windows the plugin
      // hands back a path into a temporary directory whose lifetime is tied to
      // the controller, so reading after `dispose()` is a race we do not need.
      return jpegSize(await _frameStore.readAndDelete(path));
    } catch (_) {
      return null;
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {
        // A controller that failed to open may also fail to close. The next
        // rung's open is what matters, and it is not blocked by this.
      }
    }
  }

  /// Whether the camera will open at [resolution]'s tier with [fps] requested.
  ///
  /// No picture is taken: the question is only whether the open succeeds, and
  /// the plugin throws rather than silently substituting a rate it cannot hold.
  Future<bool> _acceptsFramerate(
    CameraDescription description,
    CameraResolution resolution,
    int fps,
  ) async {
    CameraController? controller;
    try {
      controller = _controllerFactory(
        description,
        presetForHeight(resolution.height),
        fps,
      );
      await controller.initialize();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {}
    }
  }
}

CameraController _defaultProbeControllerFactory(
  CameraDescription description,
  ResolutionPreset preset,
  int? fps,
) => CameraController(
  description,
  preset,
  // Audio is off, same reasoning as the capture path: the server needs video,
  // not sound, and skipping it removes a whole permission and failure class.
  // It also means the probe does not ask for the microphone permission.
  enableAudio: false,
  // `camera` 0.12.1 takes the rate as a named argument. Passing null leaves the
  // platform default, which is what the resolution sweep wants.
  fps: fps,
);
