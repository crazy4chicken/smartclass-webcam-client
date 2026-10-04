import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/ui/widgets/camera_error_view.dart';

void main() {
  testWidgets('shows typed guidance and forwards retry taps', (tester) async {
    var tapped = 0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CameraErrorView(
          failure: const CameraFailure.permissionDenied(),
          onRetry: () => tapped++,
        ),
      ),
    ));

    expect(find.textContaining('权限'), findsOneWidget);

    await tester.tap(find.text('重试'));
    expect(tapped, 1);
  });

  testWidgets('every failure class gets its own wording', (tester) async {
    for (final failure in const <CameraFailure>[
      CameraFailure.noDevice(),
      CameraFailure.deviceBusy(),
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CameraErrorView(failure: failure, onRetry: () {}),
        ),
      ));
      expect(find.textContaining('摄像头'), findsWidgets);
    }
  });
}
