import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cross_file/cross_file.dart';
import 'package:permission_handler/permission_handler.dart';

import 'camera_backend.dart';
import 'camera_resolution.dart';
import 'camera_service.dart';
import 'frame_source.dart';
import 'frame_store.dart';
import 'video_chunk_recorder.dart';

/// Lists the platform's cameras. Injectable so [CameraPluginBackend] can be
/// exercised without hardware.
typedef CameraLister = Future<List<CameraDescription>> Function();

/// Asks the OS for camera permission.
typedef PermissionRequester = Future<bool> Function();

/// Builds the plugin controller. Injectable for the same reason.
typedef CameraControllerFactory = CameraController Function(
  CameraDescription description,
  CaptureConfig config,
);

/// Nominal resolution ladder reported to the backend.
///
/// The plugin takes a `ResolutionPreset`, which the docs describe as a
/// *relative* tier that does not guarantee pixel dimensions. So these are
/// advertised as candidates only — the value that really took effect is read
/// back from the live controller and reported as `appliedResolution`.
const List<CameraResolution> kNominalResolutions = <CameraResolution>[
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1920, height: 1080),
  CameraResolution(width: 3840, height: 2160),
];

ResolutionPreset _presetForHeight(int height) {
  if (height <= 240) return ResolutionPreset.low;
  if (height <= 480) return ResolutionPreset.medium;
  if (height <= 720) return ResolutionPreset.high;
  if (height <= 1080) return ResolutionPreset.veryHigh;
  return ResolutionPreset.ultraHigh;
}

CameraController _defaultControllerFactory(
  CameraDescription description,
  CaptureConfig config,
) {
  // Audio is off: the backend needs video for liveness, motion and trajectory,
  // not sound, and skipping it removes a whole permission and failure class.
  return CameraController(
    description,
    _presetForHeight(config.height),
    enableAudio: false,
  );
}

Future<bool> _defaultPermissionRequest() async {
  // Desktop platforms do not gate the camera behind a runtime prompt.
  if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
    return true;
  }
  try {
    final status = await Permission.camera.request();
    return status.isGranted || status.isLimited;
  } catch (_) {
    // permission_handler may not cover this platform; let the camera attempt
    // decide instead of failing here.
    return true;
  }
}

/// The single camera backend for all five platforms.
///
/// `camera` only ships Android / iOS / web implementations, so desktop support
/// comes from `camera_desktop` (Media Foundation on Windows, AVFoundation on
/// macOS, GStreamer + V4L2 on Linux). `camera_windows` is deliberately not a
/// dependency: it lacks an image stream and is strictly less capable.
class CameraPluginBackend implements CameraBackend {
  CameraPluginBackend({
    CameraLister? listCameras,
    PermissionRequester? requestPermission,
    FrameStore frameStore = const IoFrameStore(),
    CameraControllerFactory? controllerFactory,
    CameraPluginVideoChunkRecorder? recorder,
  })  : _listCameras = listCameras ?? availableCameras,
        _requestPermission = requestPermission ?? _defaultPermissionRequest,
        _frameStore = frameStore,
        _controllerFactory = controllerFactory ?? _defaultControllerFactory,
        _recorder = recorder;

  final CameraLister _listCameras;
  final PermissionRequester _requestPermission;
  final FrameStore _frameStore;
  final CameraControllerFactory _controllerFactory;
  final CameraPluginVideoChunkRecorder? _recorder;

  @override
  String get id {
    if (Platform.isAndroid) return 'camera_android_camerax';
    if (Platform.isIOS) return 'camera_avfoundation';
    return 'camera_desktop';
  }

  /// Never throws: every failure becomes `available: false` plus a reason.
  @override
  Future<BackendProbe> probe() async {
    try {
      final granted = await _requestPermission();
      if (!granted) {
        return const BackendProbe(
          available: false,
          reason: CameraUnavailableReason.permissionDenied,
        );
      }

      final cameras = await _listCameras();
      if (cameras.isEmpty) {
        return const BackendProbe(
          available: false,
          reason: CameraUnavailableReason.noDevice,
        );
      }

      return BackendProbe(
        available: true,
        devices: [
          for (var i = 0; i < cameras.length; i++)
            CameraDescriptor(
              name: cameras[i].name,
              index: i,
              lensDirection: cameras[i].lensDirection.name,
            ),
        ],
        supportedResolutions: kNominalResolutions,
        maxFps: 30,
        supportsPreview: true,
      );
    } catch (error) {
      return BackendProbe(
        available: false,
        reason: CameraUnavailableReason.initFailed,
        detail: '$error',
      );
    }
  }

  @override
  Future<CameraService> open(CaptureConfig config) async {
    final List<CameraDescription> cameras;
    try {
      cameras = await _listCameras();
    } catch (error) {
      throw CameraFailure.initFailed(error);
    }
    if (cameras.isEmpty) {
      throw const CameraFailure.noDevice();
    }

    final service = _PluginCameraService(
      cameras: cameras,
      config: config,
      cameraIndex: 0,
      frameStore: _frameStore,
      controllerFactory: _controllerFactory,
    );
    await service.initialize();

    // Late-bind the recorder so video chunks come from this camera.
    _recorder?.host = service;
    return service;
  }
}

/// [CameraService] backed by `CameraController`.
///
/// Rebuilds (reconfigure / switchCamera) are serialised and roll back to the
/// last working configuration, so a bad command from the backend can never
/// leave the probe without a camera.
class _PluginCameraService
    implements CameraService, RecorderHost, CameraPreviewProvider {
  _PluginCameraService({
    required List<CameraDescription> cameras,
    required CaptureConfig config,
    required int cameraIndex,
    required FrameStore frameStore,
    required CameraControllerFactory controllerFactory,
  })  : _cameras = cameras,
        _frameStore = frameStore,
        _controllerFactory = controllerFactory,
        _config = config,
        _cameraIndex = cameraIndex,
        _appliedResolution = config.resolution,
        _descriptors = [
          for (var i = 0; i < cameras.length; i++)
            CameraDescriptor(
              name: cameras[i].name,
              index: i,
              lensDirection: cameras[i].lensDirection.name,
            ),
        ];

  final List<CameraDescription> _cameras;
  final List<CameraDescriptor> _descriptors;
  final FrameStore _frameStore;
  final CameraControllerFactory _controllerFactory;

  final StreamController<CameraHealth> _healthController =
      StreamController<CameraHealth>.broadcast();

  CameraController? _controller;
  FrameSource? _frameSource;

  CaptureConfig _config;
  int _cameraIndex;
  CameraResolution _appliedResolution;
  bool _initialized = false;
  bool _previewEnabled = true;

  /// Serialises rebuilds. Captures are deliberately **not** serialised here —
  /// the coordinator drops overlapping ticks instead of queueing them.
  Future<void> _lock = Future<void>.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _lock;
    _lock = completer.future;
    return previous
        .catchError((Object _) {})
        .then((_) => action())
        .whenComplete(completer.complete);
  }

  @override
  CameraDescriptor get descriptor => _descriptors[_cameraIndex];

  @override
  List<CameraDescriptor> get cameras => List.unmodifiable(_descriptors);

  @override
  int get cameraIndex => _cameraIndex;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get previewEnabled => _previewEnabled;

  @override
  CameraResolution get appliedResolution => _appliedResolution;

  @override
  List<CameraResolution> get supportedResolutions => kNominalResolutions;

  @override
  Stream<CameraHealth> get health => _healthController.stream;

  @override
  Future<void> initialize() =>
      _synchronized(() => _rebuild(_config, _cameraIndex, rollback: false));

  @override
  Future<void> reconfigure(CaptureConfig config) =>
      _synchronized(() => _rebuild(config, _cameraIndex, rollback: true));

  @override
  Future<void> switchCamera(int index) =>
      _synchronized(() => _rebuild(_config, index, rollback: true));

  @override
  Future<void> release() => _synchronized(() async {
        await _disposeController();
      });

  @override
  Future<Uint8List?> captureFrame(int quality) async {
    final source = _frameSource;
    if (!_initialized || source == null) return null;
    return source.nextFrame(quality);
  }

  /// Turns the preview on or off without touching the capture loop.
  @override
  Future<void> setPreviewEnabled(bool enabled) async {
    _previewEnabled = enabled;
    final controller = _controller;
    if (!_initialized || controller == null) return;
    try {
      if (enabled) {
        await controller.resumePreview();
      } else {
        await controller.pausePreview();
      }
    } catch (_) {
      // Preview is cosmetic; a failure here must not disturb capture.
    }
  }

  // --- RecorderHost ---------------------------------------------------------

  @override
  Future<void> startRecording() async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('camera is not open');
    }
    await controller.startVideoRecording();
  }

  @override
  Future<XFile> stopRecording() async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('camera is not open');
    }
    return controller.stopVideoRecording();
  }

  @override
  Future<Uint8List> readFile(String path) => _frameStore.readAndDelete(path);

  // --- CameraPreviewProvider ------------------------------------------------

  @override
  Object? get previewController => _controller;

  // --- internals -----------------------------------------------------------

  Future<void> _rebuild(
    CaptureConfig config,
    int cameraIndex, {
    required bool rollback,
  }) async {
    final previousConfig = _config;
    final previousIndex = _cameraIndex;
    final previousResolution = _appliedResolution;
    final hadWorkingController = _controller != null;

    await _disposeController();

    try {
      await _openController(config, cameraIndex);
      return;
    } catch (error) {
      if (!rollback || !hadWorkingController) {
        _emitHealth(CameraHealth.lost);
        throw CameraFailure.initFailed(error);
      }

      // Restore the last configuration that worked, then still report the
      // failure so the backend learns its command was rejected.
      try {
        await _openController(previousConfig, previousIndex);
      } catch (_) {
        _emitHealth(CameraHealth.lost);
        throw CameraFailure.initFailed(error);
      }
      _appliedResolution = previousResolution;
      throw CameraFailure.initFailed(error);
    }
  }

  Future<void> _openController(CaptureConfig config, int cameraIndex) async {
    if (cameraIndex < 0 || cameraIndex >= _cameras.length) {
      throw CameraFailure.initFailed(
        'camera index $cameraIndex is out of range '
        '(${_cameras.length} available)',
      );
    }

    final description = _cameras[cameraIndex];
    final controller = _controllerFactory(description, config);
    await controller.initialize();
    if (!_previewEnabled) {
      await controller.pausePreview();
    }

    final source = TakePictureFrameSource(
      takePicture: () async => (await controller.takePicture()).path,
      frameStore: _frameStore,
    );
    await source.start(config);

    _controller = controller;
    _frameSource = source;
    _config = config;
    _cameraIndex = cameraIndex;
    _appliedResolution = _readAppliedResolution(controller, config);
    _initialized = true;
    _emitHealth(CameraHealth.ok);
  }

  Future<void> _disposeController() async {
    final source = _frameSource;
    final controller = _controller;
    _frameSource = null;
    _controller = null;
    _initialized = false;

    try {
      await source?.stop();
    } catch (_) {}
    try {
      await controller?.dispose();
    } catch (_) {}
  }

  /// Reads what the pipeline actually produced, normalised to landscape.
  CameraResolution _readAppliedResolution(
    CameraController controller,
    CaptureConfig config,
  ) {
    final size = controller.value.previewSize;
    if (size == null) return config.resolution;
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0) return config.resolution;
    return w >= h
        ? CameraResolution(width: w, height: h)
        : CameraResolution(width: h, height: w);
  }

  void _emitHealth(CameraHealth health) {
    if (!_healthController.isClosed) {
      _healthController.add(health);
    }
  }
}
