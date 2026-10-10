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
/// so adding a fallback backend — a second camera plugin, for instance — is a
/// matter of appending to the list.
class CameraProvider {
  CameraProvider({required List<CameraBackend> backends})
    : _backends = List<CameraBackend>.unmodifiable(backends);

  final List<CameraBackend> _backends;

  List<String> get backendIds => [for (final b in _backends) b.id];

  Future<CameraOpenResult> open(CaptureConfig config) async {
    final attempts = <BackendProbe>[];

    // The most specific failure seen, so the UI can say "permission denied"
    // instead of a generic "no backend available".
    CameraFailure? lastFailure;

    for (final backend in _backends) {
      final BackendProbe probe;
      try {
        probe = await backend.probe();
      } catch (error) {
        attempts.add(
          BackendProbe(
            available: false,
            reason: CameraUnavailableReason.initFailed,
            detail: '$error',
          ),
        );
        continue;
      }

      attempts.add(probe);
      if (!probe.available) {
        lastFailure ??= _failureForProbe(probe);
        continue;
      }

      try {
        final service = await backend.open(config);
        return CameraOpenResult(
          service: service,
          backendId: backend.id,
          attempts: List<BackendProbe>.unmodifiable(attempts),
        );
      } catch (error) {
        // This backend could not deliver; remember why and try the next one.
        lastFailure = error is CameraFailure
            ? error
            : CameraFailure.initFailed(error);
        continue;
      }
    }

    return CameraOpenResult(
      attempts: List<BackendProbe>.unmodifiable(attempts),
      failure:
          lastFailure ??
          CameraFailure.noBackendAvailable(
            List<BackendProbe>.unmodifiable(attempts),
          ),
    );
  }

  static CameraFailure _failureForProbe(BackendProbe probe) {
    switch (probe.reason) {
      case CameraUnavailableReason.permissionDenied:
        return const CameraFailure.permissionDenied();
      case CameraUnavailableReason.noDevice:
        return const CameraFailure.noDevice();
      case CameraUnavailableReason.deviceBusy:
        return const CameraFailure.deviceBusy();
      case CameraUnavailableReason.missingDependency:
      case CameraUnavailableReason.initFailed:
      case null:
        return CameraFailure.initFailed(
          probe.detail ?? probe.reason?.name ?? 'unknown',
        );
    }
  }
}
