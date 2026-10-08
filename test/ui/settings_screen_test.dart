import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/app/capability_bootstrap.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/backend/health_probe.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/capability_report.dart';
import 'package:webcam_client/src/config/connection_settings.dart';
import 'package:webcam_client/src/ui/screens/capabilities_screen.dart';
import 'package:webcam_client/src/ui/screens/settings_screen.dart';

const _creds = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

final CameraInventory _inventory = CameraInventory(
  descriptors: const [
    CameraDescriptor(name: 'back', index: 0, lensDirection: 'back'),
    CameraDescriptor(name: 'front', index: 1, lensDirection: 'front'),
  ],
  order: const [1, 0],
  capabilities: [
    CameraCapabilities.of(
      resolutions: const [
        CameraResolution(width: 1920, height: 1080),
        CameraResolution(width: 1280, height: 720),
      ],
      framerates: const [30],
    ),
    CameraCapabilities.of(
      resolutions: const [CameraResolution(width: 640, height: 480)],
      framerates: const [30],
    ),
  ],
);

/// The report the settings screen hands to the capability page, built from the
/// same fixture the re-detect tests use so the two cannot disagree.
List<CameraCapabilityReport> _capabilityReport({
  int active = 0,
}) => buildCapabilityReport(
  cameras: _inventory.descriptors,
  modes: const [
    CameraMode(resolution: CameraResolution(width: 1280, height: 720), fps: 15),
    CameraMode(resolution: CameraResolution(width: 640, height: 480), fps: 5),
  ],
  declared: _inventory.capabilities,
  activeCameraEnum: active,
);

class _FakeProbe implements HealthProbe {
  _FakeProbe(this.result);

  final HealthProbeResult result;
  Uri? lastBase;

  @override
  Future<HealthProbeResult> probe(Uri base) async {
    lastBase = base;
    return result;
  }
}

/// Pumps a host route with a button that opens the settings screen, because
/// saving pops — and a pop needs somewhere to go back to.
Future<List<ConnectionSettings>> _open(
  WidgetTester tester, {
  ConnectionSettings? initial,
  bool isRecording = false,
  LinkState linkState = LinkState.idle,
  HealthProbe? probe,
  Future<CameraInventory> Function()? onRefreshCapabilities,
  List<CameraCapabilityReport> Function()? readCapabilities,
}) async {
  // A tall surface so every field and button is laid out and hit-testable; the
  // default 800x600 would push the action row out of the viewport.
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final saved = <ConnectionSettings>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(
                    initial:
                        initial ??
                        ConnectionSettings(
                          baseUrl: Uri.parse('http://127.0.0.1:8080'),
                          credentials: _creds,
                        ),
                    isRecording: isRecording,
                    linkState: linkState,
                    probe: probe,
                    onRefreshCapabilities: onRefreshCapabilities,
                    readCapabilities: readCapabilities,
                    onSaved: (next) async => saved.add(next),
                  ),
                ),
              ),
              child: const Text('open settings'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open settings'));
  await tester.pumpAndSettle();
  return saved;
}

/// Whether the re-detect button can be pressed.
bool _refreshEnabled(WidgetTester tester) =>
    tester
        .widget<OutlinedButton>(
          find.byKey(SettingsScreen.refreshCapabilitiesKey),
        )
        .onPressed !=
    null;

void main() {
  testWidgets('the fields are seeded from the current settings', (
    tester,
  ) async {
    await _open(tester);

    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.urlFieldKey))
          .controller!
          .text,
      'http://127.0.0.1:8080',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.deviceIdFieldKey))
          .controller!
          .text,
      _creds.deviceId,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.tokenFieldKey))
          .controller!
          .text,
      _creds.deviceToken,
    );
  });

  testWidgets('a bad address is explained and blocks saving', (tester) async {
    await _open(tester);

    await tester.enterText(find.byKey(SettingsScreen.urlFieldKey), 'http://');
    await tester.pump();

    expect(find.byKey(SettingsScreen.urlErrorKey), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(SettingsScreen.saveKey)).onPressed,
      isNull,
      reason: 'the button must be disabled, not complain after a tap',
    );

    await tester.enterText(
      find.byKey(SettingsScreen.urlFieldKey),
      '192.168.1.20:8080',
    );
    await tester.pump();

    expect(find.byKey(SettingsScreen.urlErrorKey), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byKey(SettingsScreen.saveKey)).onPressed,
      isNotNull,
    );
  });

  testWidgets('half a credential is reported on the field that is empty', (
    tester,
  ) async {
    await _open(tester);

    // Token cleared, device id still filled in.
    await tester.enterText(find.byKey(SettingsScreen.tokenFieldKey), '');
    await tester.pump();

    expect(find.byKey(SettingsScreen.tokenErrorKey), findsOneWidget);
    expect(
      find.byKey(SettingsScreen.deviceIdErrorKey),
      findsNothing,
      reason: 'the device id is not what is wrong',
    );
    expect(
      tester.widget<FilledButton>(find.byKey(SettingsScreen.saveKey)).onPressed,
      isNull,
    );

    // The other way round: the token is back, the device id is gone.
    await tester.enterText(
      find.byKey(SettingsScreen.tokenFieldKey),
      _creds.deviceToken,
    );
    await tester.enterText(find.byKey(SettingsScreen.deviceIdFieldKey), '');
    await tester.pump();

    expect(find.byKey(SettingsScreen.deviceIdErrorKey), findsOneWidget);
    expect(find.byKey(SettingsScreen.tokenErrorKey), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byKey(SettingsScreen.saveKey)).onPressed,
      isNull,
    );
  });

  testWidgets('the token is masked until the eye is pressed', (tester) async {
    await _open(tester);

    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.tokenFieldKey))
          .obscureText,
      isTrue,
      reason: 'it is a live credential and is written to plain-text prefs',
    );

    await tester.tap(find.byKey(SettingsScreen.tokenVisibilityKey));
    await tester.pump();

    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.tokenFieldKey))
          .obscureText,
      isFalse,
    );
  });

  testWidgets('saving hands back the trimmed and normalised values', (
    tester,
  ) async {
    final saved = await _open(tester);

    await tester.enterText(
      find.byKey(SettingsScreen.urlFieldKey),
      '  192.168.1.20:8080/  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(SettingsScreen.saveKey));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.baseUrl.toString(), 'http://192.168.1.20:8080');
    expect(saved.single.credentials?.deviceId, _creds.deviceId);
    // The screen is gone: the kiosk comes back immediately.
    expect(find.byKey(SettingsScreen.saveKey), findsNothing);
  });

  // Split in two rather than pumping twice in one test: the second `pumpWidget`
  // would update the same `MaterialApp` element, so the first screen would
  // still be sitting on the navigator.
  testWidgets('no recording warning when nothing is being recorded', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byKey(SettingsScreen.recordingBannerKey), findsNothing);
  });

  testWidgets('the recording warning is shown while recording', (tester) async {
    await _open(tester, isRecording: true);
    expect(find.byKey(SettingsScreen.recordingBannerKey), findsOneWidget);
    expect(find.textContaining('failed'), findsOneWidget);
  });

  testWidgets('the current link state is shown so a change can be confirmed', (
    tester,
  ) async {
    await _open(tester, linkState: LinkState.failed);
    expect(find.byKey(SettingsScreen.linkStatusKey), findsOneWidget);
    expect(find.textContaining('链路失败'), findsOneWidget);
  });

  testWidgets(
    'reset restores the build-time address but keeps the credentials',
    (tester) async {
      await _open(
        tester,
        initial: ConnectionSettings(
          baseUrl: Uri.parse('http://10.0.0.9:9000'),
          credentials: _creds,
        ),
      );

      await tester.tap(find.byKey(SettingsScreen.resetKey));
      await tester.pump();

      expect(
        tester
            .widget<TextField>(find.byKey(SettingsScreen.urlFieldKey))
            .controller!
            .text,
        defaultBaseUrl,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(SettingsScreen.deviceIdFieldKey))
            .controller!
            .text,
        _creds.deviceId,
      );
    },
  );

  testWidgets('clearing credentials empties both fields', (tester) async {
    await _open(tester);

    await tester.tap(find.byKey(SettingsScreen.clearCredentialsKey));
    await tester.pump();

    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.deviceIdFieldKey))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.tokenFieldKey))
          .controller!
          .text,
      isEmpty,
    );
    // Still saveable: an unprovisioned device is a legitimate state, and the
    // status bar already explains what is wrong.
    expect(
      tester.widget<FilledButton>(find.byKey(SettingsScreen.saveKey)).onPressed,
      isNotNull,
    );
  });

  testWidgets('the probe result is reported and does not block saving', (
    tester,
  ) async {
    final probe = _FakeProbe(
      const HealthProbeResult(reachable: true, statusCode: 200),
    );
    await _open(tester, probe: probe);

    await tester.enterText(
      find.byKey(SettingsScreen.urlFieldKey),
      'http://10.0.0.9:9000',
    );
    await tester.pump();
    await tester.tap(find.byKey(SettingsScreen.probeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(SettingsScreen.probeResultKey), findsOneWidget);
    expect(find.textContaining('可达'), findsOneWidget);
    expect(
      probe.lastBase.toString(),
      'http://10.0.0.9:9000',
      reason: 'the probe uses what is typed, not what is saved',
    );
  });

  group('re-detect cameras', () {
    testWidgets('the button is absent when no probe is wired up', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byKey(SettingsScreen.refreshCapabilitiesKey), findsNothing);
    });

    testWidgets('a refresh button is present and enabled when idle', (
      tester,
    ) async {
      await _open(tester, onRefreshCapabilities: () async => _inventory);

      expect(find.byKey(SettingsScreen.refreshCapabilitiesKey), findsOneWidget);
      expect(_refreshEnabled(tester), isTrue);
      expect(find.text('重新检测'), findsOneWidget);
    });

    testWidgets(
      'the refresh button is disabled while the device is recording',
      (tester) async {
        // Re-probing reopens every camera, which would kill a live stream — the
        // same hazard the banner above warns about, except this one is
        // preventable by simply not offering the button.
        await _open(
          tester,
          isRecording: true,
          onRefreshCapabilities: () async => _inventory,
        );

        expect(
          find.byKey(SettingsScreen.refreshCapabilitiesKey),
          findsOneWidget,
        );
        expect(_refreshEnabled(tester), isFalse);
      },
    );

    testWidgets('tapping it runs the probe and reports the outcome', (
      tester,
    ) async {
      var calls = 0;
      await _open(
        tester,
        onRefreshCapabilities: () async {
          calls++;
          return _inventory;
        },
      );

      await tester.tap(find.byKey(SettingsScreen.refreshCapabilitiesKey));
      await tester.pump();
      await tester.pump();

      expect(calls, 1);
      expect(find.byKey(SettingsScreen.refreshResultKey), findsOneWidget);
      expect(find.textContaining('2 个摄像头'), findsOneWidget);
      // Two cameras, three resolutions between them.
      expect(find.textContaining('3 个分辨率'), findsOneWidget);
      expect(_refreshEnabled(tester), isTrue);
    });

    testWidgets('a failed probe reports a message instead of failing silently', (
      tester,
    ) async {
      // The probe swallows its own errors by design, so without this the only
      // visible result of a broken camera would be a button that does nothing.
      await _open(
        tester,
        onRefreshCapabilities: () async => throw StateError('camera exploded'),
      );

      await tester.tap(find.byKey(SettingsScreen.refreshCapabilitiesKey));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(SettingsScreen.refreshResultKey), findsOneWidget);
      expect(find.textContaining('检测失败'), findsOneWidget);
      expect(find.textContaining('camera exploded'), findsOneWidget);
      // The button comes back, so a second attempt is possible.
      expect(_refreshEnabled(tester), isTrue);
    });

    testWidgets('a probe that finds nothing says so and does not crash', (
      tester,
    ) async {
      await _open(
        tester,
        onRefreshCapabilities: () async => CameraInventory.empty,
      );

      await tester.tap(find.byKey(SettingsScreen.refreshCapabilitiesKey));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('未检测到摄像头'), findsOneWidget);
    });

    testWidgets('every tap probes again, so what gets persisted is fresh', (
      tester,
    ) async {
      // The callback is what re-probes and writes the cache; short-circuiting
      // on a previous result here would leave the next connection announcing a
      // measurement the operator has already replaced.
      var calls = 0;
      await _open(
        tester,
        onRefreshCapabilities: () async {
          calls++;
          return _inventory;
        },
      );

      await tester.tap(find.byKey(SettingsScreen.refreshCapabilitiesKey));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(SettingsScreen.refreshCapabilitiesKey));
      await tester.pump();
      await tester.pump();

      expect(calls, 2);
    });

    testWidgets('the re-detect result does not disturb the connection fields', (
      tester,
    ) async {
      await _open(tester, onRefreshCapabilities: () async => _inventory);

      await tester.tap(find.byKey(SettingsScreen.refreshCapabilitiesKey));
      await tester.pump();
      await tester.pump();

      // Capabilities are a different kind of fact from the connection: a probe
      // must never be able to touch the address or the credentials.
      expect(
        tester
            .widget<TextField>(find.byKey(SettingsScreen.urlFieldKey))
            .controller!
            .text,
        'http://127.0.0.1:8080',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(SettingsScreen.tokenFieldKey))
            .controller!
            .text,
        _creds.deviceToken,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(SettingsScreen.saveKey))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('the capability page', () {
    testWidgets('opens from the action row and lists what was measured', (
      tester,
    ) async {
      await _open(tester, readCapabilities: _capabilityReport);

      await tester.tap(find.byKey(SettingsScreen.viewCapabilitiesKey));
      await tester.pumpAndSettle();

      expect(find.byType(CapabilitiesScreen), findsOneWidget);
      expect(find.byKey(CapabilitiesScreen.cameraKey(0)), findsOneWidget);
      expect(find.text('back'), findsOneWidget);
      expect(find.text('front'), findsOneWidget);
    });

    testWidgets('is absent when nothing can supply it', (tester) async {
      // A screen built without a coordinator — the mock-backend path, or a
      // test — must not render a button that opens an empty page.
      await _open(tester);
      expect(find.byKey(SettingsScreen.viewCapabilitiesKey), findsNothing);
    });

    testWidgets('reads fresh data on every tap', (tester) async {
      // The report is a callback rather than a snapshot: a re-detect can happen
      // while this screen is open, and a stale list would contradict the result
      // line sitting right above it.
      var calls = 0;
      await _open(
        tester,
        readCapabilities: () {
          calls++;
          return _capabilityReport(active: calls - 1);
        },
      );

      await tester.tap(find.byKey(SettingsScreen.viewCapabilitiesKey));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
        find.descendant(
          of: find.byKey(CapabilitiesScreen.cameraKey(0)),
          matching: find.text('使用中'),
        ),
        findsOneWidget,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SettingsScreen.viewCapabilitiesKey));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(
        find.descendant(
          of: find.byKey(CapabilitiesScreen.cameraKey(1)),
          matching: find.text('使用中'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('stays reachable while recording, unlike a re-detect', (
      tester,
    ) async {
      // Reading a page cannot disturb a live stream, so it must not inherit the
      // re-detect button's recording lockout.
      await _open(
        tester,
        isRecording: true,
        onRefreshCapabilities: () async => _inventory,
        readCapabilities: _capabilityReport,
      );

      expect(_refreshEnabled(tester), isFalse);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(SettingsScreen.viewCapabilitiesKey),
            )
            .onPressed,
        isNotNull,
      );
    });
  });
}
