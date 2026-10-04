import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'src/agent/agent_coordinator.dart';
import 'src/app/lifecycle_controller.dart';
import 'src/backend/backend_gateway.dart';
import 'src/backend/command_codec.dart';
import 'src/backend/mock_backend_gateway.dart';
import 'src/backend/unrecognized_command_log.dart';
import 'src/backend/websocket_backend_gateway.dart';
import 'src/capture/camera_backend.dart';
import 'src/capture/camera_plugin_backend.dart';
import 'src/capture/camera_provider.dart';
import 'src/capture/video_chunk_recorder.dart';
import 'src/config/app_config.dart';
import 'src/identity/device_id_service.dart';
import 'src/ui/screens/agent_screen.dart';

/// The ordered camera backend chain.
///
/// `camera` + `camera_desktop` covers all five platforms. A future native-HEVC
/// or ffmpeg backend is added here and nowhere else.
List<CameraBackend> buildBackendChain({
  CameraPluginVideoChunkRecorder? recorder,
}) {
  return <CameraBackend>[
    CameraPluginBackend(recorder: recorder),
  ];
}

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
  final deviceIdService = DeviceIdService();
  final deviceId = await deviceIdService.getOrCreateDeviceId();

  // Unrecognised backend messages go straight to the console: while the
  // protocol is not final this is the main diagnostic surface.
  final unrecognized = UnrecognizedCommandLog(sink: debugPrint);

  final BackendGateway gateway = AppConfig.useMockBackend
      ? MockBackendGateway()
      : WebSocketBackendGateway(
          codec: JsonCommandCodec(unrecognizedLog: unrecognized),
          channelFactory: WebSocketChannel.connect,
          deviceId: deviceId,
        );

  final recorder = CameraPluginVideoChunkRecorder();
  final coordinator = AgentCoordinator(
    cameraProvider:
        CameraProvider(backends: buildBackendChain(recorder: recorder)),
    gateway: gateway,
    deviceIdService: deviceIdService,
    recorder: recorder,
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

  // Capture starts on local defaults; the backend only steers it later.
  await coordinator.start();
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
