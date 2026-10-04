import 'camera_backend.dart';
import 'camera_resolution.dart';
import 'camera_service.dart';

/// Outcome of walking the backend chain.
class CameraOpenResult {
  const CameraOpenResult({
    this.service,
    this.backendId,
    this.attempts = const [],
    this.failure,
  });

  final CameraService? service;
  final String? backendId;

  /// Every probe that was tried, in order — the diagnostic trail.
  final List<BackendProbe> attempts;

  final CameraFailure? failure;

  bool get succeeded => service != null;
}

/// Walks an ordered list of [CameraBackend]s and returns the first one that
/// can actually deliver a camera.
///
/// A backend that probes fine but throws on open is skipped rather than fatal,
/// so adding a fallback backend (a native encoder, an ffmpeg fallback) is a
/// matter of appending to the list.
class CameraProvider {
  CameraProvider({required List<CameraBackend> backends})
      : _backends = List<CameraBackend>.unmodifiable(backends);

  final List<CameraBackend> _backends;

  List<String> get backendIds => [for (final b in _backends) b.id];

  Future<CameraOpenResult> open(CaptureConfig config) async {
    final attempts = <BackendProbe>[];

    for (final backend in _backends) {
      final BackendProbe probe;
      try {
        probe = await backend.probe();
      } catch (error) {
        attempts.add(BackendProbe(
          available: false,
          reason: CameraUnavailableReason.initFailed,
          detail: '$error',
        ));
        continue;
      }

      attempts.add(probe);
      if (!probe.available) continue;

      try {
        final service = await backend.open(config);
        return CameraOpenResult(
          service: service,
          backendId: backend.id,
          attempts: List<BackendProbe>.unmodifiable(attempts),
        );
      } catch (_) {
        // This backend lied about being available; try the next one.
        continue;
      }
    }

    return CameraOpenResult(
      attempts: List<BackendProbe>.unmodifiable(attempts),
      failure: CameraFailure.noBackendAvailable(
        List<BackendProbe>.unmodifiable(attempts),
      ),
    );
  }
}
