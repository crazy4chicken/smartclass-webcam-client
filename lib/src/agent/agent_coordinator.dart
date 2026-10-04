import 'dart:async';
import 'dart:io';

import '../backend/backend_gateway.dart';
import '../backend/client_signal.dart';
import '../backend/server_command.dart';
import '../backend/unrecognized_command_log.dart';
import '../capture/camera_backend.dart';
import '../capture/camera_plugin_backend.dart';
import '../capture/camera_provider.dart';
import '../capture/camera_resolution.dart';
import '../capture/camera_service.dart';
import '../capture/stream_settings.dart';
import '../capture/video_chunk_recorder.dart';
import '../config/app_config.dart';
import '../identity/device_id_service.dart';
import 'agent_status.dart';

/// Owns the capture loop, the command router, state re-sync and local autonomy.
///
/// It only ever sees domain objects: the wire format lives behind
/// [BackendGateway], and the camera behind [CameraProvider].
class AgentCoordinator {
  AgentCoordinator({
    required CameraProvider cameraProvider,
    required BackendGateway gateway,
    required DeviceIdService deviceIdService,
    VideoChunkRecorder? recorder,
    StreamSettings? initialSettings,
    Duration? registerTimeout,
  })  : _cameraProvider = cameraProvider,
        _gateway = gateway,
        _deviceIdService = deviceIdService,
        _recorder = recorder,
        _settings = initialSettings ?? StreamSettings.defaults(),
        _registerTimeout = registerTimeout ??
            const Duration(seconds: AppConfig.registerTimeoutSeconds);

  final CameraProvider _cameraProvider;
  final BackendGateway _gateway;
  final DeviceIdService _deviceIdService;
  final VideoChunkRecorder? _recorder;
  final Duration _registerTimeout;

  final StreamController<FaceResult> _faceResults =
      StreamController<FaceResult>.broadcast();
  final StreamController<double> _fpsUpdates =
      StreamController<double>.broadcast();
  final StreamController<AgentStatus> _statuses =
      StreamController<AgentStatus>.broadcast();

  StreamSettings _settings;
  CaptureConfig _captureConfig = CaptureConfig.defaults();

  CameraService? _camera;
  CameraFailure? _failure;
  String? _backendId;
  String? _deviceId;

  /// Local defaults mean we start streaming immediately, before the backend
  /// has said anything.
  bool _streaming = true;
  bool _autonomous = false;
  bool _started = false;
  bool _paused = false;
  bool _isRecording = false;
  bool _isUploading = false;
  bool _codecMismatchReported = false;

  double _targetFps = AppConfig.defaultFps;
  double _measuredFps = 0;
  int _framesInWindow = 0;
  int _chunksInWindow = 0;
  int _frameId = 0;
  int _chunkId = 0;
  int _cameraIndex = 0;
  ConnectionState _connectionState = ConnectionState.offline;

  Timer? _captureTimer;
  Timer? _fpsTimer;
  Timer? _registerTimeoutTimer;
  Timer? _autonomousRetryTimer;
  StreamSubscription<ServerCommand>? _commandSub;
  StreamSubscription<ConnectionState>? _connectionSub;
  StreamSubscription<VideoChunk>? _chunkSub;
  StreamSubscription<CameraHealth>? _healthSub;

  // --- read-only view -------------------------------------------------------

  StreamSettings get settings => _settings;

  double get currentFps => _measuredFps;

  bool get isStreaming => _streaming;

  bool get isAutonomous => _autonomous;

  String get cameraName => _camera?.descriptor.name ?? '';

  String? get backendId => _backendId;

  CameraFailure? get failure => _failure;

  CameraService? get cameraService => _camera;

  UnrecognizedCommandLog get unrecognizedCommands =>
      _gateway.unrecognizedCommands;

  Stream<FaceResult> get onFaceResult => _faceResults.stream;

  Stream<double> get onFpsUpdate => _fpsUpdates.stream;

  Stream<AgentStatus> get onStatus => _statuses.stream;

  AgentStatus get status => AgentStatus(
        connection: _connectionState,
        fps: _measuredFps,
        cameraName: cameraName,
        streaming: _streaming,
        autonomous: _autonomous,
        resolutionLabel: _effectiveResolution.label,
        streamModeLabel: _streamModeLabel,
        previewEnabled: _settings.previewEnabled,
        backendId: _backendId ?? '',
      );

  CameraResolution get _effectiveResolution =>
      _camera?.appliedResolution ?? _captureConfig.resolution;

  String get _streamModeLabel => _settings.mode == StreamMode.still
      ? '静态帧'
      : '视频·${_settings.codec.name.toUpperCase()}';

  // --- lifecycle ------------------------------------------------------------

  /// Starts capturing on local defaults immediately — it does **not** wait for
  /// the backend to answer.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _deviceId = await _deviceIdService.getOrCreateDeviceId();

    _commandSub = _gateway.commands.listen(handleCommand);
    _connectionSub = _gateway.connectionChanges.listen(_onConnectionState);

    await _openCamera();
    await _gateway.connect(AppConfig.wsUrl);

    _sendRegister();
    _startFpsWindow();
    await _applyCurrentMode();

    _registerTimeoutTimer = Timer(_registerTimeout, _enterAutonomousIfSilent);
    _emitStatus();
  }

  /// Pauses capture, releases the camera and drops the connection.
  ///
  /// iOS and Android forbid background camera use outright, so this is not
  /// optional politeness — it is the only correct behaviour.
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    _stopStillLoop();
    await _stopVideoMode();
    await _camera?.release();
    await _gateway.disconnect();
    _emitStatus();
  }

  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    await _openCamera();
    await _gateway.connect(AppConfig.wsUrl);
    await _applyCurrentMode();
    _startFpsWindow();
    _sendRegister();
    _emitStatus();
  }

  Future<void> stop() async {
    _stopStillLoop();
    _fpsTimer?.cancel();
    _fpsTimer = null;
    _registerTimeoutTimer?.cancel();
    _registerTimeoutTimer = null;
    _autonomousRetryTimer?.cancel();
    _autonomousRetryTimer = null;

    await _stopVideoMode();
    await _commandSub?.cancel();
    await _connectionSub?.cancel();
    await _healthSub?.cancel();
    await _camera?.release();
    await _gateway.disconnect();

    _started = false;
    _emitStatus();
  }

  Future<void> dispose() async {
    await stop();
    await _faceResults.close();
    await _fpsUpdates.close();
    await _statuses.close();
  }

  // --- camera ---------------------------------------------------------------

  Future<void> _openCamera() async {
    final result = await _cameraProvider.open(_captureConfig);
    _camera = result.service;
    _backendId = result.backendId;
    _failure = result.failure;

    final camera = _camera;
    if (camera == null) return;

    _cameraIndex = camera.cameraIndex;
    await _healthSub?.cancel();
    _healthSub = camera.health.listen(_onCameraHealth);
    try {
      await camera.setPreviewEnabled(_settings.previewEnabled);
    } catch (_) {
      // Preview is cosmetic; never block startup on it.
    }
  }

  /// Re-runs camera discovery. Wired to the retry button on the error screen.
  Future<void> retryCamera() async {
    await _openCamera();
    if (_camera != null) {
      await _applyCurrentMode();
    }
    _emitStatus();
  }

  void _onCameraHealth(CameraHealth health) {
    if (health == CameraHealth.lost) {
      _failure = const CameraFailure.deviceBusy();
    }
    _emitStatus();
  }

  // --- capture loop ---------------------------------------------------------

  /// One still-frame tick.
  ///
  /// Public so tests can drive it directly. The in-flight lock is claimed
  /// **before** the first `await`, so a tick that arrives while the previous
  /// upload is still running is dropped rather than queued.
  Future<void> performCaptureTick() async {
    if (!_streaming || _isUploading) return;

    final camera = _camera;
    if (camera == null || !camera.isInitialized) return;

    _isUploading = true;
    try {
      final frame = await camera.captureFrame(_captureConfig.quality);
      if (frame == null) return;

      final resolution = camera.appliedResolution;
      _gateway.sendFrameMeta(FrameMeta(
        frameId: ++_frameId,
        deviceId: _deviceId ?? '',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        width: resolution.width,
        height: resolution.height,
        quality: _captureConfig.quality,
      ));
      _gateway.sendFrameBytes(frame);
      _framesInWindow++;
    } catch (_) {
      // A dropped frame is expected; never rethrow into the loop.
    } finally {
      // Must release on every path, including the early return above.
      _isUploading = false;
    }
  }

  void _startStillLoop() {
    _captureTimer?.cancel();
    if (!_streaming) return;
    final fps = _targetFps > 0 ? _targetFps : AppConfig.defaultFps;
    final intervalMs = (1000 / fps).round().clamp(1, 60000);
    _captureTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => performCaptureTick(),
    );
  }

  void _stopStillLoop() {
    _captureTimer?.cancel();
    _captureTimer = null;
  }

  Future<void> _applyCurrentMode() async {
    if (_settings.mode == StreamMode.video && _recorder != null) {
      final started = await _startVideoMode();
      if (started) return;
    }
    _startStillLoop();
  }

  Future<bool> _startVideoMode() async {
    final recorder = _recorder;
    if (recorder == null) return false;

    _stopStillLoop();
    try {
      await recorder.start(
        codec: _settings.codec,
        chunkSeconds: _settings.chunkSeconds,
        config: _captureConfig,
      );
    } catch (_) {
      return false;
    }

    _isRecording = true;
    _codecMismatchReported = false;
    await _chunkSub?.cancel();
    _chunkSub = recorder.chunks.listen(_onVideoChunk);
    return true;
  }

  Future<void> _stopVideoMode() async {
    await _chunkSub?.cancel();
    _chunkSub = null;
    if (!_isRecording) return;
    _isRecording = false;
    try {
      await _recorder?.stop();
    } catch (_) {
      // Stopping a dead recorder is not an error worth surfacing.
    }
  }

  void _onVideoChunk(VideoChunk chunk) {
    if (!_streaming) return;

    _gateway.sendVideoMeta(VideoMeta(
      chunkId: ++_chunkId,
      deviceId: _deviceId ?? '',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      codec: chunk.codec,
      sequence: chunk.sequence,
      durationMs: chunk.durationMs,
      width: chunk.width,
      height: chunk.height,
    ));
    _gateway.sendVideoBytes(chunk.bytes);
    _chunksInWindow++;

    // Report the degradation once per mode change, not once per chunk.
    final requested = chunk.requestedCodec;
    if (chunk.isCodecMismatch && requested != null && !_codecMismatchReported) {
      _codecMismatchReported = true;
      _gateway.sendSignal(CapabilityMismatchSignal(
        requested: requested.wireName,
        applied: chunk.codec.wireName,
        reason: 'the camera plugin can only encode AVC',
      ));
    }
  }

  void _startFpsWindow() {
    _fpsTimer?.cancel();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // In still mode this is frames per second; in video mode it is chunks
      // per second, which is the only upload event there is.
      final measured = _settings.mode == StreamMode.video
          ? _chunksInWindow.toDouble()
          : _framesInWindow.toDouble();
      _framesInWindow = 0;
      _chunksInWindow = 0;
      _measuredFps = measured;
      if (!_fpsUpdates.isClosed) {
        _fpsUpdates.add(measured);
      }
      _emitStatus();
    });
  }

  // --- command routing ------------------------------------------------------

  /// Preview toggle entry point for the UI.
  Future<void> setPreviewEnabled(bool enabled) =>
      _handleSetPreview(SetPreviewCommand(enabled: enabled));

  Future<void> handleCommand(ServerCommand command) async {
    switch (command) {
      case UpdateConfigCommand():
        await _handleUpdateConfig(command);
      case SetStreamModeCommand():
        await _handleSetStreamMode(command);
      case ControlStreamCommand():
        await _handleControlStream(command);
      case SwitchCameraCommand():
        await _handleSwitchCamera(command);
      case SetPreviewCommand():
        await _handleSetPreview(command);
      case FaceResultCommand():
        if (!_faceResults.isClosed) {
          _faceResults.add(command.result);
        }
    }
    _emitStatus();
  }

  Future<void> _handleUpdateConfig(UpdateConfigCommand command) async {
    _captureConfig = _captureConfig.copyWith(
      width: command.width,
      height: command.height,
      quality: command.quality,
    );
    final fps = command.fps;
    if (fps != null && fps > 0) {
      _targetFps = fps;
    }

    final camera = _camera;
    if (camera != null) {
      try {
        await camera.reconfigure(_captureConfig);
      } catch (_) {
        _reportMismatch(
          '${command.width ?? '-'}x${command.height ?? '-'}',
          _effectiveResolution.label,
          'the camera rejected the requested format',
        );
      }
    }

    if (_settings.mode == StreamMode.still) {
      _startStillLoop();
    }
  }

  Future<void> _handleSetStreamMode(SetStreamModeCommand command) async {
    final previous = _settings;
    _settings = _settings.copyWith(
      mode: command.mode,
      codec: command.codec,
      chunkSeconds: command.chunkSeconds,
    );

    if (_settings.mode == StreamMode.video) {
      final started = await _startVideoMode();
      if (started) return;

      // Never leave the probe without a picture: fall back to still frames and
      // tell the backend what actually happened.
      _settings = previous.copyWith(mode: StreamMode.still);
      _reportMismatch(
        'video',
        'still',
        'video recording is unavailable on this device',
      );
      _startStillLoop();
      return;
    }

    await _stopVideoMode();
    _startStillLoop();
  }

  Future<void> _handleControlStream(ControlStreamCommand command) async {
    _streaming = command.enabled;
    if (!_streaming) {
      _stopStillLoop();
      await _stopVideoMode();
      return;
    }
    await _applyCurrentMode();
  }

  Future<void> _handleSwitchCamera(SwitchCameraCommand command) async {
    final camera = _camera;
    if (camera == null) return;
    try {
      await camera.switchCamera(command.index);
      _cameraIndex = command.index;
    } catch (_) {
      _reportMismatch(
        'camera ${command.index}',
        'camera $_cameraIndex',
        'the camera could not be switched',
      );
    }
  }

  /// Toggles the preview only — the capture loop keeps running either way.
  Future<void> _handleSetPreview(SetPreviewCommand command) async {
    _settings = _settings.copyWith(previewEnabled: command.enabled);
    try {
      await _camera?.setPreviewEnabled(command.enabled);
    } catch (_) {
      // Preview failure must not disturb capture.
    }
  }

  void _reportMismatch(String requested, String applied, String reason) {
    _gateway.sendSignal(CapabilityMismatchSignal(
      requested: requested,
      applied: applied,
      reason: reason,
    ));
  }

  // --- connection -----------------------------------------------------------

  void _onConnectionState(ConnectionState state) {
    _connectionState = state;
    _emitStatus();
  }

  /// Called when the gateway comes back up.
  ///
  /// Every mutable setting is re-announced, because the backend has no idea
  /// what changed while it was away.
  Future<void> onGatewayConnectionChanged(ConnectionState state) async {
    if (state != ConnectionState.connected) return;

    final deviceId =
        _deviceId ??= await _deviceIdService.getOrCreateDeviceId();
    _gateway.sendSignal(
      RegisterSignal(deviceId: deviceId, capabilities: _buildCapabilities()),
    );
    _gateway.sendSignal(_buildStateSync());

    // We are talking to the backend again, so local autonomy is over.
    _autonomous = false;
    _autonomousRetryTimer?.cancel();
    _autonomousRetryTimer = null;
    _emitStatus();
  }

  void _sendRegister() {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    _gateway.sendSignal(
      RegisterSignal(deviceId: deviceId, capabilities: _buildCapabilities()),
    );
  }

  void _enterAutonomousIfSilent() {
    if (_autonomous) return;
    _autonomous = true;
    _autonomousRetryTimer = Timer.periodic(
      const Duration(seconds: AppConfig.autonomousRetrySeconds),
      (_) => _sendRegister(),
    );
    _emitStatus();
  }

  ClientCapabilities _buildCapabilities() {
    final camera = _camera;
    return ClientCapabilities(
      platform: Platform.operatingSystem,
      modes: const [StreamMode.still, StreamMode.video],
      videoCodecs: _recorder?.supportedCodecs.toList() ??
          const [VideoCodec.avc],
      maxFps: _targetFps,
      hasPreview: true,
      supportedResolutions:
          camera?.supportedResolutions ?? kNominalResolutions,
      cameras: camera?.cameras.map((c) => c.name).toList() ?? const [],
    );
  }

  StateSyncSignal _buildStateSync() {
    final resolution = _effectiveResolution;
    return StateSyncSignal(
      width: resolution.width,
      height: resolution.height,
      quality: _captureConfig.quality,
      fps: _targetFps,
      cameraIndex: _cameraIndex,
      streaming: _streaming,
      mode: _settings.mode,
      codec: _settings.codec,
      chunkSeconds: _settings.chunkSeconds,
      previewEnabled: _settings.previewEnabled,
    );
  }

  void _emitStatus() {
    if (_statuses.isClosed) return;
    _statuses.add(status);
  }
}
