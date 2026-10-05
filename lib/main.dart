import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'src/agent/agent_coordinator.dart';
import 'src/app/lifecycle_controller.dart';
import 'src/backend/backend_gateway.dart';
import 'src/backend/credential_store.dart';
import 'src/backend/device_credentials.dart';
import 'src/backend/mock_backend_gateway.dart';
import 'src/backend/registration_client.dart';
import 'src/backend/registration_request.dart';
import 'src/backend/smartclass_backend_gateway.dart';
import 'src/backend/unrecognized_command_log.dart';
import 'src/capture/camera_backend.dart';
import 'src/capture/camera_plugin_backend.dart';
import 'src/capture/camera_provider.dart';
import 'src/capture/camera_resolution.dart';
import 'src/capture/codec_probe.dart';
import 'src/capture/frame_pump.dart';
import 'src/capture/stream_settings.dart';
import 'src/config/app_config.dart';
import 'src/ui/screens/agent_screen.dart';

/// The ordered camera backend chain.
///
/// `camera` + `camera_desktop` covers all five platforms. A future native or
/// ffmpeg encoder is added here and nowhere else.
List<CameraBackend> buildBackendChain() {
  return <CameraBackend>[CameraPluginBackend()];
}

/// Used only when `USE_MOCK_BACKEND` is on, so the offline path needs no
/// provisioning.
const DeviceCredentials _mockCredentials = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };

  await runZonedGuarded(_bootstrap, (error, stack) {
    // Nothing may take the kiosk down silently.
    debugPrint('[uncaught] $error');
    debugPrint('$stack');
  });
}

Future<void> _bootstrap() async {
  final base = Uri.parse(AppConfig.baseUrl);

  // Unrecognised server messages go straight to the console: they are never
  // sent back, and they are the main diagnostic surface when the server and
  // the client disagree about the protocol.
  final unrecognized = UnrecognizedCommandLog(sink: debugPrint);

  final credentials = await _resolveCredentials(
    SharedPrefsCredentialStore(),
    unrecognized,
  );

  // Which codecs this device can produce is measured, not assumed. Today the
  // only probe is the baseline one — JPEG from the still-picture path — so the
  // selection lands on `mjpeg`, which the server defines as exactly that.
  final available = await CompositeCodecProbe(
    probes: [const BaselineCodecProbe()],
  ).availableCodecs();
  final codec = await CodecSelector(probe: StaticCodecProbe(available))
      .select();
  debugPrint(
    '[codec] available=${available.map((c) => c.wireName).join(",")} '
    'selected=${codec.wireName}',
  );

  final settings = StreamSettings.defaults().copyWith(codec: codec);

  // The camera is opened before the gateway is built, because the camera list
  // has to be announced on registration.
  final cameraProvider = CameraProvider(backends: buildBackendChain());
  final captureConfig = CaptureConfig.defaults();
  final openResult = await cameraProvider.open(captureConfig);
  final camera = openResult.service;
  if (camera == null) {
    debugPrint('[camera] no backend available: ${openResult.failure}');
  }

  // Announce what this device will actually deliver, not a capability ladder.
  //
  // `supportedResolutions` is the nominal ladder `[640x480, 1280x720, …]`, and
  // passing it positionally handed camera 0 the *lowest* rung: the server was
  // told 640x480 for a stream that is really 1280x720, and that value is what
  // gets snapshotted into the stream's `metadata.resolution`. Every camera is
  // driven by the same [CaptureConfig], so one resolution is the truth for all
  // of them — and a single-element list is exactly how `buildAnnouncements`
  // expresses "same for every camera".
  final announcedResolution =
      camera?.appliedResolution ?? captureConfig.resolution;

  final announcements = buildAnnouncements(
    cameraNames:
        camera?.cameras.map((c) => c.name).toList() ?? const <String>['camera'],
    resolutions: <CameraResolution>[announcedResolution],
    fps: settings.fps,
    codecs: wireCodecsFor(available),
  );
  debugPrint('[register] announcing $announcements');

  // The gateway and the coordinator refer to each other: the gateway needs the
  // coordinator's live state for its periodic `status`, and the coordinator
  // needs the gateway to send anything. `late final` breaks the cycle without
  // a nullable field.
  late final AgentCoordinator coordinator;

  final BackendGateway gateway;
  if (AppConfig.useMockBackend) {
    gateway = MockBackendGateway(unrecognizedLog: unrecognized);
  } else {
    gateway = SmartClassBackendGateway(
      base: base,
      registration: HttpRegistrationClient(),
      channelFactory: (uri) =>
          WebSocketBackendChannel(WebSocketChannel.connect(uri)),
      cameras: announcements,
      statusReport: () => coordinator.reportStatus(),
      unrecognizedLog: unrecognized,
    );
  }

  coordinator = AgentCoordinator(
    gateway: gateway,
    cameraProvider: cameraProvider,
    // A fresh pump per recording: a pump is bound to one stream for its life.
    pumpFactory: () {
      final service = coordinator.cameraService;
      if (service == null) {
        throw StateError('no camera is open');
      }
      return TakePictureFramePump(camera: service);
    },
    credentials: credentials,
    initialCamera: camera,
    initialBackendId: openResult.backendId,
    settings: settings,
    // The server never waits for an ack and records nothing about most
    // commands, so the console is the only place a refusal is visible. Without
    // this, a device that acks `ok:false` looks identical to one that ignored
    // the command entirely.
    log: debugPrint,
  );

  try {
    // A kiosk must never dim or lock.
    await WakelockPlus.enable();
  } catch (_) {
    // Not fatal: some platforms/desktops simply do not support it.
  }

  LifecycleController(
    onPause: coordinator.pause,
    onResume: coordinator.resume,
  ).attach();

  runApp(AgentApp(coordinator: coordinator));

  // Opens the camera and registers. The device pushes nothing until the server
  // sends `start_recording`.
  await coordinator.start();
}

/// Prefers a stored credential, falls back to `--dart-define`, and promotes a
/// build-time credential into the store so the next launch is provisioned.
Future<DeviceCredentials?> _resolveCredentials(
  CredentialStore store,
  UnrecognizedCommandLog unrecognized,
) async {
  final stored = await store.load();
  if (stored != null && stored.isConfigured) return stored;

  const fromBuild = DeviceCredentials(
    deviceId: AppConfig.deviceId,
    deviceToken: AppConfig.deviceToken,
  );

  if (fromBuild.isConfigured) {
    if (!fromBuild.looksValid) {
      unrecognized.record(
        'DEVICE_ID / DEVICE_TOKEN do not look like a server-issued pair',
        UnrecognizedReason.invalidPayload,
      );
    }
    await store.save(fromBuild);
    return fromBuild;
  }

  if (AppConfig.useMockBackend) return _mockCredentials;

  debugPrint(
    '[credentials] none configured. Pass --dart-define=DEVICE_ID=… and '
    '--dart-define=DEVICE_TOKEN=… (both issued by POST /api/devices).',
  );
  return null;
}

/// Root widget. Kept tiny so tests can build it without touching bootstrap.
class AgentApp extends StatelessWidget {
  const AgentApp({super.key, required this.coordinator});

  final AgentCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebCam Edge Probe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: AgentScreen(coordinator: coordinator),
    );
  }
}
