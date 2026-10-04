import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/agent/agent_status.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/ui/widgets/preview_toggle_button.dart';
import 'package:webcam_client/src/ui/widgets/status_bar_overlay.dart';

const _connected = AgentStatus(
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

void main() {
  testWidgets('renders camera, resolution, mode and fps', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: StatusBarOverlay(status: _connected),
          ),
        ),
      ),
    );

    expect(find.textContaining('1280x720'), findsOneWidget);
    expect(find.textContaining('视频·AVC'), findsOneWidget);
    expect(find.textContaining('Integrated Camera'), findsOneWidget);
  });

  testWidgets('keeps a recording indicator visible even when preview is off', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: StatusBarOverlay(
              status: AgentStatus(
                connection: ConnectionState.connected,
                fps: 2.0,
                cameraName: 'cam',
                streaming: true,
                autonomous: false,
                resolutionLabel: '1280x720',
                streamModeLabel: '视频·AVC',
                previewEnabled: false,
                backendId: 'camera_desktop',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('采集进行中'), findsOneWidget);
  });

  testWidgets(
    'content clears the system status bar while the background does not',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              // Simulate an Android status bar without clobbering size.
              data: MediaQuery.of(context)
                  .copyWith(padding: const EdgeInsets.only(top: 40)),
              child: const Scaffold(
                body: Align(
                  alignment: Alignment.topCenter,
                  child: StatusBarOverlay(status: _connected),
                ),
              ),
            ),
          ),
        ),
      );

      final contentTop = tester.getTopLeft(find.textContaining('1280x720')).dy;
      expect(
        contentTop,
        greaterThanOrEqualTo(40),
        reason: 'the strip must not sit under the system status bar',
      );
    },
  );

  testWidgets('no longer hosts the preview switch', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: StatusBarOverlay(status: _connected),
          ),
        ),
      ),
    );

    expect(find.byKey(PreviewToggleButton.toggleKey), findsNothing);
  });
}
