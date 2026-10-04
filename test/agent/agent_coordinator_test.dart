import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:webcam_client/src/agent/agent_coordinator.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/client_signal.dart';
import 'package:webcam_client/src/backend/server_command.dart';
import 'package:webcam_client/src/backend/unrecognized_command_log.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/capture/camera_plugin_backend.dart';
import 'package:webcam_client/src/capture/camera_provider.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/video_chunk_recorder.dart';
import 'package:webcam_client/src/identity/device_id_service.dart';

class MockCameraService extends Mock implements CameraService {}

class MockBackendGateway extends Mock implements BackendGateway {}

class MockVideoChunkRecorder extends Mock implements VideoChunkRecorder {}

class _FakeDeviceIdService extends DeviceIdService {
  @override
  Future<String> getOrCreateDeviceId() async => 'test-device';
}

class _FixedBackend implements CameraBackend {
  _FixedBackend(this._service);

  final CameraService _service;

  @override
  String get id => 'test_backend';

  @override
  Future<BackendProbe> probe() async =>
      const BackendProbe(available: true, maxFps: 30, supportsPreview: true);

  @override
  Future<CameraService> open(CaptureConfig config) async => _service;
}

AgentCoordinator _build(
  CameraService camera,
  BackendGateway gateway, {
  VideoChunkRecorder? recorder,
  Duration? registerTimeout,
}) {
  when(() => camera.isInitialized).thenReturn(true);
  when(() => camera.appliedResolution)
      .thenReturn(const CameraResolution(width: 1280, height: 720));
  when(() => camera.descriptor)
      .thenReturn(const CameraDescriptor(name: 'Test Camera', index: 0));
  when(() => camera.cameras).thenReturn(const []);
  when(() => camera.cameraIndex).thenReturn(0);
  when(() => camera.supportedResolutions).thenReturn(kNominalResolutions);
  when(() => camera.previewEnabled).thenReturn(true);
  when(() => camera.health)
      .thenAnswer((_) => const Stream<CameraHealth>.empty());
  when(() => camera.initialize()).thenAnswer((_) async {});
  when(() => camera.release()).thenAnswer((_) async {});
  when(() => camera.setPreviewEnabled(any())).thenAnswer((_) async {});
  when(() => camera.reconfigure(any())).thenAnswer((_) async {});
  when(() => camera.switchCamera(any())).thenAnswer((_) async {});
  when(() => camera.captureFrame(any()))
      .thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));

  when(() => gateway.commands)
      .thenAnswer((_) => const Stream<ServerCommand>.empty());
  when(() => gateway.connectionChanges)
      .thenAnswer((_) => const Stream<ConnectionState>.empty());
  when(() => gateway.unrecognizedCommands)
      .thenReturn(UnrecognizedCommandLog(sink: null));
  when(() => gateway.connect(any())).thenAnswer((_) async {});
  when(() => gateway.disconnect()).thenAnswer((_) async {});

  if (recorder != null) {
    when(() => recorder.supportedCodecs).thenReturn({VideoCodec.avc});
    when(() => recorder.chunks)
        .thenAnswer((_) => const Stream<VideoChunk>.empty());
    when(
      () => recorder.start(
        codec: any(named: 'codec'),
        chunkSeconds: any(named: 'chunkSeconds'),
        config: any(named: 'config'),
      ),
    ).thenAnswer((_) async {});
    when(() => recorder.stop()).thenAnswer((_) async {});
  }

  return AgentCoordinator(
    cameraProvider: CameraProvider(backends: [_FixedBackend(camera)]),
    gateway: gateway,
    deviceIdService: _FakeDeviceIdService(),
    recorder: recorder,
    registerTimeout: registerTimeout ?? const Duration(seconds: 5),
  );
}

void main() {
  setUpAll(() {
    // mocktail resolves fallbacks by `is`-check, so one concrete signal covers
    // the whole ClientSignal parameter type.
    registerFallbackValue(const HeartbeatSignal(deviceId: 'fallback'));
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(
      const FrameMeta(
        frameId: 0,
        deviceId: '',
        timestampMs: 0,
        width: 0,
        height: 0,
        quality: 0,
      ),
    );
    registerFallbackValue(
      const VideoMeta(
        chunkId: 0,
        deviceId: '',
        timestampMs: 0,
        codec: VideoCodec.avc,
        sequence: 0,
        durationMs: 0,
        width: 0,
        height: 0,
      ),
    );
    registerFallbackValue(CaptureConfig.defaults());
    registerFallbackValue(VideoCodec.avc);
  });

  test('drops the second frame while the first upload is in flight', () async {
    final camera = MockCameraService();
    final gw = MockBackendGateway();
    final co = _build(camera, gw);
    when(() => camera.captureFrame(any())).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return Uint8List.fromList([1, 2, 3]);
    });

    final f1 = co.performCaptureTick();
    final f2 = co.performCaptureTick();
    await Future.wait([f1, f2]);

    verify(() => camera.captureFrame(any())).called(1);
    verify(() => gw.sendFrameBytes(any())).called(1);
  });

  test(
    'releases the in-flight lock in finally even when capture throws',
    () async {
      final camera = MockCameraService();
      final co = _build(camera, MockBackendGateway());
      when(() => camera.captureFrame(any()))
          .thenThrow(StateError('camera died'));

      await expectLater(co.performCaptureTick(), returnsNormally);
      await co.performCaptureTick();

      verify(() => camera.captureFrame(any())).called(2);
    },
  );

  test('sends frame_meta before every binary frame', () async {
    final camera = MockCameraService();
    final gw = MockBackendGateway();
    final co = _build(camera, gw);
    when(() => camera.captureFrame(any()))
        .thenAnswer((_) async => Uint8List.fromList([1]));

    await co.performCaptureTick();

    verifyInOrder([
      () => gw.sendFrameMeta(any()),
      () => gw.sendFrameBytes(any()),
    ]);
  });

  test(
    'video mode uploads chunks with video_meta and reports codec mismatch',
    () async {
      final gw = MockBackendGateway();
      final recorder = MockVideoChunkRecorder();
      final co = _build(MockCameraService(), gw, recorder: recorder);
      when(() => recorder.chunks).thenAnswer(
        (_) => Stream<VideoChunk>.fromIterable([
          VideoChunk(
            bytes: Uint8List.fromList([1]),
            codec: VideoCodec.avc,
            requestedCodec: VideoCodec.hevc,
            sequence: 0,
            durationMs: 3000,
            width: 1280,
            height: 720,
          ),
        ]),
      );

      co.handleCommand(
        const SetStreamModeCommand(
          mode: StreamMode.video,
          codec: VideoCodec.hevc,
        ),
      );
      await pumpEventQueue();

      verify(() => gw.sendVideoMeta(any())).called(greaterThan(0));
      verify(() => gw.sendVideoBytes(any())).called(greaterThan(0));
      verify(() => gw.sendSignal(any(that: isA<CapabilityMismatchSignal>())))
          .called(1);
    },
  );

  test(
    'preview command toggles the camera service, not the capture loop',
    () async {
      final camera = MockCameraService();
      final co = _build(camera, MockBackendGateway());

      co.handleCommand(const SetPreviewCommand(enabled: false));
      await pumpEventQueue();

      verify(() => camera.setPreviewEnabled(false)).called(1);
      expect(co.settings.previewEnabled, isFalse);
      expect(co.isStreaming, isTrue);
    },
  );

  test('routes each command type to the right collaborator', () async {
    final camera = MockCameraService();
    final co = _build(camera, MockBackendGateway());

    co.handleCommand(
      const UpdateConfigCommand(width: 640, height: 480, fps: 4),
    );
    co.handleCommand(const ControlStreamCommand(enabled: false));
    co.handleCommand(const SwitchCameraCommand(index: 1));
    await pumpEventQueue();

    verify(() => camera.reconfigure(any())).called(1);
    expect(co.isStreaming, isFalse);
    verify(() => camera.switchCamera(1)).called(1);
  });

  test('face results are forwarded to the UI stream', () async {
    final co = _build(MockCameraService(), MockBackendGateway());

    final expectation = expectLater(
      co.onFaceResult,
      emits(predicate<FaceResult>((r) => r.name == '张三')),
    );
    co.handleCommand(
      FaceResultCommand(
        result: const FaceResult(name: '张三', status: 'approved'),
      ),
    );
    await expectation;
  });

  test('re-syncs every mutable setting after a reconnect', () async {
    final gw = MockBackendGateway();
    final camera = MockCameraService();
    final co = _build(camera, gw);

    await co.onGatewayConnectionChanged(ConnectionState.connected);
    await pumpEventQueue();

    verify(() => gw.sendSignal(any(that: isA<RegisterSignal>())))
        .called(greaterThan(0));
    final sync =
        verify(() => gw.sendSignal(captureAny(that: isA<StateSyncSignal>())))
                .captured
                .single
            as StateSyncSignal;
    expect(sync.mode, StreamMode.video);
    expect(sync.codec, VideoCodec.avc);
    expect(sync.previewEnabled, isTrue);
    expect(sync.width, 1280);
    expect(sync.height, 720);
  });

  test(
    'goes autonomous when no command arrives within the register timeout',
    () async {
      final co = _build(
        MockCameraService(),
        MockBackendGateway(),
        registerTimeout: const Duration(milliseconds: 10),
      );

      await co.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(co.isAutonomous, isTrue);
      expect(co.isStreaming, isTrue);

      await co.stop();
    },
  );

  test('pause releases the camera and drops the connection', () async {
    final camera = MockCameraService();
    final gw = MockBackendGateway();
    final co = _build(camera, gw);

    await co.start();
    await co.pause();

    verify(() => camera.release()).called(greaterThan(0));
    verify(() => gw.disconnect()).called(greaterThan(0));

    await co.stop();
  });
}
