import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_order.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/plugin_camera_ranker.dart';

import '../support/doubles.dart';

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

void main() {
  const descriptors = [
    CameraDescriptor(name: 'front', index: 0, lensDirection: 'front'),
    CameraDescriptor(name: 'back', index: 1, lensDirection: 'back'),
  ];

  test('ranks every camera with exactly one open each', () async {
    final controllers = <FakeCameraController>[];
    final ranker = PluginCameraRanker(
      listCameras: () async => const [_front, _back],
      controllerFactory: (description) {
        final controller = FakeCameraController(
          description,
          ResolutionPreset.max,
          previewSize: description.name == 'back'
              ? const Size(1920, 1080)
              : const Size(1280, 720),
        );
        controllers.add(controller);
        return controller;
      },
    );

    final ranked = await ranker.rank(descriptors);

    // One open per camera is the whole point: a full probe here would cost
    // `n × 9` opens, and this pass only exists to learn the ceiling.
    expect(controllers, hasLength(2));
    expect(controllers.map((c) => c.initialized), everyElement(isTrue));
    expect(controllers.map((c) => c.disposed), everyElement(isTrue));

    expect(ranked, hasLength(2));
    expect(ranked[0].index, 0);
    expect(ranked[0].group, CameraGroup.front);
    expect(ranked[0].maxPixels, 1280 * 720);
    expect(ranked[1].index, 1);
    expect(ranked[1].group, CameraGroup.back);
    expect(ranked[1].maxPixels, 1920 * 1080);
  });

  test(
    'asks for the top preset, because the ceiling is the question',
    () async {
      final presets = <ResolutionPreset>[];
      final ranker = PluginCameraRanker(
        listCameras: () async => const [_front],
        controllerFactory: (description) {
          final controller = FakeCameraController(
            description,
            ResolutionPreset.max,
            previewSize: const Size(640, 480),
          );
          presets.add(controller.resolutionPreset);
          return controller;
        },
      );

      await ranker.rank(const [CameraDescriptor(name: 'front', index: 0)]);

      expect(presets, [ResolutionPreset.max]);
    },
  );

  test(
    'a camera that fails to open reports no ceiling instead of throwing',
    () async {
      final controllers = <FakeCameraController>[];
      final ranker = PluginCameraRanker(
        listCameras: () async => const [_front, _back],
        controllerFactory: (description) {
          final controller = FakeCameraController(
            description,
            ResolutionPreset.max,
            failOnInitialize: description.name == 'back'
                ? CameraException('CameraAccessDenied', 'denied')
                : null,
            previewSize: const Size(1280, 720),
          );
          controllers.add(controller);
          return controller;
        },
      );

      final ranked = await ranker.rank(descriptors);

      expect(ranked, hasLength(2));
      expect(ranked[0].maxPixels, 1280 * 720);
      expect(ranked[1].maxPixels, 0);
      // Still disposed, so a failed open does not leak into the next one.
      expect(controllers.every((c) => c.disposed), isTrue);
    },
  );

  test('a null preview size reports no ceiling', () async {
    final ranker = PluginCameraRanker(
      listCameras: () async => const [_front],
      controllerFactory: (description) =>
          FakeCameraController(description, ResolutionPreset.max),
    );

    final ranked = await ranker.rank(const [
      CameraDescriptor(name: 'front', index: 0),
    ]);

    expect(ranked.single.maxPixels, 0);
  });

  test(
    'a descriptor with no matching plugin camera reports no ceiling',
    () async {
      final opened = <String>[];
      final ranker = PluginCameraRanker(
        listCameras: () async => const [_front],
        controllerFactory: (description) {
          opened.add(description.name);
          return FakeCameraController(description, ResolutionPreset.max);
        },
      );

      final ranked = await ranker.rank(const [
        CameraDescriptor(name: 'ghost', index: 7),
      ]);

      expect(ranked.single.index, 7);
      expect(ranked.single.maxPixels, 0);
      expect(opened, isEmpty, reason: 'nothing to open for an unknown index');
    },
  );

  test('rank never throws', () async {
    // The plugin list itself blowing up must not take the ranking down: without
    // a permutation the device would not register at all.
    final noList = PluginCameraRanker(
      listCameras: () async => throw CameraException('x', 'no list'),
      controllerFactory: (d) => throw StateError('never called'),
    );
    final ranked = await noList.rank(descriptors);

    expect(ranked, hasLength(2));
    expect(ranked.every((c) => c.maxPixels == 0), isTrue);
    expect(ranked.map((c) => c.index), [0, 1]);
    expect(ranked[0].group, CameraGroup.front);
    expect(ranked[1].group, CameraGroup.back);

    // A factory that throws for every camera is the same story.
    final noControllers = PluginCameraRanker(
      listCameras: () async => const [_front, _back],
      controllerFactory: (d) => throw StateError('boom'),
    );
    expect(await noControllers.rank(descriptors), hasLength(2));
  });
}
