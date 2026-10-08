import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/capability_report.dart';
import 'package:webcam_client/src/ui/screens/capabilities_screen.dart';

const _vga = CameraResolution(width: 640, height: 480);
const _hd = CameraResolution(width: 1280, height: 720);
const _fhd = CameraResolution(width: 1920, height: 1080);

/// The green the screen uses to mark whatever is in effect.
const _highlight = Color(0xFF81C784);

List<CameraCapabilityReport> _report({
  List<CameraDescriptor>? cameras,
  List<CameraMode>? modes,
  List<CameraCapabilities>? declared,
  int active = 0,
}) => buildCapabilityReport(
  cameras:
      cameras ??
      const [
        CameraDescriptor(name: '后置主摄', index: 0, lensDirection: 'back'),
        CameraDescriptor(name: '前置', index: 1, lensDirection: 'front'),
      ],
  modes:
      modes ??
      const [
        CameraMode(resolution: _hd, fps: 15),
        CameraMode(resolution: _vga, fps: 5),
      ],
  declared:
      declared ??
      [
        CameraCapabilities.of(
          resolutions: const [_fhd, _hd, _vga],
          framerates: const [30, 15],
        ),
        CameraCapabilities.of(resolutions: const [_vga], framerates: const [5]),
      ],
  activeCameraEnum: active,
);

Future<void> _pump(
  WidgetTester tester,
  List<CameraCapabilityReport> cameras,
) async {
  // Tall enough that both cards and the note are laid out, so a `findsNothing`
  // means absent rather than off-screen.
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(home: CapabilitiesScreen(cameras: cameras)),
  );
  await tester.pumpAndSettle();
}

/// The colour of the label inside a chip, which is how "this is the one in
/// effect" is expressed.
Color? _chipColour(WidgetTester tester, Key key) => tester
    .widget<Text>(
      find.descendant(of: find.byKey(key), matching: find.byType(Text)),
    )
    .style
    ?.color;

void main() {
  testWidgets('lists every camera with its declared resolutions', (
    tester,
  ) async {
    await _pump(tester, _report());

    expect(find.byKey(CapabilitiesScreen.cameraKey(0)), findsOneWidget);
    expect(find.byKey(CapabilitiesScreen.cameraKey(1)), findsOneWidget);
    expect(find.text('后置主摄'), findsOneWidget);
    expect(find.text('前置'), findsOneWidget);

    // Every declared resolution gets a chip, per camera.
    for (final resolution in <CameraResolution>[_fhd, _hd, _vga]) {
      expect(
        find.byKey(CapabilitiesScreen.resolutionKey(0, resolution)),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(CapabilitiesScreen.resolutionKey(1, _vga)),
      findsOneWidget,
    );
    // And the other camera's resolutions do not leak into this one.
    expect(find.byKey(CapabilitiesScreen.resolutionKey(1, _fhd)), findsNothing);

    expect(find.byKey(CapabilitiesScreen.frameratesKey(0)), findsOneWidget);
    expect(find.byKey(CapabilitiesScreen.noteKey), findsOneWidget);
  });

  testWidgets('marks the active camera and only that one', (tester) async {
    await _pump(tester, _report(active: 1));

    expect(
      find.descendant(
        of: find.byKey(CapabilitiesScreen.cameraKey(1)),
        matching: find.text('使用中'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(CapabilitiesScreen.cameraKey(0)),
        matching: find.text('使用中'),
      ),
      findsNothing,
    );
  });

  testWidgets('shows each camera its own current mode', (tester) async {
    await _pump(tester, _report());

    final first = tester.widget<Text>(
      find.byKey(CapabilitiesScreen.currentKey(0)),
    );
    final second = tester.widget<Text>(
      find.byKey(CapabilitiesScreen.currentKey(1)),
    );

    expect(first.data, '当前模式：1280x720 · 15 fps');
    expect(second.data, '当前模式：640x480 · 5 fps');
  });

  testWidgets('marks the resolution in effect, and not the others', (
    tester,
  ) async {
    // The declared list is a menu; the operator needs to see where the device
    // sits on it, because that is what the server snapshots into `metadata`.
    await _pump(tester, _report());

    expect(
      _chipColour(tester, CapabilitiesScreen.resolutionKey(0, _hd)),
      _highlight,
    );
    expect(
      _chipColour(tester, CapabilitiesScreen.resolutionKey(0, _fhd)),
      isNot(_highlight),
    );
    expect(
      _chipColour(tester, CapabilitiesScreen.resolutionKey(0, _vga)),
      isNot(_highlight),
    );

    // The two cameras are at different modes, so each marks its own.
    expect(
      _chipColour(tester, CapabilitiesScreen.resolutionKey(1, _vga)),
      _highlight,
    );
  });

  testWidgets('says so when a camera has nothing measured', (tester) async {
    // Not a failure state: the device still registers, declaring only the mode
    // it is in. Showing an empty list would read as a hardware fault.
    await _pump(
      tester,
      _report(
        declared: [
          CameraCapabilities.of(
            resolutions: const [_hd],
            framerates: const [15],
          ),
          CameraCapabilities.empty,
        ],
      ),
    );

    expect(find.text('未测到'), findsNWidgets(2));
    expect(find.byKey(CapabilitiesScreen.cameraKey(1)), findsOneWidget);
  });

  testWidgets('admits an unknown mode rather than inventing one', (
    tester,
  ) async {
    await _pump(
      tester,
      _report(modes: const [CameraMode(resolution: _hd, fps: 15)]),
    );

    expect(
      tester.widget<Text>(find.byKey(CapabilitiesScreen.currentKey(1))).data,
      '当前模式：未知',
    );
  });

  testWidgets('no camera at all shows a message instead of a list', (
    tester,
  ) async {
    await _pump(tester, _report(cameras: const []));

    expect(find.byKey(CapabilitiesScreen.emptyKey), findsOneWidget);
    expect(find.byKey(CapabilitiesScreen.listKey), findsNothing);
  });

  testWidgets('the page says it is read-only and why', (tester) async {
    await _pump(tester, _report());

    final note = tester.widget<Text>(
      find.descendant(
        of: find.byKey(CapabilitiesScreen.noteKey),
        matching: find.byType(Text),
      ),
    );
    expect(note.data, contains('只读'));
    expect(note.data, contains('switch_camera'));
  });
}
