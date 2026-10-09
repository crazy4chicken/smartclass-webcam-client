import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'src/agent/agent_coordinator.dart';
import 'src/app/capability_bootstrap.dart';
import 'src/app/lifecycle_controller.dart';
import 'src/backend/backend_gateway.dart';
import 'src/backend/device_credentials.dart';
import 'src/backend/mock_backend_gateway.dart';
import 'src/backend/registration_client.dart';
import 'src/backend/registration_request.dart';
import 'src/backend/smartclass_backend_gateway.dart';
import 'src/backend/unrecognized_command_log.dart';
import 'src/capture/camera_backend.dart';
import 'src/capture/camera_capabilities.dart';
import 'src/capture/camera_plugin_backend.dart';
import 'src/capture/camera_provider.dart';
import 'src/capture/camera_resolution.dart';
import 'src/capture/codec_probe.dart';
import 'src/capture/frame_pump.dart';
import 'src/capture/plugin_camera_ranker.dart';
import 'src/capture/plugin_capability_probe.dart';
import 'src/capture/stream_settings.dart';
import 'src/config/app_config.dart';
import 'src/config/capabilities_store.dart';
import 'src/config/connection_settings.dart';
import 'src/config/settings_store.dart';
import 'src/config/shared_prefs_capabilities_store.dart';
import 'src/config/shared_prefs_settings_store.dart';
import 'src/ui/screens/agent_screen.dart';
import 'src/ui/screens/bootstrap_screen.dart';

/// The ordered camera backend chain.
///
/// `camera` + `camera_desktop` covers all five platforms. A future native or
/// ffmpeg encoder is added here and nowhere else.
///
/// [cameraOrder] is the announced → physical permutation the capability probe
/// produced. Null keeps the identity mapping, which is what a caller with no
/// inventory — and every test — wants.
List<CameraBackend> buildBackendChain({List<int>? cameraOrder}) {
  return <CameraBackend>[CameraPluginBackend(cameraOrder: cameraOrder)];
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
  final captureConfig = CaptureConfig.defaults();
  final capabilitiesStore = SharedPrefsCapabilitiesStore();

  // `runApp` is called **once**, with a root that probes first. Probing before
  // `runApp` would mean a black window for as long as the cameras take to rank
  // and measure — ten seconds on a three-camera machine, which reads as a
  // crashed app.
  runApp(
    BootstrapRoot(
      probe: () => ensureInventory(
        enumerate: pluginCameraEnumerator(),
        ranker: PluginCameraRanker(),
        probe: PluginCapabilityProbe(),
        store: capabilitiesStore,
        fallbackResolution: captureConfig.resolution,
        fallbackFps: settings.fps,
        log: debugPrint,
      ),
      build: (inventory) => _startKiosk(
        inventory: inventory,
        unrecognized: unrecognized,
        settingsStore: settingsStore,
        capabilitiesStore: capabilitiesStore,
        connection: connection,
        settings: settings,
        available: available,
        captureConfig: captureConfig,
      ),
    ),
  );
}

/// Opens a camera and assembles the running kiosk.
///
/// Separate from [_bootstrap] because it can only run once the inventory
/// exists: the announced camera list and the backend's permutation both come
/// from it, and they have to agree or the server would be asking for one camera
/// while the device opened another.
Future<Widget> _startKiosk({
  required CameraInventory inventory,
  required UnrecognizedCommandLog unrecognized,
  required SettingsStore settingsStore,
  required CapabilitiesStore capabilitiesStore,
  required ConnectionSettings connection,
  required StreamSettings settings,
  required Set<CaptureCodec> available,
  required CaptureConfig captureConfig,
}) async {
  debugPrint('[camera] inventory: $inventory');

  // Open at camera 0's measured ceiling. `CaptureConfig` is the only source
  // of truth for what the pipeline is built at, and camera 0's announced mode
  // must agree with it or the registration would describe a geometry the
  // device never opened. A probe that found nothing keeps the build default —
  // the same pair the probe folded into every declared list.
  final camera0Ceiling = inventory.capabilities.isEmpty
      ? null
      : inventory.capabilities.first.highestResolution;
  final openConfig = camera0Ceiling == null
      ? captureConfig
      : captureConfig.copyWith(
          width: camera0Ceiling.width,
          height: camera0Ceiling.height,
        );

  final cameraProvider = CameraProvider(
    backends: buildBackendChain(cameraOrder: inventory.order),
  );
  final openResult = await cameraProvider.open(openConfig);
  final camera = openResult.service;
  if (camera == null) {
    debugPrint('[camera] no backend available: ${openResult.failure}');
  }

  // The announced codecs, in preference order. Derived from `wireCodecsFor`
  // rather than ordered again here, so the capture-layer list and the wire list
  // cannot disagree — that is the whole reason `wireCodecsFor` exists instead
  // of a cast.
  final announcedCodecs = <CaptureCodec>[
    for (final codec in wireCodecsFor(available))
      CaptureCodec.tryParse(codec.wireName)!,
  ];

  /// The live inventory. A re-probe replaces it, and the gateway factory reads
  /// it at registration time.
  ///
  /// Mutable for one reason: a re-probe can change the canonical **order**, and
  /// the announcements and the backend's permutation have to change together or
  /// the server would be asking for a camera the backend does not have. See
  /// [applyInventory] for the ordering that keeps them in step.
  var currentInventory = inventory;

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
  /// The announcements are produced **inside a callback**, and that is
  /// load-bearing twice over.
  ///
  /// First, it is what makes a parameter-changing `switch_camera` visible to
  /// the server: it reconnects through `reconfigure`, which comes back through
  /// this factory, and the registration then carries the mode the device is
  /// actually in. Building them once at start-up was the documented limitation
  /// that let a local-only switch leave the server's `metadata` snapshot
  /// describing a mode the device had left — the class of bug `45364b2` and
  /// `d81992b` fixed.
  ///
  /// Second, it is the only thing that makes the construction order work. The
  /// coordinator builds its gateway **inside its own constructor**, so this
  /// factory runs while `coordinator` is still an unassigned `late final`.
  /// Reading it here would be a `LateInitializationError` — and because it
  /// happens inside the awaited start-up path, the symptom is not a crash but a
  /// kiosk stuck on the splash screen. Deferring to registration time means the
  /// coordinator is fully built by the time anything is read from it.
  BackendGateway buildGateway(ConnectionSettings c) {
    if (AppConfig.useMockBackend) {
      return MockBackendGateway(unrecognizedLog: unrecognized);
    }
    return SmartClassBackendGateway(
      base: c.baseUrl,
      registration: HttpRegistrationClient(),
      channelFactory: (uri) =>
          WebSocketBackendChannel(WebSocketChannel.connect(uri)),
      cameras: () => buildAnnouncements(
        cameras: _declarations(currentInventory, coordinator, openConfig),
        codecs: wireCodecsFor(available),
      ),
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
    config: openConfig,
    settings: settings,
    capabilities: inventory.capabilities,
    announcedCodecs: announcedCodecs,
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

  // Opens the camera and registers. The device pushes nothing until the server
  // sends `start_recording`. Deliberately not awaited: the kiosk screen renders
  // from `coordinator.status` immediately and reports the link as it settles,
  // which is friendlier than holding the progress screen through a registration
  // round trip.
  unawaited(coordinator.start());

  /// Re-probes every camera and adopts the result.
  ///
  /// **The order of the first two statements is load-bearing.** `adoptInventory`
  /// reconnects, and the gateway factory reads `currentInventory` when it builds
  /// the registration — so the new inventory has to be in place *before* the
  /// reconnect, or the device would publish a camera order its backend does not
  /// implement. Swapping them is a one-line change with no compile-time signal
  /// and a failure that only shows up as the server opening the wrong camera.
  Future<CameraInventory> applyInventory() async {
    final fresh = await ensureInventory(
      enumerate: pluginCameraEnumerator(),
      ranker: PluginCameraRanker(),
      probe: PluginCapabilityProbe(),
      store: capabilitiesStore,
      fallbackResolution: captureConfig.resolution,
      fallbackFps: settings.fps,
      // The operator pressed a button; a cached answer would be a lie.
      forceReprobe: true,
      log: debugPrint,
    );

    currentInventory = fresh;
    await coordinator.adoptInventory(
      cameraProvider: CameraProvider(
        backends: buildBackendChain(cameraOrder: fresh.order),
      ),
      capabilities: fresh.capabilities,
    );
    return fresh;
  }

  return AgentApp(
    coordinator: coordinator,
    settingsStore: settingsStore,
    // Persist first, then reconnect: a power cut in between must not lose
    // what the operator just typed.
    onConnectionChanged: (next) async {
      await settingsStore.save(next);
      await coordinator.reconfigure(next);
    },
    onRefreshCapabilities: applyInventory,
  );
}

/// One declaration per announced camera, from the coordinator's live state.
///
/// [captureConfig] is only the floor for an index past the end of the mode list,
/// which the inventory makes unreachable — but the cost of being wrong is a
/// registration the server refuses, so the fallback stays.
List<CameraDeclaration> _declarations(
  CameraInventory inventory,
  AgentCoordinator coordinator,
  CaptureConfig captureConfig,
) {
  final descriptors = inventory.descriptors;
  final modes = coordinator.cameraModes;
  final capabilities = coordinator.capabilities;
  final liveFps = coordinator.settings.fps;

  if (descriptors.isEmpty) {
    // No camera at all. Registering one synthetic entry beats not registering:
    // the operator sees the device online and can fix it from the settings
    // screen, which is exactly what a fresh install shows.
    return <CameraDeclaration>[
      CameraDeclaration(
        name: 'camera',
        resolution: captureConfig.resolution,
        fps: liveFps,
      ),
    ];
  }

  return <CameraDeclaration>[
    for (var announced = 0; announced < descriptors.length; announced++)
      CameraDeclaration(
        name: descriptors[announced].name,
        resolution: announced < modes.length
            ? modes[announced].resolution
            : captureConfig.resolution,
        fps: announced < modes.length ? modes[announced].fps : liveFps,
        capabilities: announced < capabilities.length
            ? capabilities[announced]
            : CameraCapabilities.empty,
      ),
  ];
}

/// The root widget: probes the cameras, then hands the kiosk what it found.
///
/// The probe runs inside the tree rather than before `runApp`, which is what
/// lets [BootstrapScreen] be the first thing the operator sees instead of a
/// black window.
class BootstrapRoot extends StatefulWidget {
  const BootstrapRoot({super.key, required this.probe, required this.build});

  /// Runs the capability probe. Called once, from [BootstrapScreen].
  final Future<CameraInventory> Function() probe;

  /// Builds the kiosk once the inventory is known. Slow — it opens the camera —
  /// so the progress screen stays up until it returns.
  final Future<Widget> Function(CameraInventory inventory) build;

  @override
  State<BootstrapRoot> createState() => _BootstrapRootState();
}

class _BootstrapRootState extends State<BootstrapRoot> {
  Widget? _app;
  CameraInventory? _inventory;
  String? _failure;

  Future<void> _onInventory(CameraInventory inventory) async {
    _inventory = inventory;
    try {
      final app = await widget.build(inventory);
      if (!mounted) return;
      setState(() {
        _app = app;
        _failure = null;
      });
    } catch (error, stack) {
      // A throw here used to leave the device on the splash screen forever,
      // showing the last progress line — which, because the probe had already
      // succeeded, read as "detected 2 cameras" and looked like success. That
      // is exactly how the `LateInitializationError` in the gateway factory
      // presented itself on a real Android device.
      //
      // Nothing may take the kiosk down silently, so say what happened and
      // offer a retry.
      debugPrint('[bootstrap] could not start the kiosk: $error');
      debugPrint('$stack');
      if (!mounted) return;
      setState(() => _failure = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Cached rather than rebuilt: a second call to `widget.build` would open a
    // second camera and build a second coordinator.
    final app = _app;
    if (app != null) return app;

    final failure = _failure;
    final inventory = _inventory;
    if (failure != null) {
      return MaterialApp(
        title: 'WebCam Edge Probe',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: BootstrapFailureView(
          message: failure,
          onRetry: inventory == null
              ? null
              : () {
                  setState(() => _failure = null);
                  unawaited(_onInventory(inventory));
                },
        ),
      );
    }

    return MaterialApp(
      title: 'WebCam Edge Probe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: BootstrapScreen(
        run: widget.probe,
        onDone: (inventory) => unawaited(_onInventory(inventory)),
      ),
    );
  }
}

/// Root widget. Kept tiny so tests can build it without touching bootstrap.
class AgentApp extends StatelessWidget {
  const AgentApp({
    super.key,
    required this.coordinator,
    this.settingsStore,
    this.onConnectionChanged,
    this.onRefreshCapabilities,
  });

  final AgentCoordinator coordinator;

  /// When both this and [onConnectionChanged] are supplied, the kiosk screen
  /// grows a settings entry point. Both are optional so existing tests can
  /// build the app without a store.
  final SettingsStore? settingsStore;

  final Future<void> Function(ConnectionSettings next)? onConnectionChanged;

  /// Runs a forced camera re-probe from the settings screen.
  final Future<CameraInventory> Function()? onRefreshCapabilities;

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
        onRefreshCapabilities: onRefreshCapabilities,
      ),
    );
  }
}
