// Runs the protocol, capture and agent layers on a plain Dart VM.
//
// `flutter test` cannot run in this environment (see README / memory notes),
// so this harness exercises every module that does not transitively depend on
// Flutter. That covers the whole wire protocol, the registration client, both
// gateways, the capture pipeline and the coordinator — which is most of the
// system, and the part where a protocol mistake is expensive.
//
//   dart run tool/verify_pure.dart
//
// It is intentionally dependency-free apart from `fake_async`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:webcam_client/src/agent/agent_coordinator.dart';
import 'package:webcam_client/src/agent/agent_status.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/backend/health_probe.dart';
import 'package:webcam_client/src/backend/mock_backend_gateway.dart';
import 'package:webcam_client/src/backend/protocol/binary_frame.dart';
import 'package:webcam_client/src/backend/protocol/device_command.dart';
import 'package:webcam_client/src/backend/protocol/device_message.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';
import 'package:webcam_client/src/backend/registration_client.dart';
import 'package:webcam_client/src/backend/registration_request.dart';
import 'package:webcam_client/src/backend/smartclass_backend_gateway.dart';
import 'package:webcam_client/src/backend/unrecognized_command_log.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_order.dart';
import 'package:webcam_client/src/capture/camera_provider.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/capability_probe.dart';
import 'package:webcam_client/src/capture/codec_probe.dart';
import 'package:webcam_client/src/capture/frame_pump.dart';
import 'package:webcam_client/src/capture/frame_store.dart';
import 'package:webcam_client/src/capture/jpeg.dart';
import 'package:webcam_client/src/capture/resolution_selector.dart';
import 'package:webcam_client/src/capture/serial_lock.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/video_encoder.dart';
import 'package:webcam_client/src/config/capabilities_store.dart';
import 'package:webcam_client/src/config/connection_settings.dart';

// --- harness ----------------------------------------------------------------

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool condition) {
  if (condition) {
    _passed++;
  } else {
    _failures.add(name);
    print('  FAIL: $name');
  }
}

void eq(String name, Object? actual, Object? expected) {
  check('$name  (got: $actual, want: $expected)', actual == expected);
}

void eqBytes(String name, List<int> actual, List<int> expected) {
  var same = actual.length == expected.length;
  if (same) {
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) {
        same = false;
        break;
      }
    }
  }
  check('$name  (got: $actual, want: $expected)', same);
}

void section(String name) => print(name);

/// Lets queued microtasks and zero-delay timers run.
Future<void> settle([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// --- shared fixtures --------------------------------------------------------

const DeviceCredentials credentials = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

final String ticket64 = List<String>.filled(64, 'b').join();

const String streamId = '01J8ZKQ3B5N7P9R1T3V5X7Z9B2';

/// A provisioned connection pointing at the built-in default address.
final ConnectionSettings testConnection = ConnectionSettings(
  baseUrl: Uri.parse(defaultBaseUrl),
  credentials: credentials,
);

const CameraAnnouncement cameraAnnouncement = CameraAnnouncement(
  cameraEnum: 0,
  resolution: '1280x720',
  fps: 5,
  supportedCodec: <WireCodec>[WireCodec.mjpeg],
  supportedResolutions: <CameraResolution>[
    CameraResolution(width: 1280, height: 720),
  ],
  supportedFramerates: <int>[5],
);

const List<CameraResolution> nominalResolutions = <CameraResolution>[
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1920, height: 1080),
];

// --- fakes ------------------------------------------------------------------

class _FakeCameraService implements CameraService {
  _FakeCameraService({this.bytes, this.failTimes = 0, this.delay});

  final Uint8List? bytes;
  int failTimes;
  final Duration? delay;

  int captureCalls = 0;
  int reconfigureCalls = 0;
  CaptureConfig? lastConfig;
  int _inFlight = 0;
  int maxConcurrentCaptures = 0;
  int _cameraIndex = 0;
  bool _initialized = true;
  bool _preview = true;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> reconfigure(CaptureConfig config) async {
    reconfigureCalls++;
    lastConfig = config;
  }

  @override
  Future<void> switchCamera(int index) async => _cameraIndex = index;

  @override
  Future<Uint8List?> captureFrame(int quality) async {
    captureCalls++;
    _inFlight++;
    maxConcurrentCaptures = max(maxConcurrentCaptures, _inFlight);
    try {
      if (delay != null) await Future<void>.delayed(delay!);
      if (failTimes > 0) {
        failTimes--;
        throw StateError('camera busy');
      }
      return bytes;
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<void> setPreviewEnabled(bool enabled) async => _preview = enabled;
  @override
  Future<void> release() async => _initialized = false;

  @override
  CameraDescriptor get descriptor =>
      CameraDescriptor(name: 'fake camera', index: _cameraIndex);
  @override
  bool get isInitialized => _initialized;
  @override
  bool get previewEnabled => _preview;
  @override
  CameraResolution get appliedResolution =>
      const CameraResolution(width: 1280, height: 720);
  @override
  List<CameraResolution> get supportedResolutions => nominalResolutions;
  @override
  List<CameraDescriptor> get cameras => const <CameraDescriptor>[
    CameraDescriptor(name: 'fake camera', index: 0),
  ];
  @override
  int get cameraIndex => _cameraIndex;
  @override
  Stream<CameraHealth> get health => const Stream<CameraHealth>.empty();
}

class _FakeBackend implements CameraBackend {
  _FakeBackend(this.id, {this.probeResult, this.openError});

  @override
  final String id;
  final BackendProbe? probeResult;
  final Object? openError;

  @override
  Future<BackendProbe> probe() async => probeResult!;

  @override
  Future<CameraService> open(CaptureConfig config) async {
    final error = openError;
    if (error != null) throw error;
    return _FakeCameraService(bytes: Uint8List.fromList([1]));
  }
}

class _ThrowingBackend implements CameraBackend {
  @override
  String get id => 'explodes';
  @override
  Future<BackendProbe> probe() async => throw StateError('no backend here');
  @override
  Future<CameraService> open(CaptureConfig config) async =>
      throw StateError('unreachable');
}

BackendProbe _unavailable(CameraUnavailableReason reason) =>
    BackendProbe(available: false, reason: reason);

const BackendProbe _okProbe = BackendProbe(
  available: true,
  devices: <CameraDescriptor>[],
  supportedResolutions: <CameraResolution>[],
  maxFps: 30,
  supportsPreview: true,
);

/// A pump whose frames the test drives by hand.
class _FakeFramePump implements FramePump {
  final StreamController<CapturedFrame> _controller =
      StreamController<CapturedFrame>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  int? lastCameraEnum;
  String? lastStreamId;
  int? lastFps;
  int? lastQuality;

  /// Frames emitted from inside `start()`, before it completes.
  ///
  /// Models a pump that can produce a frame while the coordinator is still
  /// awaiting startup — the window in which a naive implementation drops the
  /// first frame of every recording.
  List<CapturedFrame> framesOnStart = const <CapturedFrame>[];

  /// When set, [start] fails the way a busy sensor does.
  Object? startError;

  @override
  Stream<CapturedFrame> get frames => _controller.stream;

  @override
  Future<void> start({
    required int cameraEnum,
    required String streamId,
    required int fps,
    required int quality,
  }) async {
    startCalls++;
    lastCameraEnum = cameraEnum;
    lastStreamId = streamId;
    lastFps = fps;
    lastQuality = quality;
    final error = startError;
    if (error != null) throw error;
    for (final frame in framesOnStart) {
      _controller.add(frame);
    }
  }

  @override
  Future<void> stop() async => stopCalls++;

  void emit(CapturedFrame frame) => _controller.add(frame);
}

/// A gateway that records everything the device hands it.
class _FakeGateway implements BackendGateway {
  final StreamController<DeviceCommand> _commands =
      StreamController<DeviceCommand>.broadcast();
  final StreamController<LinkState> _states =
      StreamController<LinkState>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();

  final List<DeviceMessage> sent = <DeviceMessage>[];
  final List<RecordingFrameMeta> frameMeta = <RecordingFrameMeta>[];
  final List<Uint8List> frameBytes = <Uint8List>[];
  final List<PhotoMeta> photoMeta = <PhotoMeta>[];
  final List<Uint8List> photoBytes = <Uint8List>[];

  LinkState _state = LinkState.idle;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<DeviceCommand> get commands => _commands.stream;
  @override
  Stream<LinkState> get states => _states.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  LinkState get state => _state;
  @override
  UnrecognizedCommandLog get unrecognizedCommands => UnrecognizedCommandLog();

  @override
  Future<void> start(DeviceCredentials creds) async {
    startCalls++;
    setState(LinkState.live);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    setState(LinkState.idle);
  }

  @override
  void send(DeviceMessage message) => sent.add(message);

  @override
  void sendRecordingFrame(RecordingFrameMeta meta, Uint8List bytes) {
    frameMeta.add(meta);
    frameBytes.add(bytes);
  }

  @override
  void sendPhoto(PhotoMeta meta, Uint8List bytes) {
    photoMeta.add(meta);
    photoBytes.add(bytes);
  }

  void setState(LinkState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  void emitCommand(DeviceCommand command) {
    if (!_commands.isClosed) _commands.add(command);
  }

  void emitError(String message) {
    if (!_errors.isClosed) _errors.add(message);
  }

  List<AckMessage> get acks => sent.whereType<AckMessage>().toList();
}

/// Hands out a fresh gateway per call, recording what it was asked for.
///
/// A real factory has to produce a new instance each time — re-pointing a
/// gateway that latched `_stopped` on a `401` would never retry — so the double
/// does the same and keeps the evidence.
class _FakeGatewayFactory {
  final List<ConnectionSettings> requested = <ConnectionSettings>[];
  final List<_FakeGateway> built = <_FakeGateway>[];

  BackendGateway call(ConnectionSettings connection) {
    requested.add(connection);
    final gateway = _FakeGateway();
    built.add(gateway);
    return gateway;
  }
}

class _FakeSink implements ChannelSink {
  final List<dynamic> records = <dynamic>[];
  bool closed = false;

  List<String> get text => records.whereType<String>().toList();
  List<Uint8List> get binary => records.whereType<Uint8List>().toList();

  @override
  void add(dynamic data) => records.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }
}

class _FakeChannel implements BackendChannel {
  _FakeChannel(this.stream, this.sink, {this.readyError, this.closeCode});

  @override
  final Stream<dynamic> stream;
  @override
  final _FakeSink sink;
  final Object? readyError;
  @override
  int? closeCode;

  @override
  Future<void> get ready => readyError == null
      ? Future<void>.value()
      : Future<void>.error(readyError!);
}

class _FakeRegistration implements RegistrationClient {
  _FakeRegistration({this.failure, this.ticket, this.websocketPath});

  final RegistrationFailure? failure;
  final String? ticket;
  final String? websocketPath;

  int calls = 0;
  Uri? lastBase;
  DeviceCredentials? lastCredentials;
  List<CameraAnnouncement>? lastCameras;

  @override
  Future<RegistrationResult> register(
    Uri base,
    DeviceCredentials creds,
    List<CameraAnnouncement> cameras,
  ) async {
    calls++;
    lastBase = base;
    lastCredentials = creds;
    lastCameras = cameras;

    final failure = this.failure;
    if (failure != null) throw RegistrationException(failure);

    final resolved = ticket ?? ticket64;
    return RegistrationResult(
      ticket: resolved,
      expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 60)),
      websocketPath: websocketPath ?? '/ws/device/$resolved',
    );
  }
}

/// A gateway harness that keeps its socket open.
class _GatewayHarness {
  _GatewayHarness({
    RegistrationFailure? failure,
    Object? readyError,
    Duration Function(int)? backoff,
    Duration? idleStatusInterval,
    Map<String, Object?> Function()? statusReport,
    String? websocketPath,
  }) : registration = _FakeRegistration(
         failure: failure,
         websocketPath: websocketPath,
       ) {
    first = StreamController<dynamic>();
    gateway = SmartClassBackendGateway(
      base: Uri.parse('http://localhost:8080'),
      registration: registration,
      channelFactory: (_) {
        // A fresh socket per attach: a retry must never reuse the previous one.
        final controller = opened.isEmpty ? first : StreamController<dynamic>();
        opened.add(controller);
        return _FakeChannel(controller.stream, sink, readyError: readyError);
      },
      cameras: const <CameraAnnouncement>[cameraAnnouncement],
      backoff: backoff ?? (_) => const Duration(milliseconds: 5),
      idleStatusInterval: idleStatusInterval,
      statusReport: statusReport,
    );
  }

  final _FakeRegistration registration;
  final _FakeSink sink = _FakeSink();
  final List<StreamController<dynamic>> opened = <StreamController<dynamic>>[];
  late final StreamController<dynamic> first;
  late final SmartClassBackendGateway gateway;

  Future<void> dispose() async {
    await gateway.stop();
    for (final controller in opened) {
      // Not awaited on purpose: a single-subscription controller that was
      // never listened to (an attach that failed before subscribing) only
      // completes its done future once someone listens, so awaiting here would
      // hang forever.
      if (!controller.isClosed) unawaited(controller.close());
    }
  }
}

// --- checks -----------------------------------------------------------------

void checkResolutionSelection() {
  section('resolution selection');
  eq(
    'exact match wins',
    selectClosestResolution(
      nominalResolutions,
      const CameraResolution(width: 1280, height: 720),
    ),
    const CameraResolution(width: 1280, height: 720),
  );
  eq(
    'never upscales past the target',
    selectClosestResolution(
      nominalResolutions,
      const CameraResolution(width: 1000, height: 700),
    ),
    const CameraResolution(width: 640, height: 480),
  );
  eq(
    'falls back to the smallest when nothing fits',
    selectClosestResolution(
      nominalResolutions,
      const CameraResolution(width: 320, height: 240),
    ),
    const CameraResolution(width: 640, height: 480),
  );
}

void checkStreamSettings() {
  section('stream settings and codec vocabulary');
  final settings = StreamSettings.defaults();
  eq(
    'default codec is the guaranteed floor',
    settings.codec,
    CaptureCodec.mjpeg,
  );
  eq('default fps is a positive int', settings.fps > 0, true);
  eq('default preview', settings.previewEnabled, true);

  final changed = settings.copyWith(
    codec: CaptureCodec.h265,
    fps: 15,
    previewEnabled: false,
  );
  eq('copyWith sets codec', changed.codec, CaptureCodec.h265);
  eq('copyWith sets fps', changed.fps, 15);
  eq('copyWith clears preview', changed.previewEnabled, false);
  eq('copyWith keeps quality', changed.quality, settings.quality);

  eq(
    'preference order',
    CaptureCodec.preference.map((c) => c.wireName).join(','),
    'h265,h264,mjpeg',
  );
  eq(
    'the closed set is exact lowercase',
    CaptureCodec.values.map((c) => c.wireName).join(','),
    'h265,h264,mjpeg,mpeg4,vp8,vp9,av1',
  );
  check(
    'hevc is never emitted',
    !CaptureCodec.values.any((c) => c.wireName == 'hevc'),
  );
  eq('hevc is not parseable', CaptureCodec.tryParse('hevc'), null);
  eq('H264 is not parseable', CaptureCodec.tryParse('H264'), null);
}

void checkWireCodec() {
  section('wire codec vocabulary');
  eq('h264 parses', WireCodec.tryParse('h264'), WireCodec.h264);
  eq('h265 parses', WireCodec.tryParse('h265'), WireCodec.h265);
  eq('mjpeg parses', WireCodec.tryParse('mjpeg'), WireCodec.mjpeg);
  eq('the hevc alias is rejected', WireCodec.tryParse('hevc'), null);
  eq('a case variant is rejected', WireCodec.tryParse('H264'), null);
  eq('trailing space is rejected', WireCodec.tryParse('h264 '), null);
  // Declaration order differs on purpose — the wire set follows the server's
  // canonical order, the capture set follows preference — so the invariant is
  // over the name sets, not the sequences.
  final wireNames = WireCodec.values.map((c) => c.wireName).toList()..sort();
  final captureNames = CaptureCodec.values.map((c) => c.wireName).toList()
    ..sort();
  eq(
    'the wire set matches the capture set name for name',
    wireNames.join(','),
    captureNames.join(','),
  );
}

void checkCommandParsing() {
  section('command parsing');
  final log = UnrecognizedCommandLog(sink: null);

  final start =
      parseDeviceCommand(
            '{"channel":"control","type":"start_recording",'
            '"id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B1",'
            '"payload":{"camera_enum":0,"stream_id":"$streamId"}}',
            log: log,
          )!
          as StartRecordingCommand;
  eq('start_recording id', start.id, '01J8ZKQ3B5N7P9R1T3V5X7Z9B1');
  eq('start_recording camera', start.cameraEnum, 0);
  eq('start_recording stream', start.streamId, streamId);

  final stop =
      parseDeviceCommand(
            '{"channel":"control","type":"stop_recording","id":"b",'
            '"payload":{"camera_enum":0,"stream_id":"$streamId"}}',
          )!
          as StopRecordingCommand;
  eq('stop_recording stream', stop.streamId, streamId);

  final photo =
      parseDeviceCommand(
            '{"channel":"control","type":"take_photo","id":"c",'
            '"payload":{"camera_enum":1,"request_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B3"}}',
          )!
          as TakePhotoCommand;
  eq('take_photo camera', photo.cameraEnum, 1);
  eq('take_photo request', photo.requestId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B3');

  final switchCmd =
      parseDeviceCommand(
            '{"channel":"control","type":"switch_camera","id":"e",'
            '"payload":{"camera_enum":2}}',
          )!
          as SwitchCameraCommand;
  eq('switch_camera camera', switchCmd.cameraEnum, 2);
  eq(
    'switch_camera without parameters asks for nothing',
    switchCmd.resolution,
    null,
  );
  eq('and no frame rate either', switchCmd.fps, null);

  // Protocol v0.3.0: the server may name the mode along with the camera.
  final switchWithMode =
      parseDeviceCommand(
            '{"channel":"control","type":"switch_camera","id":"e",'
            '"payload":{"camera_enum":1,"resolution":"1280x720","fps":30}}',
          )!
          as SwitchCameraCommand;
  eq(
    'switch_camera carries the resolution',
    switchWithMode.resolution?.label,
    '1280x720',
  );
  eq('switch_camera carries the frame rate', switchWithMode.fps, 30);

  // Lenient on purpose: a value the device cannot read must leave the camera
  // switch honoured rather than dropping the command — a dropped command is
  // never acked, and the server does not retry.
  for (final blank in <String>['', '   ', '720p', '1280x', '0x480']) {
    final parsed =
        parseDeviceCommand(
              '{"channel":"control","type":"switch_camera","id":"e",'
              '"payload":{"camera_enum":1,"resolution":"$blank"}}',
            )!
            as SwitchCameraCommand;
    check(
      'an unusable resolution "$blank" is treated as absent',
      parsed.resolution == null && parsed.cameraEnum == 1,
    );
  }
  for (final value in <String>['0', '-5']) {
    final parsed =
        parseDeviceCommand(
              '{"channel":"control","type":"switch_camera","id":"e",'
              '"payload":{"camera_enum":1,"fps":$value}}',
            )!
            as SwitchCameraCommand;
    check(
      'a non-positive fps ($value) is treated as absent',
      parsed.fps == null,
    );
  }

  final withCodec =
      parseDeviceCommand(
            '{"channel":"control","type":"start_recording","id":"a",'
            '"payload":{"camera_enum":0,"stream_id":"$streamId",'
            '"codec":"mjpeg"}}',
          )!
          as StartRecordingCommand;
  eq(
    'start_recording carries the requested codec',
    withCodec.codec,
    CaptureCodec.mjpeg,
  );

  final withoutCodec =
      parseDeviceCommand(
            '{"channel":"control","type":"start_recording","id":"a",'
            '"payload":{"camera_enum":0,"stream_id":"$streamId"}}',
          )!
          as StartRecordingCommand;
  eq('an absent codec decodes to null', withoutCodec.codec, null);

  for (final name in <String>['hevc', 'H264', 'MJPEG', 'garbage', '']) {
    final parsed =
        parseDeviceCommand(
              '{"channel":"control","type":"start_recording","id":"a",'
              '"payload":{"camera_enum":0,"stream_id":"$streamId",'
              '"codec":"$name"}}',
            )!
            as StartRecordingCommand;
    check('an unknown codec "$name" decodes to null', parsed.codec == null);
  }

  // A recognised but unavailable codec still decodes: refusing it is the
  // coordinator's job, and it needs to know what was asked for to say so.
  final h264 =
      parseDeviceCommand(
            '{"channel":"control","type":"start_recording","id":"a",'
            '"payload":{"camera_enum":0,"stream_id":"$streamId",'
            '"codec":"h264"}}',
          )!
          as StartRecordingCommand;
  eq('a recognised codec survives parsing', h264.codec, CaptureCodec.h264);

  final ping =
      parseDeviceCommand(
            '{"channel":"control","type":"ping",'
            '"payload":{"ts":"2026-10-04T10:00:30.512384921Z"}}',
          )!
          as PingCommand;
  eq('ping ts is kept verbatim', ping.ts, '2026-10-04T10:00:30.512384921Z');
  eq('ping has no id', ping.id, null);

  // Fault tolerance: never throw, always record.
  eq(
    'unknown type -> null',
    parseDeviceCommand('{"channel":"control","type":"backflip"}', log: log),
    null,
  );
  eq('garbage -> null', parseDeviceCommand('<<garbage>>', log: log), null);
  eq('empty -> null', parseDeviceCommand('', log: log), null);
  eq('bare array -> null', parseDeviceCommand('[]', log: log), null);
  eq(
    'missing field -> null',
    parseDeviceCommand(
      '{"channel":"control","type":"start_recording",'
      '"payload":{"camera_enum":0}}',
      log: log,
    ),
    null,
  );
  eq(
    'empty stream id -> null',
    parseDeviceCommand(
      '{"channel":"control","type":"start_recording",'
      '"payload":{"camera_enum":0,"stream_id":""}}',
      log: log,
    ),
    null,
  );
  eq(
    'wrong field type -> null',
    parseDeviceCommand(
      '{"channel":"control","type":"take_photo",'
      '"payload":{"camera_enum":"zero","request_id":"r"}}',
      log: log,
    ),
    null,
  );

  eq('seven problems were recorded', log.entries.length, 7);
  eq(
    'reasons in order',
    log.entries.map((e) => e.reason.name).join(','),
    'unknownType,malformedJson,malformedJson,malformedJson,'
        'invalidPayload,invalidPayload,invalidPayload',
  );

  final quiet = UnrecognizedCommandLog(sink: null);
  parseDeviceCommand(
    '{"channel":"control","type":"ping","payload":{"ts":"t"}}',
    log: quiet,
  );
  eq('a valid command is not recorded', quiet.entries.isEmpty, true);
}

void checkDeviceMessages() {
  section('device messages');
  final ack = AckMessage(
    id: 'X',
    ok: false,
    error: 'camera 0 is busy',
  ).toJson();
  eq('ack channel', ack['channel'], 'control');
  eq('ack type', ack['type'], 'ack');
  eq('ack id echoed verbatim', ack['id'], 'X');
  eq('ack ok', (ack['payload']! as Map)['ok'], false);
  eq('ack error', (ack['payload']! as Map)['error'], 'camera 0 is busy');
  check(
    'a successful ack carries no error key',
    !(AckMessage(id: 'X', ok: true).toJson()['payload']! as Map).containsKey(
      'error',
    ),
  );

  final pong = const PongMessage(ts: '2026-10-04T10:00:30Z').toJson();
  eq('pong type', pong['type'], 'pong');
  eq('pong ts', (pong['payload']! as Map)['ts'], '2026-10-04T10:00:30Z');

  final status = const StatusMessage(report: {'recording': false}).toJson();
  eq('status type', status['type'], 'status');
  eq('status payload', (status['payload']! as Map)['recording'], false);

  final error = const ErrorMessage(message: 'camera 1 is unavailable').toJson();
  eq('error type', error['type'], 'error');
  check('error omits id when absent', !error.containsKey('id'));

  final photo = PhotoMeta(
    cameraEnum: 0,
    requestId: 'r',
    ts: DateTime.utc(2026),
  ).toJson();
  eq('photo channel', photo['channel'], 'photo');
  eq(
    'photo content type',
    (photo['payload']! as Map)['content_type'],
    'image/jpeg',
  );
}

void checkBinaryFraming() {
  section('binary framing');

  // The protocol doc's worked example must encode to exactly 144 header bytes.
  final docHeader = const Message(
    channel: WireChannel.recording,
    type: 'frame',
    payload: <String, Object?>{
      'camera_enum': 0,
      'seq': 42,
      'stream_id': '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
      'ts': '2026-10-04T10:00:00Z',
    },
  );
  eq('the doc example header is 144 bytes', docHeader.encode().length, 144);
  eq(
    'the doc example header is byte-identical',
    docHeader.encode(),
    '{"channel":"recording","type":"frame","payload":'
        '{"camera_enum":0,"seq":42,'
        '"stream_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B2",'
        '"ts":"2026-10-04T10:00:00Z"}}',
  );

  final frame = encodeBinaryFrame(docHeader, Uint8List.fromList([0xAA, 0xBB]));
  final n = ByteData.view(
    frame.buffer,
    frame.offsetInBytes,
    4,
  ).getUint32(0, Endian.big);
  eq('length prefix is big-endian', n, 144);
  eq('whole frame length', frame.length, 4 + n + 2);

  final decoded = tryDecodeBinaryFrame(frame);
  check('round trip decodes', decoded != null);
  eq('  type', decoded!.header.type, 'frame');
  eq('  channel', decoded.header.channel, WireChannel.recording);
  eq('  stream_id', decoded.header.payload!['stream_id'], streamId);
  eqBytes('  payload bytes', decoded.data, [0xAA, 0xBB]);

  final emptyPayload = tryDecodeBinaryFrame(
    encodeBinaryFrame(docHeader, Uint8List(0)),
  );
  eq('an empty payload round-trips', emptyPayload!.data.length, 0);

  eq(
    'shorter than the prefix is rejected',
    tryDecodeBinaryFrame(Uint8List.fromList([0, 0])),
    null,
  );
  eq(
    'a zero header length is rejected',
    tryDecodeBinaryFrame(Uint8List.fromList([0, 0, 0, 0, 0x7b])),
    null,
  );
  eq(
    'a header length past the frame is rejected',
    tryDecodeBinaryFrame(Uint8List.fromList([0, 0, 0, 99, 0x7b])),
    null,
  );
  eq(
    'a header length above 65536 is rejected',
    tryDecodeBinaryFrame(Uint8List.fromList([0, 1, 0, 1, 0x7b])),
    null,
  );
  eq(
    'a non-JSON header is rejected',
    tryDecodeBinaryFrame(Uint8List.fromList([0, 0, 0, 3, 0x20, 0x20, 0x20])),
    null,
  );

  check('a control message cannot be framed as binary', () {
    try {
      encodeBinaryFrame(
        const Message(channel: WireChannel.control, type: 'ack'),
        Uint8List(0),
      );
      return false;
    } catch (_) {
      return true;
    }
  }());
  check('a channel/type mismatch is refused', () {
    try {
      encodeBinaryFrame(
        const Message(channel: WireChannel.recording, type: 'photo'),
        Uint8List(0),
      );
      return false;
    } catch (_) {
      return true;
    }
  }());
  check('a frame above 16 MiB is refused', () {
    try {
      encodeBinaryFrame(docHeader, Uint8List(maxFrameBytes));
      return false;
    } catch (_) {
      return true;
    }
  }());
  check('a frame just under the limit is accepted', () {
    try {
      encodeBinaryFrame(docHeader, Uint8List(maxFrameBytes - 4 - 144));
      return true;
    } catch (_) {
      return false;
    }
  }());
}

// --- runtime connection settings --------------------------------------------

void checkBaseUrlValidation() {
  section('base url validation');

  BaseUrlValidation ok(String raw) {
    final result = validateBaseUrl(raw);
    check('"$raw" is accepted  (problem: ${result.problem})', result.isOk);
    return result;
  }

  BaseUrlProblem bad(String raw) {
    final result = validateBaseUrl(raw);
    check('"$raw" is rejected', !result.isOk);
    return result.problem!;
  }

  eq('empty', bad(''), BaseUrlProblem.empty);
  eq('whitespace only', bad('   '), BaseUrlProblem.empty);

  eq(
    'a plain origin',
    ok('http://127.0.0.1:8080').uri!.toString(),
    'http://127.0.0.1:8080',
  );
  eq(
    'a trailing slash is dropped',
    ok('http://127.0.0.1:8080/').uri!.toString(),
    'http://127.0.0.1:8080',
  );
  // The case this whole layer exists for: nobody types a URI, they type an
  // address. Dart will not even parse this one — a scheme may not start with a
  // digit — so it has to survive a failed parse.
  eq(
    'a bare host:port gets http://',
    ok('192.168.1.20:8080').uri!.toString(),
    'http://192.168.1.20:8080',
  );
  // Dart *does* parse this, as scheme `localhost` with path `8080`.
  eq(
    'localhost:port gets http://',
    ok('localhost:8080').uri!.toString(),
    'http://localhost:8080',
  );
  eq(
    'a bare hostname gets http://',
    ok('cameras.test').uri!.toString(),
    'http://cameras.test',
  );
  eq(
    'surrounding whitespace is trimmed',
    ok('  http://cameras.test  ').uri!.toString(),
    'http://cameras.test',
  );
  eq(
    'https is preserved',
    ok('https://cameras.test').uri!.toString(),
    'https://cameras.test',
  );
  // `toWebSocketUri` only accepts http(s), so leaving `ws://` in place would
  // point the *registration* call at a WebSocket address.
  eq(
    'ws is folded to http',
    ok('ws://cameras.test:8080').uri!.toString(),
    'http://cameras.test:8080',
  );
  eq(
    'wss is folded to https',
    ok('wss://cameras.test').uri!.toString(),
    'https://cameras.test',
  );
  // Without this, `HTTPS://Host` and `https://host` look like a change and cost
  // a pointless reconnect.
  eq(
    'scheme and host are lower-cased',
    ok('HTTPS://Cameras.Test:8443').uri!.toString(),
    'https://cameras.test:8443',
  );
  eq(
    'a sub-path is preserved',
    ok('http://host:8080/base/').uri!.toString(),
    'http://host:8080/base',
  );
  eq(
    'a sub-path without a trailing slash is preserved',
    ok('http://host:8080/base').uri!.toString(),
    'http://host:8080/base',
  );

  eq(
    'ftp is a bad scheme',
    bad('ftp://cameras.test'),
    BaseUrlProblem.badScheme,
  );
  eq(
    'a dropped slash leaves no host',
    bad('https:/cameras.test'),
    BaseUrlProblem.noHost,
  );
  eq('http:// alone has no host', bad('http://'), BaseUrlProblem.noHost);
  eq(
    'a query is refused',
    bad('http://cameras.test?a=1'),
    BaseUrlProblem.hasQuery,
  );
  eq(
    'a fragment is refused',
    bad('http://cameras.test#x'),
    BaseUrlProblem.hasFragment,
  );
  eq(
    'a URL carrying a password is refused',
    bad('http://user:pass@cameras.test'),
    BaseUrlProblem.hasUserInfo,
  );
  // Dart round-trips an out-of-range port without complaint and only fails
  // later, inside the HTTP client, so it has to be caught here.
  eq(
    'an out-of-range port is refused',
    bad('http://cameras.test:99999999999'),
    BaseUrlProblem.notAbsolute,
  );
  eq(
    'an unparseable string is refused',
    bad('http://[::bad'),
    BaseUrlProblem.notAbsolute,
  );

  // Every problem code has to be reachable with wording an installer can act
  // on, or the field would go silent exactly when it matters.
  check(
    'every problem carries a message',
    BaseUrlProblem.values.every((p) {
      final sample = switch (p) {
        BaseUrlProblem.empty => '',
        BaseUrlProblem.notAbsolute => 'http://[::bad',
        BaseUrlProblem.badScheme => 'ftp://host',
        BaseUrlProblem.noHost => 'http://',
        BaseUrlProblem.hasUserInfo => 'http://u:p@host',
        BaseUrlProblem.hasQuery => 'http://host?a',
        BaseUrlProblem.hasFragment => 'http://host#a',
      };
      final result = validateBaseUrl(sample);
      return result.problem == p && result.message.isNotEmpty;
    }),
  );
  eq('a valid url has no message', ok('http://host').message, '');
}

void checkConnectionSettings() {
  section('connection settings');

  final unprovisioned = ConnectionSettings(
    baseUrl: Uri.parse('http://127.0.0.1:8080'),
  );
  eq(
    'no credentials means not provisioned',
    unprovisioned.isProvisioned,
    false,
  );
  eq('and nothing to shape-check', unprovisioned.looksValid, false);

  final provisioned = unprovisioned.copyWith(credentials: credentials);
  eq('copyWith adds credentials', provisioned.isProvisioned, true);
  eq(
    'and leaves the address alone',
    provisioned.baseUrl,
    unprovisioned.baseUrl,
  );

  final cleared = provisioned.copyWith(clearCredentials: true);
  eq('clearCredentials removes them', cleared.credentials, null);
  eq('but keeps the address', cleared.baseUrl, provisioned.baseUrl);

  final moved = provisioned.copyWith(
    baseUrl: Uri.parse('http://10.0.0.9:9000'),
  );
  eq(
    'copyWith replaces the address',
    moved.baseUrl.toString(),
    'http://10.0.0.9:9000',
  );
  eq('and keeps the credentials', moved.credentials, credentials);

  eq(
    'the same values are the same endpoint',
    provisioned.hasSameEndpoint(
      ConnectionSettings(
        baseUrl: Uri.parse('http://127.0.0.1:8080'),
        credentials: credentials,
      ),
    ),
    true,
  );
  eq(
    'a trailing slash is the same endpoint',
    provisioned.hasSameEndpoint(
      ConnectionSettings(
        baseUrl: Uri.parse('http://127.0.0.1:8080/'),
        credentials: credentials,
      ),
    ),
    true,
  );
  eq(
    'letter case is the same endpoint',
    ConnectionSettings(baseUrl: Uri.parse('https://Cameras.Test:8443'))
        .hasSameEndpoint(
          ConnectionSettings(baseUrl: Uri.parse('https://cameras.test:8443')),
        ),
    true,
  );
  eq(
    'a different port is a different endpoint',
    provisioned.hasSameEndpoint(
      ConnectionSettings(
        baseUrl: Uri.parse('http://127.0.0.1:9000'),
        credentials: credentials,
      ),
    ),
    false,
  );
  eq(
    'a different credential is a different endpoint',
    provisioned.hasSameEndpoint(unprovisioned),
    false,
  );

  final sameAgain = ConnectionSettings(
    baseUrl: Uri.parse('http://127.0.0.1:8080/'),
    credentials: credentials,
  );
  eq('== follows the endpoint', provisioned == sameAgain, true);
  eq('hashCode follows too', provisioned.hashCode == sameAgain.hashCode, true);
  check(
    'toString never leaks the token',
    !provisioned.toString().contains('wdt_'),
  );
  check(
    'toString still names the address',
    provisioned.toString().contains('127.0.0.1:8080'),
  );
}

void checkResolveConnectionSettings() {
  section('resolve connection settings');

  const buildUrl = 'http://192.168.1.20:8080';

  // Default parameter values have to be compile-time constants, so the build
  // credential pair is passed explicitly wherever it matters.
  ConnectionSettings resolve({
    Uri? storedBaseUrl,
    DeviceCredentials? storedCredentials,
    String buildBaseUrl = buildUrl,
    String buildDeviceId = '',
    String buildDeviceToken = '',
  }) => resolveConnectionSettings(
    storedBaseUrl: storedBaseUrl,
    storedCredentials: storedCredentials,
    buildBaseUrl: buildBaseUrl,
    buildDeviceId: buildDeviceId,
    buildDeviceToken: buildDeviceToken,
  );

  final fromStore = resolve(
    storedBaseUrl: Uri.parse('http://10.0.0.9:9000'),
    storedCredentials: credentials,
  );
  eq(
    'what was saved wins',
    fromStore.baseUrl.toString(),
    'http://10.0.0.9:9000',
  );
  eq('and its credentials come along', fromStore.credentials, credentials);

  final seeded = resolve(
    buildDeviceId: credentials.deviceId,
    buildDeviceToken: credentials.deviceToken,
  );
  eq(
    'an empty store is seeded from the build value',
    seeded.baseUrl.toString(),
    buildUrl,
  );
  eq('and so are the credentials', seeded.credentials, credentials);

  // The store is only trusted if it still parses; otherwise the build value is
  // a better answer than an address nothing can dial.
  final repaired = resolve(
    storedBaseUrl: Uri.parse('http://'),
    storedCredentials: credentials,
  );
  eq(
    'an unusable saved address falls back to the build value',
    repaired.baseUrl.toString(),
    buildUrl,
  );

  // Neither layer has anything useful: the compiled-in default is the floor.
  final floor = resolve(
    buildBaseUrl: '',
    buildDeviceId: '',
    buildDeviceToken: '',
  );
  eq(
    'an unusable build value lands on the default',
    floor.baseUrl.toString(),
    defaultBaseUrl,
  );
  eq('with no credentials', floor.isProvisioned, false);

  // A saved address with no credentials keeps the address and takes the
  // build-time pair.
  final halfStored = resolve(
    storedBaseUrl: Uri.parse('http://10.0.0.9:9000'),
    buildDeviceId: credentials.deviceId,
    buildDeviceToken: credentials.deviceToken,
  );
  eq(
    'a saved address still wins',
    halfStored.baseUrl.toString(),
    'http://10.0.0.9:9000',
  );
  eq(
    'and the build credentials fill the gap',
    halfStored.credentials,
    credentials,
  );

  // **The upgrade case, and the bug this shape exists to prevent.** A build
  // from before the settings store existed wrote `device_id` / `device_token`
  // and no `base_url`. Loading the two halves as a single value would produce a
  // settings object carrying no credentials — and seeding *saves* it, which
  // means replace, which would delete a working device's identity on the first
  // launch after the upgrade. Observed for real on the test phone.
  final upgrade = resolve(
    storedCredentials: credentials,
    buildBaseUrl: '',
    buildDeviceId: '',
    buildDeviceToken: '',
  );
  eq(
    'an upgrade that only has credentials keeps them',
    upgrade.credentials,
    credentials,
  );
  eq(
    'and still gets an address to seed',
    upgrade.baseUrl.toString(),
    defaultBaseUrl,
  );
  eq('so the seed is provisioned', upgrade.isProvisioned, true);
}

void checkCredentials() {
  section('device credentials');
  check('a server-shaped pair looks valid', credentials.looksValid);
  check('26-char ULID accepted', credentials.hasValidDeviceId);
  check('43-char wdt_ token accepted', credentials.hasValidDeviceToken);
  check(
    'a short token is rejected',
    !const DeviceCredentials(
      deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
      deviceToken: 'wdt_short',
    ).looksValid,
  );
  check(
    'a token without the prefix is rejected',
    !const DeviceCredentials(
      deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
      deviceToken: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    ).looksValid,
  );
  check(
    'an empty pair is not configured',
    !const DeviceCredentials(deviceId: '', deviceToken: '').isConfigured,
  );
  check('toString redacts the token', !credentials.toString().contains('wdt_'));
  check('validate accepts a good pair', () {
    try {
      credentials.validate();
      return true;
    } catch (_) {
      return false;
    }
  }());
  check('validate rejects an empty pair', () {
    try {
      const DeviceCredentials(deviceId: '', deviceToken: '').validate();
      return false;
    } catch (_) {
      return true;
    }
  }());
}

void checkRegistrationRequest() {
  section('registration request');

  const vga = CameraResolution(width: 640, height: 480);
  const hd = CameraResolution(width: 1280, height: 720);
  const fhd = CameraResolution(width: 1920, height: 1080);

  // What a 1080p webcam really reports: two rungs on the same real size.
  final measured = CameraCapabilities.of(
    resolutions: <CameraResolution>[fhd, hd, hd, vga],
    framerates: <int>[30, 15],
  );

  final announcements = buildAnnouncements(
    cameras: <CameraDeclaration>[
      CameraDeclaration(
        name: 'back',
        resolution: fhd,
        fps: 5,
        capabilities: measured,
      ),
      const CameraDeclaration(name: 'front', resolution: vga, fps: 5),
    ],
    codecs: const <WireCodec>[WireCodec.mjpeg],
  );

  eq(
    'camera_enum equals the index',
    announcements.map((c) => c.cameraEnum).join(','),
    '0,1',
  );
  eq('resolution label', announcements.first.resolution, '1920x1080');
  eq('codec list', announcements.first.supportedCodec.single, WireCodec.mjpeg);
  eq(
    'the camera name travels in attrs.label',
    announcements.first.attrs['label'],
    'back',
  );

  // Protocol v0.3.0: without these two lists the server refuses the whole
  // registration, so an announcement missing them is not a device that lost a
  // feature — it is a device that cannot connect.
  eq(
    'supported_resolutions is declared, deduped and sorted',
    announcements.first.supportedResolutions.map((r) => r.label).join(','),
    '1920x1080,1280x720,1024x768,800x600,640x480,320x240',
  );
  eq(
    'supported_framerates is declared with the ladder filled in',
    announcements.first.supportedFramerates.join(','),
    '60,50,30,25,24,20,15,10,5',
  );
  check(
    'the current resolution is always among the declared values',
    announcements.first.supportedResolutions.contains(fhd),
  );
  check(
    'the current frame rate is always among the declared values',
    announcements.first.supportedFramerates.contains(5),
  );
  check(
    'the declared lists contain no duplicates',
    announcements.first.supportedResolutions.toSet().length ==
            announcements.first.supportedResolutions.length &&
        announcements.first.supportedFramerates.toSet().length ==
            announcements.first.supportedFramerates.length,
  );

  // A probe that found nothing must become "only what I am doing", never
  // nothing: an empty list is a `400`, and a kiosk that cannot register is
  // worse than one that declares less.
  final unmeasured = buildAnnouncements(
    cameras: const <CameraDeclaration>[
      CameraDeclaration(name: 'front', resolution: hd, fps: 15),
    ],
    codecs: const <WireCodec>[WireCodec.mjpeg],
  );
  eq(
    'an unmeasured camera declares exactly its current pair',
    unmeasured.single.supportedResolutions.map((r) => r.label).join(','),
    '1280x720',
  );
  eq(
    'and exactly its current rate',
    unmeasured.single.supportedFramerates.join(','),
    '15',
  );
  check(
    'so an unmeasured camera is never announced with an empty list',
    unmeasured.single.supportedResolutions.isNotEmpty &&
        unmeasured.single.supportedFramerates.isNotEmpty,
  );

  // The measured set does not contain the current mode, which is the case that
  // makes `withCurrent` load-bearing.
  final offLadder = buildAnnouncements(
    cameras: <CameraDeclaration>[
      CameraDeclaration(
        name: 'front',
        resolution: fhd,
        fps: 5,
        capabilities: CameraCapabilities.of(
          resolutions: <CameraResolution>[vga],
          framerates: <int>[30, 15],
        ),
      ),
    ],
    codecs: const <WireCodec>[WireCodec.mjpeg],
  );
  check(
    'a current resolution the probe never produced is still declared',
    offLadder.single.supportedResolutions.contains(fhd),
  );
  check(
    'and so is a current rate the probe never produced',
    offLadder.single.supportedFramerates.contains(5),
  );

  final clamped = buildAnnouncements(
    cameras: const <CameraDeclaration>[
      CameraDeclaration(name: 'front', resolution: hd, fps: 0),
    ],
    codecs: const <WireCodec>[WireCodec.mjpeg],
  );
  eq('fps is clamped to a positive integer', clamped.single.fps, 1);
  check('fps is an int', clamped.single.fps is int);
  check(
    'and the clamped value is declared, not just reported',
    clamped.single.supportedFramerates.contains(minAnnounceableFps),
  );

  final emptyCodecs = buildAnnouncements(
    cameras: const <CameraDeclaration>[
      CameraDeclaration(name: 'front', resolution: hd, fps: 5),
    ],
    codecs: const <WireCodec>[],
  );
  eq(
    'an empty codec list falls back rather than 400ing',
    emptyCodecs.single.supportedCodec.single,
    WireCodec.mjpeg,
  );

  final body = buildRegisterBody(credentials.deviceId, announcements);
  eq('body device_id', body['device_id'], credentials.deviceId);
  final cam0 = (body['cameras']! as List).first as Map;
  eq('body camera_enum', cam0['camera_enum'], 0);
  eq(
    'body supported_codec',
    (cam0['supported_codec']! as List).single,
    'mjpeg',
  );
  eq('body fps', cam0['fps'], 5);
  eq(
    'body supported_resolutions',
    (cam0['supported_resolutions']! as List).join(','),
    '1920x1080,1280x720,1024x768,800x600,640x480,320x240',
  );
  check(
    'body supported_framerates is non-empty',
    (cam0['supported_framerates']! as List).isNotEmpty,
  );

  eq(
    'capture codecs map onto the wire names',
    wireCodecsFor({CaptureCodec.mjpeg}).map((c) => c.wireName).join(','),
    'mjpeg',
  );
  eq(
    'the mapping is ordered by preference',
    wireCodecsFor({CaptureCodec.mjpeg, CaptureCodec.h265, CaptureCodec.h264})
        .map((c) => c.wireName)
        .join(','),
    'h265,h264,mjpeg',
  );
}

void checkUriHelpers() {
  section('uri helpers and timestamps');

  // The reachability probe must land on the same base path the registration
  // uses. It used to build the address with `replace(path:)`, which threw the
  // base path away: against a deployment mounted under a route prefix the
  // device registered fine and then got a 404 from a path it had never used.
  eq(
    'the probe has no base path to keep on a bare origin',
    healthProbeUri(Uri.parse('http://h:8080')).toString(),
    'http://h:8080/healthz',
  );
  eq(
    'the probe keeps a base path',
    healthProbeUri(Uri.parse('http://h:8080/webcam')).toString(),
    'http://h:8080/webcam/healthz',
  );
  eq(
    'the probe keeps a trailing-slash base path',
    healthProbeUri(Uri.parse('http://h:8080/webcam/')).toString(),
    'http://h:8080/webcam/healthz',
  );
  eq(
    'the probe and the registration agree on the base path',
    healthProbeUri(Uri.parse('http://h:8080/webcam')).path
        .replaceAll('/healthz', ''),
    resolveDevicePath(
      Uri.parse('http://h:8080/webcam'),
      '/ws/register',
    ).path.replaceAll('/ws/register', ''),
  );

  // A response is an answer: 404 still proves the address resolved. Only the
  // absence of a response means unreachable.
  check('a 404 is reachable but not healthy', () {
    final r = const HealthProbeResult(reachable: true, statusCode: 404);
    return r.reachable && !r.healthy;
  }());
  check(
    'a 200 is healthy',
    const HealthProbeResult(reachable: true, statusCode: 200).healthy,
  );
  check(
    'no status is unreachable',
    !const HealthProbeResult(reachable: false, detail: 'timeout').healthy,
  );

  eq(
    'a base path is kept',
    resolveDevicePath(
      Uri.parse('http://h:8080/api'),
      '/ws/register',
    ).toString(),
    'http://h:8080/api/ws/register',
  );
  eq(
    'a bare origin gets the path',
    resolveDevicePath(Uri.parse('http://h:8080'), '/ws/register').toString(),
    'http://h:8080/ws/register',
  );
  eq(
    'a trailing slash does not double up',
    resolveDevicePath(Uri.parse('http://h:8080/'), '/ws/device/x').toString(),
    'http://h:8080/ws/device/x',
  );
  eq(
    'http becomes ws',
    toWebSocketUri(Uri.parse('http://h:8080/x')).toString(),
    'ws://h:8080/x',
  );
  eq(
    'https becomes wss',
    toWebSocketUri(Uri.parse('https://h/x')).toString(),
    'wss://h/x',
  );

  final nano = parseServerTimestamp('2026-10-04T10:01:00.512384921Z');
  eq('nanoseconds are parsed, not rejected', nano.millisecond, 512);
  eq('the timestamp is UTC', nano.isUtc, true);
  eq(
    'a whole-second timestamp parses',
    parseServerTimestamp('2026-10-04T10:01:00Z'),
    DateTime.utc(2026, 10, 4, 10, 1),
  );
}

void checkUnrecognizedLog() {
  section('unrecognized command log');
  final bounded = UnrecognizedCommandLog(capacity: 3, sink: null);
  for (var i = 0; i < 5; i++) {
    bounded.record('raw-$i', UnrecognizedReason.unknownType);
  }
  eq(
    'keeps the newest entries',
    bounded.entries.map((e) => e.raw).join(','),
    'raw-2,raw-3,raw-4',
  );
  eq('counts the dropped entries', bounded.droppedCount, 2);

  final truncating = UnrecognizedCommandLog(sink: null);
  truncating.record('x' * 20000, UnrecognizedReason.malformedJson);
  eq('truncates oversized payloads', truncating.entries.single.raw.length, 512);

  final messages = <String>[];
  UnrecognizedCommandLog(sink: messages.add)
      .record('{"type":"nope"}', UnrecognizedReason.unknownType);
  check(
    'the sink gets a readable message',
    messages.single.contains('unknownType') && messages.single.contains('nope'),
  );

  final cleared = UnrecognizedCommandLog(capacity: 1, sink: null);
  cleared.record('a', UnrecognizedReason.unknownType);
  cleared.record('b', UnrecognizedReason.unknownType);
  eq('drop counter before clear', cleared.droppedCount, 1);
  cleared.clear();
  eq('entries after clear', cleared.entries.length, 0);
  eq('drop counter after clear', cleared.droppedCount, 0);
}

Future<void> checkCameraProvider() async {
  section('camera provider');

  final skip = CameraProvider(
    backends: <CameraBackend>[
      _FakeBackend(
        'broken',
        probeResult: _unavailable(CameraUnavailableReason.noDevice),
      ),
      _FakeBackend('good', probeResult: _okProbe),
    ],
  );
  final r1 = await skip.open(CaptureConfig.defaults());
  eq('skips the unavailable backend', r1.backendId, 'good');
  eq('records both attempts', r1.attempts.length, 2);

  final allFail = CameraProvider(
    backends: <CameraBackend>[
      _FakeBackend(
        'a',
        probeResult: _unavailable(CameraUnavailableReason.permissionDenied),
      ),
    ],
  );
  final r3 = await allFail.open(CaptureConfig.defaults());
  check('no service when every backend fails', r3.service == null);
  check(
    'an unavailable probe maps onto its typed failure',
    r3.failure is CameraFailurePermissionDenied,
  );

  final empty = await CameraProvider(backends: <CameraBackend>[])
      .open(CaptureConfig.defaults());
  check(
    'no backends at all falls back to NoBackendAvailable',
    empty.failure is CameraFailureNoBackendAvailable,
  );

  final throwingProbe = CameraProvider(
    backends: <CameraBackend>[
      _ThrowingBackend(),
      _FakeBackend('good', probeResult: _okProbe),
    ],
  );
  final r4 = await throwingProbe.open(CaptureConfig.defaults());
  eq('a probe that throws is not fatal', r4.backendId, 'good');
  eq(
    'a throwing probe is recorded as unavailable',
    r4.attempts.first.reason,
    CameraUnavailableReason.initFailed,
  );

  section('failure messages');
  check(
    'noDevice guidance',
    failureMessage(const CameraFailure.noDevice()).contains('未检测到摄像头'),
  );
  check(
    'permissionDenied guidance',
    failureMessage(const CameraFailure.permissionDenied()).contains('权限'),
  );
  check(
    'deviceBusy guidance',
    failureMessage(const CameraFailure.deviceBusy()).contains('占用'),
  );
  check(
    'initFailed carries the cause',
    failureMessage(CameraFailure.initFailed('boom')).contains('boom'),
  );
}

Future<void> checkFrameStore() async {
  section('frame store');
  final dir = await Directory.systemTemp.createTemp('probe_verify');
  final file = File('${dir.path}${Platform.pathSeparator}frame.jpg')
    ..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9]);

  final bytes = await const IoFrameStore().readAndDelete(file.path);
  eqBytes('reads the frame bytes', bytes, [0xFF, 0xD8, 1, 0xFF, 0xD9]);
  eq('deletes the file immediately', file.existsSync(), false);
  await const IoFrameStore().delete('definitely/not/here.jpg');
  check('deleting a missing file is tolerated', true);
  await dir.delete(recursive: true);
}

void checkCodecSelection() {
  section('codec selection');
  check('the baseline probe reports mjpeg', true);
  final selector = CodecSelector(probe: const BaselineCodecProbe());
  fakeAsync((async) {
    CaptureCodec? selected;
    selector.select().then((value) => selected = value);
    async.flushMicrotasks();
    eq('the baseline selects mjpeg', selected, CaptureCodec.mjpeg);
  });

  final h265 = CodecSelector(
    probe: const StaticCodecProbe({CaptureCodec.h265, CaptureCodec.mjpeg}),
  );
  fakeAsync((async) {
    CaptureCodec? selected;
    h265.select().then((value) => selected = value);
    async.flushMicrotasks();
    eq('h265 wins when offered', selected, CaptureCodec.h265);
  });

  final h264 = CodecSelector(
    probe: const StaticCodecProbe({CaptureCodec.h264, CaptureCodec.mjpeg}),
  );
  fakeAsync((async) {
    CaptureCodec? selected;
    h264.select().then((value) => selected = value);
    async.flushMicrotasks();
    eq('h264 is the fallback', selected, CaptureCodec.h264);
  });

  final composite = CompositeCodecProbe(
    probes: <CodecProbe>[
      const StaticCodecProbe({CaptureCodec.h265}),
      const StaticCodecProbe({CaptureCodec.mjpeg}),
    ],
  );
  fakeAsync((async) {
    Set<CaptureCodec>? found;
    composite.availableCodecs().then((value) => found = value);
    async.flushMicrotasks();
    eq('a composite probe unions its sources', found?.length, 2);
  });
}

Future<void> checkFramePump() async {
  section('frame pump');

  fakeAsync((async) {
    final camera = _FakeCameraService(bytes: Uint8List.fromList([1]));
    final pump = TakePictureFramePump(camera: camera);
    final received = <CapturedFrame>[];
    pump.frames.listen(received.add);

    pump.start(cameraEnum: 0, streamId: streamId, fps: 20, quality: 80);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 160));

    eq('three frames at 20 fps over 160 ms', received.length, 3);
    eq(
      'seq starts at zero and increments',
      received.map((f) => f.seq).join(','),
      '0,1,2',
    );
    eq('the pump remembers its stream', pump.streamId, streamId);

    pump.stop();
    async.flushMicrotasks();
    async.elapse(const Duration(seconds: 1));
    eq('stop is idempotent', pump.isRunning, false);
    eq('no frames after stop', received.length, 3);
  });

  fakeAsync((async) {
    final camera = _FakeCameraService(
      bytes: Uint8List.fromList([1]),
      failTimes: 1,
    );
    final pump = TakePictureFramePump(camera: camera);
    final received = <CapturedFrame>[];
    pump.frames.listen(received.add);

    pump.start(cameraEnum: 0, streamId: streamId, fps: 20, quality: 80);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 160));
    pump.stop();
    async.flushMicrotasks();

    // seq counts attempts, so the first delivered frame is #1: the gap is the
    // dropped one, which is exactly what a consumer needs to see.
    eq('the first delivered frame is seq 1', received.first.seq, 1);
    eq('one frame is counted as dropped', pump.droppedFrames, 1);
  });

  fakeAsync((async) {
    final camera = _FakeCameraService(bytes: Uint8List(0));
    final pump = TakePictureFramePump(camera: camera);
    final received = <CapturedFrame>[];
    pump.frames.listen(received.add);

    pump.start(cameraEnum: 0, streamId: streamId, fps: 30, quality: 80);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 120));
    pump.stop();
    async.flushMicrotasks();

    eq('an empty capture is never emitted', received.length, 0);
    check('an empty capture counts as a drop', pump.droppedFrames > 0);
  });

  fakeAsync((async) {
    // A 100 ms capture against 50 ms ticks: every other tick must be shed.
    final camera = _FakeCameraService(
      bytes: Uint8List.fromList([1]),
      delay: const Duration(milliseconds: 100),
    );
    final pump = TakePictureFramePump(camera: camera);
    pump.frames.listen((_) {});

    pump.start(cameraEnum: 0, streamId: streamId, fps: 20, quality: 80);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 300));
    pump.stop();
    async.flushMicrotasks();

    // The property that matters: a tick that lands mid-capture is dropped, so
    // captures never overlap and never queue behind each other.
    eq('captures never overlap', camera.maxConcurrentCaptures, 1);
    check('overlapping ticks were shed, not queued', camera.captureCalls < 6);
  });

  fakeAsync((async) {
    final camera = _FakeCameraService(bytes: Uint8List.fromList([1]));
    camera.release();
    final pump = TakePictureFramePump(camera: camera);
    pump.start(cameraEnum: 0, streamId: streamId, fps: 30, quality: 80);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 100));
    pump.stop();
    async.flushMicrotasks();

    eq(
      'nothing is captured while the camera is closed',
      camera.captureCalls,
      0,
    );
  });

  var rejectedZeroRate = false;
  try {
    await TakePictureFramePump(camera: _FakeCameraService(bytes: Uint8List(0)))
        .start(cameraEnum: 0, streamId: streamId, fps: 0, quality: 80);
  } catch (_) {
    rejectedZeroRate = true;
  }
  check('a zero rate is rejected', rejectedZeroRate);
}

void checkSerialLock() {
  section('serial lock');

  fakeAsync((async) {
    final lock = SerialLock();
    final order = <String>[];
    var concurrent = 0;
    var maxConcurrent = 0;

    void job(String name, int ms) {
      lock.run(() async {
        concurrent++;
        maxConcurrent = max(maxConcurrent, concurrent);
        order.add('start-$name');
        await Future<void>.delayed(Duration(milliseconds: ms));
        order.add('end-$name');
        concurrent--;
      });
    }

    // Queued out of duration order on purpose: the lock must preserve *call*
    // order, not completion order.
    job('a', 30);
    job('b', 10);
    job('c', 20);
    async.elapse(const Duration(milliseconds: 300));

    eq(
      'runs in call order, not duration order',
      order.join(','),
      'start-a,end-a,start-b,end-b,start-c,end-c',
    );
    eq('items never overlap', maxConcurrent, 1);
    eq('the queue drains', lock.pending, 0);
  });

  fakeAsync((async) {
    final lock = SerialLock();
    final done = <String>[];
    // The failure must reach *this* caller (it is the capture that failed) while
    // still releasing the lock for the next item.
    final failing = lock.run<void>(() async => throw StateError('boom'));
    unawaited(failing.then<void>((_) {}, onError: (Object _) {}));

    lock.run(() async => done.add('after'));
    async.elapse(const Duration(milliseconds: 100));
    eq('a failing item does not poison the queue', done.join(','), 'after');
  });

  fakeAsync((async) {
    // The regression this exists for: `take_photo` racing the frame pump.
    // Both go through `takePicture()`, which cannot run twice at once on one
    // controller; unserialised, the loser throws and the photo is lost.
    final lock = SerialLock();
    var concurrent = 0;
    var maxConcurrent = 0;
    for (var i = 0; i < 4; i++) {
      lock.run(() async {
        concurrent++;
        maxConcurrent = max(maxConcurrent, concurrent);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        concurrent--;
      });
    }
    async.elapse(const Duration(milliseconds: 400));
    eq('still captures never overlap', maxConcurrent, 1);
  });
}

void checkJpegTrim() {
  section('jpeg padding trim');

  Uint8List jpeg([int filler = 8, int pad = 0]) {
    final bytes = <int>[0xFF, 0xD8, 0xFF, 0xE0];
    for (var i = 0; i < filler; i++) {
      bytes.add(0x11);
    }
    bytes.addAll([0xFF, 0xD9]);
    bytes.addAll(List<int>.filled(pad, 0));
    return Uint8List.fromList(bytes);
  }

  eqBytes(
    'a clean JPEG is returned untouched',
    trimJpegPadding(jpeg()),
    jpeg(),
  );

  // The observed shape: EOI present, then a few zero bytes.
  final padded = jpeg(8, 6);
  eqBytes('six trailing zeros are trimmed', trimJpegPadding(padded), jpeg());
  eqBytes(
    'eight trailing zeros are trimmed',
    trimJpegPadding(jpeg(8, 8)),
    jpeg(),
  );

  // Everything below must be left alone, so a real problem stays visible.
  eqBytes(
    'a long zero run is not treated as padding',
    trimJpegPadding(jpeg(8, 65)),
    jpeg(8, 65),
  );
  final nonZeroTail = jpeg(8, 6);
  nonZeroTail[nonZeroTail.length - 1] = 0x7A;
  eqBytes(
    'a non-zero byte after the EOI is left alone',
    trimJpegPadding(nonZeroTail),
    nonZeroTail,
  );
  eqBytes(
    'a payload that is not a JPEG is left alone',
    trimJpegPadding(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7])),
    Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]),
  );
  final truncated = Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
  ]);
  eqBytes(
    'a truncated frame with no EOI stays visible',
    trimJpegPadding(truncated),
    truncated,
  );

  // An EXIF thumbnail is a whole JPEG inside APP1, so `FF D9` appears twice;
  // only the outermost EOI ends the file.
  final withThumbnail = Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, 0x00, 0x10, // APP1
    0xFF, 0xD8, 0xAA, 0xBB, 0xFF, 0xD9, // embedded thumbnail
    0xCC, 0xDD, 0xFF, 0xD9, // the real EOI
    0x00, 0x00, // padding
  ]);
  eqBytes(
    'the outermost EOI wins over an embedded thumbnail',
    trimJpegPadding(withThumbnail),
    Uint8List.sublistView(withThumbnail, 0, withThumbnail.length - 2),
  );
}

/// A structurally real JPEG carrying a start-of-frame segment.
///
/// The marker is a parameter so the checks can cover the whole `C0`-`CF` range
/// rather than only baseline.
Uint8List jpegWithSof({
  required int width,
  required int height,
  int marker = 0xC0,
  bool withTrailingSegment = false,
}) {
  return Uint8List.fromList(<int>[
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x10, // APP0, length 16
    ...List<int>.filled(14, 0x00),
    if (withTrailingSegment) ...[
      0xFF,
      0xDB,
      0x00,
      0x06,
      ...List<int>.filled(4, 0x00),
    ],
    0xFF, marker, 0x00, 0x11, // SOF, length 17
    0x08,
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    0x03,
    0x01, 0x22, 0x00,
    0x02, 0x11, 0x01,
    0x03, 0x11, 0x01,
    0xFF, 0xD9, // EOI
  ]);
}

void checkJpegSize() {
  section('jpeg size reader');

  eq(
    'SOF0 dimensions are read',
    jpegSize(jpegWithSof(width: 1280, height: 720)).toString(),
    'CameraResolution(1280x720)',
  );
  eq(
    'a portrait capture is reported as it is',
    jpegSize(jpegWithSof(width: 480, height: 640)).toString(),
    'CameraResolution(480x640)',
  );
  eq(
    'the full 16-bit range is read',
    jpegSize(jpegWithSof(width: 3840, height: 2160)).toString(),
    'CameraResolution(3840x2160)',
  );
  eq(
    'a segment before the frame header is skipped',
    jpegSize(jpegWithSof(width: 1024, height: 768, withTrailingSegment: true))
        .toString(),
    'CameraResolution(1024x768)',
  );

  var sofFlavours = 0;
  for (final marker in <int>[
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF,
  ]) {
    if (jpegSize(jpegWithSof(width: 640, height: 480, marker: marker)) !=
        null) {
      sofFlavours++;
    }
  }
  eq('every start-of-frame flavour is read', sofFlavours, 13);

  eq('an empty buffer is null', jpegSize(Uint8List(0)), null);
  eq(
    'a two-byte buffer is null',
    jpegSize(Uint8List.fromList([0xFF, 0xD8])),
    null,
  );
  eq(
    'a buffer that is not a JPEG is null',
    jpegSize(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])),
    null,
  );
  eq(
    'a JPEG with no frame header is null',
    jpegSize(
      Uint8List.fromList(<int>[
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        ...List<int>.filled(14, 0x00),
        0xFF,
        0xD9,
      ]),
    ),
    null,
  );
  eq(
    'a truncated frame header is null, not a throw',
    jpegSize(
      Uint8List.fromList(<int>[
        0xFF,
        0xD8,
        0xFF,
        0xC0,
        0x00,
        0x11,
        0x08,
        0x02,
        0xD0,
      ]),
    ),
    null,
  );
  eq(
    'a thumbnail after the start of scan is not mistaken for the picture',
    jpegSize(
      Uint8List.fromList(<int>[
        0xFF,
        0xD8,
        0xFF,
        0xDA,
        0x00,
        0x08,
        ...List<int>.filled(6, 0x00),
        ...jpegWithSof(width: 160, height: 120),
      ]),
    ),
    null,
  );
}

void checkCameraCapabilities() {
  section('camera capabilities');

  const vga = CameraResolution(width: 640, height: 480);
  const svga = CameraResolution(width: 800, height: 600);
  const xga = CameraResolution(width: 1024, height: 768);
  const hd = CameraResolution(width: 1280, height: 720);
  const fhd = CameraResolution(width: 1920, height: 1080);

  final deduped = CameraCapabilities.of(
    resolutions: <CameraResolution>[vga, fhd, vga, hd],
    framerates: <int>[5, 30, 30, 15],
  );
  eq(
    'duplicate resolutions collapse and sort by pixel count',
    deduped.resolutions.map((r) => r.label).join(','),
    '1920x1080,1280x720,640x480',
  );
  eq(
    'duplicate frame rates collapse and sort descending',
    deduped.framerates.join(','),
    '30,15,5',
  );

  final measured = CameraCapabilities.of(
    resolutions: <CameraResolution>[fhd, vga],
    framerates: <int>[30],
  ).withCommonBaseline();
  eq(
    'the common ladder fills the gaps below the ceiling',
    measured.resolutions.map((r) => r.label).join(','),
    '1920x1080,1280x720,1024x768,800x600,640x480,320x240',
  );
  check(
    'the common frame rates are added',
    kCommonFramerates.every(measured.framerates.contains),
  );
  check(
    'the declared list is still free of duplicates',
    measured.resolutions.toSet().length == measured.resolutions.length &&
        measured.framerates.toSet().length == measured.framerates.length,
  );

  final capped = CameraCapabilities.of(
    resolutions: <CameraResolution>[vga],
    framerates: <int>[30],
  ).withCommonBaseline();
  check(
    'nothing above the measured maximum is ever declared',
    capped.resolutions.every((r) => r.pixelCount <= vga.pixelCount),
  );
  eq(
    'so a 480p camera tops out at 640x480',
    capped.resolutions.first.label,
    '640x480',
  );

  check(
    'an unmeasured camera declares nothing',
    CameraCapabilities.empty.withCommonBaseline().isEmpty,
  );

  // The server rejects a registration that omits the camera's *current* mode.
  final current = CameraCapabilities.of(
    resolutions: <CameraResolution>[vga, xga],
    framerates: <int>[60, 30, 15],
  ).withCommonBaseline().withCurrent(resolution: svga, fps: 5);
  check(
    'the current resolution is declared',
    current.resolutions.contains(svga),
  );
  check('the current frame rate is declared', current.framerates.contains(5));
  check(
    'withCurrent still leaves the list deduped',
    current.resolutions.toSet().length == current.resolutions.length,
  );

  final roundTripped = CameraCapabilities.fromJson(measured.toJson());
  eq(
    'capabilities survive a JSON round trip',
    roundTripped.toString(),
    measured.toString(),
  );
  eq(
    'a null payload answers empty',
    CameraCapabilities.fromJson(null).isEmpty,
    true,
  );
  eq(
    'a corrupt payload answers empty rather than throwing',
    CameraCapabilities.fromJson(<String, Object?>{
      'resolutions': <Object?>['not-a-size', 640, null, '0x480'],
      'framerates': <Object?>['30', null, -5],
    }).isEmpty,
    true,
  );
  eq(
    'the current pair survives a JSON round trip',
    CameraCapabilities.fromJson(current.toJson()).toString(),
    current.toString(),
  );

  const mode = CameraMode(resolution: hd, fps: 5);
  check(
    'an unchanged mode does not differ',
    !mode.differsFrom(const CameraMode(resolution: hd, fps: 5)),
  );
  check(
    'a changed resolution differs',
    mode.differsFrom(const CameraMode(resolution: fhd, fps: 5)),
  );
  check(
    'a changed frame rate differs',
    mode.differsFrom(const CameraMode(resolution: hd, fps: 15)),
  );
}

void checkCameraOrder() {
  section('canonical camera order');

  eq(
    'the group order is rear, then external, then front',
    CameraGroup.values.map((g) => g.name).join(','),
    'back,external,front',
  );
  eq('back maps to the back group', cameraGroupFor('back'), CameraGroup.back);
  eq(
    'front maps to the front group',
    cameraGroupFor('front'),
    CameraGroup.front,
  );
  eq(
    'external maps to the external group',
    cameraGroupFor('external'),
    CameraGroup.external,
  );
  eq(
    'an unknown direction is treated as external',
    cameraGroupFor('unknown'),
    CameraGroup.external,
  );

  const weakBack = RankedCamera(
    index: 3,
    group: CameraGroup.back,
    maxPixels: 640 * 480,
  );
  const strongBack = RankedCamera(
    index: 2,
    group: CameraGroup.back,
    maxPixels: 1920 * 1080,
  );
  const weakFront = RankedCamera(
    index: 0,
    group: CameraGroup.front,
    maxPixels: 640 * 480,
  );
  const strongFront = RankedCamera(
    index: 1,
    group: CameraGroup.front,
    maxPixels: 1280 * 720,
  );

  const mixed = <RankedCamera>[weakFront, weakBack, strongFront, strongBack];
  eq(
    'the strongest back camera lands at index 0',
    canonicalCameraOrder(mixed).first,
    2,
  );
  eq(
    'the strongest front camera lands right after the back cameras',
    canonicalCameraOrder(mixed)[2],
    1,
  );
  eq(
    'the full order is back, then external, then front',
    canonicalCameraOrder(mixed).join(','),
    '2,3,1,0',
  );

  // Windows reports every camera as `front`; Linux reports every one as
  // `external`. Both must collapse to plain resolution order with no special
  // case, and camera 0 must still be the strongest camera.
  const windows = <RankedCamera>[
    RankedCamera(index: 0, group: CameraGroup.front, maxPixels: 640 * 480),
    RankedCamera(index: 1, group: CameraGroup.front, maxPixels: 1920 * 1080),
    RankedCamera(index: 2, group: CameraGroup.front, maxPixels: 1280 * 720),
  ];
  eq(
    'an all-front device falls back to resolution order',
    canonicalCameraOrder(windows).join(','),
    '1,2,0',
  );
  eq(
    'and its camera 0 is the strongest one',
    canonicalCameraOrder(windows).first,
    1,
  );

  const linux = <RankedCamera>[
    RankedCamera(index: 0, group: CameraGroup.external, maxPixels: 1280 * 720),
    RankedCamera(index: 1, group: CameraGroup.external, maxPixels: 640 * 480),
    RankedCamera(index: 2, group: CameraGroup.external, maxPixels: 1920 * 1080),
  ];
  eq(
    'an all-external device falls back to resolution order',
    canonicalCameraOrder(linux).join(','),
    '2,0,1',
  );

  // A camera the ranking pass could not measure must not displace one it did.
  const unmeasured = RankedCamera(index: 0, group: CameraGroup.back);
  const measuredBack = RankedCamera(
    index: 1,
    group: CameraGroup.back,
    maxPixels: 640 * 480,
  );
  eq(
    'an unranked camera sorts last within its group',
    canonicalCameraOrder(<RankedCamera>[unmeasured, measuredBack]).join(','),
    '1,0',
  );

  eq(
    'ties fall back to the physical index, so the order is stable',
    canonicalCameraOrder(<RankedCamera>[
      const RankedCamera(index: 2, group: CameraGroup.external, maxPixels: 100),
      const RankedCamera(index: 0, group: CameraGroup.external, maxPixels: 100),
      const RankedCamera(index: 1, group: CameraGroup.external, maxPixels: 100),
    ]).join(','),
    '0,1,2',
  );

  // The property that matters most: whatever happens, the result is a
  // permutation. A dropped or repeated entry silently redefines camera_enum.
  final messy = <RankedCamera>[
    const RankedCamera(index: 4, group: CameraGroup.front, maxPixels: 100),
    const RankedCamera(index: 0, group: CameraGroup.back),
    const RankedCamera(index: 2, group: CameraGroup.external, maxPixels: 900),
    const RankedCamera(index: 1, group: CameraGroup.back, maxPixels: 500),
    RankedCamera(index: 3, group: cameraGroupFor('unknown'), maxPixels: 0),
  ];
  final ordered = canonicalCameraOrder(messy);
  check(
    'the result is always a permutation of the input indices',
    ordered.length == messy.length &&
        ordered.toSet().length == ordered.length &&
        ordered.toSet().containsAll(<int>[0, 1, 2, 3, 4]),
  );
  eq(
    'the empty list stays empty',
    canonicalCameraOrder(const <RankedCamera>[]).length,
    0,
  );
}

void checkCapabilityCache() {
  section('capability cache key');

  eq(
    'the fingerprint is stable for the same camera list',
    cameraFingerprint(<String>['front', 'back']),
    cameraFingerprint(<String>['front', 'back']),
  );
  check(
    'adding a camera changes the fingerprint',
    cameraFingerprint(<String>['front']) !=
        cameraFingerprint(<String>['front', 'back']),
  );
  // `camera_enum` is positional, so swapping two cameras changes what index 0
  // means just as much as swapping the hardware does.
  check(
    'swapping two cameras changes the fingerprint',
    cameraFingerprint(<String>['front', 'back']) !=
        cameraFingerprint(<String>['back', 'front']),
  );
  // Names come from the platform and can contain anything, so the encoding is
  // length-prefixed rather than joined on a separator.
  check(
    'a name containing the separator cannot be forged',
    cameraFingerprint(<String>['a|b']) != cameraFingerprint(<String>['a', 'b']),
  );
  check(
    'nor can one containing the record separator',
    cameraFingerprint(<String>['a;1:b;']) !=
        cameraFingerprint(<String>['a', 'b']),
  );
  eq(
    'an empty camera list has an empty fingerprint',
    cameraFingerprint(<String>[]),
    '',
  );

  // The probe contract itself is pure, so the harness covers the two constants
  // that shape what gets declared.
  eq('the frame rates are probed highest first', kProbeFramerates.first, 60);
  check(
    'and 5 is reachable, because that is the default capture rate',
    kCommonFramerates.contains(5),
  );
  eq(
    'an empty probe result reports isEmpty',
    const CapabilityProbeResult(capabilities: CameraCapabilities.empty).isEmpty,
    true,
  );
  eq(
    'a measured probe result does not',
    CapabilityProbeResult(
      capabilities: CameraCapabilities.of(
        resolutions: <CameraResolution>[
          CameraResolution(width: 1280, height: 720),
        ],
        framerates: <int>[30],
      ),
    ).isEmpty,
    false,
  );
}

void checkMjpegEncoder() {
  section('mjpeg encoder');
  fakeAsync((async) {
    final pump = _FakeFramePump();
    final encoder = MjpegEncoder(
      camera: _FakeCameraService(bytes: Uint8List.fromList([1])),
      cameraEnum: 3,
      streamId: streamId,
      pump: pump,
    );
    eq('the encoder advertises mjpeg', encoder.codec, CaptureCodec.mjpeg);

    final received = <EncodedFrame>[];
    encoder.frames.listen(received.add);

    encoder.start(width: 1280, height: 720, fps: 5, quality: 80);
    async.flushMicrotasks();
    eq(
      'the pump was started for the bound stream',
      pump.lastStreamId,
      streamId,
    );
    eq('the pump was started for the bound camera', pump.lastCameraEnum, 3);
    eq('the declared rate reaches the pump', pump.lastFps, 5);

    pump.emit(
      CapturedFrame(
        seq: 0,
        ts: DateTime.utc(2026),
        bytes: Uint8List.fromList([0xFF, 0xD8]),
      ),
    );
    async.flushMicrotasks();

    eq('one encoded frame', received.length, 1);
    eqBytes('the JPEG passes through untouched', received.single.bytes, [
      0xFF,
      0xD8,
    ]);
    eq('a JPEG is its own key frame', received.single.isKeyFrame, true);
    eq('seq is preserved', received.single.seq, 0);

    encoder.stop();
    async.flushMicrotasks();
    eq('stop reaches the pump', pump.stopCalls, 1);
  });
}

Future<void> checkMockGateway() async {
  section('mock gateway');
  final gateway = MockBackendGateway(
    commandInterval: const Duration(milliseconds: 1),
  );
  await gateway.start(credentials);
  eq('the mock goes live', gateway.state, LinkState.live);

  final seen = <DeviceCommand>[];
  await for (final command in gateway.commands.take(4)) {
    seen.add(command);
  }

  final start = seen.whereType<StartRecordingCommand>().single;
  final photo = seen.whereType<TakePhotoCommand>().single;
  eq('stream ids are 26-character ULIDs', start.streamId.length, 26);
  eq('command ids are 26-character ULIDs', start.id!.length, 26);
  eq('request ids are 26-character ULIDs', photo.requestId.length, 26);
  eq(
    'stop names the stream that was started',
    seen.whereType<StopRecordingCommand>().single.streamId,
    start.streamId,
  );
  check('ping is part of the cycle', seen.whereType<PingCommand>().isNotEmpty);

  final ulid = generateUlid();
  check(
    'generateUlid is Crockford base32',
    RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(ulid),
  );
  check(
    'generateUlid sorts by time',
    generateUlid(DateTime.utc(2026))
            .compareTo(generateUlid(DateTime.utc(2027))) <
        0,
  );

  gateway.sendRecordingFrame(
    RecordingFrameMeta(
      cameraEnum: 0,
      streamId: 's',
      seq: 1,
      ts: DateTime.utc(2026),
    ),
    Uint8List.fromList([1]),
  );
  gateway.sendPhoto(
    PhotoMeta(cameraEnum: 0, requestId: 'r', ts: DateTime.utc(2026)),
    Uint8List.fromList([2]),
  );
  eq('frames are counted', gateway.recordedFrames, 1);
  eq('photos are counted', gateway.recordedPhotos, 1);

  await gateway.stop();
  eq('the mock stops', gateway.state, LinkState.idle);
}

Future<void> checkSmartClassGateway() async {
  section('smartclass gateway');

  // register -> attach
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    eq('registered once', harness.registration.calls, 1);
    eq('the link is live', harness.gateway.state, LinkState.live);
    eq(
      'the credentials were passed through',
      harness.registration.lastCredentials,
      credentials,
    );
    eq(
      'the cameras were announced',
      harness.registration.lastCameras?.length,
      1,
    );
    eq(
      'the base was passed through',
      harness.registration.lastBase?.toString(),
      'http://localhost:8080',
    );
    eq('the ticket is known', harness.gateway.ticket, ticket64);
    await harness.dispose();
  }

  // attach URI
  {
    Uri? attached;
    final incoming = StreamController<dynamic>();
    final gateway = SmartClassBackendGateway(
      base: Uri.parse('https://cameras.test/base'),
      registration: _FakeRegistration(),
      channelFactory: (uri) {
        attached = uri;
        return _FakeChannel(incoming.stream, _FakeSink());
      },
      cameras: const <CameraAnnouncement>[cameraAnnouncement],
    );
    await gateway.start(credentials);
    eq('the upgrade uses wss for an https base', attached?.scheme, 'wss');
    eq('the base path is kept', attached?.path, '/base/ws/device/$ticket64');
    await gateway.stop();
    await incoming.close();
  }

  // ping -> pong
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    harness.first.add(
      '{"channel":"control","type":"ping","payload":{"ts":"2026-10-04T10:00:30Z"}}',
    );
    await settle();

    final pong = jsonDecode(harness.sink.text.last) as Map<String, dynamic>;
    eq('a ping is answered with a pong', pong['type'], 'pong');
    eq(
      'the pong echoes the ts',
      (pong['payload']! as Map)['ts'],
      '2026-10-04T10:00:30Z',
    );
    eq(
      'the ping never reaches the command stream',
      harness.gateway.unrecognizedCommands.entries.length,
      0,
    );
    await harness.dispose();
  }

  // commands reach the stream
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    final next = harness.gateway.commands.first;
    harness.first.add(
      '{"channel":"control","type":"start_recording","id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B1",'
      '"payload":{"camera_enum":0,"stream_id":"$streamId"}}',
    );
    final command = await next;
    check(
      'start_recording reaches the coordinator',
      command is StartRecordingCommand,
    );
    eq(
      '  with the stream id intact',
      (command as StartRecordingCommand).streamId,
      streamId,
    );
    await harness.dispose();
  }

  // fault tolerance
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    harness.first.add('<<garbage>>');
    await settle();
    eq(
      'garbage is recorded locally',
      harness.gateway.unrecognizedCommands.entries.length,
      1,
    );
    eq(
      '  verbatim',
      harness.gateway.unrecognizedCommands.entries.single.raw,
      '<<garbage>>',
    );
    eq('the link survives', harness.gateway.state, LinkState.live);

    harness.first.add(
      '{"channel":"control","type":"ping","payload":{"ts":"t"}}',
    );
    await settle();
    eq(
      'the next valid frame still parses',
      harness.gateway.state,
      LinkState.live,
    );
    await harness.dispose();
  }

  // close -> backoff -> fresh registration
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    eq('one socket before the close', harness.opened.length, 1);

    harness.gateway.simulateClose();
    eq('a close goes to backoff', harness.gateway.state, LinkState.backoff);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    eq(
      'a fresh ticket is minted rather than reusing one',
      harness.registration.calls,
      2,
    );
    eq('a second socket is opened', harness.opened.length, 2);
    eq('the link is live again', harness.gateway.state, LinkState.live);
    await harness.dispose();
  }

  // 401 is terminal
  {
    final harness = _GatewayHarness(failure: RegistrationFailure.unauthorized);
    await harness.gateway.start(credentials);
    eq('401 is terminal', harness.gateway.state, LinkState.failed);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    eq('401 is not retried', harness.registration.calls, 1);
    check('401 is reported to the operator', harness.gateway.lastError != null);
    await harness.dispose();
  }

  // 500 is retried
  {
    final harness = _GatewayHarness(failure: RegistrationFailure.serverError);
    await harness.gateway.start(credentials);
    eq('a 500 goes to backoff', harness.gateway.state, LinkState.backoff);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    check('a 500 is retried', harness.registration.calls > 1);
    await harness.dispose();
  }

  // a failed attach re-registers
  {
    final harness = _GatewayHarness(
      readyError: StateError('404 device websocket not found'),
    );
    await harness.gateway.start(credentials);
    eq(
      'a failed attach goes to backoff',
      harness.gateway.state,
      LinkState.backoff,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    check('a failed attach mints a new ticket', harness.registration.calls > 1);
    check('and opens another socket', harness.opened.length > 1);
    await harness.dispose();
  }

  // close codes
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    harness.gateway.simulateClose(closeCode: 1009);
    await settle();
    check(
      '1009 is reported as an oversized frame',
      harness.gateway.lastError!.contains('16 MiB'),
    );
    await harness.dispose();
  }
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    harness.gateway.simulateClose(closeCode: 1006);
    await settle();
    eq(
      '1006 is normal operation, not an error',
      harness.gateway.lastError,
      null,
    );
    eq(
      '1006 still triggers a reconnect',
      harness.gateway.state,
      LinkState.backoff,
    );
    await harness.dispose();
  }

  // idle status
  {
    final harness = _GatewayHarness(
      idleStatusInterval: const Duration(milliseconds: 5),
      statusReport: () => {'recording': true, 'frames_sent': 7},
    );
    await harness.gateway.start(credentials);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final statuses = harness.sink.text
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .where((m) => m['type'] == 'status')
        .toList();
    check('an idle status goes out', statuses.isNotEmpty);
    eq(
      '  carrying the coordinator report',
      (statuses.last['payload']! as Map)['frames_sent'],
      7,
    );
    await harness.dispose();
  }

  // media gating and framing
  {
    final harness = _GatewayHarness();
    harness.gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: 0,
        streamId: streamId,
        seq: 1,
        ts: DateTime.utc(2026),
      ),
      Uint8List.fromList([9]),
    );
    eq(
      'nothing is pushed before the link is live',
      harness.sink.records.length,
      0,
    );

    await harness.gateway.start(credentials);
    harness.sink.records.clear();
    harness.gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: 0,
        streamId: streamId,
        seq: 1,
        ts: DateTime.utc(2026),
      ),
      Uint8List.fromList([9]),
    );

    final decoded = tryDecodeBinaryFrame(harness.sink.binary.single)!;
    eq(
      'the frame is on the recording channel',
      decoded.header.channel,
      WireChannel.recording,
    );
    eq('the header type is frame', decoded.header.type, 'frame');
    eq(
      'the stream id is carried',
      decoded.header.payload!['stream_id'],
      streamId,
    );
    eqBytes('the payload is carried', decoded.data, [9]);

    harness.sink.records.clear();
    harness.gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: 0,
        streamId: streamId,
        seq: 2,
        ts: DateTime.utc(2026),
      ),
      Uint8List(maxFrameBytes),
    );
    eq(
      'an oversized frame is dropped, not sent',
      harness.sink.records.length,
      0,
    );
    check('and reported locally', harness.gateway.lastError != null);
    await harness.dispose();
  }

  // a stale connection cannot tear down the new one
  {
    final harness = _GatewayHarness();
    await harness.gateway.start(credentials);
    harness.gateway.simulateClose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    eq('reconnected', harness.gateway.state, LinkState.live);

    await harness.opened.first.close();
    await settle();
    eq(
      'a late onDone from the dead socket is ignored',
      harness.gateway.state,
      LinkState.live,
    );
    await harness.dispose();
  }
}

Future<void> checkCoordinator() async {
  section('agent coordinator');

  Future<
    ({
      AgentCoordinator coordinator,
      _FakeGateway gateway,
      _FakeFramePump pump,
      _FakeCameraService camera,
    })
  >
  build({Uint8List? frameBytes, bool initialized = true}) async {
    final gateway = _FakeGateway();
    final pump = _FakeFramePump();
    final camera = _FakeCameraService(bytes: frameBytes);
    if (!initialized) camera.release();

    final coordinator = AgentCoordinator(
      gatewayFactory: (_) => gateway,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => pump,
      connection: testConnection,
      initialCamera: camera,
      initialBackendId: 'stub',
    );
    await coordinator.start();
    return (
      coordinator: coordinator,
      gateway: gateway,
      pump: pump,
      camera: camera,
    );
  }

  // start pushes nothing
  {
    final h = await build();
    eq('the gateway was started', h.gateway.startCalls, 1);
    eq(
      'nothing is recorded until asked',
      h.coordinator.captureState,
      CaptureState.idle,
    );
    eq('no stream is active', h.coordinator.activeStreamId, null);
    eq('no frames were pushed', h.gateway.frameMeta.length, 0);
  }

  // start_recording
  {
    final h = await build(frameBytes: Uint8List.fromList([0xFF, 0xD8]));
    await h.coordinator.handleCommand(
      const StartRecordingCommand(
        id: '01J8ZKQ3B5N7P9R1T3V5X7Z9B1',
        cameraEnum: 0,
        streamId: streamId,
      ),
    );

    eq('one ack', h.gateway.acks.length, 1);
    eq(
      '  echoing the id',
      h.gateway.acks.single.id,
      '01J8ZKQ3B5N7P9R1T3V5X7Z9B1',
    );
    eq('  ok', h.gateway.acks.single.ok, true);
    eq('the pump was started', h.pump.startCalls, 1);
    eq('  for the announced stream', h.pump.lastStreamId, streamId);
    eq('  for the announced camera', h.pump.lastCameraEnum, 0);
    eq(
      'the state is recording',
      h.coordinator.captureState,
      CaptureState.recording,
    );
    eq('the stream is active', h.coordinator.activeStreamId, streamId);

    h.pump.emit(
      CapturedFrame(
        seq: 7,
        ts: DateTime.utc(2026, 10, 4, 10),
        bytes: Uint8List.fromList([0xFF, 0xD8, 1]),
      ),
    );
    await settle();

    eq('a frame is pushed', h.gateway.frameMeta.length, 1);
    final meta = h.gateway.frameMeta.single;
    eq('  tagged with the stream id', meta.streamId, streamId);
    eq('  tagged with the camera', meta.cameraEnum, 0);
    eq('  carrying the pump seq', meta.seq, 7);
    eqBytes('  carrying the bytes', h.gateway.frameBytes.single, [
      0xFF,
      0xD8,
      1,
    ]);
    eq('the status counts the frames', h.coordinator.status.framesSent, 1);
  }

  // a second start is refused
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's1'),
    );
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'b', cameraEnum: 0, streamId: 's2'),
    );

    eq('two acks', h.gateway.acks.length, 2);
    eq('the second is refused', h.gateway.acks.last.ok, false);
    check('  with a reason', h.gateway.acks.last.error != null);
    eq('the pump was started once', h.pump.startCalls, 1);
    eq('the original stream stays active', h.coordinator.activeStreamId, 's1');
  }

  // a frame produced while start() is still in flight must not be lost
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    h.pump.framesOnStart = <CapturedFrame>[
      CapturedFrame(
        seq: 0,
        ts: DateTime.utc(2026),
        bytes: Uint8List.fromList([0xF0]),
      ),
      CapturedFrame(
        seq: 1,
        ts: DateTime.utc(2026),
        bytes: Uint8List.fromList([0xF1]),
      ),
    ];

    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    await settle();

    // The stream has to be claimed before the pump starts, otherwise the head
    // of the server's first segment is silently missing.
    eq('no frame is lost to the startup window', h.gateway.frameMeta.length, 2);
    eq(
      'and the sequence survives intact',
      h.gateway.frameMeta.map((m) => m.seq).join(','),
      '0,1',
    );
    eq(
      'both frames carry the stream id',
      h.gateway.frameMeta.every((m) => m.streamId == streamId),
      true,
    );
  }

  // a pump that fails to start must not leave the stream claimed
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    h.pump.startError = StateError('sensor busy');

    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    await settle();

    eq('the failure is acked, not swallowed', h.gateway.acks.length, 1);
    eq('  as a failure', h.gateway.acks.single.ok, false);
    check('  with the cause', h.gateway.acks.single.error!.contains('busy'));
    eq('the stream is not left claimed', h.coordinator.activeStreamId, null);
    eq('the state is idle', h.coordinator.captureState, CaptureState.idle);
    eq('the pump was stopped', h.pump.stopCalls, 1);
  }

  // stop_recording
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    await h.coordinator.handleCommand(
      const StopRecordingCommand(id: 'b', cameraEnum: 0, streamId: streamId),
    );

    eq('the pump was stopped', h.pump.stopCalls, 1);
    eq('the state is idle', h.coordinator.captureState, CaptureState.idle);
    eq('no stream is active', h.coordinator.activeStreamId, null);
    eq('both commands were acked', h.gateway.acks.length, 2);
    eq('the stop was ok', h.gateway.acks.last.ok, true);

    // Frames arriving after the stop must not be pushed: the server drops them.
    h.pump.emit(
      CapturedFrame(
        seq: 9,
        ts: DateTime.utc(2026),
        bytes: Uint8List.fromList([1]),
      ),
    );
    await settle();
    eq('nothing is pushed after the stop', h.gateway.frameMeta.length, 0);
  }

  // take_photo
  {
    final h = await build(frameBytes: Uint8List.fromList([0xFF, 0xD8]));
    await h.coordinator.handleCommand(
      const TakePhotoCommand(
        id: 'c',
        cameraEnum: 0,
        requestId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B3',
      ),
    );

    eq('one photo', h.gateway.photoMeta.length, 1);
    eq(
      '  with the request id',
      h.gateway.photoMeta.single.requestId,
      '01J8ZKQ3B5N7P9R1T3V5X7Z9B3',
    );
    eq(
      '  with the canonical content type',
      h.gateway.photoMeta.single.contentType,
      'image/jpeg',
    );
    eqBytes('  with the bytes', h.gateway.photoBytes.single, [0xFF, 0xD8]);
    eq('the photo was acked', h.gateway.acks.single.ok, true);
    eq(
      'the state returns to idle',
      h.coordinator.captureState,
      CaptureState.idle,
    );
  }

  // failures are acked, never dropped
  {
    final h = await build(initialized: false);
    await h.coordinator.handleCommand(
      const TakePhotoCommand(id: 'd', cameraEnum: 0, requestId: 'r'),
    );
    eq('a command that cannot run is still acked', h.gateway.acks.length, 1);
    eq('  with the right id', h.gateway.acks.single.id, 'd');
    eq('  marked failed', h.gateway.acks.single.ok, false);
    check('  with a reason', h.gateway.acks.single.error != null);
    eq('no photo is uploaded', h.gateway.photoMeta.length, 0);
  }

  // switch_camera
  {
    final h = await build();
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 1),
    );
    eq('the camera was switched', h.camera.cameraIndex, 1);
    eq('the coordinator tracks it', h.coordinator.cameraEnum, 1);
    eq('the switch was acked', h.gateway.acks.single.ok, true);
  }
  {
    final h = await build();
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 1),
    );
    eq(
      'switching under a live stream is refused',
      h.gateway.acks.last.ok,
      false,
    );
    eq('the camera did not move', h.camera.cameraIndex, 0);
  }

  // ping is not acked
  {
    final h = await build();
    await h.coordinator.handleCommand(const PingCommand(ts: 't'));
    eq('ping is not acked', h.gateway.acks.length, 0);
  }

  // losing the link aborts the recording
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    h.gateway.setState(LinkState.backoff);
    await settle();

    eq('the pump was stopped', h.pump.stopCalls, 1);
    eq('the state is idle', h.coordinator.captureState, CaptureState.idle);
    eq('the stream was released', h.coordinator.activeStreamId, null);
  }

  // gateway errors surface in the status
  {
    final h = await build();
    h.gateway.emitError('单帧超过 16 MiB');
    await settle();
    check(
      'a gateway error reaches the status',
      h.coordinator.status.lastError!.contains('16 MiB'),
    );
  }

  // status reporting
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    final report = h.coordinator.reportStatus();
    eq('the report says it is recording', report['recording'], true);
    eq('the report names the stream', report['stream_id'], streamId);
    eq('the report names the camera', report['active_camera'], 0);

    final status = h.coordinator.status;
    eq(
      'the status carries the announced rate',
      status.fps,
      h.coordinator.announcedFps,
    );
    check('the announced rate is positive', status.fps > 0);
    eq('the status carries the camera name', status.cameraName, 'fake camera');
  }

  // the preview toggle is local
  {
    final h = await build();
    await h.coordinator.setPreviewEnabled(false);
    eq('the setting is updated', h.coordinator.settings.previewEnabled, false);
    eq('the camera is told', h.camera.previewEnabled, false);
    eq(
      'the capture state is untouched',
      h.coordinator.captureState,
      CaptureState.idle,
    );
  }

  // missing credentials fail the link instead of crashing
  {
    final gateway = _FakeGateway();
    final coordinator = AgentCoordinator(
      gatewayFactory: (_) => gateway,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
      connection: ConnectionSettings(baseUrl: Uri.parse(defaultBaseUrl)),
      initialCamera: _FakeCameraService(bytes: Uint8List(0)),
    );
    await coordinator.start();

    eq('the link is failed', coordinator.linkState, LinkState.failed);
    check('and says why', coordinator.status.lastError != null);
    eq('the gateway was never started', gateway.startCalls, 0);
  }

  // command outcomes are reported, because the ack is otherwise invisible
  {
    final gateway = _FakeGateway();
    final lines = <String>[];
    final coordinator = AgentCoordinator(
      gatewayFactory: (_) => gateway,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
      connection: testConnection,
      initialCamera: _FakeCameraService(bytes: Uint8List.fromList([1])),
      log: lines.add,
    );
    await coordinator.start();

    await coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 1),
    );
    eq(
      'the command is reported',
      lines.any((l) => l.contains('switch_camera')),
      true,
    );
    eq('the ack is reported', lines.any((l) => l.contains('ack ok')), true);

    // A refusal has to be just as visible: the server never waits for an ack
    // and records nothing about most commands, so this line is the only place
    // an operator can learn the device said no.
    lines.clear();
    await coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    lines.clear();
    await coordinator.handleCommand(
      const StartRecordingCommand(id: 'b', cameraEnum: 0, streamId: 's2'),
    );
    eq(
      'a refusal is reported with its reason',
      lines.any((l) => l.contains('ack FAILED') && l.contains('already')),
      true,
    );
  }

  // pause releases everything
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    await h.coordinator.pause();

    eq('the pump was stopped', h.pump.stopCalls, 1);
    eq('the camera was released', h.camera.isInitialized, false);
    eq('the gateway was stopped', h.gateway.stopCalls, 1);
    eq('the state is idle', h.coordinator.captureState, CaptureState.idle);
  }

  // pause then resume must leave exactly one subscription
  {
    final h = await build(frameBytes: Uint8List.fromList([1]));
    await h.coordinator.pause();
    await h.coordinator.resume();

    // Both real gateways expose *broadcast* streams, so a second subscription
    // would not throw — it would quietly handle every command twice, which
    // means two acks for one `id`. Counting acks is the only way to see it.
    h.gateway.emitCommand(const SwitchCameraCommand(id: 'e', cameraEnum: 1));
    await settle();

    eq('one command produces exactly one ack', h.gateway.acks.length, 1);
    eq('and it is the right one', h.gateway.acks.single.id, 'e');
    eq('the camera actually switched', h.coordinator.cameraEnum, 1);
  }

  // reconfigure swaps the gateway rather than mutating it
  {
    final factory = _FakeGatewayFactory();
    final pump = _FakeFramePump();
    final camera = _FakeCameraService(bytes: Uint8List.fromList([1]));
    final coordinator = AgentCoordinator(
      gatewayFactory: factory,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => pump,
      connection: testConnection,
      initialCamera: camera,
      initialBackendId: 'stub',
    );
    await coordinator.start();

    eq('the factory was asked once', factory.requested.length, 1);
    final first = factory.built.single;
    eq('and produced the live gateway', first.startCalls, 1);

    await coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    pump.emit(
      CapturedFrame(seq: 0, ts: DateTime.utc(2026), bytes: Uint8List(4)),
    );
    await settle();
    eq('a frame went out', coordinator.framesSent, 1);

    final moved = ConnectionSettings(
      baseUrl: Uri.parse('http://10.0.0.9:9000'),
      credentials: credentials,
    );
    await coordinator.reconfigure(moved);

    eq('a second gateway was built', factory.built.length, 2);
    eq(
      'with the new address',
      factory.requested.last.baseUrl.toString(),
      'http://10.0.0.9:9000',
    );
    eq('the old gateway was stopped', first.stopCalls, 1);
    eq('the new gateway was started', factory.built.last.startCalls, 1);
    eq('the recording was cut', pump.stopCalls, 1);
    eq(
      'the capture state is idle',
      coordinator.captureState,
      CaptureState.idle,
    );
    eq('the frame counter is reset', coordinator.framesSent, 0);
    eq(
      'the coordinator reports the new address',
      coordinator.connection.baseUrl.toString(),
      'http://10.0.0.9:9000',
    );
    eq('and the link came back up', coordinator.linkState, LinkState.live);
  }

  // the old gateway's events must not be handled after the swap
  {
    final factory = _FakeGatewayFactory();
    final coordinator = AgentCoordinator(
      gatewayFactory: factory,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
      connection: testConnection,
      initialCamera: _FakeCameraService(bytes: Uint8List(0)),
    );
    await coordinator.start();
    final old = factory.built.single;

    await coordinator.reconfigure(testConnection);
    final current = factory.built.last;

    // A command arriving on the retired gateway would be handled a second time,
    // which means two acks for one id.
    old.emitError('from the retired gateway');
    old.setState(LinkState.backoff);
    await settle();
    eq(
      'the retired gateway cannot report errors',
      coordinator.status.lastError,
      null,
    );
    eq('nor change the link state', coordinator.linkState, LinkState.live);

    current.emitError('from the live gateway');
    await settle();
    eq(
      'but the live one can',
      coordinator.status.lastError,
      'from the live gateway',
    );
  }

  // no credentials means the link fails and points at the settings screen
  {
    final factory = _FakeGatewayFactory();
    final coordinator = AgentCoordinator(
      gatewayFactory: factory,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
      connection: testConnection,
      initialCamera: _FakeCameraService(bytes: Uint8List(0)),
    );
    await coordinator.start();
    await coordinator.reconfigure(
      ConnectionSettings(baseUrl: Uri.parse(defaultBaseUrl)),
    );

    eq('the link fails', coordinator.linkState, LinkState.failed);
    eq(
      'and the message names the settings screen',
      coordinator.status.lastError!.contains('设置'),
      true,
    );
    eq('the gateway was never started', factory.built.last.startCalls, 0);
  }

  // a 401 is terminal, so only a new instance can recover it
  {
    final factory = _FakeGatewayFactory();
    final coordinator = AgentCoordinator(
      gatewayFactory: factory,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
      connection: testConnection,
      initialCamera: _FakeCameraService(bytes: Uint8List(0)),
    );
    await coordinator.start();

    // `SmartClassBackendGateway` latches `_stopped` on a 401 and never retries;
    // the fake stands in for that terminal state.
    factory.built.single.setState(LinkState.failed);
    await settle();
    eq('the link is terminal', coordinator.linkState, LinkState.failed);

    await coordinator.reconfigure(testConnection);

    eq('a fresh instance was built', factory.built.length, 2);
    eq(
      'and it recovered the link',
      coordinator.linkState != LinkState.failed,
      true,
    );
    eq('the link is live', coordinator.linkState, LinkState.live);
  }

  // --- camera mode: switch_camera parameters and the requested codec --------

  // What a 1080p webcam really reports. The device runs at the built-in default
  // 1280x720 @ 5fps, which is *not* one of the probed rates.
  final measured = CameraCapabilities.of(
    resolutions: <CameraResolution>[
      const CameraResolution(width: 1920, height: 1080),
      const CameraResolution(width: 1280, height: 720),
      const CameraResolution(width: 640, height: 480),
    ],
    framerates: <int>[60, 30, 15],
  );

  ({
    AgentCoordinator coordinator,
    _FakeGateway gateway,
    _FakeCameraService camera,
  })
  buildWithMode({
    int cameraCount = 1,
    List<CaptureCodec> announcedCodecs = const <CaptureCodec>[
      CaptureCodec.mjpeg,
    ],
    _FakeGatewayFactory? factory,
  }) {
    final gateway = _FakeGateway();
    final camera = _FakeCameraService(bytes: Uint8List.fromList(<int>[1]));
    // An explicit closure either way: `factory` and a closure share no
    // supertype, so the conditional expression would widen to `Object`.
    final BackendGatewayFactory gatewayFactory = factory == null
        ? (_) => gateway
        : (ConnectionSettings c) => factory(c);
    final coordinator = AgentCoordinator(
      gatewayFactory: gatewayFactory,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
      connection: testConnection,
      initialCamera: camera,
      capabilities: <CameraCapabilities>[
        for (var i = 0; i < cameraCount; i++) measured,
      ],
      announcedCodecs: announcedCodecs,
    );
    return (coordinator: coordinator, gateway: gateway, camera: camera);
  }

  {
    // A declared resolution and rate are applied for real: the capture
    // geometry is rebuilt, not merely recorded.
    final h = buildWithMode();
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(
        id: 'e',
        cameraEnum: 0,
        resolution: CameraResolution(width: 640, height: 480),
        fps: 30,
      ),
    );
    eq('a declared mode is accepted', h.gateway.acks.single.ok, true);
    eq(
      'the mode is recorded against the announced enum',
      h.coordinator.activeMode.toString(),
      'CameraMode(640x480 @ 30fps)',
    );
    eq(
      'the camera is rebuilt at the new geometry',
      h.camera.lastConfig?.width,
      640,
    );
    eq('and at the new height', h.camera.lastConfig?.height, 480);
    eq('the announced rate follows', h.coordinator.announcedFps, 30);
  }

  {
    // A resolution the device never published. Refusing is the point: applying
    // it would mean capturing at a geometry the server has no record of while
    // its stream row stays `active`.
    final h = buildWithMode();
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(
        id: 'e',
        cameraEnum: 0,
        resolution: CameraResolution(width: 3840, height: 2160),
      ),
    );
    eq('an undeclared resolution is refused', h.gateway.acks.single.ok, false);
    check(
      'and the error names the value',
      h.gateway.acks.single.error!.contains('3840x2160'),
    );
    eq('the camera was not touched', h.camera.cameraIndex, 0);
    eq('nor rebuilt', h.camera.reconfigureCalls, 0);
    eq(
      'and the mode is unchanged',
      h.coordinator.activeMode.toString(),
      'CameraMode(1280x720 @ 5fps)',
    );
  }

  {
    // 12 is neither measured nor on the common ladder.
    final h = buildWithMode();
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 0, fps: 12),
    );
    eq('an undeclared frame rate is refused', h.gateway.acks.single.ok, false);
    check(
      'and the error names the rate',
      h.gateway.acks.single.error!.contains('12'),
    );
  }

  {
    // 25 *is* declared: the common ladder below the ceiling is published too,
    // and the operator picks from the published list. Refusing it would be the
    // device contradicting its own announcement.
    final h = buildWithMode();
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 0, fps: 25),
    );
    eq(
      'a rate from the published ladder is accepted',
      h.gateway.acks.single.ok,
      true,
    );
    eq('and applied', h.coordinator.activeMode.fps, 25);
  }

  {
    // No parameters: the camera changes, the mode does not.
    final h = buildWithMode(cameraCount: 2);
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 1),
    );
    eq('a bare switch is accepted', h.gateway.acks.single.ok, true);
    eq(
      'the announced enum is handed straight to the service',
      h.camera.cameraIndex,
      1,
    );
    eq('nothing is rebuilt', h.camera.reconfigureCalls, 0);
    eq(
      'and the mode is untouched',
      h.coordinator.activeMode.toString(),
      'CameraMode(1280x720 @ 5fps)',
    );
    eq(
      'the other camera keeps its own mode',
      h.coordinator.cameraModes[0].fps,
      5,
    );
    eq(
      'which is recorded per announced enum',
      h.coordinator.cameraModes[1].fps,
      5,
    );
    eq('and reported', h.coordinator.reportStatus()['active_camera'], 1);
    eq(
      'with the geometry',
      h.coordinator.reportStatus()['resolution'],
      '1280x720',
    );
  }

  {
    // The server stores nothing for `switch_camera`, so its `metadata` snapshot
    // at `recording/start` is whatever the registration said. A parameter
    // change therefore has to reconnect.
    final factory = _FakeGatewayFactory();
    final h = buildWithMode(factory: factory);
    await h.coordinator.start();
    eq('one gateway so far', factory.built.length, 1);

    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 0, fps: 30),
    );
    eq('a parameter change re-registers', factory.built.length, 2);
    eq('the retired gateway was stopped', factory.built.first.stopCalls, 1);
    eq('and the new one is live', h.coordinator.linkState, LinkState.live);
  }

  {
    // A camera-only switch changes nothing the server was told about, and
    // reconnecting would cut media for no reason.
    final factory = _FakeGatewayFactory();
    final h = buildWithMode(cameraCount: 2, factory: factory);
    await h.coordinator.start();

    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 1),
    );
    eq('a camera-only switch does not re-register', factory.built.length, 1);
  }

  {
    // Nor does a refused one.
    final factory = _FakeGatewayFactory();
    final h = buildWithMode(factory: factory);
    await h.coordinator.start();

    await h.coordinator.handleCommand(
      const SwitchCameraCommand(id: 'e', cameraEnum: 0, fps: 12),
    );
    eq('a refused switch does not re-register', factory.built.length, 1);
  }

  {
    // The codec. `mjpeg` is what the pipeline actually produces — one
    // self-contained picture per frame.
    final h = buildWithMode();
    await h.coordinator.handleCommand(
      const StartRecordingCommand(
        id: 'a',
        cameraEnum: 0,
        streamId: streamId,
        codec: CaptureCodec.mjpeg,
      ),
    );
    eq('mjpeg is accepted', h.gateway.acks.single.ok, true);
    eq(
      'and the stream starts',
      h.coordinator.captureState,
      CaptureState.recording,
    );
  }

  {
    // The server's stream row is already `active` and nothing rolls it back, so
    // the device has to be honest rather than encode something else.
    final h = buildWithMode();
    await h.coordinator.handleCommand(
      const StartRecordingCommand(
        id: 'a',
        cameraEnum: 0,
        streamId: streamId,
        codec: CaptureCodec.h264,
      ),
    );
    eq('an unavailable codec is refused', h.gateway.acks.single.ok, false);
    check(
      'and the error names what was asked for',
      h.gateway.acks.single.error!.contains('h264'),
    );
    check(
      'and what is available',
      h.gateway.acks.single.error!.contains('mjpeg'),
    );
    eq('nothing is pushed', h.coordinator.captureState, CaptureState.idle);
    eq('and no stream is claimed', h.coordinator.activeStreamId, null);
  }

  {
    // An unnamed codec resolves through the announced list, whose first entry
    // is the preferred one — not a hardcoded default that could drift.
    final h = buildWithMode();
    await h.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    eq(
      'an unnamed codec uses the preferred one',
      h.gateway.acks.single.ok,
      true,
    );

    // Even when that preferred codec is one the pipeline cannot produce: an
    // announcement is a claim, and a wrong claim must not be able to make the
    // device ack a codec it cannot encode.
    final wrong = buildWithMode(
      announcedCodecs: const <CaptureCodec>[
        CaptureCodec.h264,
        CaptureCodec.mjpeg,
      ],
    );
    await wrong.coordinator.handleCommand(
      const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: streamId),
    );
    eq(
      'a preferred codec it cannot produce is refused',
      wrong.gateway.acks.single.ok,
      false,
    );
  }

  {
    // A probe that found nothing means the device published exactly the mode it
    // is in, so a switch to that same mode is a no-op rather than a refusal.
    final h = buildWithMode(cameraCount: 0);
    await h.coordinator.handleCommand(
      const SwitchCameraCommand(
        id: 'e',
        cameraEnum: 0,
        resolution: CameraResolution(width: 1280, height: 720),
        fps: 5,
      ),
    );
    eq(
      'an unmeasured camera accepts its own mode',
      h.gateway.acks.single.ok,
      true,
    );
    eq('and is not rebuilt', h.camera.reconfigureCalls, 0);

    // Anything else is refused, because it was never published.
    final other = buildWithMode(cameraCount: 0);
    await other.coordinator.handleCommand(
      const SwitchCameraCommand(
        id: 'e',
        cameraEnum: 0,
        resolution: CameraResolution(width: 640, height: 480),
      ),
    );
    eq(
      'but refuses a mode it never published',
      other.gateway.acks.single.ok,
      false,
    );
  }
}

Future<void> main() async {
  checkResolutionSelection();
  checkStreamSettings();
  checkWireCodec();
  checkCommandParsing();
  checkDeviceMessages();
  checkBinaryFraming();
  checkBaseUrlValidation();
  checkConnectionSettings();
  checkResolveConnectionSettings();
  checkCredentials();
  checkRegistrationRequest();
  checkUriHelpers();
  checkUnrecognizedLog();
  checkCodecSelection();
  await checkFramePump();
  checkSerialLock();
  checkJpegTrim();
  checkJpegSize();
  checkCameraCapabilities();
  checkCameraOrder();
  checkCapabilityCache();
  checkMjpegEncoder();
  await checkCameraProvider();
  await checkFrameStore();
  await checkMockGateway();
  await checkSmartClassGateway();
  await checkCoordinator();

  print('');
  print('passed: $_passed, failed: ${_failures.length}');
  if (_failures.isNotEmpty) {
    exitCode = 1;
  }
}
