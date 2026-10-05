import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:webcam_client/src/agent/agent_coordinator.dart';
import 'package:webcam_client/src/agent/agent_status.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/protocol/device_command.dart';
import 'package:webcam_client/src/backend/protocol/device_message.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/capture/camera_provider.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/frame_pump.dart';
import 'package:webcam_client/src/config/connection_settings.dart';

import '../support/doubles.dart';

/// A backend that always probes and opens successfully.
class _StubBackend implements CameraBackend {
  _StubBackend(this.service);

  final CameraService service;

  @override
  String get id => 'stub';

  @override
  Future<BackendProbe> probe() async => const BackendProbe(
    available: true,
    devices: [],
    supportedResolutions: [],
    maxFps: 30,
    supportsPreview: true,
  );

  @override
  Future<CameraService> open(CaptureConfig config) async => service;
}

/// A gateway double with the baseline behaviour every test wants: an empty,
/// already-live link.
MockGateway _stubbedGateway() {
  final gateway = MockGateway();
  when(() => gateway.commands).thenAnswer((_) => const Stream.empty());
  when(() => gateway.states).thenAnswer((_) => const Stream.empty());
  when(() => gateway.errors).thenAnswer((_) => const Stream.empty());
  when(() => gateway.state).thenReturn(LinkState.live);
  when(() => gateway.start(any())).thenAnswer((_) async {});
  when(() => gateway.stop()).thenAnswer((_) async {});
  return gateway;
}

/// Hands out a fresh gateway per call, recording what it was asked for.
///
/// A real factory has to build a new instance each time — re-pointing a gateway
/// that latched `_stopped` on a `401` would never retry — so the double does
/// the same and keeps the evidence.
class _GatewayFactory {
  _GatewayFactory({this.onBuild});

  /// Lets a test customise the instance before the coordinator sees it.
  final void Function(MockGateway gateway)? onBuild;

  final List<ConnectionSettings> requested = <ConnectionSettings>[];
  final List<MockGateway> built = <MockGateway>[];

  BackendGateway call(ConnectionSettings connection) {
    requested.add(connection);
    final gateway = _stubbedGateway();
    onBuild?.call(gateway);
    built.add(gateway);
    return gateway;
  }
}

void main() {
  setUpAll(registerCommonFallbacks);

  late MockGateway gateway;
  late MockCameraService camera;
  late MockFramePump pump;

  setUp(() {
    gateway = _stubbedGateway();
    camera = MockCameraService();
    pump = MockFramePump();

    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.cameraIndex).thenReturn(0);
    when(
      () => camera.descriptor,
    ).thenReturn(const CameraDescriptor(name: 'Integrated Camera', index: 0));
    when(() => camera.health).thenAnswer((_) => const Stream.empty());
    when(() => camera.switchCamera(any())).thenAnswer((_) async {});
    when(() => camera.setPreviewEnabled(any())).thenAnswer((_) async {});
    when(() => camera.release()).thenAnswer((_) async {});

    when(() => pump.frames).thenAnswer((_) => const Stream.empty());
    when(
      () => pump.start(
        cameraEnum: any(named: 'cameraEnum'),
        streamId: any(named: 'streamId'),
        fps: any(named: 'fps'),
        quality: any(named: 'quality'),
      ),
    ).thenAnswer((_) async {});
    when(() => pump.stop()).thenAnswer((_) async {});
  });

  /// A coordinator holding an already-open camera, the way bootstrap builds it.
  AgentCoordinator build({CameraService? service}) => AgentCoordinator(
    gatewayFactory: (_) => gateway,
    cameraProvider: CameraProvider(backends: [_StubBackend(service ?? camera)]),
    pumpFactory: () => pump,
    connection: testConnection,
    initialCamera: service ?? camera,
    initialBackendId: 'stub',
  );

  group('command routing', () {
    test('acks start_recording and pumps frames tagged with the stream id', () async {
      when(() => pump.frames).thenAnswer(
        (_) => Stream.fromIterable([
          CapturedFrame(
            seq: 0,
            ts: DateTime.utc(2026),
            bytes: Uint8List.fromList([1]),
          ),
          CapturedFrame(
            seq: 1,
            ts: DateTime.utc(2026),
            bytes: Uint8List.fromList([2]),
          ),
        ]),
      );

      final coordinator = build();
      await coordinator.handleCommand(
        const StartRecordingCommand(
          id: '01J8ZKQ3B5N7P9R1T3V5X7Z9B1',
          cameraEnum: 0,
          streamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
        ),
      );
      // Frame delivery is asynchronous even for a synchronous iterable, so let
      // the stream drain before counting what was pushed.
      await pumpEventQueue();

      final ack =
          verify(() => gateway.send(captureAny())).captured.single
              as AckMessage;
      expect(ack.id, '01J8ZKQ3B5N7P9R1T3V5X7Z9B1');
      expect(ack.ok, isTrue);

      verify(
        () => pump.start(
          cameraEnum: 0,
          streamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
          fps: any(named: 'fps'),
          quality: any(named: 'quality'),
        ),
      ).called(1);

      expect(coordinator.captureState, CaptureState.recording);
      expect(coordinator.activeStreamId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');

      final frames = verify(
        () => gateway.sendRecordingFrame(captureAny(), captureAny()),
      ).captured;
      final meta = frames.first as RecordingFrameMeta;
      expect(meta.streamId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
      expect(meta.cameraEnum, 0);
      expect(frames, hasLength(4)); // two frames, each as meta + bytes
    });

    test(
      'stop_recording halts the pump and stops pushing immediately',
      () async {
        final coordinator = build();
        await coordinator.handleCommand(
          const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
        );
        await coordinator.handleCommand(
          const StopRecordingCommand(id: 'b', cameraEnum: 0, streamId: 's'),
        );

        verify(() => pump.stop()).called(1);
        expect(coordinator.captureState, CaptureState.idle);
        expect(coordinator.activeStreamId, isNull);

        // Both commands were acked; nothing was silently dropped.
        final acks = verify(() => gateway.send(captureAny())).captured
            .cast<AckMessage>();
        expect(acks.map((a) => a.id), ['a', 'b']);
        expect(acks.every((a) => a.ok), isTrue);
      },
    );

    test(
      'a second start_recording is refused rather than double-pumped',
      () async {
        final coordinator = build();
        await coordinator.handleCommand(
          const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's1'),
        );
        await coordinator.handleCommand(
          const StartRecordingCommand(id: 'b', cameraEnum: 0, streamId: 's2'),
        );

        final acks = verify(() => gateway.send(captureAny())).captured
            .cast<AckMessage>();
        expect(acks.last.id, 'b');
        expect(acks.last.ok, isFalse);
        expect(acks.last.error, isNotNull);
        expect(coordinator.activeStreamId, 's1');
        verify(
          () => pump.start(
            cameraEnum: any(named: 'cameraEnum'),
            streamId: any(named: 'streamId'),
            fps: any(named: 'fps'),
            quality: any(named: 'quality'),
          ),
        ).called(1);
      },
    );

    test('take_photo uploads one photo carrying the request id', () async {
      when(() => camera.captureFrame(any()))
          .thenAnswer((_) async => Uint8List.fromList([0xFF, 0xD8]));

      final coordinator = build();
      await coordinator.handleCommand(
        const TakePhotoCommand(
          id: 'c',
          cameraEnum: 0,
          requestId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B3',
        ),
      );

      final meta =
          verify(() => gateway.sendPhoto(captureAny(), captureAny()))
                  .captured
                  .first
              as PhotoMeta;
      expect(meta.requestId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B3');
      expect(meta.contentType, 'image/jpeg');
      expect(meta.cameraEnum, 0);

      final ack =
          verify(() => gateway.send(captureAny())).captured.single
              as AckMessage;
      expect(ack.ok, isTrue);
      expect(coordinator.captureState, CaptureState.idle);
    });

    test('a command the device cannot run is acked with ok false, never '
        'dropped', () async {
      when(() => camera.isInitialized).thenReturn(false);

      final coordinator = build();
      await coordinator.handleCommand(
        const TakePhotoCommand(id: 'd', cameraEnum: 0, requestId: 'r'),
      );

      final ack =
          verify(() => gateway.send(captureAny())).captured.single
              as AckMessage;
      expect(ack.id, 'd');
      expect(ack.ok, isFalse);
      expect(ack.error, isNotNull);
    });

    test('switch_camera reconfigures the active camera and acks', () async {
      final coordinator = build();
      await coordinator.handleCommand(
        const SwitchCameraCommand(id: 'e', cameraEnum: 1),
      );

      verify(() => camera.switchCamera(1)).called(1);
      expect(coordinator.cameraEnum, 1);

      final ack =
          verify(() => gateway.send(captureAny())).captured.single
              as AckMessage;
      expect(ack.ok, isTrue);
    });

    test('switch_camera is refused while a stream is live', () async {
      final coordinator = build();
      await coordinator.handleCommand(
        const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
      );
      await coordinator.handleCommand(
        const SwitchCameraCommand(id: 'e', cameraEnum: 1),
      );

      verifyNever(() => camera.switchCamera(any()));
      final acks = verify(() => gateway.send(captureAny())).captured
          .cast<AckMessage>();
      expect(acks.last.id, 'e');
      expect(acks.last.ok, isFalse);
    });

    test(
      'a camera failure during switch is acked rather than thrown',
      () async {
        when(() => camera.switchCamera(any()))
            .thenThrow(StateError('camera 1 is busy'));

        final coordinator = build();
        await coordinator.handleCommand(
          const SwitchCameraCommand(id: 'e', cameraEnum: 1),
        );

        final ack =
            verify(() => gateway.send(captureAny())).captured.single
                as AckMessage;
        expect(ack.ok, isFalse);
        expect(ack.error, contains('busy'));
      },
    );

    test('ping is not acked — the gateway already answered it', () async {
      final coordinator = build();
      await coordinator.handleCommand(const PingCommand(ts: 't'));
      verifyNever(() => gateway.send(any()));
    });
  });

  group('link behaviour', () {
    test('start() opens the camera and the link but pushes nothing', () async {
      final coordinator = build();
      await coordinator.start();

      verify(() => gateway.start(testCredentials)).called(1);
      expect(coordinator.captureState, CaptureState.idle);
      expect(coordinator.activeStreamId, isNull);
      verifyNever(() => gateway.sendRecordingFrame(any(), any()));
    });

    test('missing credentials fail the link instead of crashing', () async {
      final coordinator = AgentCoordinator(
        gatewayFactory: (_) => gateway,
        cameraProvider: CameraProvider(backends: [_StubBackend(camera)]),
        pumpFactory: () => pump,
        connection: ConnectionSettings(baseUrl: Uri.parse(defaultBaseUrl)),
        initialCamera: camera,
      );

      await coordinator.start();

      expect(coordinator.linkState, LinkState.failed);
      expect(coordinator.status.lastError, isNotNull);
      verifyNever(() => gateway.start(any()));
    });

    test('losing the link aborts the recording', () async {
      final states = StreamController<LinkState>();
      when(() => gateway.states).thenAnswer((_) => states.stream);

      final coordinator = build();
      await coordinator.start();
      await coordinator.handleCommand(
        const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
      );
      expect(coordinator.captureState, CaptureState.recording);

      // The server marks an interrupted stream failed and never resumes it, so
      // there is nothing left to push into.
      states.add(LinkState.backoff);
      await pumpEventQueue();

      expect(coordinator.captureState, CaptureState.idle);
      expect(coordinator.activeStreamId, isNull);
      verify(() => pump.stop()).called(1);

      unawaited(states.close());
    });

    test('a gateway error surfaces in the status', () async {
      final errors = StreamController<String>();
      when(() => gateway.errors).thenAnswer((_) => errors.stream);

      final coordinator = build();
      await coordinator.start();

      errors.add('单帧超过 16 MiB');
      await pumpEventQueue();

      expect(coordinator.status.lastError, contains('16 MiB'));
      unawaited(errors.close());
    });

    test('pause stops media, releases the camera and drops the link', () async {
      final coordinator = build();
      await coordinator.start();
      await coordinator.handleCommand(
        const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
      );
      await coordinator.pause();

      verify(() => pump.stop()).called(1);
      verify(() => camera.release()).called(1);
      verify(() => gateway.stop()).called(1);
      expect(coordinator.captureState, CaptureState.idle);
      expect(coordinator.activeStreamId, isNull);
    });
  });

  group('reconfigure', () {
    /// A coordinator built on a factory, so the swap can be observed.
    ({AgentCoordinator coordinator, _GatewayFactory factory}) buildWithFactory({
      void Function(MockGateway gateway)? onBuild,
      ConnectionSettings? connection,
    }) {
      final factory = _GatewayFactory(onBuild: onBuild);
      final coordinator = AgentCoordinator(
        gatewayFactory: factory,
        cameraProvider: CameraProvider(backends: [_StubBackend(camera)]),
        pumpFactory: () => pump,
        connection: connection ?? testConnection,
        initialCamera: camera,
        initialBackendId: 'stub',
      );
      return (coordinator: coordinator, factory: factory);
    }

    test('swaps the gateway rather than mutating it', () async {
      final h = buildWithFactory();
      await h.coordinator.start();

      expect(h.factory.built, hasLength(1));
      final first = h.factory.built.single;

      final moved = ConnectionSettings(
        baseUrl: Uri.parse('http://10.0.0.9:9000'),
        credentials: testCredentials,
      );
      await h.coordinator.reconfigure(moved);

      expect(h.factory.built, hasLength(2));
      expect(
        h.factory.requested.last.baseUrl.toString(),
        'http://10.0.0.9:9000',
        reason: 'the new instance must be built for the new address',
      );
      verify(() => first.stop()).called(1);
      verify(() => h.factory.built.last.start(any())).called(1);
      expect(
        h.coordinator.connection.baseUrl.toString(),
        'http://10.0.0.9:9000',
      );
      expect(h.coordinator.linkState, LinkState.live);
    });

    test('cuts a live recording and resets the frame counter', () async {
      final h = buildWithFactory();
      await h.coordinator.start();
      await h.coordinator.handleCommand(
        const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
      );
      expect(h.coordinator.captureState, CaptureState.recording);

      await h.coordinator.reconfigure(testConnection);

      verify(() => pump.stop()).called(1);
      expect(h.coordinator.captureState, CaptureState.idle);
      expect(h.coordinator.activeStreamId, isNull);
      expect(h.coordinator.framesSent, 0);
    });

    test('the retired gateway can no longer be heard', () async {
      // Each instance gets its own error stream, so the test can talk to the
      // retired one specifically.
      final errors = <StreamController<String>>[];
      final h = buildWithFactory(
        onBuild: (g) {
          final controller = StreamController<String>();
          errors.add(controller);
          when(() => g.errors).thenAnswer((_) => controller.stream);
        },
      );
      await h.coordinator.start();

      await h.coordinator.reconfigure(testConnection);
      expect(errors, hasLength(2));

      // Two live subscriptions would mean the same command handled twice, and
      // therefore two acks for one id.
      errors.first.add('from the retired gateway');
      await pumpEventQueue();
      expect(h.coordinator.status.lastError, isNull);

      errors.last.add('from the live gateway');
      await pumpEventQueue();
      expect(h.coordinator.status.lastError, 'from the live gateway');

      unawaited(errors.first.close());
      unawaited(errors.last.close());
    });

    test(
      'missing credentials fail the link and point at the settings screen',
      () async {
        final h = buildWithFactory();
        await h.coordinator.start();

        await h.coordinator.reconfigure(
          ConnectionSettings(baseUrl: Uri.parse(defaultBaseUrl)),
        );

        expect(h.coordinator.linkState, LinkState.failed);
        expect(h.coordinator.status.lastError, contains('设置'));
        verifyNever(() => h.factory.built.last.start(any()));
      },
    );

    test('a terminal 401 is recovered by the new instance', () async {
      // The real gateway latches `_stopped` on a 401 and never retries, so a
      // setter on the old instance could never bring it back. This is the test
      // that guards the "rebuild, don't mutate" decision.
      final states = StreamController<LinkState>();
      final h = buildWithFactory(
        onBuild: (g) => when(() => g.states).thenAnswer((_) => states.stream),
      );
      await h.coordinator.start();

      states.add(LinkState.failed);
      await pumpEventQueue();
      expect(h.coordinator.linkState, LinkState.failed);

      await h.coordinator.reconfigure(testConnection);

      expect(h.factory.built, hasLength(2));
      expect(h.coordinator.linkState, isNot(LinkState.failed));
      expect(h.coordinator.linkState, LinkState.live);

      unawaited(states.close());
    });
  });

  group('status', () {
    test('carries the announced rate and the live stream', () async {
      final coordinator = build();
      await coordinator.handleCommand(
        const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
      );

      final status = coordinator.status;
      expect(status.captureState, CaptureState.recording);
      expect(status.activeStreamId, 's');
      expect(status.cameraName, 'Integrated Camera');
      expect(status.fps, coordinator.announcedFps);
      expect(status.fps, greaterThan(0));
    });

    test(
      'the preview toggle is local and never touches the capture state',
      () async {
        final coordinator = build();
        await coordinator.setPreviewEnabled(false);

        verify(() => camera.setPreviewEnabled(false)).called(1);
        expect(coordinator.settings.previewEnabled, isFalse);
        // Turning the preview off must not stop the device answering commands.
        expect(coordinator.captureState, CaptureState.idle);
      },
    );

    test('reportStatus is what the gateway sends as an idle status', () async {
      final coordinator = build();
      await coordinator.handleCommand(
        const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
      );

      final report = coordinator.reportStatus();
      expect(report['recording'], isTrue);
      expect(report['stream_id'], 's');
      expect(report['active_camera'], 0);
    });

    test('status updates are emitted to listeners', () async {
      final coordinator = build();
      final seen = <AgentStatus>[];
      final subscription = coordinator.onStatus.listen(seen.add);

      await coordinator.handleCommand(
        const StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'),
      );
      await pumpEventQueue();

      expect(seen, isNotEmpty);
      expect(seen.last.captureState, CaptureState.recording);
      await subscription.cancel();
    });
  });
}
