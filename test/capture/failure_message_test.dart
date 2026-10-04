import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';

void main() {
  test('gives distinct guidance per failure type', () {
    expect(failureMessage(const CameraFailure.noDevice()), contains('未检测到摄像头'));
    expect(
      failureMessage(const CameraFailure.permissionDenied()),
      contains('权限'),
    );
    expect(failureMessage(const CameraFailure.deviceBusy()), contains('占用'));
    expect(
      failureMessage(CameraFailure.noBackendAvailable(const [])),
      isNotEmpty,
    );
    expect(failureMessage(CameraFailure.initFailed('boom')), contains('boom'));
    expect(
      failureMessage(CameraFailure.captureFailed('bang')),
      contains('bang'),
    );
  });
}
