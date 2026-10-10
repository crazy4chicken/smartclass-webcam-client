import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/agent/agent_status.dart';
import 'package:webcam_client/src/agent/stream_diagnostics.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/ui/widgets/preview_toggle_button.dart';
import 'package:webcam_client/src/ui/widgets/status_bar_overlay.dart';

/// A stream the camera cannot keep up with: 30 fps captured against a 60 fps
/// target, everything downstream of the camera keeping up with it.
const _recording = AgentStatus(
  linkState: LinkState.live,
  captureState: CaptureState.recording,
  activeStreamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
  cameraName: 'Integrated Camera',
  previewEnabled: true,
  framesSent: 42,
  diagnostics: StreamDiagnostics(
    recording: true,
    targetFps: 60,
    selectedFps: 30,
    capturedFps: 30,
    encodedFps: 30,
    sentFps: 30,
    codec: CaptureCodec.mjpeg,
    encoderIdentity: 'mjpeg.takePicture',
    width: 1920,
    height: 1080,
    droppedFrames: 1,
    repeatedFrames: 2,
  ),
);

const _backoff = AgentStatus(
  linkState: LinkState.backoff,
  captureState: CaptureState.idle,
  activeStreamId: null,
  cameraName: 'cam',
  previewEnabled: true,
  diagnostics: StreamDiagnostics(targetFps: 60, selectedFps: 5),
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
          previewEnabled: true,
          lastError: '设备令牌被拒绝（401）',
          diagnostics: StreamDiagnostics(targetFps: 60, selectedFps: 5),
        ),
      ),
    );

    expect(find.textContaining('链路失败'), findsOneWidget);
    expect(find.textContaining('401'), findsOneWidget);
  });

  testWidgets('an idle device shows the two rates it would run at', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_backoff));
    // Idle: there is no measured rate to explain, so the strip says what the
    // device was told and what it declared instead of a row of dashes.
    expect(find.textContaining('目标 60 fps'), findsOneWidget);
    expect(find.textContaining('声明 5 fps'), findsOneWidget);
    expect(find.byKey(StatusBarOverlay.rateLineKey), findsNothing);
  });

  testWidgets('while recording it names the stage holding the rate down', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_recording));
    // "30 fps" is not actionable; "相机慢" is.
    expect(find.textContaining('相机慢'), findsOneWidget);
    expect(find.textContaining('已推 42 帧'), findsOneWidget);
    expect(find.textContaining('未推流'), findsNothing);
  });

  testWidgets('and shows all five rates, target and declared first', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_recording));

    final line = tester.widget<Text>(find.byKey(StatusBarOverlay.rateLineKey));
    expect(line.data, contains('目标 60'));
    expect(line.data, contains('声明 30'));
    expect(line.data, contains('采集 30'));
    expect(line.data, contains('编码 30'));
    expect(line.data, contains('发送 30'));
  });

  testWidgets('a rate that has not been measured reads as unknown, not zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AgentStatus(
          linkState: LinkState.live,
          captureState: CaptureState.recording,
          activeStreamId: 's',
          cameraName: 'cam',
          previewEnabled: true,
          diagnostics: StreamDiagnostics(
            recording: true,
            targetFps: 60,
            selectedFps: 30,
          ),
        ),
      ),
    );

    final line = tester.widget<Text>(find.byKey(StatusBarOverlay.rateLineKey));
    expect(
      line.data,
      contains('采集 —'),
      reason: '"not measured" must not read as "measured and held nothing"',
    );
  });

  testWidgets('the codec, geometry and losses are shown', (tester) async {
    await tester.pumpWidget(_host(_recording));

    final line = tester.widget<Text>(find.byKey(StatusBarOverlay.infoLineKey));
    expect(line.data, contains('mjpeg'));
    expect(line.data, contains('1920x1080'));
    expect(line.data, contains('mjpeg.takePicture'));
    expect(line.data, contains('丢 1'));
    expect(line.data, contains('重 2'));
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

      final contentTop = tester
          .getTopLeft(find.byKey(StatusBarOverlay.rateLineKey))
          .dy;
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
