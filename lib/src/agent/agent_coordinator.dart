import 'dart:async';
import 'dart:typed_data';

import '../backend/backend_gateway.dart';
import '../backend/protocol/device_command.dart';
import '../backend/protocol/device_message.dart';
import '../backend/unrecognized_command_log.dart';
import '../capture/camera_backend.dart';
import '../capture/camera_capabilities.dart';
import '../capture/camera_provider.dart';
import '../capture/capability_report.dart';
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

/// The starting mode for every announced camera.
///
/// Each camera starts at its **own measured ceiling** — the highest resolution
/// the probe saw it produce — because `resolution` is what the server
/// snapshots into `metadata`, and "the widest picture this camera gives" is
/// the honest default. The device still captures from exactly one camera at
/// one geometry ([CaptureConfig], built at camera 0's ceiling by bootstrap);
/// a camera that has never been switched to is nevertheless announced at the
/// mode it *would* run at, and the backend clamps to it via the preset ladder
/// when it is opened.
///
/// A camera the probe could not measure — an empty entry, or an index past
/// the list — falls back to [CaptureConfig]'s geometry, the same pair the
/// probe folded into its declared list, so the announced pair is always one
/// the registration can carry.
///
/// The count comes from the capabilities list, because that is what the
/// announcements are built from and the two must agree on how many cameras
/// exist. At least one entry always exists: a device whose probe found nothing
/// still has a camera 0, and `switch_camera(camera=0)` must not be out of range.
List<CameraMode> _seedModes({
  required List<CameraCapabilities> capabilities,
  required CaptureConfig config,
  required StreamSettings settings,
}) {
  final count = capabilities.isEmpty ? 1 : capabilities.length;
  return <CameraMode>[
    for (var i = 0; i < count; i++)
      CameraMode(resolution: _seedResolutionFor(capabilities, i, config), fps: settings.fps),
  ];
}

/// The ceiling camera [cameraEnum] was measured at, or [config]'s geometry.
///
/// The declared lists are cached with the probe-time fallback mode already
/// folded in, so `highestResolution` can exceed what a sub-default camera
/// really produces (a 480p webcam whose declared max reads 1280x720). That is
/// pre-existing behaviour and harmless: `presetForHeight` clamps to the real
/// ceiling when the camera opens, exactly as it did when every mode was the
/// fixed default.
CameraResolution _seedResolutionFor(
  List<CameraCapabilities> capabilities,
  int cameraEnum,
  CaptureConfig config,
) {
  if (cameraEnum < 0 || cameraEnum >= capabilities.length) {
    return config.resolution;
  }
  return capabilities[cameraEnum].highestResolution ?? config.resolution;
}

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
    List<CameraCapabilities> capabilities = const <CameraCapabilities>[],
    List<CaptureCodec> announcedCodecs = const <CaptureCodec>[
      CaptureCodec.mjpeg,
    ],
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
       _capabilities = List<CameraCapabilities>.unmodifiable(capabilities),
       _announcedCodecs = List<CaptureCodec>.unmodifiable(
         announcedCodecs.isEmpty
             ? const <CaptureCodec>[CaptureCodec.mjpeg]
             : announcedCodecs,
       ),
       _modes = _seedModes(
         capabilities: capabilities,
         config: config ?? CaptureConfig.defaults(),
         settings: settings ?? StreamSettings.defaults(),
       ),
       _log = log;

  final BackendGatewayFactory _gatewayFactory;

  /// Replaced wholesale by [adoptInventory]; never mutated in place.
  CameraProvider _cameraProvider;

  final FramePumpFactory _pumpFactory;

  /// What each announced camera was measured to accept, indexed by
  /// `camera_enum`. Empty on a device whose probe found nothing, which is not a
  /// failure state — it just means every camera declares only the mode it is in.
  List<CameraCapabilities> _capabilities;

  /// The codecs announced at registration, in order. The **first** is the
  /// preferred one, which is what an unnamed `start_recording.codec` selects.
  final List<CaptureCodec> _announcedCodecs;

  /// The mode each announced camera is at right now, indexed by `camera_enum`.
  ///
  /// The server stores **nothing** for `switch_camera`, so this is the only
  /// record of what the device is doing — and it has to be re-announced (see
  /// [_reregister]) rather than merely remembered, because the server snapshots
  /// the *registration's* values into the stream's `metadata` at
  /// `recording/start`.
  ///
  /// Grows if a command names an enum past the end: the backend range-checks
  /// the real camera list, so a value that gets this far is one the server
  /// believes in, and refusing it locally would be the device inventing a
  /// second opinion.
  List<CameraMode> _modes;

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

  /// The mode each announced camera is at, indexed by `camera_enum`.
  ///
  /// Bootstrap reads this to build the announcements, which is what makes a
  /// parameter-changing `switch_camera` visible to the server at all.
  List<CameraMode> get cameraModes => List<CameraMode>.unmodifiable(_modes);

  /// What the probe measured, indexed by `camera_enum`.
  List<CameraCapabilities> get capabilities =>
      List<CameraCapabilities>.unmodifiable(_capabilities);

  /// The announced codecs, in order. The first is the preferred one.
  List<CaptureCodec> get announcedCodecs =>
      List<CaptureCodec>.unmodifiable(_announcedCodecs);

  /// The codecs this pipeline can actually produce.
  ///
  /// `CaptureCodec.isIntraOnly` is the test rather than a name comparison: the
  /// frame pump emits one self-contained picture per frame, so a codec that
  /// needs inter-frame state cannot be produced no matter what was announced.
  /// Today that is `mjpeg` and nothing else — see the deferred native-encoder
  /// work in the plan.
  ///
  /// Checking this rather than membership of [_announcedCodecs] matters: an
  /// announcement is a claim, and a wrong claim must not be able to make the
  /// device ack a codec it cannot encode.
  List<CaptureCodec> get _producibleCodecs => <CaptureCodec>[
    for (final codec in _announcedCodecs)
      if (codec.isIntraOnly) codec,
  ];

  /// The mode the active camera is at.
  CameraMode get activeMode => _modeFor(_cameraEnum);

  /// What [cameraEnum] was announced as accepting.
  ///
  /// The same computation `buildAnnouncements` performs, so the device accepts
  /// exactly what it published. A value outside this set was never offered to
  /// the operator, so honouring it would mean capturing at a geometry the
  /// server has no record of.
  CameraCapabilities declaredFor(int cameraEnum) => declaredCapabilities(
    measured: _measuredFor(cameraEnum),
    currentResolution: _modeFor(cameraEnum).resolution,
    currentFps: _modeFor(cameraEnum).fps,
  );

  /// One entry per announced camera, for the settings screen's capability page.
  ///
  /// Reads through [declaredFor] rather than [_capabilities] directly, so the
  /// page shows the same set the device publishes and accepts. A third
  /// computation of the declared list would be free to drift from both, and the
  /// drift would show up as an operator reading a resolution off the device's
  /// own screen and being refused.
  ///
  /// Built on demand rather than cached: the mode list moves on every
  /// parameter-changing `switch_camera`, and a snapshot taken at construction
  /// would be stale exactly when it is worth reading.
  List<CameraCapabilityReport> capabilityReport() {
    // The open service is the only place camera names live. Without one there
    // are no cameras to describe, and the page says so.
    final cameras = _camera?.cameras ?? const <CameraDescriptor>[];

    return buildCapabilityReport(
      cameras: cameras,
      modes: _modes,
      declared: <CameraCapabilities>[
        for (var i = 0; i < cameras.length; i++) declaredFor(i),
      ],
      activeCameraEnum: _cameraEnum,
    );
  }

  CameraCapabilities _measuredFor(int cameraEnum) =>
      cameraEnum >= 0 && cameraEnum < _capabilities.length
      ? _capabilities[cameraEnum]
      : CameraCapabilities.empty;

  /// The mode of [cameraEnum], or the current default for one past the end.
  CameraMode _modeFor(int cameraEnum) =>
      cameraEnum >= 0 && cameraEnum < _modes.length
      ? _modes[cameraEnum]
      : CameraMode(resolution: _config.resolution, fps: _settings.fps);

  void _setMode(int cameraEnum, CameraMode mode) {
    while (_modes.length <= cameraEnum) {
      _modes.add(
        CameraMode(resolution: _config.resolution, fps: _settings.fps),
      );
    }
    _modes[cameraEnum] = mode;
  }

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
    // The mode the device is actually in. `switch_camera` stores nothing
    // server-side, so this periodic report is the only place an operator can
    // see the current geometry without reading the registration back.
    'resolution': activeMode.resolution.label,
    'fps': activeMode.fps,
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

  /// Adopts a freshly probed inventory and reconnects.
  ///
  /// Called from the settings screen's "re-detect" button, after a forced
  /// re-probe. It has to do more than update a list: the canonical order can
  /// change (a camera was plugged in, or a ceiling changed), and the announced
  /// `camera_enum` values only mean anything if the backend resolves them the
  /// same way. So the permutation and the capabilities are swapped **together**
  /// — [cameraProvider] carries the new permutation — and the device
  /// re-registers from scratch.
  ///
  /// The camera is released first because the probe has already opened every
  /// camera on the machine to measure it; holding one open here would have made
  /// the measurement a coin toss on Windows and Linux, where a second open of a
  /// busy device fails.
  ///
  /// [cameraProvider] must be built from the same inventory's order as the
  /// announcements the gateway factory publishes. Passing one without the other
  /// is the exact "two indices" mistake this design exists to prevent.
  Future<void> adoptInventory({
    required CameraProvider cameraProvider,
    required List<CameraCapabilities> capabilities,
  }) async {
    _report('adopt inventory: ${capabilities.length} camera(s)');

    await _stopRecording();
    await _camera?.release();

    _cameraProvider = cameraProvider;
    _capabilities = List<CameraCapabilities>.unmodifiable(capabilities);
    _modes = _seedModes(
      capabilities: capabilities,
      config: _config,
      settings: _settings,
    );
    // The modes above already claim the fresh ceilings, and `reconfigure`
    // below re-opens camera 0 through `_openCamera(_config)` — so the config
    // has to move with them, or the pipeline would come back up at the old
    // geometry while the registration announces the new one. Quality is kept:
    // only the geometry is re-derived.
    final camera0Ceiling = capabilities.isEmpty
        ? null
        : capabilities.first.highestResolution;
    if (camera0Ceiling != null) {
      _config = _config.copyWith(
        width: camera0Ceiling.width,
        height: camera0Ceiling.height,
      );
    }
    _camera = null;
    _cameraEnum = 0;

    // Through [reconfigure] rather than a bare `start()`, and that is
    // load-bearing: the camera list is baked into a gateway at construction, so
    // re-registering on the *same* instance would republish the list the device
    // started with. Rebuilding is what runs the gateway factory again and picks
    // up the new order and the new capabilities. It also owns the paused case.
    await reconfigure(_connection);
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
    StartRecordingCommand(:final cameraEnum, :final streamId, :final codec) =>
      'start_recording(camera=$cameraEnum, stream=$streamId'
          '${codec == null ? '' : ', codec=${codec.wireName}'})',
    StopRecordingCommand(:final cameraEnum, :final streamId) =>
      'stop_recording(camera=$cameraEnum, stream=$streamId)',
    TakePhotoCommand(:final cameraEnum, :final requestId) =>
      'take_photo(camera=$cameraEnum, request=$requestId)',
    SwitchCameraCommand(:final cameraEnum, :final resolution, :final fps) =>
      'switch_camera(camera=$cameraEnum'
          '${resolution == null ? '' : ', ${resolution.label}'}'
          '${fps == null ? '' : ' @ ${fps}fps'})',
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

    // Absent means the device's preferred codec, which is the **first** entry
    // of what was announced — not a hardcoded default that could drift from the
    // registration.
    final codec = command.codec ?? _announcedCodecs.first;
    final producible = _producibleCodecs;
    if (!producible.contains(codec)) {
      // The server's stream row is already `active` and nothing here rolls it
      // back, so the device has to be honest that it is not feeding it.
      // Encoding something else and acking `ok` would leave an operator with a
      // stream that looks alive and a recording that is not what was asked for.
      await _ack(
        command,
        ok: false,
        error:
            'codec ${codec.wireName} is not available; '
            'this device can produce '
            '${producible.map((c) => c.wireName).join('/')}',
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

    final cameraEnum = command.cameraEnum;
    final previous = _modeFor(cameraEnum);
    final requested = CameraMode(
      resolution: command.resolution ?? previous.resolution,
      fps: command.fps ?? previous.fps,
    );

    // Validate against what this camera was **announced** as accepting. The
    // operator picks from the published lists, so a value outside them is a
    // mismatch, and applying it would mean capturing at a geometry the server
    // has no record of while its stream row stays `active`.
    final declared = declaredFor(cameraEnum);
    if (!declared.resolutions.contains(requested.resolution)) {
      await _ack(
        command,
        ok: false,
        error:
            'camera $cameraEnum does not support ${requested.resolution.label}; '
            'declared ${declared.resolutions.map((r) => r.label).join('/')}',
      );
      return;
    }
    if (!declared.framerates.contains(requested.fps)) {
      await _ack(
        command,
        ok: false,
        error:
            'camera $cameraEnum does not support ${requested.fps}fps; '
            'declared ${declared.framerates.join('/')}',
      );
      return;
    }

    // Build the config first and only adopt it on success: a `reconfigure` that
    // rolls back must not leave the coordinator believing in a geometry the
    // camera is not actually at.
    final resolutionChanged = requested.resolution != previous.resolution;
    final nextConfig = resolutionChanged
        ? _config.copyWith(
            width: requested.resolution.width,
            height: requested.resolution.height,
          )
        : _config;

    try {
      await camera.switchCamera(cameraEnum);
      if (resolutionChanged) {
        await camera.reconfigure(nextConfig);
      }
    } catch (error) {
      await _ack(command, ok: false, error: '$error');
      return;
    }

    _config = nextConfig;
    _settings = _settings.copyWith(fps: requested.fps);
    _cameraEnum = cameraEnum;
    _setMode(cameraEnum, requested);
    await _ack(command, ok: true);

    if (requested.differsFrom(previous)) {
      // `switch_camera` stores no server state — the protocol doc says so
      // outright — so the server's `metadata.resolution` / `metadata.fps` are
      // whatever the registration said. Without re-registering, the next
      // recording would be recorded as the old mode.
      await _reregister();
    }
  }

  /// Reconnects so the server re-registers with the current modes.
  ///
  /// Deliberately routed through [reconfigure] rather than wiring a second
  /// reconnect path here: that method already owns "stop media, drop the old
  /// gateway, build a new one, reconnect", and the `401`-terminal-state
  /// recovery that goes with it. What makes the re-registration carry the new
  /// mode is bootstrap's gateway factory, which builds the announcements from
  /// [cameraModes] at the moment it is called.
  Future<void> _reregister() async {
    _report('  re-registering: ${_modes.map((m) => m.toString()).join(', ')}');
    await reconfigure(_connection);
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
