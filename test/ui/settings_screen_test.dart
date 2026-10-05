import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/backend/health_probe.dart';
import 'package:webcam_client/src/config/connection_settings.dart';
import 'package:webcam_client/src/ui/screens/settings_screen.dart';

const _creds = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
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
}
