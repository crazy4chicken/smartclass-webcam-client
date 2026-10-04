import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/agent/agent_status.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/ui/widgets/preview_toggle_button.dart';
import 'package:webcam_client/src/ui/widgets/status_bar_overlay.dart';

const _recording = AgentStatus(
  linkState: LinkState.live,
  captureState: CaptureState.recording,
  activeStreamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
  cameraName: 'Integrated Camera',
  fps: 5,
  previewEnabled: true,
  framesSent: 42,
);

const _backoff = AgentStatus(
  linkState: LinkState.backoff,
  captureState: CaptureState.idle,
  activeStreamId: null,
  cameraName: 'cam',
  fps: 5,
  previewEnabled: true,
);

Widget _host(AgentStatus status) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: StatusBarOverlay(status: status),
    ),
  ),
);

void main() {
  testWidgets('shows link state, capture state and the active stream', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_recording));

    expect(find.textContaining('Integrated Camera'), findsOneWidget);
    expect(find.textContaining('已连接'), findsOneWidget);
    expect(find.textContaining('采集中'), findsOneWidget);
    expect(
      find.textContaining('01J8ZKQ3B5N7P9R1T3V5X7Z9B2'),
      findsOneWidget,
      reason: 'the operator needs the stream id to match it server-side',
    );
  });

  testWidgets('backoff is legible so an operator can tell it is retrying', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_backoff));
    expect(find.textContaining('重连'), findsOneWidget);
    expect(find.textContaining('空闲'), findsOneWidget);
  });

  testWidgets('a rejected credential says so instead of looking idle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AgentStatus(
          linkState: LinkState.failed,
          captureState: CaptureState.idle,
          activeStreamId: null,
          cameraName: 'cam',
          fps: 5,
          previewEnabled: true,
          lastError: '设备令牌被拒绝（401）',
        ),
      ),
    );

    expect(find.textContaining('链路失败'), findsOneWidget);
    expect(find.textContaining('401'), findsOneWidget);
  });

  testWidgets('the declared rate is shown, not a guessed one', (tester) async {
    await tester.pumpWidget(_host(_recording));
    expect(find.textContaining('5 fps'), findsOneWidget);
    expect(find.textContaining('已推 42 帧'), findsOneWidget);
  });

  testWidgets(
    'content clears the system status bar while the background does',
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
                  child: StatusBarOverlay(status: _recording),
                ),
              ),
            ),
          ),
        ),
      );

      final contentTop = tester.getTopLeft(find.textContaining('5 fps')).dy;
      expect(
        contentTop,
        greaterThanOrEqualTo(40),
        reason: 'the strip must not sit under the system status bar',
      );
    },
  );

  testWidgets('no longer hosts the preview switch', (tester) async {
    // The switch lives at the bottom of the kiosk screen: on Android the system
    // status bar owns this corner and swallowed its tap target.
    await tester.pumpWidget(_host(_recording));
    expect(find.byKey(PreviewToggleButton.toggleKey), findsNothing);
  });
}
