import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';
import 'package:webcam_client/src/backend/registration_request.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

void main() {
  group('buildAnnouncements', () {
    test('camera_enum always equals the array index', () {
      final list = buildAnnouncements(
        cameraNames: const ['front', 'back'],
        resolutions: const [
          CameraResolution(width: 1280, height: 720),
          CameraResolution(width: 640, height: 480),
        ],
        fps: 5,
        codecs: const [WireCodec.mjpeg],
      );

      expect(list.map((c) => c.cameraEnum), [0, 1]);
      expect(list.first.resolution, '1280x720');
      expect(list.last.resolution, '640x480');
      expect(list.first.supportedCodec, [WireCodec.mjpeg]);
    });

    test('the camera name travels in attrs.label', () {
      final list = buildAnnouncements(
        cameraNames: const ['Integrated Camera'],
        resolutions: const [CameraResolution(width: 1280, height: 720)],
        fps: 5,
        codecs: const [WireCodec.mjpeg],
      );
      expect(list.single.attrs['label'], 'Integrated Camera');
    });

    test('fps is coerced to a positive integer', () {
      final list = buildAnnouncements(
        cameraNames: const ['front'],
        resolutions: const [CameraResolution(width: 1280, height: 720)],
        fps: 0,
        codecs: const [WireCodec.mjpeg],
      );
      expect(list.single.fps, greaterThan(0));
      expect(list.single.fps, isA<int>());
      expect(list.single.fps, minAnnounceableFps);
    });

    test('an empty codec list falls back to mjpeg rather than 400', () {
      // `supported_codec: []` is a 400, so an empty list must never be sent.
      final list = buildAnnouncements(
        cameraNames: const ['front'],
        resolutions: const [CameraResolution(width: 1280, height: 720)],
        fps: 5,
        codecs: const [],
      );
      expect(list.single.supportedCodec, [WireCodec.mjpeg]);
    });

    test('a short resolution list reuses the last known format', () {
      final list = buildAnnouncements(
        cameraNames: const ['a', 'b', 'c'],
        resolutions: const [CameraResolution(width: 1280, height: 720)],
        fps: 5,
        codecs: const [WireCodec.mjpeg],
      );
      expect(list.map((c) => c.resolution), everyElement('1280x720'));
    });
  });

  group('buildRegisterBody', () {
    test('serialises to the shape the server decodes', () {
      final body = buildRegisterBody(
        '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
        buildAnnouncements(
          cameraNames: const ['front'],
          resolutions: const [CameraResolution(width: 1280, height: 720)],
          fps: 5,
          codecs: const [WireCodec.mjpeg],
        ),
      );

      expect(body['device_id'], '01J8ZK9WQ7X3YV0M4N5P6Q7R8S');
      final cameras = body['cameras']! as List;
      expect(cameras, hasLength(1));
      expect((cameras.single as Map)['camera_enum'], 0);
      expect((cameras.single as Map)['supported_codec'], ['mjpeg']);
      expect((cameras.single as Map)['fps'], 5);
    });
  });

  group('wireCodecsFor', () {
    test('maps capture codecs onto the wire vocabulary by exact name', () {
      expect(wireCodecsFor({CaptureCodec.mjpeg}), [WireCodec.mjpeg]);
      expect(
        wireCodecsFor({
          CaptureCodec.h265,
          CaptureCodec.h264,
          CaptureCodec.mjpeg,
        }),
        [WireCodec.h265, WireCodec.h264, WireCodec.mjpeg],
      );
    });

    test('never emits the hevc alias', () {
      final names = wireCodecsFor(CaptureCodec.values.toSet())
          .map((c) => c.wireName);
      expect(names, isNot(contains('hevc')));
      expect(names, contains('h265'));
    });

    test('orders by preference, then appends anything else', () {
      final mapped = wireCodecsFor({CaptureCodec.vp9, CaptureCodec.mjpeg});
      expect(mapped.first, WireCodec.mjpeg);
      expect(mapped.last, WireCodec.vp9);
    });
  });
}
