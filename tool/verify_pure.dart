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
import 'package:webcam_client/src/capture/camera_provider.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/codec_probe.dart';
import 'package:webcam_client/src/capture/frame_pump.dart';
import 'package:webcam_client/src/capture/frame_store.dart';
import 'package:webcam_client/src/capture/jpeg.dart';
import 'package:webcam_client/src/capture/resolution_selector.dart';
import 'package:webcam_client/src/capture/serial_lock.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/video_encoder.dart';

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

const CameraAnnouncement cameraAnnouncement = CameraAnnouncement(
  cameraEnum: 0,
  resolution: '1280x720',
  fps: 5,
  supportedCodec: <WireCodec>[WireCodec.mjpeg],
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
  int _inFlight = 0;
  int maxConcurrentCaptures = 0;
  int _cameraIndex = 0;
  bool _initialized = true;
  bool _preview = true;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> reconfigure(CaptureConfig config) async {}
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

  void emitError(String message) {
    if (!_errors.isClosed) _errors.add(message);
  }

  List<AckMessage> get acks => sent.whereType<AckMessage>().toList();
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
  final announcements = buildAnnouncements(
    cameraNames: const ['front', 'back'],
    resolutions: const <CameraResolution>[
      CameraResolution(width: 1280, height: 720),
      CameraResolution(width: 640, height: 480),
    ],
    fps: 5,
    codecs: const <WireCodec>[WireCodec.mjpeg],
  );
  eq(
    'camera_enum equals the index',
    announcements.map((c) => c.cameraEnum).join(','),
    '0,1',
  );
  eq('resolution label', announcements.first.resolution, '1280x720');
  eq('codec list', announcements.first.supportedCodec.single, WireCodec.mjpeg);
  eq(
    'the camera name travels in attrs.label',
    announcements.first.attrs['label'],
    'front',
  );

  final clamped = buildAnnouncements(
    cameraNames: const ['front'],
    resolutions: const <CameraResolution>[
      CameraResolution(width: 1280, height: 720),
    ],
    fps: 0,
    codecs: const <WireCodec>[WireCodec.mjpeg],
  );
  eq('fps is clamped to a positive integer', clamped.single.fps, 1);
  check('fps is an int', clamped.single.fps is int);

  final emptyCodecs = buildAnnouncements(
    cameraNames: const ['front'],
    resolutions: const <CameraResolution>[
      CameraResolution(width: 1280, height: 720),
    ],
    fps: 5,
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
      gateway: gateway,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => pump,
      credentials: credentials,
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
      gateway: gateway,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
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
      gateway: gateway,
      cameraProvider: CameraProvider(
        backends: <CameraBackend>[_FakeBackend('stub', probeResult: _okProbe)],
      ),
      pumpFactory: () => _FakeFramePump(),
      credentials: credentials,
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
}

Future<void> main() async {
  checkResolutionSelection();
  checkStreamSettings();
  checkWireCodec();
  checkCommandParsing();
  checkDeviceMessages();
  checkBinaryFraming();
  checkCredentials();
  checkRegistrationRequest();
  checkUriHelpers();
  checkUnrecognizedLog();
  checkCodecSelection();
  await checkFramePump();
  checkSerialLock();
  checkJpegTrim();
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
