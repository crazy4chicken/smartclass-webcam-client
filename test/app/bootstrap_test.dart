import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webcam_client/main.dart';
import 'package:webcam_client/src/app/capability_bootstrap.dart';
import 'package:webcam_client/src/backend/credential_store.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/config/app_config.dart';
import 'package:webcam_client/src/ui/screens/bootstrap_screen.dart';

const _creds = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppConfig', () {
    test('base url is injected at build time and is not hardcoded', () {
      expect(AppConfig.baseUrl, isNotEmpty);
      expect(AppConfig.baseUrl, startsWith('http'));
    });

    test('capture defaults are sane', () {
      expect(AppConfig.defaultWidth, 1280);
      expect(AppConfig.defaultHeight, 720);
      expect(AppConfig.defaultQuality, inInclusiveRange(1, 100));
      expect(AppConfig.defaultPreviewEnabled, isTrue);
    });

    test('the declared rate is a positive whole number', () {
      // The server rejects `29.97` outright, so this can never be a double.
      expect(AppConfig.defaultFps, greaterThan(0));
      expect(AppConfig.defaultFps, isA<int>());
    });

    test('the mock backend is off unless it is asked for', () {
      expect(AppConfig.useMockBackend, isFalse);
    });
  });

  group('bootstrap', () {
    test('the camera chain starts with camera_desktop', () {
      expect(buildBackendChain().first.id, 'camera_desktop');
    });

    test('an empty credential set is reported as missing, not blank', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SharedPrefsCredentialStore().load(), isNull);
    });

    test('credentials round-trip through the store', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPrefsCredentialStore();

      await store.save(_creds);
      final loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.deviceId, _creds.deviceId);
      expect(loaded.deviceToken, startsWith('wdt_'));
    });
  });

  group('BootstrapRoot', () {
    testWidgets('swaps in the kiosk once the inventory is known', (
      tester,
    ) async {
      await tester.pumpWidget(
        BootstrapRoot(
          probe: () async => CameraInventory.empty,
          build: (_) async => const MaterialApp(home: Text('kiosk')),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('kiosk'), findsOneWidget);
    });

    testWidgets('reports a failed start instead of stalling on the splash', (
      tester,
    ) async {
      // The bug this guards: the probe succeeds, the splash shows "detected N
      // cameras", and then a throw inside the kiosk build leaves the device
      // there forever — looking exactly like a successful start.
      await tester.pumpWidget(
        BootstrapRoot(
          probe: () async => CameraInventory.empty,
          build: (_) async => throw StateError('LateInitializationError'),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(BootstrapFailureView.messageKey), findsOneWidget);
      expect(find.textContaining('LateInitializationError'), findsOneWidget);
      expect(find.text('kiosk'), findsNothing);
      // And there is a way out.
      expect(find.byKey(const Key('bootstrap-retry')), findsOneWidget);
    });

    testWidgets('retrying a failed start calls build again', (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        BootstrapRoot(
          probe: () async => CameraInventory.empty,
          build: (_) async {
            attempts++;
            if (attempts == 1) throw StateError('first time unlucky');
            return const MaterialApp(home: Text('kiosk'));
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(attempts, 1);

      await tester.tap(find.byKey(const Key('bootstrap-retry')));
      await tester.pump();
      await tester.pump();

      expect(attempts, 2);
      expect(find.text('kiosk'), findsOneWidget);
    });
  });
}
