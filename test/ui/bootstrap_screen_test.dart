import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/app/capability_bootstrap.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/ui/screens/bootstrap_screen.dart';

final CameraInventory _inventory = CameraInventory(
  descriptors: const [
    CameraDescriptor(name: 'back', index: 0, lensDirection: 'back'),
    CameraDescriptor(name: 'front', index: 1, lensDirection: 'front'),
  ],
  order: const [1, 0],
  capabilities: [
    CameraCapabilities.of(
      resolutions: const [CameraResolution(width: 1920, height: 1080)],
      framerates: const [30],
    ),
    CameraCapabilities.of(
      resolutions: const [CameraResolution(width: 1280, height: 720)],
      framerates: const [30],
    ),
  ],
);

/// Hosts the screen without swapping it out, so the outcome message stays on
/// screen for the test to read. `main.dart` swaps in the kiosk instead.
Widget _host({
  required Future<CameraInventory> Function() run,
  required ValueChanged<CameraInventory> onDone,
}) => MaterialApp(
  home: BootstrapScreen(run: run, onDone: onDone),
);

void main() {
  testWidgets('shows progress while probing', (tester) async {
    final gate = Completer<CameraInventory>();
    await tester.pumpWidget(_host(run: () => gate.future, onDone: (_) {}));
    await tester.pump();

    expect(find.byKey(BootstrapScreen.progressKey), findsOneWidget);
    expect(find.byKey(BootstrapScreen.statusKey), findsOneWidget);
    // A kiosk that boots to a black screen for ten seconds looks broken; this
    // is what it shows instead.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('正在检测'), findsOneWidget);

    // Let it finish so the indeterminate animation does not outlive the test.
    gate.complete(_inventory);
    await tester.pump();
    await tester.pump();
  });

  testWidgets('calls onDone with the inventory when the probe finishes', (
    tester,
  ) async {
    final received = <CameraInventory>[];
    await tester.pumpWidget(
      _host(run: () async => _inventory, onDone: received.add),
    );
    await tester.pump();
    await tester.pump();

    expect(received, hasLength(1));
    expect(received.single.descriptors.map((d) => d.name).toList(), [
      'back',
      'front',
    ]);
    expect(find.textContaining('检测到 2 个摄像头'), findsOneWidget);
  });

  testWidgets('calls onDone exactly once', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(run: () async => _inventory, onDone: (_) => calls++),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(calls, 1);
  });

  testWidgets(
    'shows a message and still completes when the probe finds nothing',
    (tester) async {
      // The one thing this screen must never do is strand the kiosk: no camera is
      // a situation the kiosk screen already handles, and the settings screen is
      // reachable from there.
      final received = <CameraInventory>[];
      await tester.pumpWidget(
        _host(run: () async => CameraInventory.empty, onDone: received.add),
      );
      await tester.pump();
      await tester.pump();

      expect(received, hasLength(1));
      expect(received.single.isEmpty, isTrue);
      expect(find.textContaining('未检测到摄像头'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('a probe that throws still completes', (tester) async {
    // The probe is not supposed to throw. If it ever does, a spinner that never
    // stops is the worst possible outcome.
    final received = <CameraInventory>[];
    await tester.pumpWidget(
      _host(
        run: () async => throw StateError('camera subsystem exploded'),
        onDone: received.add,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(received, hasLength(1));
    expect(received.single.isEmpty, isTrue);
    expect(find.textContaining('检测失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
