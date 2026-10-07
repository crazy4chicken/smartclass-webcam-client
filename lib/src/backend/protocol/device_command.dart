import '../../capture/camera_resolution.dart';
import '../../capture/stream_settings.dart';

/// Every server-to-device message the client understands.
///
/// The server sends exactly five types: four operator-triggered commands
/// (`switch_camera`, `start_recording`, `stop_recording`, `take_photo`) and
/// the application keepalive `ping`. There is no retry, no re-delivery and no
/// queue that survives a reconnection — each command is emitted once.
///
/// The coordinator only ever sees these objects, never JSON.
sealed class DeviceCommand {
  const DeviceCommand({this.id});

  /// Command identifier (a server-minted 26-character ULID), echoed back
  /// verbatim in the `ack`. Absent on [PingCommand].
  ///
  /// Treated as an opaque string: the device never mints or rewrites it.
  final String? id;
}

/// `switch_camera` — make one camera the active one, optionally at a given
/// mode.
///
/// Since protocol v0.3.0 the server can name the resolution and frame rate it
/// wants along with the camera. Absent means "keep what you are doing", which
/// is the pre-v0.3.0 behaviour and therefore the safe reading of a payload that
/// omits them.
///
/// **The server stores no state for this command** (the protocol doc says
/// "Server state: None"), so its idea of this camera's resolution and frame
/// rate is whatever the registration said. A device that applies a change
/// without re-registering leaves that snapshot describing a mode it is no
/// longer in — the coordinator's job, not this class's.
class SwitchCameraCommand extends DeviceCommand {
  const SwitchCameraCommand({
    super.id,
    required this.cameraEnum,
    this.resolution,
    this.fps,
  });

  /// Index into the camera list the device announced at registration, so it
  /// is always in `0..n-1`.
  final int cameraEnum;

  /// Null keeps the resolution the camera is at.
  final CameraResolution? resolution;

  /// Null keeps the frame rate the camera is at.
  final int? fps;

  @override
  String toString() =>
      'SwitchCameraCommand($cameraEnum'
      '${resolution == null ? '' : ', ${resolution!.label}'}'
      '${fps == null ? '' : ' @ ${fps}fps'})';
}

/// `start_recording` — push video frames for one camera into one stream.
class StartRecordingCommand extends DeviceCommand {
  const StartRecordingCommand({
    super.id,
    required this.cameraEnum,
    required this.streamId,
    this.codec,
  });

  final int cameraEnum;

  /// Server-issued stream id; must be copied verbatim onto every
  /// `recording.frame` for this stream.
  final String streamId;

  /// The codec the server asked for, or null for the device's preferred one —
  /// which is the **first** entry of the announced `supported_codec`, not
  /// necessarily `mjpeg`.
  final CaptureCodec? codec;

  @override
  String toString() =>
      'StartRecordingCommand($cameraEnum, $streamId'
      '${codec == null ? '' : ', ${codec!.wireName}'})';
}

/// `stop_recording` — stop pushing frames for one stream.
class StopRecordingCommand extends DeviceCommand {
  const StopRecordingCommand({
    super.id,
    required this.cameraEnum,
    required this.streamId,
  });

  final int cameraEnum;
  final String streamId;

  @override
  String toString() => 'StopRecordingCommand($cameraEnum, $streamId)';
}

/// `take_photo` — capture and upload one still.
class TakePhotoCommand extends DeviceCommand {
  const TakePhotoCommand({
    super.id,
    required this.cameraEnum,
    required this.requestId,
  });

  final int cameraEnum;

  /// Correlation id that must be copied into the uploaded `photo.photo`.
  final String requestId;

  @override
  String toString() => 'TakePhotoCommand($cameraEnum, $requestId)';
}

/// `ping` — application-level keepalive, sent every 30 seconds.
///
/// Carries no `id`: it is answered with `pong`, never with `ack`.
class PingCommand extends DeviceCommand {
  const PingCommand({this.ts});

  /// The server's send time (RFC3339Nano). Informational only; echoed back in
  /// the `pong` payload.
  final String? ts;

  @override
  String toString() => 'PingCommand($ts)';
}
