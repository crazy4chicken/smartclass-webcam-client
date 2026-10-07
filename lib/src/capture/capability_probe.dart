import 'camera_capabilities.dart';

/// The frame rates the probe tries, **highest first**.
///
/// Highest-first is not cosmetic: the probe stops at nothing, but an operator
/// reading the log wants the ceiling first, and more importantly a device that
/// cannot hold 60 must still be offered 30 — so the set has to be tried
/// independently rather than narrowed from the top.
///
/// Three values, not the whole ladder, because each one is a full camera open
/// and the common ladder in [CameraCapabilities.withCommonBaseline] fills in the
/// rest for free. These three are the ones a real webcam is most likely to
/// actually accept, so they are the ones worth spending opens on.
const List<int> kProbeFramerates = <int>[60, 30, 15];

/// What one probe run found, plus a line an operator can read.
class CapabilityProbeResult {
  const CapabilityProbeResult({required this.capabilities, this.detail});

  final CameraCapabilities capabilities;

  /// Human-readable outcome. Present on failure; also set on success, because
  /// "3 个分辨率 / 2 个帧率" is the only thing that tells an operator whether a
  /// re-probe actually measured anything.
  final String? detail;

  bool get isEmpty => capabilities.isEmpty;

  @override
  String toString() =>
      'CapabilityProbeResult(${capabilities.isEmpty ? 'empty' : capabilities}'
      '${detail == null ? '' : ', $detail'})';
}

/// Measures one camera.
///
/// **Takes a physical index.** The probe runs against the plugin's own camera
/// list, which is the only list it can open from; the announced enum lives in
/// the canonical permutation and is applied by the caller. Keeping the two
/// apart here is what stops a second numbering scheme appearing.
///
/// Pure Dart — the `package:camera` implementation is
/// `PluginCapabilityProbe`, in its own file, so `tool/verify_pure.dart` can
/// still import this contract.
abstract interface class CapabilityProbe {
  /// Never throws.
  ///
  /// A camera that will not open, or one that produces nothing readable, comes
  /// back as empty [CapabilityProbeResult.capabilities] plus a detail. The
  /// caller decides what to do about that; the probe does not get to take the
  /// kiosk down over it.
  Future<CapabilityProbeResult> probe(int physicalCameraIndex);
}
