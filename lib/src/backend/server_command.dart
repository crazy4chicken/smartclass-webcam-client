import '../capture/stream_settings.dart';

/// Result of a face recognition pass performed by the backend model.
class FaceResult {
  const FaceResult({required this.name, required this.status});

  final String name;
  final String status;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FaceResult && other.name == name && other.status == status;

  @override
  int get hashCode => Object.hash(name, status);

  @override
  String toString() => 'FaceResult($name, $status)';
}

/// Every inbound message the client understands, as a domain object.
///
/// The coordinator only ever sees these types — never JSON, never a map. That
/// is what keeps a not-yet-finalised backend protocol replaceable: swap
/// [CommandCodec] and nothing above this layer changes.
sealed class ServerCommand {
  const ServerCommand();
}

/// `cmd_update_config` — still-frame geometry and rate.
///
/// All fields are optional: the backend may adjust one knob at a time.
class UpdateConfigCommand extends ServerCommand {
  const UpdateConfigCommand({this.width, this.height, this.quality, this.fps});

  final int? width;
  final int? height;
  final int? quality;
  final double? fps;
}

/// `cmd_set_stream_mode` — switch between still frames and video chunks.
class SetStreamModeCommand extends ServerCommand {
  const SetStreamModeCommand({this.mode, this.codec, this.chunkSeconds});

  final StreamMode? mode;
  final VideoCodec? codec;
  final int? chunkSeconds;
}

/// `cmd_control_stream` — start/stop uploading entirely.
class ControlStreamCommand extends ServerCommand {
  const ControlStreamCommand({required this.enabled});

  final bool enabled;
}

/// `cmd_switch_camera` — move to another physical device.
class SwitchCameraCommand extends ServerCommand {
  const SwitchCameraCommand({required this.index});

  final int index;
}

/// `cmd_set_preview` — toggle the on-screen preview.
///
/// Preview off is **not** capture off: the capture loop keeps running.
class SetPreviewCommand extends ServerCommand {
  const SetPreviewCommand({required this.enabled});

  final bool enabled;
}

/// `event_face_result` — the backend recognised someone.
class FaceResultCommand extends ServerCommand {
  const FaceResultCommand({required this.result});

  final FaceResult result;
}
