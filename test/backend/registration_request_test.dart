import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';
import 'package:webcam_client/src/backend/registration_request.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

const CameraResolution _qvga = CameraResolution(width: 320, height: 240);
const CameraResolution _vga = CameraResolution(width: 640, height: 480);
const CameraResolution _hd = CameraResolution(width: 1280, height: 720);
const CameraResolution _fhd = CameraResolution(width: 1920, height: 1080);

/// What a 1080p webcam really reports: two rungs on the same size.
final CameraCapabilities _measured = CameraCapabilities.of(
  resolutions: const [_fhd, _hd, _hd, _vga],
  framerates: const [30, 15],
);

void main() {
  group('buildAnnouncements', () {
    test(
      'each camera emits supported_resolutions and supported_framerates',
      () {
        final list = buildAnnouncements(
          cameras: [
            CameraDeclaration(
              name: 'front',
              resolution: _fhd,
              fps: 5,
              capabilities: _measured,
            ),
          ],
          codecs: const [WireCodec.mjpeg],
        );

        final json = list.single.toJson();
        // Measured 1920x1080/1280x720/640x480, plus the common ladder below the
        // ceiling — a camera that can do 1080p can do 1024x768.
        expect(json['supported_resolutions'], [
          '1920x1080',
          '1280x720',
          '1024x768',
          '800x600',
          '640x480',
          '320x240',
        ]);
        expect(json['supported_framerates'], [
          60,
          50,
          30,
          25,
          24,
          20,
          15,
          10,
          5,
        ]);
        expect(list.single.supportedResolutions.last, _qvga);
      },
    );

    test('a resolution produced by two presets is announced once', () {
      // `ResolutionPreset` is relative, so two rungs landing on the same real
      // size is the normal case — and the server answers `400 … must not
      // contain duplicates`. Even a hand-built list carrying a duplicate is
      // deduped on the way out.
      const duplicated = CameraCapabilities(
        resolutions: [_hd, _hd, _vga, _vga],
        framerates: [30, 30],
      );

      final list = buildAnnouncements(
        cameras: const [
          CameraDeclaration(
            name: 'front',
            resolution: _hd,
            fps: 30,
            capabilities: duplicated,
          ),
        ],
        codecs: const [WireCodec.mjpeg],
      );

      final declared = list.single.supportedResolutions;
      expect(declared.where((r) => r == _hd), hasLength(1));
      expect(declared.where((r) => r == _vga), hasLength(1));
      expect(declared.toSet(), hasLength(declared.length));
      expect(list.single.supportedFramerates, const [30]);
    });

    test('the current resolution and fps are always among the declared values', () {
      // The server rejects a registration that omits the camera's current mode.
      // Here the probe measured 480p at 30/15 while the device runs 1080p at 5
      // — neither the resolution nor the rate is in the measured set.
      final list = buildAnnouncements(
        cameras: [
          CameraDeclaration(
            name: 'front',
            resolution: _fhd,
            fps: 5,
            capabilities: CameraCapabilities.of(
              resolutions: const [_vga],
              framerates: const [30, 15],
            ),
          ),
        ],
        codecs: const [WireCodec.mjpeg],
      );

      expect(list.single.supportedResolutions, contains(_fhd));
      expect(list.single.supportedFramerates, contains(5));
      expect(list.single.resolution, '1920x1080');
      expect(list.single.fps, 5);
    });

    test('a camera with empty capabilities falls back to its current pair', () {
      // A probe that found nothing must become "only what I am doing", never
      // nothing: `supported_resolutions: []` is a `400`, and a kiosk that
      // cannot register is worse than one that declares less.
      final list = buildAnnouncements(
        cameras: const [
          CameraDeclaration(name: 'front', resolution: _hd, fps: 15),
        ],
        codecs: const [WireCodec.mjpeg],
      );

      expect(list.single.supportedResolutions, const [_hd]);
      expect(list.single.supportedFramerates, const [15]);
      expect(list.single.toJson()['supported_resolutions'], ['1280x720']);
      expect(list.single.toJson()['supported_framerates'], [15]);
    });

    test('the codec list is emitted verbatim and stays non-empty', () {
      final list = buildAnnouncements(
        cameras: const [
          CameraDeclaration(name: 'front', resolution: _hd, fps: 5),
        ],
        codecs: const [WireCodec.h264, WireCodec.mjpeg],
      );
      expect(list.single.supportedCodec, const [
        WireCodec.h264,
        WireCodec.mjpeg,
      ]);
      expect(list.single.toJson()['supported_codec'], ['h264', 'mjpeg']);

      // `supported_codec: []` is a `400`, so an empty list must never be sent.
      final empty = buildAnnouncements(
        cameras: const [
          CameraDeclaration(name: 'front', resolution: _hd, fps: 5),
        ],
        codecs: const [],
      );
      expect(empty.single.supportedCodec, const [WireCodec.mjpeg]);
    });

    test('camera_enum equals the element index, in canonical order', () {
      // The list arrives already ordered, and the order *is* the protocol's
      // vocabulary for "which camera" — so the index is the only thing that
      // can be `camera_enum`.
      final list = buildAnnouncements(
        cameras: [
          CameraDeclaration(
            name: 'back',
            resolution: _fhd,
            fps: 5,
            capabilities: _measured,
          ),
          const CameraDeclaration(name: 'front', resolution: _vga, fps: 5),
        ],
        codecs: const [WireCodec.mjpeg],
      );

      expect(list.map((c) => c.cameraEnum), [0, 1]);
      expect(list.map((c) => c.attrs['label']), ['back', 'front']);
      expect(list.first.resolution, '1920x1080');
      expect(list.last.resolution, '640x480');
    });

    test('attrs.label still carries the camera name', () {
      final list = buildAnnouncements(
        cameras: const [
          CameraDeclaration(name: 'Integrated Camera', resolution: _hd, fps: 5),
        ],
        codecs: const [WireCodec.mjpeg],
      );
      expect(list.single.attrs['label'], 'Integrated Camera');
    });

    test('shared attrs are merged under the per-camera label', () {
      final list = buildAnnouncements(
        cameras: const [
          CameraDeclaration(name: 'front', resolution: _hd, fps: 5),
        ],
        codecs: const [WireCodec.mjpeg],
        attrs: const {'site': 'classroom-a'},
      );

      expect(list.single.attrs, {'site': 'classroom-a', 'label': 'front'});
    });

    test('fps is coerced to a positive integer', () {
      final list = buildAnnouncements(
        cameras: const [
          CameraDeclaration(name: 'front', resolution: _hd, fps: 0),
        ],
        codecs: const [WireCodec.mjpeg],
      );

      expect(list.single.fps, minAnnounceableFps);
      expect(list.single.fps, isA<int>());
      // The declared list has to agree with the clamped field, or the server
      // rejects the registration for omitting its own current rate.
      expect(list.single.supportedFramerates, contains(minAnnounceableFps));
    });

    test('an empty camera list produces an empty announcement list', () {
      expect(
        buildAnnouncements(cameras: const [], codecs: const [WireCodec.mjpeg]),
        isEmpty,
      );
    });
  });

  group('buildRegisterBody', () {
    test('serialises to the shape the server decodes', () {
      final body = buildRegisterBody(
        '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
        buildAnnouncements(
          cameras: [
            CameraDeclaration(
              name: 'front',
              resolution: _hd,
              fps: 5,
              capabilities: _measured,
            ),
          ],
          codecs: const [WireCodec.mjpeg],
        ),
      );

      expect(body['device_id'], '01J8ZK9WQ7X3YV0M4N5P6Q7R8S');
      final cameras = body['cameras']! as List;
      expect(cameras, hasLength(1));

      final camera = cameras.single as Map;
      expect(camera['camera_enum'], 0);
      expect(camera['resolution'], '1280x720');
      expect(camera['fps'], 5);
      expect(camera['supported_codec'], ['mjpeg']);
      expect(camera['supported_resolutions'], contains('1920x1080'));
      expect(camera['supported_framerates'], contains(5));
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
