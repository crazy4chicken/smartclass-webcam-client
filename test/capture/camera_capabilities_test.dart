import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';

const CameraResolution _qvga = CameraResolution(width: 320, height: 240);
const CameraResolution _vga = CameraResolution(width: 640, height: 480);
const CameraResolution _svga = CameraResolution(width: 800, height: 600);
const CameraResolution _xga = CameraResolution(width: 1024, height: 768);
const CameraResolution _hd = CameraResolution(width: 1280, height: 720);
const CameraResolution _fhd = CameraResolution(width: 1920, height: 1080);

void main() {
  group('of', () {
    test('drops duplicates and sorts by pixel count, descending', () {
      // Two presets resolving to the same real size is the normal case, and the
      // server answers `400 … must not contain duplicates`.
      final caps = CameraCapabilities.of(
        resolutions: const [_vga, _fhd, _vga, _hd],
        framerates: const [5, 30, 30, 15],
      );

      expect(caps.resolutions, const [_fhd, _hd, _vga]);
      expect(caps.framerates, const [30, 15, 5]);
    });

    test('drops non-positive dimensions and frame rates', () {
      final caps = CameraCapabilities.of(
        resolutions: const [
          CameraResolution(width: 0, height: 480),
          CameraResolution(width: 640, height: 0),
          _vga,
        ],
        framerates: const [0, -1, 15],
      );

      expect(caps.resolutions, const [_vga]);
      expect(caps.framerates, const [15]);
    });
  });

  group('withCurrent', () {
    test('adds a resolution the probe never produced', () {
      // The ladder is coarse: a camera running at 800x600 may only have been
      // measured at 640x480 and 1024x768. The server rejects a registration
      // that omits the current resolution.
      final caps = CameraCapabilities.of(
        resolutions: const [_vga, _xga],
        framerates: const [30],
      ).withCurrent(resolution: _svga, fps: 30);

      expect(caps.resolutions, contains(_svga));
      expect(caps.resolutions.first, _xga);
    });

    test('adds an fps the probe never produced', () {
      // `AppConfig.defaultFps` is 5 and the probe only tries 60/30/15.
      final caps = CameraCapabilities.of(
        resolutions: const [_hd],
        framerates: const [60, 30, 15],
      ).withCurrent(resolution: _hd, fps: 5);

      expect(caps.framerates, contains(5));
      expect(caps.framerates, const [60, 30, 15, 5]);
    });

    test('clamps a non-positive fps to the server floor', () {
      // The announced `fps` field is clamped by `minAnnounceableFps`, so the
      // declared list has to hold the same value or the two disagree and the
      // registration is refused.
      final caps = CameraCapabilities.empty.withCurrent(
        resolution: _hd,
        fps: 0,
      );

      expect(caps.framerates, const [kMinDeclaredFramerate]);
    });
  });

  group('withCommonBaseline', () {
    test('adds common resolutions the probe did not produce', () {
      final caps = CameraCapabilities.of(
        resolutions: const [_fhd, _vga],
        framerates: const [30],
      ).withCommonBaseline();

      expect(caps.resolutions, containsAll(const [_hd, _xga, _svga, _qvga]));
    });

    test('never adds a resolution above the measured maximum', () {
      // Declaring 4K for a 480p webcam is worse than declaring less: the server
      // accepts it, and an operator can then select a mode that cannot exist.
      final caps = CameraCapabilities.of(
        resolutions: const [_vga],
        framerates: const [30],
      ).withCommonBaseline();

      expect(caps.resolutions.first, _vga);
      expect(caps.resolutions, isNot(contains(_hd)));
      expect(caps.resolutions, isNot(contains(_fhd)));
      expect(
        caps.resolutions.every((r) => r.pixelCount <= _vga.pixelCount),
        isTrue,
      );
    });

    test('adds the common frame rates', () {
      final caps = CameraCapabilities.of(
        resolutions: const [_hd],
        framerates: const [60, 30, 15],
      ).withCommonBaseline();

      expect(caps.framerates, containsAll(kCommonFramerates));
    });

    test('on empty capabilities stays empty', () {
      // No measurement means no ceiling to cap against, so there is nothing
      // honest to add — and inventing a ladder would be the exact mistake this
      // class exists to prevent.
      expect(CameraCapabilities.empty.withCommonBaseline().isEmpty, isTrue);
    });

    test('output is still deduped and sorted', () {
      // 1280x720 and 640x480 are measured *and* on the common ladder.
      final caps = CameraCapabilities.of(
        resolutions: const [_fhd, _hd],
        framerates: const [30, 5],
      ).withCommonBaseline();

      expect(caps.resolutions, const [_fhd, _hd, _xga, _svga, _vga, _qvga]);
      expect(caps.resolutions.toSet(), hasLength(caps.resolutions.length));
      expect(caps.framerates, const [60, 50, 30, 25, 24, 20, 15, 10, 5]);
    });
  });

  group('empty', () {
    test('empty capabilities stay empty and report isEmpty', () {
      expect(CameraCapabilities.empty.isEmpty, isTrue);
      expect(CameraCapabilities.empty.resolutions, isEmpty);
      expect(CameraCapabilities.empty.framerates, isEmpty);
      expect(CameraCapabilities.empty.highestResolution, isNull);

      final measured = CameraCapabilities.of(
        resolutions: const [_hd],
        framerates: const [5],
      );
      expect(measured.isEmpty, isFalse);
      expect(measured.highestResolution, _hd);
    });
  });

  group('json', () {
    test('toJson/fromJson round-trips', () {
      final caps = CameraCapabilities.of(
        resolutions: const [_fhd, _hd, _vga],
        framerates: const [30, 15, 5],
      );

      expect(CameraCapabilities.fromJson(caps.toJson()), caps);
      expect(caps.toJson(), {
        'resolutions': ['1920x1080', '1280x720', '640x480'],
        'framerates': [30, 15, 5],
      });
    });

    test('fromJson ignores malformed input rather than throwing', () {
      expect(CameraCapabilities.fromJson(null), CameraCapabilities.empty);
      expect(CameraCapabilities.fromJson('nonsense'), CameraCapabilities.empty);
      expect(CameraCapabilities.fromJson(42), CameraCapabilities.empty);
      expect(
        CameraCapabilities.fromJson(<String, Object?>{}),
        CameraCapabilities.empty,
      );
      expect(
        CameraCapabilities.fromJson(const <String, Object?>{
          'resolutions': ['not-a-size', 640, null, '0x480', '640x480'],
          'framerates': ['30', null, -5, 15],
        }),
        CameraCapabilities.of(
          resolutions: const [_vga],
          framerates: const [15],
        ),
      );
    });
  });

  group('CameraMode', () {
    test('differsFrom reports a changed resolution or frame rate', () {
      const mode = CameraMode(resolution: _hd, fps: 5);

      expect(
        mode.differsFrom(const CameraMode(resolution: _hd, fps: 5)),
        isFalse,
      );
      expect(
        mode.differsFrom(const CameraMode(resolution: _fhd, fps: 5)),
        isTrue,
      );
      expect(
        mode.differsFrom(const CameraMode(resolution: _hd, fps: 15)),
        isTrue,
      );
    });
  });

  group('parseResolutionLabel', () {
    test('reads a WIDTHxHEIGHT label and rejects anything else', () {
      expect(parseResolutionLabel('1280x720'), _hd);
      expect(parseResolutionLabel(' 640x480 '), _vga);
      expect(parseResolutionLabel('1280X720'), isNull);
      expect(parseResolutionLabel('1280'), isNull);
      expect(parseResolutionLabel('1280x720x30'), isNull);
      expect(parseResolutionLabel('axb'), isNull);
      expect(parseResolutionLabel('0x480'), isNull);
      expect(parseResolutionLabel(''), isNull);
      expect(parseResolutionLabel(null), isNull);
    });
  });
}
