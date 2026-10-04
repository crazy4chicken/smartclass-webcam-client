import 'camera_resolution.dart';
import 'camera_service.dart';

/// Why a backend could not provide a camera.
enum CameraUnavailableReason {
  noDevice,
  permissionDenied,
  missingDependency,
  deviceBusy,
  initFailed,
}

/// The result of probing a [CameraBackend] without opening anything.
///
/// [probe] must never throw: every failure is expressed as
/// `available: false` plus a [reason].
class BackendProbe {
  const BackendProbe({
    required this.available,
    this.reason,
    this.devices = const [],
    this.supportedResolutions = const [],
    this.maxFps = 0,
    this.supportsPreview = false,
    this.detail,
  });

  final bool available;
  final CameraUnavailableReason? reason;
  final List<CameraDescriptor> devices;
  final List<CameraResolution> supportedResolutions;
  final double maxFps;
  final bool supportsPreview;

  /// Free-form diagnostic text, surfaced in the unrecognised-command log style.
  final String? detail;

  @override
  String toString() =>
      'BackendProbe(available: $available, reason: ${reason?.name}, '
      'devices: ${devices.length})';
}

/// A typed camera failure, suitable for driving distinct UI guidance.
sealed class CameraFailure {
  const CameraFailure();

  const factory CameraFailure.noDevice() = CameraFailureNoDevice;

  const factory CameraFailure.permissionDenied() =
      CameraFailurePermissionDenied;

  const factory CameraFailure.deviceBusy() = CameraFailureDeviceBusy;

  const factory CameraFailure.initFailed(Object cause) =
      CameraFailureInitFailed;

  const factory CameraFailure.captureFailed(Object cause) =
      CameraFailureCaptureFailed;

  const factory CameraFailure.noBackendAvailable(List<BackendProbe> attempts) =
      CameraFailureNoBackendAvailable;
}

class CameraFailureNoDevice extends CameraFailure {
  const CameraFailureNoDevice();
}

class CameraFailurePermissionDenied extends CameraFailure {
  const CameraFailurePermissionDenied();
}

class CameraFailureDeviceBusy extends CameraFailure {
  const CameraFailureDeviceBusy();
}

class CameraFailureInitFailed extends CameraFailure {
  const CameraFailureInitFailed(this.cause);

  final Object cause;
}

class CameraFailureCaptureFailed extends CameraFailure {
  const CameraFailureCaptureFailed(this.cause);

  final Object cause;
}

class CameraFailureNoBackendAvailable extends CameraFailure {
  const CameraFailureNoBackendAvailable(this.attempts);

  final List<BackendProbe> attempts;
}

/// Human-readable guidance for a failure. Pure function, safe to call from
/// `build`.
String failureMessage(CameraFailure failure) {
  switch (failure) {
    case CameraFailureNoDevice():
      return '未检测到摄像头。请确认设备已连接（或已被系统识别）后重试。';
    case CameraFailurePermissionDenied():
      return '摄像头权限被拒绝。请在系统设置中允许本应用访问摄像头后重试。';
    case CameraFailureDeviceBusy():
      return '摄像头被其它程序占用。请关闭正在使用摄像头的程序后重试。';
    case CameraFailureInitFailed(:final cause):
      return '摄像头初始化失败：$cause';
    case CameraFailureCaptureFailed(:final cause):
      return '画面采集失败：$cause';
    case CameraFailureNoBackendAvailable(:final attempts):
      return '没有可用的摄像头后端（已尝试 ${attempts.length} 个）。'
          '请检查摄像头驱动与权限设置后重试。';
  }
}

/// One way of getting at a camera. The provider walks an ordered list of these.
abstract interface class CameraBackend {
  String get id;

  /// Inspects availability **without** opening a stream. Never throws.
  Future<BackendProbe> probe();

  /// Opens the camera. Throws [CameraFailure] on failure.
  Future<CameraService> open(CaptureConfig config);
}
