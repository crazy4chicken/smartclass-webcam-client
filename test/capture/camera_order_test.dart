import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_order.dart';

const RankedCamera _weakBack = RankedCamera(
  index: 3,
  group: CameraGroup.back,
  maxPixels: 640 * 480,
);
const RankedCamera _strongBack = RankedCamera(
  index: 2,
  group: CameraGroup.back,
  maxPixels: 1920 * 1080,
);
const RankedCamera _weakFront = RankedCamera(
  index: 0,
  group: CameraGroup.front,
  maxPixels: 640 * 480,
);
const RankedCamera _strongFront = RankedCamera(
  index: 1,
  group: CameraGroup.front,
  maxPixels: 1280 * 720,
);

void main() {
  group('cameraGroupFor', () {
    test('maps the plugin directions onto the three groups', () {
      expect(cameraGroupFor('back'), CameraGroup.back);
      expect(cameraGroupFor('front'), CameraGroup.front);
      expect(cameraGroupFor('external'), CameraGroup.external);
    });

    test('an unknown lens direction is treated as external', () {
      // `unknown` has to land somewhere, and the middle bucket keeps a rear
      // camera in front of it and a front camera behind it.
      expect(cameraGroupFor('unknown'), CameraGroup.external);
      expect(cameraGroupFor(''), CameraGroup.external);
    });

    test('the group order is rear, then external, then front', () {
      // Declaration order *is* the sort order, so this pins it: reordering the
      // enum silently redefines what camera 0 means.
      expect(CameraGroup.values.map((g) => g.name).toList(), [
        'back',
        'external',
        'front',
      ]);
    });
  });

  group('canonicalCameraOrder', () {
    test('back cameras come before external, external before front', () {
      expect(
        canonicalCameraOrder(const [
          _weakFront,
          RankedCamera(index: 9, group: CameraGroup.external, maxPixels: 10),
          _weakBack,
        ]),
        [3, 9, 0],
      );
    });

    test('within a group, cameras are ordered by pixel count descending', () {
      expect(canonicalCameraOrder(const [_weakBack, _strongBack]), [2, 3]);
    });

    test('the strongest back camera lands at index 0', () {
      expect(
        canonicalCameraOrder(const [
          _weakFront,
          _weakBack,
          _strongFront,
          _strongBack,
        ]).first,
        2,
      );
    });

    test(
      'the strongest front camera lands at index 1 when a back camera exists',
      () {
        expect(
          canonicalCameraOrder(const [
            _weakFront,
            _weakBack,
            _strongFront,
            _strongBack,
          ]),
          [2, 3, 1, 0],
        );
      },
    );

    test('a device with no back camera puts its strongest remaining camera '
        'at 0', () {
      // A laptop with two front-facing cameras and nothing else. Nothing may
      // assume a rear camera exists.
      final order = canonicalCameraOrder(const [
        RankedCamera(index: 0, group: CameraGroup.front, maxPixels: 640 * 480),
        RankedCamera(
          index: 1,
          group: CameraGroup.front,
          maxPixels: 1920 * 1080,
        ),
      ]);

      expect(order.first, 1);
      expect(order, [1, 0]);
    });

    test('all-front devices (Windows) fall back to pure resolution order', () {
      // `camera_desktop` hardcodes `lensDirection` to `0` (front) on Windows,
      // so the grouping collapses and camera 0 is simply the strongest camera.
      const windows = [
        RankedCamera(index: 0, group: CameraGroup.front, maxPixels: 640 * 480),
        RankedCamera(
          index: 1,
          group: CameraGroup.front,
          maxPixels: 1920 * 1080,
        ),
        RankedCamera(index: 2, group: CameraGroup.front, maxPixels: 1280 * 720),
      ];

      expect(canonicalCameraOrder(windows), [1, 2, 0]);
    });

    test('all-external devices (Linux) fall back to pure resolution order', () {
      // `device_enumerator.cc` / `pipewire_portal.cc` send `2` (external).
      const linux = [
        RankedCamera(
          index: 0,
          group: CameraGroup.external,
          maxPixels: 1280 * 720,
        ),
        RankedCamera(
          index: 1,
          group: CameraGroup.external,
          maxPixels: 640 * 480,
        ),
        RankedCamera(
          index: 2,
          group: CameraGroup.external,
          maxPixels: 1920 * 1080,
        ),
      ];

      expect(canonicalCameraOrder(linux), [2, 0, 1]);
    });

    test('a camera whose rank probe failed sorts last within its group', () {
      const unmeasured = RankedCamera(index: 0, group: CameraGroup.back);
      const measured = RankedCamera(
        index: 1,
        group: CameraGroup.back,
        maxPixels: 640 * 480,
      );

      expect(canonicalCameraOrder(const [unmeasured, measured]), [1, 0]);
    });

    test('ties fall back to the physical index, so the order is stable', () {
      expect(
        canonicalCameraOrder(const [
          RankedCamera(index: 2, group: CameraGroup.external, maxPixels: 100),
          RankedCamera(index: 0, group: CameraGroup.external, maxPixels: 100),
          RankedCamera(index: 1, group: CameraGroup.external, maxPixels: 100),
        ]),
        [0, 1, 2],
      );
    });

    test('the result is always a permutation of the input indices', () {
      // The property the whole camera_enum contract rests on: a dropped or
      // repeated entry silently redefines which camera the server means.
      final messy = <RankedCamera>[
        const RankedCamera(index: 4, group: CameraGroup.front, maxPixels: 100),
        const RankedCamera(index: 0, group: CameraGroup.back),
        const RankedCamera(
          index: 2,
          group: CameraGroup.external,
          maxPixels: 900,
        ),
        const RankedCamera(index: 1, group: CameraGroup.back, maxPixels: 500),
        RankedCamera(index: 3, group: cameraGroupFor('unknown'), maxPixels: 0),
      ];

      final ordered = canonicalCameraOrder(messy);

      expect(ordered, hasLength(messy.length));
      expect(ordered.toSet(), hasLength(ordered.length));
      expect(ordered.toSet(), {0, 1, 2, 3, 4});
    });

    test('an empty list stays empty', () {
      expect(canonicalCameraOrder(const []), isEmpty);
    });
  });
}
