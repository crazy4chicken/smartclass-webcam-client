import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/server_command.dart';
import 'package:webcam_client/src/ui/widgets/recognition_hud.dart';

void main() {
  testWidgets('shows the name and status label then unmounts after 3 seconds',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RecognitionHud(
          result: FaceResult(name: '张三', status: 'approved'),
        ),
      ),
    ));

    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining('识别成功'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.textContaining('张三'), findsNothing);
  });

  testWidgets('a second result resets the dismiss timer instead of being cut short',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RecognitionHud(
          result: FaceResult(name: '张三', status: 'approved'),
        ),
      ),
    ));

    await tester.pump(const Duration(milliseconds: 2000));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RecognitionHud(
          result: FaceResult(name: '李四', status: 'rejected'),
        ),
      ),
    ));

    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.textContaining('李四'), findsOneWidget);
    expect(find.textContaining('识别失败'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.textContaining('李四'), findsNothing);
  });

  testWidgets('unknown status renders 未识别', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RecognitionHud(
          result: FaceResult(name: '王五', status: 'who-dis'),
        ),
      ),
    ));

    expect(find.textContaining('未识别'), findsOneWidget);
  });
}
