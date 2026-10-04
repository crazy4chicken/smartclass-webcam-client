import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/resolution_selector.dart';

const available = [
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1920, height: 1080),
];

void main() {
  test('returns exact match when the target format exists', () {
    expect(
      selectClosestResolution(
        available,
        const CameraResolution(width: 1280, height: 720),
      ),
      const CameraResolution(width: 1280, height: 720),
    );
  });

  test('never upscales past the target', () {
    expect(
      selectClosestResolution(
        available,
        const CameraResolution(width: 1000, height: 700),
      ),
      const CameraResolution(width: 640, height: 480),
    );
    expect(
      selectClosestResolution(
        available,
        const CameraResolution(width: 3840, height: 2160),
      ),
      const CameraResolution(width: 1920, height: 1080),
    );
  });

  test('falls back to smallest format when every format exceeds target', () {
    expect(
      selectClosestResolution(
        available,
        const CameraResolution(width: 320, height: 240),
      ),
      const CameraResolution(width: 640, height: 480),
    );
  });

  test('a single available format is returned as-is when it fits', () {
    expect(
      selectClosestResolution(
        const [CameraResolution(width: 640, height: 480)],
        const CameraResolution(width: 1280, height: 720),
      ),
      const CameraResolution(width: 640, height: 480),
    );
  });
}
