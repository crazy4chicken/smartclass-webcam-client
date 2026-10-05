import 'dart:async';
import 'dart:typed_data';

import '../backend/backend_gateway.dart';
import '../backend/protocol/device_command.dart';
import '../backend/protocol/device_message.dart';
import '../backend/unrecognized_command_log.dart';
import '../capture/camera_backend.dart';
import '../capture/camera_provider.dart';
import '../capture/camera_resolution.dart';
import '../capture/camera_service.dart';
import '../capture/frame_pump.dart';
import '../capture/stream_settings.dart';
import '../config/connection_settings.dart';
import 'agent_status.dart';

/// Builds the pump for one recording.
///
/// A factory rather than an instance because a stream is created per
/// `start_recording`, and a pump is bound to one stream for its whole life.
typedef FramePumpFactory = FramePump Function();

/// Builds a gateway for one set of connection settings.
///
/// A factory rather than an instance because changing servers means a **new**
/// gateway, not a mutated one: `SmartClassBackendGateway` latches `_stopped`
/// on a `401`, and a stopped instance never retries. Rebuilding is what makes
/// "the token was wrong, here is the right one" recoverable at all.
///
/// The settings arrive as an **argument** rather than being captured from a
/// mutable variable on purpose. With capture, "update the variable then apply"
/// and "apply then update the variable" differ by one line and produce a
/// ghost bug that reconnects to the old address, with no compile-time signal.
/// Passing it in makes the ordering impossible to get wrong.
typedef BackendGatewayFactory = BackendGateway Function(
  ConnectionSettings connection,
);

/// Owns the camera, the command router and the frame push.
///
/// The device is a **subordinate**: it pushes nothing until the server asks.
/// The server's own words are that "frames sent after `stop_recording` are
/// dropped even if the device has not yet processed the stop", so the pump must
/// stop the instant the command lands — which is why [handleCommand] is the
/// only entry point that starts or stops media.
///
/// It only ever sees domain objects: the wire format lives behind
/// [BackendGateway], and the camera behind [CameraProvider].
class AgentCoordinator {
  AgentCoordinator({
    required BackendGatewayFactory gatewayFactory,
    required CameraProvider cameraProvider,
    required FramePumpFactory pumpFactory,
    required ConnectionSettings connection,
    CameraService? initialCamera,
    String? initialBackendId,
    CaptureConfig? config,
    StreamSettings? settings,
    void Function(String message)? log,
  }) : _gatewayFactory = gatewayFactory,
       _connection = connection,
       _gateway = gatewayFactory(connection),
       _cameraProvider = cameraProvider,
       _pumpFactory = pumpFactory,
       _camera = initialCamera,
       _backendId = initialBackendId,
       _config = config ?? CaptureConfig.defaults(),
       _settings = settings ?? StreamSettings.defaults(),
       _log = log;

  final BackendGatewayFactory _gatewayFactory;
  final CameraProvider _cameraProvider;
  final FramePumpFactory _pumpFactory;

  /// Replaced wholesale by [reconfigure]; never mutated in place.
  BackendGateway _gateway;

  ConnectionSettings _connection;

  /// Where command outcomes go.
  ///
  /// Injected rather than imported so this file stays Flutter-free, and
  /// **necessary** rather than nice-to-have: the server never waits for an ack,
  /// never retries and records nothing about most commands, so the ack is the
  /// only place an operator can learn that a command was refused. A device that
  /// acks `ok:false` into the void is indistinguishable from one that ignored
  /// the command.
  final void Function(String message)? _log;

  final StreamController<AgentStatus> _statuses =
      StreamController<AgentStatus>.broadcast();

  CameraService? _camera;
  CameraFailure? _failure;
  String? _backendId;

  CaptureConfig _config;
  StreamSettings _settings;

  LinkState _linkState = LinkState.idle;
  CaptureState _captureState = CaptureState.idle;

  /// The stream currently being fed, and the camera it belongs to.
  String? _activeStreamId;
  int? _recordingCameraEnum;

  FramePump? _pump;
  StreamSubscription<CapturedFrame>? _frameSub;

  StreamSubscription<DeviceCommand>? _commandSub;
  StreamSubscription<LinkState>? _linkSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<CameraHealth>? _healthSub;

  int _cameraEnum = 0;
  int _framesSent = 0;
  String? _lastError;
  bool _started = false;
  bool _paused = false;

  // --- read-only view -------------------------------------------------------

  /// Where this device is currently pointed, and as whom.
  ConnectionSettings get connection => _connection;

  LinkState get linkState => _linkState;

  CaptureState get captureState => _captureState;

  String? get activeStreamId => _activeStreamId;

  int get cameraEnum => _cameraEnum;

  /// The frame rate announced to the server.
  int get announcedFps => _settings.fps;

  StreamSettings get settings => _settings;

  CameraService? get cameraService => _camera;

  CameraFailure? get failure => _failure;

  String? get backendId => _backendId;

  String get cameraName => _camera?.descriptor.name ?? '';

  int get framesSent => _framesSent;

  UnrecognizedCommandLog get unrecognizedCommands =>
      _gateway.unrecognizedCommands;

  Stream<AgentStatus> get onStatus => _statuses.stream;

  AgentStatus get status => AgentStatus(
    linkState: _linkState,
    captureState: _captureState,
    activeStreamId: _activeStreamId,
    cameraName: cameraName,
    fps: _settings.fps,
    previewEnabled: _settings.previewEnabled,
    framesSent: _framesSent,
    lastError: _lastError,
  );

  /// The payload for the gateway's periodic idle `status`.
  ///
  /// The server treats it as opaque and stores nothing, but it is what keeps
  /// the 60-second read deadline from tripping and what an operator sees in
  /// the server log while nothing is being recorded.
  Map<String, Object?> reportStatus() => {
    'active_camera': _cameraEnum,
    'recording': _captureState == CaptureState.recording,
    'stream_id': _activeStreamId,
    'frames_sent': _framesSent,
    'link': _linkState.name,
  };

  // --- lifecycle ------------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _bindGateway();

    if (_camera == null) {
      await _openCamera();
    } else {
      _bindHealth();
    }

    final credentials = _connection.credentials;
    if (credentials == null) {
      // Never crash a kiosk over a missing configuration. The camera is open
      // and previewing, and the status bar says exactly what is wrong.
      _linkState = LinkState.failed;
      _lastError = '未配置设备凭据。请打开设置填写后端地址与设备凭据。';
      _emitStatus();
      return;
    }

    // Nothing is pushed here on purpose: the device waits to be told.
    await _gateway.start(credentials);
    // The gateway may already have reached `live` synchronously; adopt whatever
    // it settled on rather than assuming.
    _linkState = _gateway.state;
    _emitStatus();
  }

  /// Stops media, releases the camera and drops the link.
  ///
  /// iOS and Android forbid background camera use outright, so this is not
  /// optional politeness — it is the only correct behaviour.
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    await _stopRecording();
    // Unbinding here is what keeps [reconfigure]-while-paused correct: the
    // gateway can be swapped while backgrounded, and the subscriptions have to
    // follow the new instance rather than the old one.
    await _unbindGateway();
    await _camera?.release();
    await _gateway.stop();
    _linkState = LinkState.idle;
    _emitStatus();
  }

  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    _bindGateway();
    await _openCamera();
    final credentials = _connection.credentials;
    if (credentials != null) {
      await _gateway.start(credentials);
      _linkState = _gateway.state;
    }
    _emitStatus();
  }

  Future<void> stop() async {
    await _stopRecording();
    await _unbindGateway();
    await _healthSub?.cancel();
    _healthSub = null;

    await _camera?.release();
    await _gateway.stop();
    _linkState = LinkState.idle;
    _started = false;
    _emitStatus();
  }

  /// Swaps the backend address and/or the device credentials, then reconnects.
  ///
  /// **The caller must persist first.** Saving is the caller's job (it owns the
  /// store), and doing it before this call means a power cut during the
  /// reconnect still leaves the new settings on disk.
  ///
  /// A whole new gateway is built rather than the existing one re-pointed:
  /// a gateway that was answered with `401` has latched `_stopped` and will
  /// never retry, so "the token was mistyped, here is the right one" would
  /// otherwise be unfixable without restarting the app.
  Future<void> reconfigure(ConnectionSettings next) async {
    _report('reconfigure → ${next.baseUrl}');

    // Stop media first: the disconnect marks the stream `failed` server-side,
    // so anything pushed after this point is thrown away.
    await _stopRecording();
    await _unbindGateway();
    await _gateway.stop();

    _connection = next;
    _gateway = _gatewayFactory(next);
    _framesSent = 0;
    _lastError = null;

    if (_paused) {
      // The kiosk is in the background, so nothing may touch the camera or the
      // network. `_started` is left alone deliberately: the session is still
      // running, and `resume()` binds and starts the new gateway.
      return;
    }

    _started = false;
    // Deliberately routed through `start()` rather than wiring the link here:
    // when credentials are missing, `start()` already has the complete
    // "fail the link and say why" path. A second copy would drift from it.
    await start();
  }

  Future<void> dispose() async {
    await stop();
    await _statuses.close();
  }

  /// Re-runs camera discovery. Wired to the retry button on the error screen.
  Future<void> retryCamera() async {
    await _openCamera();
    _emitStatus();
  }

  /// Toggles the preview. Purely local — there is no server command for it,
  /// and turning it off never stops the capture path.
  Future<void> setPreviewEnabled(bool enabled) async {
    _settings = _settings.copyWith(previewEnabled: enabled);
    try {
      await _camera?.setPreviewEnabled(enabled);
    } catch (_) {
      // Preview failure must not disturb capture.
    }
    _emitStatus();
  }

  // --- command routing ------------------------------------------------------

  /// The single entry point for every server command.
  ///
  /// Every command that carries an `id` is acked, success or failure. Silent
  /// failure is forbidden: the server never waits for an ack and never retries,
  /// so an unacked command leaves an operator with no idea anything happened.
  Future<void> handleCommand(DeviceCommand command) async {
    _report('${_describe(command)} →');
    try {
      switch (command) {
        case StartRecordingCommand():
          await _startRecording(command);
        case StopRecordingCommand():
          await _stopRecordingCommand(command);
        case TakePhotoCommand():
          await _takePhoto(command);
        case SwitchCameraCommand():
          await _switchCamera(command);
        case PingCommand():
          // Answered by the gateway, which owns the transport-level pong.
          break;
      }
    } catch (error) {
      await _ack(command, ok: false, error: '$error');
    }
    _emitStatus();
  }

  /// A short, greppable rendering of a command for the console.
  static String _describe(DeviceCommand command) => switch (command) {
    StartRecordingCommand(:final cameraEnum, :final streamId) =>
      'start_recording(camera=$cameraEnum, stream=$streamId)',
    StopRecordingCommand(:final cameraEnum, :final streamId) =>
      'stop_recording(camera=$cameraEnum, stream=$streamId)',
    TakePhotoCommand(:final cameraEnum, :final requestId) =>
      'take_photo(camera=$cameraEnum, request=$requestId)',
    SwitchCameraCommand(:final cameraEnum) =>
      'switch_camera(camera=$cameraEnum)',
    PingCommand() => 'ping',
  };

  void _report(String message) => _log?.call(message);

  Future<void> _startRecording(StartRecordingCommand command) async {
    if (_captureState == CaptureState.recording) {
      // The server also refuses a second active stream for the same camera, so
      // agreeing here would only produce frames it drops.
      await _ack(
        command,
        ok: false,
        error: 'already recording stream ${_activeStreamId ?? '-'}',
      );
      return;
    }

    final camera = _camera;
    if (camera == null || !camera.isInitialized) {
      await _ack(
        command,
        ok: false,
        error: 'camera ${command.cameraEnum} is not available',
      );
      return;
    }

    final pump = _pumpFactory();
    _pump = pump;

    // Claim the stream BEFORE starting the pump. `_onCapturedFrame` drops any
    // frame that has no stream to belong to, so a pump that emits while
    // `start()` is still in flight would otherwise lose its first frame — and
    // the server's first segment would silently lose its head.
    _activeStreamId = command.streamId;
    _recordingCameraEnum = command.cameraEnum;
    _captureState = CaptureState.recording;

    _frameSub = pump.frames.listen(_onCapturedFrame);

    try {
      await pump.start(
        cameraEnum: command.cameraEnum,
        streamId: command.streamId,
        fps: _settings.fps,
        quality: _settings.quality,
      );
    } catch (_) {
      // The pump never came up, so the stream must not stay claimed. The ack
      // for this failure is written by `handleCommand`'s catch.
      await _stopRecording();
      rethrow;
    }

    await _ack(command, ok: true);
  }

  Future<void> _stopRecordingCommand(StopRecordingCommand command) async {
    // The stream id is not checked against the active one on purpose: whatever
    // the server says to stop, we stop. Frames sent after the stop are dropped
    // server-side, so continuing would be pure waste.
    //
    // A stop for an already-idle device is still `ok: true` — the server marks
    // the stream completed as soon as it queues the command, so there is no
    // failure for the device to report.
    await _stopRecording();
    await _ack(command, ok: true);
  }

  Future<void> _takePhoto(TakePhotoCommand command) async {
    final camera = _camera;
    if (camera == null || !camera.isInitialized) {
      await _ack(
        command,
        ok: false,
        error: 'camera ${command.cameraEnum} is not available',
      );
      return;
    }

    _captureState = CaptureState.capturingPhoto;
    _emitStatus();

    try {
      final bytes = await camera.captureFrame(_settings.quality);
      if (bytes == null || bytes.isEmpty) {
        await _ack(command, ok: false, error: 'the camera returned no picture');
        return;
      }

      _gateway.sendPhoto(
        PhotoMeta(
          cameraEnum: command.cameraEnum,
          requestId: command.requestId,
          // The camera plugin only ever emits JPEG.
          contentType: 'image/jpeg',
          ts: DateTime.now(),
        ),
        bytes,
      );
      await _ack(command, ok: true);
    } finally {
      // Never leave the state machine stuck in `capturingPhoto`.
      if (_captureState == CaptureState.capturingPhoto) {
        _captureState = _activeStreamId == null
            ? CaptureState.idle
            : CaptureState.recording;
      }
    }
  }

  Future<void> _switchCamera(SwitchCameraCommand command) async {
    final camera = _camera;
    if (camera == null) {
      await _ack(command, ok: false, error: 'no camera is open');
      return;
    }
    if (_captureState == CaptureState.recording) {
      // Rebuilding the pipeline under a live stream would drop frames the
      // server is still counting on.
      await _ack(
        command,
        ok: false,
        error: 'cannot switch camera while stream $_activeStreamId is active',
      );
      return;
    }

    try {
      await camera.switchCamera(command.cameraEnum);
      _cameraEnum = command.cameraEnum;
      await _ack(command, ok: true);
    } catch (error) {
      await _ack(command, ok: false, error: '$error');
    }
  }

  Future<void> _ack(
    DeviceCommand command, {
    required bool ok,
    String? error,
  }) async {
    final id = command.id;
    // `ping` is the only command without an id, and it is answered with a
    // `pong`, not an `ack`.
    if (id == null) return;
    _report('  ack ${ok ? 'ok' : 'FAILED'}${error == null ? '' : ': $error'}');
    _gateway.send(AckMessage(id: id, ok: ok, error: error));
  }

  // --- media ----------------------------------------------------------------

  void _onCapturedFrame(CapturedFrame frame) {
    final streamId = _activeStreamId;
    if (streamId == null || _captureState != CaptureState.recording) return;

    _gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: _recordingCameraEnum ?? _cameraEnum,
        streamId: streamId,
        seq: frame.seq,
        ts: frame.ts,
      ),
      frame.bytes,
    );
    _framesSent++;
  }

  Future<void> _stopRecording() async {
    final pump = _pump;
    final subscription = _frameSub;
    _pump = null;
    _frameSub = null;

    // Drop the stream identity first, then tear down. `cancel()` and `stop()`
    // both await, and a frame landing in that window must not be pushed: the
    // server discards anything that arrives after the stop anyway.
    _activeStreamId = null;
    _recordingCameraEnum = null;
    _captureState = CaptureState.idle;

    await subscription?.cancel();

    try {
      await pump?.stop();
    } catch (_) {
      // Stopping an already-dead pump is not an error worth surfacing.
    }
  }

  // --- link -----------------------------------------------------------------

  /// Subscribes to the current gateway.
  ///
  /// Split out from [start] because [reconfigure] swaps the gateway underneath
  /// and has to re-subscribe. Without the matching [unbindGateway] the old
  /// subscriptions would still be live, and the same command would be handled
  /// twice — which means two acks for one `id`.
  void _bindGateway() {
    _commandSub = _gateway.commands.listen(
      (command) => unawaited(handleCommand(command)),
    );
    _linkSub = _gateway.states.listen(_onLinkState);
    _errorSub = _gateway.errors.listen(_onGatewayError);
  }

  Future<void> _unbindGateway() async {
    await _commandSub?.cancel();
    await _linkSub?.cancel();
    await _errorSub?.cancel();
    _commandSub = null;
    _linkSub = null;
    _errorSub = null;
  }

  void _onLinkState(LinkState state) {
    final wasLive = _linkState == LinkState.live;
    _linkState = state;

    if (state != LinkState.live && wasLive) {
      // The server marks an interrupted stream `failed` and never resumes it
      // under the old id, so there is nothing to keep pushing into.
      unawaited(_stopRecording());
    }
    _emitStatus();
  }

  void _onGatewayError(String message) {
    _lastError = message;
    _emitStatus();
  }

  // --- camera ---------------------------------------------------------------

  Future<void> _openCamera() async {
    final result = await _cameraProvider.open(_config);
    _camera = result.service;
    _backendId = result.backendId;
    _failure = result.failure;

    final camera = _camera;
    if (camera == null) return;

    _cameraEnum = camera.cameraIndex;
    _bindHealth();
    try {
      await camera.setPreviewEnabled(_settings.previewEnabled);
    } catch (_) {
      // Preview is cosmetic; never block startup on it.
    }
  }

  void _bindHealth() {
    final camera = _camera;
    if (camera == null) return;
    unawaited(_healthSub?.cancel());
    _healthSub = camera.health.listen(_onCameraHealth);
  }

  void _onCameraHealth(CameraHealth health) {
    if (health == CameraHealth.lost) {
      _failure = const CameraFailure.deviceBusy();
      // A camera that disappeared takes its stream with it.
      unawaited(_stopRecording());
    }
    _emitStatus();
  }

  void _emitStatus() {
    if (_statuses.isClosed) return;
    _statuses.add(status);
  }
}
