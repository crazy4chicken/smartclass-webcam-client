import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/ui/widgets/preview_toggle_button.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool previewEnabled,
  required ValueChanged<bool> onToggle,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomRight,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.all(16),
            child: PreviewToggleButton(
              previewEnabled: previewEnabled,
              onToggle: onToggle,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the current state', (tester) async {
    await _pump(tester, previewEnabled: true, onToggle: (_) {});
    expect(find.text('预览开'), findsOneWidget);

    await _pump(tester, previewEnabled: false, onToggle: (_) {});
    expect(find.text('预览关'), findsOneWidget);
  });

  testWidgets('tapping asks for the opposite state', (tester) async {
    bool? requested;

    await _pump(
      tester,
      previewEnabled: true,
      onToggle: (value) => requested = value,
    );
    await tester.tap(find.byKey(PreviewToggleButton.toggleKey));
    expect(requested, isFalse);
  });

  testWidgets('tapping when off asks for on', (tester) async {
    bool? requested;

    await _pump(
      tester,
      previewEnabled: false,
      onToggle: (value) => requested = value,
    );
    await tester.tap(find.byKey(PreviewToggleButton.toggleKey));
    expect(requested, isTrue);
  });

  testWidgets('sits clear of the bottom system inset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            // Simulate a gesture navigation bar without clobbering size.
            data: MediaQuery.of(context)
                .copyWith(padding: const EdgeInsets.only(bottom: 48)),
            child: const Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: SafeArea(
                  top: false,
                  minimum: EdgeInsets.all(16),
                  child: PreviewToggleButton(
                    previewEnabled: true,
                    onToggle: _noop,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final viewportHeight = tester.getSize(find.byType(Scaffold)).height;
    final bottom = tester.getBottomLeft(
      find.byKey(PreviewToggleButton.toggleKey),
    );
    expect(
      bottom.dy,
      lessThanOrEqualTo(viewportHeight - 48),
      reason: 'the control must stay above the gesture navigation bar',
    );
  });
}

void _noop(bool value) {}
