// Runs the protocol/capture-layer checks on a plain Dart VM.
//
// `flutter test` cannot run in this environment (see README / memory notes), so
// this harness exercises every module that does not transitively depend on
// Flutter. Run it with:
//
//   dart run tool/verify_pure.dart
//
// It is intentionally dependency-free apart from `fake_async`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:fake_async/fake_async.dart';
import 'package:webcam_client/src/backend/client_signal.dart';
import 'package:webcam_client/src/backend/command_codec.dart';
import 'package:webcam_client/src/backend/server_command.dart';
import 'package:webcam_client/src/backend/unrecognized_command_log.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/capture/camera_provider.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/frame_store.dart';
import 'package:webcam_client/src/capture/resolution_selector.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/video_chunk_recorder.dart';

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

bool listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const available = <CameraResolution>[
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1920, height: 1080),
];

// --- fakes ------------------------------------------------------------------

class _FakeCameraService implements CameraService {
  @override
  Future<void> initialize() async {}
  @override
  Future<void> reconfigure(CaptureConfig config) async {}
  @override
  Future<void> switchCamera(int index) async {}
  @override
  Future<Uint8List?> captureFrame(int quality) async => null;
  @override
  Future<void> setPreviewEnabled(bool enabled) async {}
  @override
  Future<void> release() async {}
  @override
  CameraDescriptor get descriptor =>
      const CameraDescriptor(name: 'fake', index: 0);
  @override
  bool get isInitialized => true;
  @override
  bool get previewEnabled => true;
  @override
  CameraResolution get appliedResolution =>
      const CameraResolution(width: 1280, height: 720);
  @override
  List<CameraResolution> get supportedResolutions => const [];
  @override
  List<CameraDescriptor> get cameras => const [];
  @override
  int get cameraIndex => 0;
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
  Future<CameraService> open(CaptureConfig c) async {
    if (openError != null) throw openError!;
    return _FakeCameraService();
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

BackendProbe _unavailable(CameraUnavailableReason reason) => BackendProbe(
  available: false,
  reason: reason,
  devices: const [],
  supportedResolutions: const [],
  maxFps: 0,
  supportsPreview: false,
);

BackendProbe _okProbe() => const BackendProbe(
  available: true,
  devices: [],
  supportedResolutions: [],
  maxFps: 30,
  supportsPreview: true,
);

class _FakeRecorderHost implements RecorderHost {
  int startCalls = 0;
  int stopCalls = 0;
  @override
  Future<void> startRecording() async => startCalls++;
  @override
  Future<XFile> stopRecording() async {
    stopCalls++;
    return XFile('x.mp4');
  }

  @override
  Future<Uint8List> readFile(String path) async =>
      Uint8List.fromList([0, 0, 0, 24]);
}

class _NoopFileStore implements FrameStore {
  @override
  Future<Uint8List> readAndDelete(String path) async => Uint8List(0);
  @override
  Future<void> delete(String path) async {}
}

// --- checks -----------------------------------------------------------------

void checkResolutionSelection() {
  print('resolution selection');
  eq(
    'exact match wins',
    selectClosestResolution(
      available,
      const CameraResolution(width: 1280, height: 720),
    ),
    const CameraResolution(width: 1280, height: 720),
  );
  eq(
    'never upscales past the target (1000x700)',
    selectClosestResolution(
      available,
      const CameraResolution(width: 1000, height: 700),
    ),
    const CameraResolution(width: 640, height: 480),
  );
  eq(
    'never upscales past the target (4K)',
    selectClosestResolution(
      available,
      const CameraResolution(width: 3840, height: 2160),
    ),
    const CameraResolution(width: 1920, height: 1080),
  );
  eq(
    'falls back to the smallest when nothing fits',
    selectClosestResolution(
      available,
      const CameraResolution(width: 320, height: 240),
    ),
    const CameraResolution(width: 640, height: 480),
  );
  eq(
    'single format fits',
    selectClosestResolution(const [
      CameraResolution(width: 640, height: 480),
    ], const CameraResolution(width: 1280, height: 720)),
    const CameraResolution(width: 640, height: 480),
  );
}

void checkStreamSettings() {
  print('stream settings');
  final s = StreamSettings.defaults();
  eq('default mode', s.mode, StreamMode.video);
  eq('default codec', s.codec, VideoCodec.avc);
  eq('default chunk seconds', s.chunkSeconds, 3);
  eq('default preview', s.previewEnabled, true);

  final c = StreamSettings.defaults().copyWith(
    codec: VideoCodec.hevc,
    previewEnabled: false,
  );
  eq('copyWith keeps mode', c.mode, StreamMode.video);
  eq('copyWith sets codec', c.codec, VideoCodec.hevc);
  eq('copyWith clears preview', c.previewEnabled, false);
  eq('copyWith keeps chunk seconds', c.chunkSeconds, 3);

  eq('lenient mode parse', StreamMode.tryParse('still'), StreamMode.still);
  eq('unknown mode -> null', StreamMode.tryParse('teleport'), null);
  eq('unknown codec -> null', VideoCodec.tryParse('vp9'), null);
}

void checkCodecDecoding() {
  print('command codec (decode)');
  final codec = JsonCommandCodec();

  final u =
      codec.decode(
            '{"type":"cmd_update_config","payload":{"width":1920,"height":1080,"quality":90,"fps":5}}',
          )!
          as UpdateConfigCommand;
  eq('update_config width', u.width, 1920);
  eq('update_config height', u.height, 1080);
  eq('update_config quality', u.quality, 90);
  eq('update_config fps', u.fps, 5.0);

  final m =
      codec.decode(
            '{"type":"cmd_set_stream_mode","payload":{"mode":"video","codec":"hevc","chunkSeconds":2}}',
          )!
          as SetStreamModeCommand;
  eq('stream_mode mode', m.mode, StreamMode.video);
  eq('stream_mode codec', m.codec, VideoCodec.hevc);
  eq('stream_mode chunkSeconds', m.chunkSeconds, 2);

  final p =
      codec.decode('{"type":"cmd_set_preview","payload":{"enabled":false}}')!
          as SetPreviewCommand;
  eq('set_preview enabled', p.enabled, false);

  final f =
      codec.decode(
            '{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}',
          )!
          as FaceResultCommand;
  eq('face result name', f.result.name, '张三');
  eq('face result status', f.result.status, 'approved');

  final cs =
      codec.decode('{"type":"cmd_control_stream","payload":{"enabled":true}}')!
          as ControlStreamCommand;
  eq('control_stream enabled', cs.enabled, true);

  final sc =
      codec.decode('{"type":"cmd_switch_camera","payload":{"index":2}}')!
          as SwitchCameraCommand;
  eq('switch_camera index', sc.index, 2);

  // Fault tolerance: nothing may throw, everything must be recorded locally.
  final log = UnrecognizedCommandLog(sink: null);
  final strict = JsonCommandCodec(unrecognizedLog: log);
  eq('malformed json -> null', strict.decode('this is not json'), null);
  eq('empty string -> null', strict.decode(''), null);
  eq('bare array -> null', strict.decode('[]'), null);
  eq('three entries recorded', log.entries.length, 3);
  eq('raw payload preserved', log.entries.first.raw, 'this is not json');
  eq(
    'reason is malformedJson',
    log.entries.first.reason,
    UnrecognizedReason.malformedJson,
  );

  final log2 = UnrecognizedCommandLog(sink: null);
  const rawUnknown = '{"type":"cmd_do_a_backflip","payload":{"x":1}}';
  eq(
    'unknown type -> null',
    JsonCommandCodec(unrecognizedLog: log2).decode(rawUnknown),
    null,
  );
  eq(
    'reason is unknownType',
    log2.entries.single.reason,
    UnrecognizedReason.unknownType,
  );
  eq('unknown raw kept verbatim', log2.entries.single.raw, rawUnknown);

  final log3 = UnrecognizedCommandLog(sink: null);
  eq(
    'hostile field type -> null',
    JsonCommandCodec(unrecognizedLog: log3)
        .decode('{"type":"cmd_update_config","payload":{"width":"banana"}}'),
    null,
  );
  eq(
    'reason is invalidPayload',
    log3.entries.single.reason,
    UnrecognizedReason.invalidPayload,
  );

  final log4 = UnrecognizedCommandLog(sink: null);
  final quiet = JsonCommandCodec(unrecognizedLog: log4);
  quiet.decode('{"type":"cmd_control_stream","payload":{"enabled":false}}');
  quiet.decode('{"type":"cmd_set_preview","payload":{"enabled":true}}');
  eq('well-formed commands are not recorded', log4.entries.isEmpty, true);

  final log5 = UnrecognizedCommandLog(sink: null);
  final lenient = JsonCommandCodec(unrecognizedLog: log5);
  final bad =
      lenient.decode(
            '{"type":"cmd_set_stream_mode","payload":{"mode":"teleport","codec":"vp9"}}',
          )!
          as SetStreamModeCommand;
  eq('unknown enum degrades to null mode', bad.mode, null);
  eq('unknown enum degrades to null codec', bad.codec, null);
  eq('unknown enum is not an error', log5.entries.isEmpty, true);
}

void checkCodecEncoding() {
  print('command codec (encode)');
  final codec = JsonCommandCodec();

  final sync = jsonDecode(
    codec.encode(
      const StateSyncSignal(
        width: 1280,
        height: 720,
        quality: 80,
        fps: 1.0,
        cameraIndex: 0,
        streaming: true,
        mode: StreamMode.video,
        codec: VideoCodec.avc,
        chunkSeconds: 3,
        previewEnabled: false,
      ),
    ),
  ) as Map<String, dynamic>;
  eq('state_sync type', sync['type'], 'state_sync');
  eq('state_sync mode', (sync['payload'] as Map)['mode'], 'video');
  eq('state_sync codec', (sync['payload'] as Map)['codec'], 'avc');
  eq('state_sync preview', (sync['payload'] as Map)['previewEnabled'], false);

  final mismatch = jsonDecode(
    codec.encode(
      const CapabilityMismatchSignal(
        requested: 'hevc',
        applied: 'avc',
        reason: 'codec unavailable',
      ),
    ),
  ) as Map<String, dynamic>;
  eq('capability_mismatch type', mismatch['type'], 'capability_mismatch');
  eq(
    'capability_mismatch requested',
    (mismatch['payload'] as Map)['requested'],
    'hevc',
  );
  eq(
    'capability_mismatch applied',
    (mismatch['payload'] as Map)['applied'],
    'avc',
  );

  eq(
    'heartbeat uses the agreed name',
    (jsonDecode(codec.encode(const HeartbeatSignal(deviceId: 'd')))
        as Map)['type'],
    'heartbeat',
  );

  final meta = jsonDecode(
    codec.encode(
      const FrameMetaSignal(
        meta: FrameMeta(
          frameId: 7,
          deviceId: 'd',
          timestampMs: 1,
          width: 1280,
          height: 720,
          quality: 80,
        ),
      ),
    ),
  ) as Map<String, dynamic>;
  eq('frame_meta type', meta['type'], 'frame_meta');
  eq('frame_meta frameId', (meta['payload'] as Map)['frameId'], 7);

  final vmeta = jsonDecode(
    codec.encode(
      const VideoMetaSignal(
        meta: VideoMeta(
          chunkId: 1,
          deviceId: 'd',
          timestampMs: 1,
          codec: VideoCodec.avc,
          sequence: 0,
          durationMs: 3000,
          width: 1280,
          height: 720,
        ),
      ),
    ),
  ) as Map<String, dynamic>;
  eq('video_meta type', vmeta['type'], 'video_meta');
  eq('video_meta codec', (vmeta['payload'] as Map)['codec'], 'avc');
}

void checkUnrecognizedLog() {
  print('unrecognized command log');
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
    'sink gets a readable message',
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
  print('camera provider');

  final skip = CameraProvider(
    backends: [
      _FakeBackend(
        'broken',
        probeResult: _unavailable(CameraUnavailableReason.noDevice),
      ),
      _FakeBackend('good', probeResult: _okProbe()),
    ],
  );
  final r1 = await skip.open(CaptureConfig.defaults());
  eq('skips the unavailable backend', r1.backendId, 'good');
  check('opens the next one', r1.service != null);
  eq('records both attempts', r1.attempts.length, 2);

  final crashy = CameraProvider(
    backends: [
      _FakeBackend(
        'crashy',
        probeResult: _okProbe(),
        openError: CameraFailure.initFailed('boom'),
      ),
      _FakeBackend('good', probeResult: _okProbe()),
    ],
  );
  final r2 = await crashy.open(CaptureConfig.defaults());
  eq('falls through when open throws', r2.backendId, 'good');
  eq('records both attempts (throwing open)', r2.attempts.length, 2);

  final allFail = CameraProvider(
    backends: [
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
  eq('attempt list size', r3.attempts.length, 1);

  final empty = await CameraProvider(backends: <CameraBackend>[])
      .open(CaptureConfig.defaults());
  check(
    'no backends at all falls back to NoBackendAvailable',
    empty.failure is CameraFailureNoBackendAvailable,
  );

  final deniedOpen = CameraProvider(
    backends: [
      _FakeBackend(
        'denied',
        probeResult: _okProbe(),
        openError: const CameraFailure.permissionDenied(),
      ),
    ],
  );
  final r5 = await deniedOpen.open(CaptureConfig.defaults());
  check(
    'a failed open surfaces its typed failure',
    r5.failure is CameraFailurePermissionDenied,
  );

  final throwingProbe = CameraProvider(
    backends: [
      _ThrowingBackend(),
      _FakeBackend('good', probeResult: _okProbe()),
    ],
  );
  final r4 = await throwingProbe.open(CaptureConfig.defaults());
  eq('a probe that throws is not fatal', r4.backendId, 'good');
  eq(
    'throwing probe is recorded as unavailable',
    r4.attempts.first.available,
    false,
  );
  eq(
    'throwing probe reason',
    r4.attempts.first.reason,
    CameraUnavailableReason.initFailed,
  );

  print('failure messages');
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
    'noBackendAvailable guidance',
    failureMessage(CameraFailure.noBackendAvailable(const [])).isNotEmpty,
  );
  check(
    'initFailed carries the cause',
    failureMessage(CameraFailure.initFailed('boom')).contains('boom'),
  );
  check(
    'captureFailed carries the cause',
    failureMessage(CameraFailure.captureFailed('bang')).contains('bang'),
  );
}

Future<void> checkFrameStore() async {
  print('frame store');
  final dir = await Directory.systemTemp.createTemp('probe_verify');
  final file = File('${dir.path}${Platform.pathSeparator}frame.jpg')
    ..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9]);
  final bytes = await const IoFrameStore().readAndDelete(file.path);
  check('reads the frame bytes', listEq(bytes, [0xFF, 0xD8, 1, 0xFF, 0xD9]));
  eq('deletes the file immediately', file.existsSync(), false);
  await const IoFrameStore().delete('definitely/not/here.jpg');
  check('deleting a missing file is tolerated', true);
  await dir.delete(recursive: true);
}

void checkVideoChunkRecorder() {
  print('video chunk recorder');

  fakeAsync((async) {
    final host = _FakeRecorderHost();
    final rec = CameraPluginVideoChunkRecorder(
      host: host,
      fileStore: _NoopFileStore(),
    );
    rec.start(
      codec: VideoCodec.avc,
      chunkSeconds: 1,
      config: CaptureConfig.defaults(),
    );
    async.flushMicrotasks();
    eq('opens the first segment immediately', host.startCalls, 1);

    async.elapse(const Duration(milliseconds: 2300));
    eq('restarts a segment per interval', host.startCalls, 3);
    eq('closes the previous segment each time', host.stopCalls, 2);

    rec.stop();
    async.flushMicrotasks();
    eq('flushes the tail segment on stop', host.stopCalls, 3);
  });

  fakeAsync((async) {
    final host = _FakeRecorderHost();
    final rec = CameraPluginVideoChunkRecorder(
      host: host,
      fileStore: _NoopFileStore(),
    );
    final received = <VideoChunk>[];
    rec.chunks.listen(received.add);
    rec.start(
      codec: VideoCodec.hevc,
      chunkSeconds: 1,
      config: CaptureConfig.defaults(),
    );
    async.flushMicrotasks();
    async.elapse(const Duration(seconds: 2));

    check('a chunk is produced', received.isNotEmpty);
    if (received.isNotEmpty) {
      eq(
        'reports the codec that really ran',
        received.first.codec,
        VideoCodec.avc,
      );
      eq(
        'remembers what was requested',
        received.first.requestedCodec,
        VideoCodec.hevc,
      );
      eq('flags the mismatch', received.first.isCodecMismatch, true);
      eq('carries the capture width', received.first.width, 1280);
      eq('carries the capture height', received.first.height, 720);
    }
    rec.stop();
    async.flushMicrotasks();
  });

  eq(
    'supportedCodecs only lists avc',
    CameraPluginVideoChunkRecorder(
          host: _FakeRecorderHost(),
          fileStore: _NoopFileStore(),
        ).supportedCodecs.containsAll(<VideoCodec>[VideoCodec.avc]) &&
        CameraPluginVideoChunkRecorder(
              host: _FakeRecorderHost(),
              fileStore: _NoopFileStore(),
            ).supportedCodecs.length ==
            1,
    true,
  );

  fakeAsync((async) {
    final host = _FakeRecorderHost();
    final rec = CameraPluginVideoChunkRecorder(
      host: host,
      fileStore: _NoopFileStore(),
    );
    rec.start(
      codec: VideoCodec.avc,
      chunkSeconds: 1,
      config: CaptureConfig.defaults(),
    );
    async.flushMicrotasks();
    rec.stop();
    async.flushMicrotasks();
    rec.stop();
    async.flushMicrotasks();
    eq('stop is idempotent', host.stopCalls, 1);
    async.elapse(const Duration(seconds: 5));
    eq('no timers survive stop', host.startCalls, 1);
  });
}

Future<void> main() async {
  checkResolutionSelection();
  checkStreamSettings();
  checkCodecDecoding();
  checkCodecEncoding();
  checkUnrecognizedLog();
  await checkCameraProvider();
  await checkFrameStore();
  checkVideoChunkRecorder();

  print('');
  print('passed: $_passed, failed: ${_failures.length}');
  if (_failures.isNotEmpty) {
    exitCode = 1;
  }
}
