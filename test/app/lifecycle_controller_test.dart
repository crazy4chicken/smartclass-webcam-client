import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/app/lifecycle_controller.dart';

void main() {
  test('pauses when backgrounded, hidden or detached', () {
    expect(shouldPauseFor(AppLifecycleState.paused), isTrue);
    expect(shouldPauseFor(AppLifecycleState.hidden), isTrue);
    expect(shouldPauseFor(AppLifecycleState.detached), isTrue);
  });

  test('keeps running while resumed or merely inactive', () {
    expect(shouldPauseFor(AppLifecycleState.resumed), isFalse);
    expect(shouldPauseFor(AppLifecycleState.inactive), isFalse);
  });

  test(
    'translates lifecycle transitions into pause and resume exactly once',
    () async {
      var pauses = 0;
      var resumes = 0;
      final controller = LifecycleController(
        onPause: () async => pauses++,
        onResume: () async => resumes++,
      );

      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await Future<void>.delayed(Duration.zero);
      expect(pauses, 1, reason: 'repeated hidden events must not stack up');

      // Losing focus on desktop is not a reason to rebuild the camera.
      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(resumes, 0);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(resumes, 1);
    },
  );
}
