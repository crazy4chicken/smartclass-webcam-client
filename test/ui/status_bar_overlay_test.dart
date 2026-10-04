import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/agent/agent_status.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/ui/widgets/status_bar_overlay.dart';

void main() {
  testWidgets('renders mode, fps, resolution and the preview toggle',
      (tester) async {
    var toggled = false;
    const status = AgentStatus(
      connection: ConnectionState.connected,
      fps: 2.0,
      cameraName: 'Integrated Camera',
      streaming: true,
      autonomous: true,
      resolutionLabel: '1280x720',
      streamModeLabel: '视频·AVC',
      previewEnabled: true,
      backendId: 'camera_desktop',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatusBarOverlay(
          status: status,
          onPreviewToggle: (_) => toggled = true,
        ),
      ),
    ));

    expect(find.textContaining('1280x720'), findsOneWidget);
    expect(find.textContaining('视频·AVC'), findsOneWidget);
    expect(find.textContaining('Integrated Camera'), findsOneWidget);

    await tester.tap(find.byKey(const Key('preview-toggle')));
    expect(toggled, isTrue);
  });

  testWidgets('keeps a recording indicator visible even when preview is off',
      (tester) async {
    const status = AgentStatus(
      connection: ConnectionState.connected,
      fps: 2.0,
      cameraName: 'cam',
      streaming: true,
      autonomous: false,
      resolutionLabel: '1280x720',
      streamModeLabel: '视频·AVC',
      previewEnabled: false,
      backendId: 'camera_desktop',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatusBarOverlay(status: status, onPreviewToggle: (_) {}),
      ),
    ));

    expect(find.textContaining('采集进行中'), findsOneWidget);
  });

  testWidgets('the toggle reports the desired new state, not the current one',
      (tester) async {
    bool? requested;
    const status = AgentStatus(
      connection: ConnectionState.connected,
      fps: 1.0,
      cameraName: 'cam',
      streaming: true,
      autonomous: false,
      resolutionLabel: '1280x720',
      streamModeLabel: '视频·AVC',
      previewEnabled: false,
      backendId: 'camera_desktop',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatusBarOverlay(
          status: status,
          onPreviewToggle: (value) => requested = value,
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('preview-toggle')));
    expect(requested, isTrue);
  });
}
