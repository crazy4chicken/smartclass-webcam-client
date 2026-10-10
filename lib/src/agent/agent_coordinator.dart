import 'dart:async';
import 'dart:typed_data';

import '../backend/backend_gateway.dart';
import '../backend/protocol/device_command.dart';
import '../backend/protocol/device_message.dart';
import '../backend/unrecognized_command_log.dart';
import '../capture/camera_backend.dart';
import '../capture/camera_capabilities.dart';
import '../capture/camera_provider.dart';
import '../capture/camera_resolution.dart';
import '../capture/capability_report.dart';
import '../capture/camera_service.dart';
import '../capture/default_mode.dart';
import '../capture/encode_budget.dart';
import '../capture/frame_pump.dart';
import '../capture/stream_settings.dart';
import '../capture/video_encoder.dart';
import '../config/connection_settings.dart';
import 'agent_status.dart';
import 'stream_diagnostics.dart';

/// Builds the pump for one recording.
///
/// A factory rather than an instance because a stream is created per
/// `start_recording`, and a pump is bound to one stream for its whole life.
typedef FramePumpFactory = FramePump Function();

/// Builds the encoder for one recording, or null if it cannot make one.
///
/// A factory rather than an instance because a stream is created per
/// `start_recording`, and an encoder is bound to one stream for its whole
/// life — the server mints a stream id per recording, so nothing here
/// outlives it.
///
/// **Null is a refusal, and it has to mean something.** The coordinator asks
/// for the codec the command named (or the device's preferred one) and acks
/// `ok:false` when it gets nothing back. It must never fall through to a
/// different codec and report success: the server's stream row is already
/// `active` by then, so a substituted codec leaves an operator with a stream
/// that looks alive and bytes that are not what was asked for.
///
/// Must be cheap to call and must open nothing on refusal, because it is
/// consulted while a command is being answered.
typedef VideoEncoderFactory = VideoEncoder? Function({
  required CaptureCodec codec,
  required int cameraEnum,
  required String streamId,
});

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

/// A [VideoEncoderFactory] that serves `mjpeg` and refuses everything else.
///
/// This is the floor every platform has: `takePicture()` already produces a
/// JPEG, and a JPEG *is* an mjpeg frame, so nothing has to be encoded. It is
/// also the honest refusal for every predictive codec, because producing one
/// needs a native encoder this build does not have — and saying so is what
/// lets the coordinator ack `ok:false` instead of quietly sending something
/// else.
///
/// [camera] is a getter rather than a value because the camera is released and
/// rebuilt on every reconfigure and re-probe; capturing one would hand an
/// encoder a dead camera service.
VideoEncoderFactory mjpegEncoderFactory({
  required FramePumpFactory pumpFactory,
  required CameraService? Function() camera,
}) => ({required codec, required cameraEnum, required streamId}) {
  if (codec != CaptureCodec.mjpeg) return null;
  final service = camera();
  if (service == null) return null;
  return MjpegEncoder(
    camera: service,
    cameraEnum: cameraEnum,
    streamId: streamId,
    pump: pumpFactory(),
  );
};

/// The starting mode for every announced camera.
///
/// One algorithm — [defaultModeFor] — for the initial open, for a re-probe and
/// for anything else that has to decide what a camera runs at, because three
/// call sites choosing a resolution independently is how a 4K camera ends up
/// opened at 4K in one path and 1080p in another, with the announcement
/// agreeing with only one of them.
///
/// The resolution is **capped at 1080p** even on a camera measured higher: 4K
/// stays in the declared list so an operator can switch to it, but the default
/// is the largest picture this client can actually sustain end to end. See
/// [defaultResolutionFor] for why the camera's own shape wins over pixel count.
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
///
/// [samples] is the device's encoding evidence. With none, [kFpsWithoutEvidence]
/// is announced rather than the configured target — see [defaultFpsFor] and
/// [kFpsWithoutEvidence]: a rate is a measurement, and a device with no
/// measurement must not declare one it has not demonstrated. The gap closes
/// itself as soon as an [EncodeBudgetProbe] supplies real samples.
List<CameraMode> _seedModes({
  required List<CameraCapabilities> capabilities,
  required CaptureConfig config,
  required List<EncodeSample> samples,
}) {
  final count = capabilities.isEmpty ? 1 : capabilities.length;
  return <CameraMode>[
    for (var i = 0; i < count; i++)
      defaultModeFor(
        measured: i < capabilities.length
            ? capabilities[i]
            : CameraCapabilities.empty,
        samples: samples,
        fallbackResolution: config.resolution,
        unmeasuredFps: kFpsWithoutEvidence,
      ),
  ];
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
    List<EncodeSample> encodeSamples = const <EncodeSample>[],
    VideoEncoderFactory? encoderFactory,
    void Function(String message)? log,
    DateTime Function()? clock,
  }) : _gatewayFactory = gatewayFactory,
       _connection = connection,
       _gateway = gatewayFactory(connection),
       _cameraProvider = cameraProvider,
       _pumpFactory = pumpFactory,
       _camera = initialCamera,
       _backendId = initialBackendId,
       _config = config ?? CaptureConfig.defaults(),
       _settings = settings ?? StreamSettings.defaults(),
       _clock = clock ?? DateTime.now,
       _capabilities = List<CameraCapabilities>.unmodifiable(capabilities),
       _announcedCodecs = List<CaptureCodec>.unmodifiable(
         announcedCodecs.isEmpty
             ? const <CaptureCodec>[CaptureCodec.mjpeg]
             : announcedCodecs,
       ),
       _encodeSamples = List<EncodeSample>.unmodifiable(encodeSamples),
       _modes = _seedModes(
         capabilities: capabilities,
         config: config ?? CaptureConfig.defaults(),
         samples: encodeSamples,
       ),
       _log = log {
    // Assigned here rather than in the initializer list because the default
    // factory has to read `_camera`, and Dart will not let an initializer read
    // another instance field. The closure stays lazy — the camera is released
    // and rebuilt on every reconfigure, so capturing one would hand an encoder
    // a dead service.
    _encoderFactory =
        encoderFactory ??
        mjpegEncoderFactory(pumpFactory: pumpFactory, camera: () => _camera);

    _statuses = StreamController<AgentStatus>.broadcast(
      onListen: _startStatusTicker,
      onCancel: _stopStatusTicker,
    );
  }

  final BackendGatewayFactory _gatewayFactory;

  /// Replaced wholesale by [adoptInventory]; never mutated in place.
  CameraProvider _cameraProvider;

  final FramePumpFactory _pumpFactory;

  /// Builds the encoder for one recording. Defaults to the mjpeg floor.
  late final VideoEncoderFactory _encoderFactory;

  /// What the device measurably held, per codec and geometry.
  ///
  /// Evidence, not capability: a codec appears here only because it was seen
  /// holding a rate. [EncodeEvidence.empty] means nothing was measured, which
  /// is a different thing from "measured and held nothing" only in how it got
  /// here — both refuse to narrow the announced list, which is why the device
  /// still needs the factory's own answer before it acks.
  List<EncodeSample> _encodeSamples;

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

  /// Broadcast to whoever is showing the status.
  ///
  /// The ticker that keeps the rates live is started and stopped by listeners
  /// rather than by the lifecycle: the status stream emits on state changes,
  /// which is right for the link but leaves a diagnostics display frozen on the
  /// first second of a recording. Tying the ticker to `onListen`/`onCancel`
  /// means a coordinator nobody is watching — every test, and the gate — never
  /// has a timer running at all.
  ///
  /// Assigned in the constructor body because the callbacks are instance
  /// methods, and a field initialiser may not touch `this`.
  late final StreamController<AgentStatus> _statuses;

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

  VideoEncoder? _encoder;
  StreamSubscription<EncodedFrame>? _frameSub;

  StreamSubscription<DeviceCommand>? _commandSub;
  StreamSubscription<LinkState>? _linkSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<CameraHealth>? _healthSub;

  int _cameraEnum = 0;
  int _framesSent = 0;
  String? _lastError;
  bool _started = false;
  bool _paused = false;

  /// The clock the diagnostics rates are sampled against.
  ///
  /// Injected so a test can drive the rolling windows without waiting: the
  /// rates are what tell a slow camera from a slow encoder from a slow link,
  /// and that rule is worth exercising.
  final DateTime Function() _clock;

  // --- live diagnostics -----------------------------------------------------

  /// Frames per second the camera produced, the encoder emitted and the
  /// gateway accepted, over a rolling window.
  ///
  /// Three windows rather than one because a single number cannot say *where*
  /// the loss is. They are cleared when a stream starts, so a fresh recording
  /// never reports the previous one's rate.
  final RollingRate _capturedRate = RollingRate();
  final RollingRate _encodedRate = RollingRate();
  final RollingRate _sentRate = RollingRate();

  /// The last source sequence seen, so a repeated picture is not counted as a
  /// new frame. Starts below any real sequence.
  int _lastSourceSeq = -1;

  /// Whether any frame has arrived for the current stream.
  ///
  /// Keeps "no window has produced a number yet" apart from "the pipeline
  /// stalled": the first reads as unknown, the second as a rate of zero.
  bool _sawFrame = false;

  /// Access units the encoder produced that never reached the gateway, and
  /// access units that carried no new picture. Both reset per stream.
  int _droppedFrames = 0;
  int _repeatedFrames = 0;

  /// What the current stream is running: the codec the command resolved to,
  /// the encoder's own identity, and the geometry it was opened at.
  CaptureCodec? _streamCodec;
  String _encoderIdentity = '';
  int _streamWidth = 0;
  int _streamHeight = 0;

  /// Why the device is not at the requested rate, when it knows.
  String? _degradationReason;

  /// Refreshes the status stream while a recording runs.
  ///
  /// The rates move every frame, but the status stream only emits on state
  /// changes — so without a ticker a diagnostics display would freeze on the
  /// first second of a recording and read as a stalled pipeline.
  Timer? _statusTicker;

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

  /// The codecs this device can serve at [mode], in preference order.
  ///
  /// Two independent filters, and both are needed:
  ///
  /// * **measurement** — [sustainableCodecsAt] keeps only codecs that were
  ///   seen holding *this* rate at *this* geometry. A codec that held 1080p30
  ///   is not available at 1080p60, and publishing it as if it were is how a
  ///   device ends up feeding a stream it cannot sustain. This is why the old
  ///   `isIntraOnly` test is gone: it excluded every real native codec on the
  ///   strength of the *codec's* shape rather than the device's evidence, so it
  ///   could never have let an H.265 stream through even on hardware that
  ///   measured fine.
  /// * **announcement** — a codec the device never published is not one the
  ///   operator was offered, so serving it would mean capturing in a form the
  ///   server has no record of.
  ///
  /// With no evidence at all the measurement filter cannot narrow anything, so
  /// the announced list passes through unchanged and the *factory* has the last
  /// word — it is what actually knows whether an encoder exists.
  List<CaptureCodec> codecsForMode(CameraMode mode) {
    final measured = sustainableCodecsAt(
      samples: _encodeSamples,
      resolution: mode.resolution,
      fps: mode.fps,
      candidates: _announcedCodecs,
    );
    return _encodeSamples.isEmpty ? _announcedCodecs : measured;
  }

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

  /// The geometry the pipeline is (re)opened at.
  ///
  /// Public so a caller can check that what the device captures at and what it
  /// announced are the same thing — which is exactly the drift this class
  /// re-derives through `defaultResolutionFor` to prevent.
  CaptureConfig get captureConfig => _config;

  CameraService? get cameraService => _camera;

  CameraFailure? get failure => _failure;

  String? get backendId => _backendId;

  String get cameraName => _camera?.descriptor.name ?? '';

  int get framesSent => _framesSent;

  UnrecognizedCommandLog get unrecognizedCommands =>
      _gateway.unrecognizedCommands;

  Stream<AgentStatus> get onStatus => _statuses.stream;

  /// The live rates, codec and geometry behind the current stream.
  ///
  /// Reads the rolling windows at call time rather than caching a snapshot:
  /// the whole point is to answer "what is happening now", and a value frozen
  /// when a state change happened would report the first second of every
  /// recording forever.
  StreamDiagnostics get diagnostics {
    final mode = activeMode;
    final recording =
        _captureState == CaptureState.recording && _activeStreamId != null;

    // Idle: the target and the declared mode are still worth showing — they are
    // what the device *would* run at — but there are no measured rates to
    // report, and reporting the previous stream's would be a lie.
    if (!recording) {
      return StreamDiagnostics(targetFps: _settings.fps, selectedFps: mode.fps);
    }

    final now = _clock();
    // Before the first frame there is nothing to divide by: "not measured" has
    // to stay distinguishable from "measured and slow", or every recording
    // would open by blaming the camera.
    final measured = _sawFrame;
    return StreamDiagnostics(
      recording: true,
      targetFps: _settings.fps,
      selectedFps: mode.fps,
      capturedFps: measured ? _capturedRate.rateAt(now) : null,
      encodedFps: measured ? _encodedRate.rateAt(now) : null,
      sentFps: measured ? _sentRate.rateAt(now) : null,
      codec: _streamCodec,
      encoderIdentity: _encoderIdentity,
      width: _streamWidth,
      height: _streamHeight,
      droppedFrames: _droppedFrames,
      repeatedFrames: _repeatedFrames,
      degradationReason: _degradationReason,
    );
  }

  AgentStatus get status => AgentStatus(
    linkState: _linkState,
    captureState: _captureState,
    activeStreamId: _activeStreamId,
    cameraName: cameraName,
    previewEnabled: _settings.previewEnabled,
    diagnostics: diagnostics,
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
    _stopStatusTicker();
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
      samples: _encodeSamples,
    );
    // The modes above already claim the fresh defaults, and `reconfigure`
    // below re-opens camera 0 through `_openCamera(_config)` — so the config
    // has to move with them, or the pipeline would come back up at the old
    // geometry while the registration announces the new one. The same
    // selector picks the geometry here, so an opened pipeline and its
    // announced mode cannot disagree. Quality is kept: only the geometry is
    // re-derived.
    _config = _config.copyWithResolution(
      defaultResolutionFor(
        measured: capabilities.isEmpty
            ? CameraCapabilities.empty
            : capabilities.first,
        fallback: _config.resolution,
      ),
    );
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

    // The mode this recording runs at, decided once and used for both the
    // validation below and the encoder's configuration — a codec is only
    // available *at a mode*, so asking the two questions separately would let
    // them disagree.
    final mode = _modeFor(command.cameraEnum);

    // Absent means the device's preferred codec for this mode, which is the
    // **first** entry of what it can serve — not a hardcoded default that
    // could drift from the registration.
    final codecs = codecsForMode(mode);
    if (codecs.isEmpty) {
      await _ack(
        command,
        ok: false,
        error:
            'no codec is available at ${mode.resolution.label} @ ${mode.fps}fps',
      );
      return;
    }
    final codec = command.codec ?? codecs.first;
    if (!codecs.contains(codec)) {
      // The server's stream row is already `active` and nothing here rolls it
      // back, so the device has to be honest that it is not feeding it.
      // Encoding something else and acking `ok` would leave an operator with a
      // stream that looks alive and a recording that is not what was asked for.
      await _ack(
        command,
        ok: false,
        error:
            'codec ${codec.wireName} is not available at '
            '${mode.resolution.label} @ ${mode.fps}fps; '
            'this device can produce '
            '${codecs.map((c) => c.wireName).join('/')}',
      );
      return;
    }

    // The command names a camera, and recording whatever happens to be open
    // instead would file every frame under the wrong id — and snapshot *that*
    // camera's announced mode into the stream's `metadata.resolution`. Moving
    // onto the named camera first is the only way the two agree.
    //
    // At its own mode, not one the command asked for: `start_recording` carries
    // no geometry, so the mode the registration already published for it is the
    // only one that is both deliverable and announced.
    if (command.cameraEnum != _cameraEnum) {
      final reason = await _activateCamera(
        command.cameraEnum,
        _modeFor(command.cameraEnum),
      );
      if (reason != null) {
        // Refused rather than recorded: the server's stream row is already
        // `active`, so acking `ok` would produce a recording it files under a
        // camera the device never switched to.
        await _ack(command, ok: false, error: reason);
        return;
      }
    }

    // Built only now, once the camera is actually on the one the command named:
    // an encoder holds the camera service, and making one for a camera the
    // device failed to move to would be building a pipeline pointed at the
    // wrong sensor.
    //
    // The last word belongs to the factory: the announced list and the
    // measurement are both claims, and this is the thing that knows whether an
    // encoder actually exists. A refusal here is the one case where "not
    // available" is not about the mode at all.
    final encoder = _encoderFactory(
      codec: codec,
      cameraEnum: command.cameraEnum,
      streamId: command.streamId,
    );
    if (encoder == null) {
      await _ack(
        command,
        ok: false,
        error: 'no ${codec.wireName} encoder is available on this device',
      );
      return;
    }
    _encoder = encoder;

    // Reset the diagnostics before any frame can land, so a fresh recording
    // never reports the previous one's rates, geometry or losses. The codec,
    // geometry and encoder identity are fixed here rather than read back from
    // the encoder later: `identity` is the platform's word and must not change
    // mid-stream.
    _capturedRate.clear();
    _encodedRate.clear();
    _sentRate.clear();
    _lastSourceSeq = -1;
    _sawFrame = false;
    _droppedFrames = 0;
    _repeatedFrames = 0;
    _streamCodec = codec;
    _encoderIdentity = encoder.identity;
    _streamWidth = mode.resolution.width;
    _streamHeight = mode.resolution.height;
    // The one degradation this layer can name without a measurement: the
    // still-picture floor is the only path in this build, and its ceiling is
    // in the capture, not the codec.
    _degradationReason = codec == CaptureCodec.mjpeg
        ? 'mjpeg 逐帧 takePicture，1080p 上限约 5–10 fps'
        : null;

    // Claim the stream BEFORE starting the producer. `_onEncodedFrame` drops
    // any frame that has no stream to belong to, so an encoder that emits while
    // `start()` is still in flight would otherwise lose its first frame — and
    // the server's first segment would silently lose its head.
    _activeStreamId = command.streamId;
    _recordingCameraEnum = command.cameraEnum;
    _captureState = CaptureState.recording;

    _frameSub = encoder.frames.listen(_onEncodedFrame);

    try {
      await encoder.start(
        width: mode.resolution.width,
        height: mode.resolution.height,
        // The **request**, not the declaration. `mode.fps` is what the server
        // is told and what it estimates segment durations from; this is the
        // ceiling the pipeline is asked to run at. The two are allowed to
        // differ, and in exactly one direction: the request may exceed what is
        // delivered, and the declaration may not. Asking for the declared rate
        // instead would throttle the pump to a number that is only a
        // placeholder until a measurement replaces it, and lose frames the
        // device could have produced.
        fps: _settings.fps,
        quality: _settings.quality,
      );
    } catch (_) {
      // The encoder never came up, so the stream must not stay claimed. The ack
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

    final reason = await _activateCamera(cameraEnum, requested);
    if (reason != null) {
      await _ack(command, ok: false, error: reason);
      return;
    }
    await _ack(command, ok: true);

    // `requested.differsFrom(previous)` is the switch's own condition, kept
    // here rather than moved into [_activateCamera]: re-registering is what a
    // *command* owes the server, not something every activation implies. This
    // is why `previous` is read before the activation and not after it.
    if (requested.differsFrom(previous)) {
      // `switch_camera` stores no server state — the protocol doc says so
      // outright — so the server's `metadata.resolution` / `metadata.fps` are
      // whatever the registration said. Without re-registering, the next
      // recording would be recorded as the old mode.
      await _reregister();
    }
  }

  /// Makes [cameraEnum] the active camera at [requested], or says why not.
  /// Returns null on success.
  ///
  /// Shared by `switch_camera` and `start_recording`: a recording that names
  /// another camera has to move the device onto it for exactly the reason a
  /// switch does — the pipeline is built at one geometry, and the server files
  /// frames under the id the command named. Split out rather than left inside
  /// `_switchCamera` because the ack is the caller's business: a switch acks a
  /// command, `start_recording` refuses one, and neither shares the other's
  /// wording.
  ///
  /// Both callers have already checked that a camera is open.
  Future<String?> _activateCamera(int cameraEnum, CameraMode requested) async {
    final camera = _camera!;

    // Validate against what this camera was **announced** as accepting. The
    // operator picks from the published lists, so a value outside them is a
    // mismatch, and applying it would mean capturing at a geometry the server
    // has no record of while its stream row stays `active`.
    final declared = declaredFor(cameraEnum);
    if (!declared.resolutions.contains(requested.resolution)) {
      return 'camera $cameraEnum does not support ${requested.resolution.label}; '
          'declared ${declared.resolutions.map((r) => r.label).join('/')}';
    }
    if (!declared.framerates.contains(requested.fps)) {
      return 'camera $cameraEnum does not support ${requested.fps}fps; '
          'declared ${declared.framerates.join('/')}';
    }

    // Compare against the geometry the pipeline is actually built at, not the
    // target camera's own mode: for a switch that carries no `resolution`,
    // `requested` is *derived from* that mode, so comparing the two always
    // reads "unchanged" and `reconfigure` is never called. The new camera then
    // keeps running at the old camera's geometry while the registration
    // announces its own ceiling — invisible while every camera shared one.
    //
    // Build the config first and only adopt it on success: a `reconfigure` that
    // rolls back must not leave the coordinator believing in a geometry the
    // camera is not actually at.
    final resolutionChanged = requested.resolution != _config.resolution;
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
      return '$error';
    }

    _config = nextConfig;
    _settings = _settings.copyWith(fps: requested.fps);
    _cameraEnum = cameraEnum;
    _setMode(cameraEnum, requested);
    return null;
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

  void _onEncodedFrame(EncodedFrame frame) {
    final now = _clock();

    // Three windows, recorded in pipeline order, because they are what tell the
    // three stages apart:
    //
    // * **capture** is measured from how far the source's own sequence moved,
    //   not from how many access units arrived. A producer whose sequence jumps
    //   from 4 to 9 has said five pictures happened; if it then hands over one
    //   access unit, the encoder — not the camera — is the stage that lost
    //   them. Counting arrivals here would make the two indistinguishable, and
    //   the encoder stage unreachable.
    // * **encode** is every access unit the encoder handed over, repeats
    //   included.
    // * **send** is what the gateway actually took.
    //
    // Collapsing these into one counter is exactly what makes a slow camera
    // indistinguishable from a slow link.
    final previous = _lastSourceSeq;
    _lastSourceSeq = frame.sourceSeq;
    // The first frame of a stream is one picture regardless of what number the
    // producer starts counting from.
    final advanced = previous < 0 ? 1 : frame.sourceSeq - previous;
    _capturedRate.record(now, weight: advanced);
    if (advanced <= 0) {
      // A picture that repeated: the producer padded its output. Counting it
      // as capture would report a rate nothing produced.
      _repeatedFrames++;
    }

    _encodedRate.record(now);
    _sawFrame = true;

    final streamId = _activeStreamId;
    if (streamId == null || _captureState != CaptureState.recording) {
      // Produced but undeliverable: the tail a native encoder flushes after a
      // stop lands here, and the server would discard those frames anyway.
      _droppedFrames++;
      return;
    }

    // The gateway answers whether the frame reached the wire. A frame it
    // refused — link down, or over the 16 MiB frame limit — must not be counted
    // as delivered, or "the network is behind" would read as "everything is
    // fine", which is the one thing the transport stage exists to rule out.
    final delivered = _gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: _recordingCameraEnum ?? _cameraEnum,
        streamId: streamId,
        seq: frame.seq,
        ts: frame.ts,
      ),
      frame.bytes,
    );
    if (!delivered) {
      _droppedFrames++;
      return;
    }
    _sentRate.record(now);
    _framesSent++;
  }

  Future<void> _stopRecording() async {
    final encoder = _encoder;
    final subscription = _frameSub;
    _encoder = null;
    _frameSub = null;

    // Drop the stream identity first, then tear down. `cancel()` and `stop()`
    // both await, and a frame landing in that window must not be pushed: the
    // server discards anything that arrives after the stop anyway.
    _activeStreamId = null;
    _recordingCameraEnum = null;
    _captureState = CaptureState.idle;

    // Stopped before cancelled, for the same reason the encoder's own `stop`
    // does it that way: a native encoder flushes pictures it is still holding
    // when told to stop, and cancelling first throws away the tail of the
    // recording — which the server cannot notice, because it just sees a
    // recording that ended a few frames early.
    try {
      await encoder?.stop();
    } catch (_) {
      // Stopping an already-dead encoder is not an error worth surfacing.
    }

    await subscription?.cancel();
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

  /// Keeps the measured rates moving while somebody is watching.
  ///
  /// One second is the coarsest tick that still reads as live and the finest
  /// that costs nothing: the rates themselves are rolling windows, so a
  /// slower tick would just sample the same window less often. Emits only
  /// while recording — an idle device has no rate to report, and a status
  /// stream that repeats itself once a second is noise for every listener.
  void _startStatusTicker() {
    _statusTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_captureState == CaptureState.recording) _emitStatus();
    });
  }

  void _stopStatusTicker() {
    _statusTicker?.cancel();
    _statusTicker = null;
  }
}
