import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:webcam_client/src/agent/agent_coordinator.dart';
import 'package:webcam_client/src/agent/agent_status.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/config/connection_settings.dart';
import 'package:webcam_client/src/config/settings_store.dart';
import 'package:webcam_client/src/ui/screens/agent_screen.dart';
import 'package:webcam_client/src/ui/screens/settings_screen.dart';
import 'package:webcam_client/src/ui/widgets/settings_button.dart';

import '../support/doubles.dart';

class MockCoordinator extends Mock implements AgentCoordinator {}

class _FakeSettingsStore implements SettingsStore {
  _FakeSettingsStore({this.baseUrl, this.credentials});

  Uri? baseUrl;
  DeviceCredentials? credentials;
  int baseUrlReads = 0;
  int credentialReads = 0;
  ConnectionSettings? saved;

  @override
  Future<Uri?> loadBaseUrl() async {
    baseUrlReads++;
    return baseUrl;
  }

  @override
  Future<DeviceCredentials?> loadCredentials() async {
    credentialReads++;
    return credentials;
  }

  @override
  Future<void> save(ConnectionSettings settings) async {
    saved = settings;
    baseUrl = settings.baseUrl;
    credentials = settings.credentials;
  }

  @override
  Future<void> clear() async {
    baseUrl = null;
    credentials = null;
  }
}

void main() {
  late MockCoordinator coordinator;
  late _FakeSettingsStore store;

  setUp(() {
    coordinator = MockCoordinator();
    store = _FakeSettingsStore(
      baseUrl: testConnection.baseUrl,
      credentials: testCredentials,
    );

    when(() => coordinator.status).thenReturn(AgentStatus.initial);
    when(() => coordinator.onStatus)
        .thenAnswer((_) => const Stream<AgentStatus>.empty());
    // No camera: the error screen is what a fresh install shows, and the
    // settings entry point has to be reachable from there too.
    when(() => coordinator.cameraService).thenReturn(null);
    when(() => coordinator.failure).thenReturn(const CameraFailure.noDevice());
    when(() => coordinator.connection).thenReturn(testConnection);
  });

  Widget host({
    SettingsStore? settingsStore,
    Future<void> Function(ConnectionSettings next)? onConnectionChanged,
  }) => MaterialApp(
    home: AgentScreen(
      coordinator: coordinator,
      settingsStore: settingsStore,
      onConnectionChanged: onConnectionChanged,
    ),
  );

  testWidgets('no settings entry point when the app is not wired for one', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    expect(find.byKey(SettingsButton.buttonKey), findsNothing);
  });

  testWidgets('the gear opens the settings screen seeded from the store', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(settingsStore: store, onConnectionChanged: (_) async {}),
    );

    expect(find.byKey(SettingsButton.buttonKey), findsOneWidget);
    await tester.tap(find.byKey(SettingsButton.buttonKey));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(store.baseUrlReads, 1);
    expect(store.credentialReads, 1);
    expect(
      tester
          .widget<TextField>(find.byKey(SettingsScreen.urlFieldKey))
          .controller!
          .text,
      testConnection.baseUrl.toString(),
    );
  });

  testWidgets('an unprovisioned device gets a red dot', (tester) async {
    when(() => coordinator.connection)
        .thenReturn(ConnectionSettings(baseUrl: Uri.parse(defaultBaseUrl)));

    await tester.pumpWidget(
      host(settingsStore: store, onConnectionChanged: (_) async {}),
    );

    expect(find.byKey(SettingsButton.alertDotKey), findsOneWidget);
  });

  testWidgets('a provisioned device does not', (tester) async {
    await tester.pumpWidget(
      host(settingsStore: store, onConnectionChanged: (_) async {}),
    );

    expect(find.byKey(SettingsButton.alertDotKey), findsNothing);
  });

  testWidgets('saving on the settings screen reaches the app callback', (
    tester,
  ) async {
    final received = <ConnectionSettings>[];

    await tester.pumpWidget(
      host(
        settingsStore: store,
        onConnectionChanged: (next) async => received.add(next),
      ),
    );

    await tester.tap(find.byKey(SettingsButton.buttonKey));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(SettingsScreen.urlFieldKey),
      'http://10.0.0.9:9000',
    );
    await tester.pump();
    await tester.tap(find.byKey(SettingsScreen.saveKey));
    await tester.pumpAndSettle();

    expect(received, hasLength(1));
    expect(received.single.baseUrl.toString(), 'http://10.0.0.9:9000');
    // Back on the kiosk screen.
    expect(find.byKey(SettingsButton.buttonKey), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });
}
