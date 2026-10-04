import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/capture/camera_provider.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/camera_service.dart';

class _FakeCameraService implements CameraService {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> reconfigure(CaptureConfig config) async {}

  @override
  Future<void> switchCamera(int index) async {}

  @override
  Future<Uint8List?> captureFrame(int quality) async => null;

  @override
  Future<void> setPreviewEnabled(bool enabled) async {}

  @override
  Future<void> release() async {}

  @override
  CameraDescriptor get descriptor =>
      const CameraDescriptor(name: 'fake', index: 0);

  @override
  bool get isInitialized => true;

  @override
  bool get previewEnabled => true;

  @override
  CameraResolution get appliedResolution =>
      const CameraResolution(width: 1280, height: 720);

  @override
  List<CameraResolution> get supportedResolutions => const [];

  @override
  List<CameraDescriptor> get cameras => const [];

  @override
  int get cameraIndex => 0;

  @override
  Stream<CameraHealth> get health => const Stream<CameraHealth>.empty();
}

class FakeBackend implements CameraBackend {
  FakeBackend(this.id, {this.probeResult, this.openError});

  @override
  final String id;

  final BackendProbe? probeResult;
  final Object? openError;

  @override
  Future<BackendProbe> probe() async => probeResult!;

  @override
  Future<CameraService> open(CaptureConfig c) async {
    if (openError != null) throw openError!;
    return _FakeCameraService();
  }
}

BackendProbe _okProbe() => const BackendProbe(
  available: true,
  devices: [],
  supportedResolutions: [],
  maxFps: 30,
  supportsPreview: true,
);

void main() {
  test('skips an unavailable backend and opens the next one', () async {
    final provider = CameraProvider(
      backends: [
        FakeBackend(
          'broken',
          probeResult: const BackendProbe(
            available: false,
            reason: CameraUnavailableReason.noDevice,
            devices: [],
            supportedResolutions: [],
            maxFps: 0,
            supportsPreview: false,
          ),
        ),
        FakeBackend('good', probeResult: _okProbe()),
      ],
    );

    final result = await provider.open(CaptureConfig.defaults());

    expect(result.backendId, 'good');
    expect(result.service, isNotNull);
    expect(result.attempts.length, 2);
  });

  test('falls through when a backend probes fine but open throws', () async {
    final provider = CameraProvider(
      backends: [
        FakeBackend(
          'crashy',
          probeResult: _okProbe(),
          openError: CameraFailure.initFailed('boom'),
        ),
        FakeBackend('good', probeResult: _okProbe()),
      ],
    );

    final result = await provider.open(CaptureConfig.defaults());

    expect(result.backendId, 'good');
    expect(result.attempts.length, 2);
  });

  test(
    'reports NoBackendAvailable with the full attempt list when all fail',
    () async {
      final provider = CameraProvider(
        backends: [
          FakeBackend(
            'a',
            probeResult: const BackendProbe(
              available: false,
              reason: CameraUnavailableReason.permissionDenied,
              devices: [],
              supportedResolutions: [],
              maxFps: 0,
              supportsPreview: false,
            ),
          ),
        ],
      );

      final result = await provider.open(CaptureConfig.defaults());

      expect(result.service, isNull);
      expect(result.failure, isA<CameraFailureNoBackendAvailable>());
      expect(result.attempts.length, 1);
    },
  );

  test('a backend that throws while probing is recorded, not fatal', () async {
    final provider = CameraProvider(
      backends: [
        _ThrowingBackend('explodes'),
        FakeBackend('good', probeResult: _okProbe()),
      ],
    );

    final result = await provider.open(CaptureConfig.defaults());

    expect(result.backendId, 'good');
    expect(result.attempts.length, 2);
    expect(result.attempts.first.available, isFalse);
    expect(result.attempts.first.reason, CameraUnavailableReason.initFailed);
  });
}

class _ThrowingBackend implements CameraBackend {
  _ThrowingBackend(this.id);

  @override
  final String id;

  @override
  Future<BackendProbe> probe() async => throw StateError('no backend here');

  @override
  Future<CameraService> open(CaptureConfig config) async =>
      throw StateError('unreachable');
}
