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

/// `switch_camera` — make one camera the active one.
class SwitchCameraCommand extends DeviceCommand {
  const SwitchCameraCommand({super.id, required this.cameraEnum});

  /// Index into the camera list the device announced at registration, so it
  /// is always in `0..n-1`.
  final int cameraEnum;

  @override
  String toString() => 'SwitchCameraCommand($cameraEnum)';
}

/// `start_recording` — push video frames for one camera into one stream.
class StartRecordingCommand extends DeviceCommand {
  const StartRecordingCommand({
    super.id,
    required this.cameraEnum,
    required this.streamId,
  });

  final int cameraEnum;

  /// Server-issued stream id; must be copied verbatim onto every
  /// `recording.frame` for this stream.
  final String streamId;

  @override
  String toString() => 'StartRecordingCommand($cameraEnum, $streamId)';
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
