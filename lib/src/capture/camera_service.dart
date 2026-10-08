import 'dart:async';
import 'dart:typed_data';

import 'camera_resolution.dart';

/// Runtime health of an open camera.
enum CameraHealth { ok, interrupted, lost }

/// A physical camera as the app sees it.
class CameraDescriptor {
  const CameraDescriptor({
    required this.name,
    required this.index,
    this.lensDirection = 'unknown',
  });

  final String name;

  /// The **announced** enum — this camera's position in the canonical order,
  /// which is what the server sees in `camera_enum` and what `cmd_switch_camera`
  /// carries. It is not a platform index: the mapping from announced to
  /// physical lives inside `CameraPluginBackend` and nowhere else.
  final int index;

  /// `front` / `back` / `external` / `unknown`, for diagnostics only.
  final String lensDirection;

  String get label => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraDescriptor &&
          other.name == name &&
          other.index == index &&
          other.lensDirection == lensDirection;

  @override
  int get hashCode => Object.hash(name, index, lensDirection);

  @override
  String toString() => 'CameraDescriptor($index: $name)';
}

/// Enumerates the platform's cameras without opening any of them.
///
/// The plugin's `availableCameras()` returns `CameraDescription`, which the
/// Flutter-free layer cannot see, so this narrows it to the domain model: name,
/// lens direction, and the position in the platform's own list.
///
/// The descriptors this returns carry a **physical** index, because the
/// canonical order does not exist yet — establishing it is the caller's next
/// step. `ensureInventory` consumes them immediately and rebuilds the list with
/// announced indices, which is what everything downstream reads.
///
/// Enumerating needs no permission on any of the five platforms, so this cannot
/// be refused; it can still fail, and the caller treats a throw as "no camera".
typedef CameraEnumerator = Future<List<CameraDescriptor>> Function();

/// Implemented by camera services that can hand a live controller to the UI so
/// it can render a preview.
///
/// The controller is typed `Object?` on purpose: preview rendering is a
/// presentation concern and the capture layer must not leak the plugin type
/// into the domain model. The UI layer narrows it back to `CameraController`.
abstract interface class CameraPreviewProvider {
  Object? get previewController;
}

/// Lifecycle of one open camera.
///
/// This is an `abstract interface class` on purpose: it can be `implements`-ed
/// by a mock, and it cannot be instantiated by accident.
///
/// `buildPreview()` deliberately does **not** live here — turning a controller
/// into a widget is a presentation concern.
abstract interface class CameraService {
  Future<void> initialize();

  /// Rebuilds the pipeline for a new capture geometry.
  ///
  /// Implementations must serialise this against [switchCamera] and roll back
  /// to the previous working configuration if the rebuild fails.
  Future<void> reconfigure(CaptureConfig config);

  Future<void> switchCamera(int index);

  /// Grabs one frame, or null if the frame was dropped.
  ///
  /// Must never queue: a tick that arrives while a previous capture is still
  /// in flight is expected to be dropped by the caller, and this method must
  /// not serialise behind itself.
  Future<Uint8List?> captureFrame(int quality);

  /// Turns the preview on or off.
  ///
  /// Turning it off must **not** stop the capture loop.
  Future<void> setPreviewEnabled(bool enabled);

  Future<void> release();

  CameraDescriptor get descriptor;

  bool get isInitialized;

  bool get previewEnabled;

  /// The resolution actually in effect, which may differ from what was asked
  /// for. Reported back to the backend so degradation is never silent.
  CameraResolution get appliedResolution;

  List<CameraResolution> get supportedResolutions;

  List<CameraDescriptor> get cameras;

  int get cameraIndex;

  Stream<CameraHealth> get health;
}
