import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_plugin_backend.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/capability_probe.dart';
import 'package:webcam_client/src/capture/plugin_capability_probe.dart';

import '../support/doubles.dart';

const CameraResolution _vga = CameraResolution(width: 640, height: 480);
const CameraResolution _hd = CameraResolution(width: 1280, height: 720);
const CameraResolution _fhd = CameraResolution(width: 1920, height: 1080);

/// A structurally real JPEG stating the given size, which is what the probe
/// actually reads.
Uint8List jpegOf(int width, int height) => Uint8List.fromList([
  0xFF, 0xD8, // SOI
  0xFF, 0xE0, 0x00, 0x10, ...List<int>.filled(14, 0x00), // APP0
  0xFF, 0xC0, 0x00, 0x11, // SOF0, length 17
  0x08,
  (height >> 8) & 0xFF, height & 0xFF,
  (width >> 8) & 0xFF, width & 0xFF,
  0x03,
  0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  0xFF, 0xD9, // EOI
]);

const CameraDescription _front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 0,
);

const CameraDescription _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 0,
);

typedef _Open = ({ResolutionPreset preset, int? fps, String camera});

/// The plugin seams, faked, with everything the probe did recorded.
class _Harness {
  _Harness({
    this.sizes = const <ResolutionPreset, CameraResolution>{},
    this.acceptedFramerates = const <int>{60, 30, 15},
    this.cameras = const <CameraDescription>[_front],
    this.listThrows = false,
    this.factoryThrows = false,
    this.takePictureThrows = false,
    this.unreadablePresets = const <ResolutionPreset>{},
  });

  /// The rungs that open and produce a picture. Anything absent refuses to open.
  final Map<ResolutionPreset, CameraResolution> sizes;

  /// The frame rates the camera will accept at the top resolution.
  final Set<int> acceptedFramerates;

  final List<CameraDescription> cameras;
  final bool listThrows;
  final bool factoryThrows;
  final bool takePictureThrows;

  /// Rungs whose picture cannot be read back, whatever they produced.
  final Set<ResolutionPreset> unreadablePresets;

  final List<_Open> opens = <_Open>[];
  final List<FakeCameraController> controllers = <FakeCameraController>[];

  List<_Open> get sweepOpens =>
      opens.where((open) => open.fps == null).toList();

  List<_Open> get framerateOpens =>
      opens.where((open) => open.fps != null).toList();

  PluginCapabilityProbe build() => PluginCapabilityProbe(
    listCameras: () async {
      if (listThrows) throw CameraException('x', 'no camera list');
      return cameras;
    },
    controllerFactory: (description, preset, fps) {
      opens.add((preset: preset, fps: fps, camera: description.name));
      if (factoryThrows) throw StateError('no controller');

      final Object? failure;
      if (fps != null) {
        failure = acceptedFramerates.contains(fps)
            ? null
            : StateError('fps $fps refused');
      } else {
        failure = sizes.containsKey(preset)
            ? null
            : StateError('preset ${preset.name} refused');
      }

      final controller = FakeCameraController(
        description,
        preset,
        fps: fps,
        picturePath: 'p-${preset.name}',
        failOnInitialize: failure,
        failOnTakePicture: takePictureThrows ? StateError('no picture') : null,
      );
      controllers.add(controller);
      return controller;
    },
    frameStore: FakeFrameStore(<String, Uint8List>{
      for (final entry in sizes.entries)
        if (!unreadablePresets.contains(entry.key))
          'p-${entry.key.name}': jpegOf(entry.value.width, entry.value.height),
    }),
  );
}

void main() {
  test('probes every preset and returns the sizes the camera really produced', () async {
    final h = _Harness(
      sizes: const {
        ResolutionPreset.low: _vga,
        ResolutionPreset.medium: _vga,
        ResolutionPreset.high: _hd,
        ResolutionPreset.veryHigh: _fhd,
        ResolutionPreset.ultraHigh: _fhd,
        ResolutionPreset.max: _fhd,
      },
    );

    final result = await h.build().probe(0);

    // Every rung was asked, in order, and one open was spent on each.
    expect(h.sweepOpens.map((o) => o.preset).toList(), kProbePresets);

    // The plugin's presets are relative, so two rungs landing on the same real
    // size is the normal case. The server answers `400 … must not contain
    // duplicates`, so they collapse.
    expect(result.capabilities.resolutions, const [_fhd, _hd, _vga]);
    expect(
      result.capabilities.resolutions.toSet(),
      hasLength(result.capabilities.resolutions.length),
    );

    expect(result.capabilities.framerates, const [60, 30, 15]);
    expect(result.detail, isNotNull);
    expect(result.isEmpty, isFalse);
  });

  test(
    'drops a preset whose open throws, without failing the whole probe',
    () async {
      final h = _Harness(
        sizes: const {
          ResolutionPreset.low: _vga,
          ResolutionPreset.high: _hd,
          ResolutionPreset.max: _fhd,
        },
      );

      final result = await h.build().probe(0);

      // All six were still attempted: one refusal must not cost the rest.
      expect(h.sweepOpens, hasLength(kProbePresets.length));
      expect(result.capabilities.resolutions, const [_fhd, _hd, _vga]);
      expect(result.isEmpty, isFalse);
    },
  );

  test('drops a preset whose picture cannot be read', () async {
    final h = _Harness(
      sizes: const {
        ResolutionPreset.low: _vga,
        ResolutionPreset.high: _hd,
        ResolutionPreset.max: _fhd,
      },
      // `high` opens fine but its file is not readable.
      unreadablePresets: const {ResolutionPreset.high},
    );

    final result = await h.build().probe(0);

    expect(result.capabilities.resolutions, const [_fhd, _vga]);
    expect(result.capabilities.resolutions, isNot(contains(_hd)));
  });

  test('probes frame rates only at the highest measured resolution', () async {
    final h = _Harness(
      sizes: const {
        ResolutionPreset.low: _vga,
        ResolutionPreset.high: _hd,
        ResolutionPreset.max: _fhd,
      },
    );

    await h.build().probe(0);

    expect(h.framerateOpens, hasLength(kProbeFramerates.length));
    expect(
      h.framerateOpens.map((o) => o.fps).toList(),
      kProbeFramerates,
      reason: 'highest first, so the log leads with the ceiling',
    );
    // 1080p maps onto `veryHigh`; asking at every rung would multiply the opens
    // by six for an answer nobody uses.
    expect(h.framerateOpens.map((o) => o.preset).toSet(), {
      presetForHeight(_fhd.height),
    });
  });

  test('drops a frame rate whose open throws', () async {
    final h = _Harness(
      sizes: const {ResolutionPreset.max: _fhd},
      acceptedFramerates: const {30},
    );

    final result = await h.build().probe(0);

    expect(result.capabilities.framerates, const [30]);
    expect(h.framerateOpens, hasLength(kProbeFramerates.length));
  });

  test('returns empty capabilities and a detail when no camera is present', () async {
    final h = _Harness(cameras: const []);

    final result = await h.build().probe(0);

    expect(result.capabilities, CameraCapabilities.empty);
    expect(result.isEmpty, isTrue);
    expect(result.detail, isNotNull);
    expect(h.opens, isEmpty, reason: 'nothing to open');

    // An index past the end of the list is the same class of answer: a detail,
    // not an exception.
    final outOfRange = await _Harness().build().probe(4);
    expect(outOfRange.isEmpty, isTrue);
    expect(outOfRange.detail, isNotNull);
  });

  test('returns empty capabilities when every open throws', () async {
    final h = _Harness(sizes: const {});

    final result = await h.build().probe(0);

    expect(result.isEmpty, isTrue);
    expect(result.detail, isNotNull);
    expect(h.sweepOpens, hasLength(kProbePresets.length));
    expect(h.framerateOpens, isEmpty, reason: 'no ceiling to ask at');
  });

  test('probes the physical camera it was asked about', () async {
    final h = _Harness(
      cameras: const [_front, _back],
      sizes: const {ResolutionPreset.max: _fhd},
    );

    final result = await h.build().probe(1);

    expect(h.opens, isNotEmpty);
    expect(h.opens.map((o) => o.camera).toSet(), {
      'back',
    }, reason: 'index 1 is the second camera in the plugin list');
    expect(result.detail, contains('back'));
  });

  test('never throws, whatever the camera does', () async {
    // The plugin's own list blowing up.
    final noList = await _Harness(listThrows: true).build().probe(0);
    expect(noList.isEmpty, isTrue);
    expect(noList.detail, isNotNull);

    // The controller factory blowing up.
    final noController = await _Harness(factoryThrows: true).build().probe(0);
    expect(noController.isEmpty, isTrue);
    expect(noController.detail, isNotNull);

    // The camera opening but refusing to produce a picture.
    final noPicture = await _Harness(
      sizes: const {ResolutionPreset.max: _fhd},
      takePictureThrows: true,
    ).build().probe(0);
    expect(noPicture.isEmpty, isTrue);
    expect(noPicture.detail, isNotNull);
  });

  test(
    'every controller it opened is disposed, including the failures',
    () async {
      final h = _Harness(
        sizes: const {ResolutionPreset.low: _vga},
        acceptedFramerates: const <int>{},
      );

      await h.build().probe(0);

      expect(h.controllers, isNotEmpty);
      expect(
        h.controllers.map((c) => c.disposed),
        everyElement(isTrue),
        reason: 'a leaked controller blocks the next open',
      );
    },
  );
}
