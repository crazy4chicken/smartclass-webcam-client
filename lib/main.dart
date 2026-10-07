import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'src/agent/agent_coordinator.dart';
import 'src/app/lifecycle_controller.dart';
import 'src/backend/backend_gateway.dart';
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
import 'src/capture/camera_service.dart';
import 'src/capture/codec_probe.dart';
import 'src/capture/frame_pump.dart';
import 'src/capture/stream_settings.dart';
import 'src/config/app_config.dart';
import 'src/config/connection_settings.dart';
import 'src/config/settings_store.dart';
import 'src/config/shared_prefs_settings_store.dart';
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
  // Unrecognised server messages go straight to the console: they are never
  // sent back, and they are the main diagnostic surface when the server and
  // the client disagree about the protocol.
  final unrecognized = UnrecognizedCommandLog(sink: debugPrint);

  // Where to connect and as whom. The store wins over `--dart-define`, which
  // wins over the built-in default — so an install no longer needs a fresh
  // build to be pointed at a different server.
  //
  // The two halves are loaded separately on purpose. `save()` means "make the
  // store match this exactly", so a settings object carrying no credentials
  // **deletes** the stored pair. Resolving them together would do exactly that
  // to an install upgrading from a build that stored credentials but no
  // address: it has nothing to load, so the seed would come out empty-handed.
  final settingsStore = SharedPrefsSettingsStore();
  final storedBaseUrl = await settingsStore.loadBaseUrl();
  final storedCredentials = await settingsStore.loadCredentials();

  var connection = resolveConnectionSettings(
    storedBaseUrl: storedBaseUrl,
    storedCredentials: storedCredentials,
    buildBaseUrl: AppConfig.baseUrl,
    buildDeviceId: AppConfig.deviceId,
    buildDeviceToken: AppConfig.deviceToken,
  );

  if (AppConfig.useMockBackend && !connection.isProvisioned) {
    connection = connection.copyWith(credentials: _mockCredentials);
  } else if (storedBaseUrl == null ||
      (storedCredentials == null && connection.credentials != null)) {
    // Seed only what is missing. Safe because `resolveConnectionSettings`
    // carried any stored credentials into `connection` — writing the address
    // therefore cannot take them away.
    await settingsStore.save(connection);
  }

  // A build-time pair of the wrong shape only gets one chance to be explained:
  // once it is seeded, the operator's own entry replaces it and there is no
  // longer anything to diagnose.
  const fromBuild = DeviceCredentials(
    deviceId: AppConfig.deviceId,
    deviceToken: AppConfig.deviceToken,
  );
  if (storedCredentials == null &&
      fromBuild.isConfigured &&
      !fromBuild.looksValid) {
    unrecognized.record(
      'DEVICE_ID / DEVICE_TOKEN do not look like a server-issued pair',
      UnrecognizedReason.invalidPayload,
    );
  }

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
  // Every camera is driven by the same [CaptureConfig], so one resolution is
  // the truth for all of them. The capability lists are empty here because the
  // probe has not run yet — `buildAnnouncements` then falls back to exactly the
  // current pair, which is the honest thing to say and, more importantly, is
  // something the server accepts. (Task 8 replaces this with the probed
  // inventory.)
  final announcedResolution =
      camera?.appliedResolution ?? captureConfig.resolution;
  final descriptors =
      camera?.cameras ??
      const <CameraDescriptor>[CameraDescriptor(name: 'camera', index: 0)];

  final announcements = buildAnnouncements(
    cameras: <CameraDeclaration>[
      for (final descriptor in descriptors)
        CameraDeclaration(
          name: descriptor.name,
          resolution: announcedResolution,
          fps: settings.fps,
        ),
    ],
    codecs: wireCodecsFor(available),
  );
  debugPrint('[register] announcing $announcements');

  // The gateway and the coordinator refer to each other: the gateway needs the
  // coordinator's live state for its periodic `status`, and the coordinator
  // needs the gateway to send anything. `late final` breaks the cycle without
  // a nullable field.
  late final AgentCoordinator coordinator;

  /// Builds one gateway per set of connection settings.
  ///
  /// `reconfigure` calls this again, so **the log instance must be shared**:
  /// a fresh `UnrecognizedCommandLog` per call would throw away the local
  /// record of every malformed message the moment an operator saved a setting.
  ///
  /// Known limitation: [announcements] is computed once, from the camera that
  /// is open at startup, and is **not** recomputed here. That is correct today
  /// because nothing in the settings screen changes the camera, resolution or
  /// fps. If those are ever added, they have to be rebuilt inside this factory
  /// — announcing a stale resolution is exactly the class of bug `45364b2`
  /// and `d81992b` fixed.
  BackendGateway buildGateway(ConnectionSettings c) {
    if (AppConfig.useMockBackend) {
      return MockBackendGateway(unrecognizedLog: unrecognized);
    }
    return SmartClassBackendGateway(
      base: c.baseUrl,
      registration: HttpRegistrationClient(),
      channelFactory: (uri) =>
          WebSocketBackendChannel(WebSocketChannel.connect(uri)),
      cameras: announcements,
      statusReport: () => coordinator.reportStatus(),
      unrecognizedLog: unrecognized,
    );
  }

  coordinator = AgentCoordinator(
    gatewayFactory: buildGateway,
    cameraProvider: cameraProvider,
    // A fresh pump per recording: a pump is bound to one stream for its life.
    pumpFactory: () {
      final service = coordinator.cameraService;
      if (service == null) {
        throw StateError('no camera is open');
      }
      return TakePictureFramePump(camera: service);
    },
    connection: connection,
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

  runApp(
    AgentApp(
      coordinator: coordinator,
      settingsStore: settingsStore,
      // Persist first, then reconnect: a power cut in between must not lose
      // what the operator just typed.
      onConnectionChanged: (next) async {
        await settingsStore.save(next);
        await coordinator.reconfigure(next);
      },
    ),
  );

  // Opens the camera and registers. The device pushes nothing until the server
  // sends `start_recording`.
  await coordinator.start();
}

/// Root widget. Kept tiny so tests can build it without touching bootstrap.
class AgentApp extends StatelessWidget {
  const AgentApp({
    super.key,
    required this.coordinator,
    this.settingsStore,
    this.onConnectionChanged,
  });

  final AgentCoordinator coordinator;

  /// When both this and [onConnectionChanged] are supplied, the kiosk screen
  /// grows a settings entry point. Both are optional so existing tests can
  /// build the app without a store.
  final SettingsStore? settingsStore;

  final Future<void> Function(ConnectionSettings next)? onConnectionChanged;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebCam Edge Probe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: AgentScreen(
        coordinator: coordinator,
        settingsStore: settingsStore,
        onConnectionChanged: onConnectionChanged,
      ),
    );
  }
}
