import 'envelope.dart';

/// RFC 3339 / RFC 3339Nano in UTC.
///
/// Dart's `toIso8601String()` on a UTC `DateTime` emits `…T10:00:00.000Z`,
/// which is a valid RFC 3339 timestamp with fractional seconds — exactly what
/// the server's `time.Time` decoder accepts.
String rfc3339(DateTime value) => value.toUtc().toIso8601String();

/// Every device-to-server control message.
///
/// Four types are understood on the `control` channel. Anything else is
/// ignored by the server with a debug log, so a rollout can add message types
/// without breaking existing servers.
sealed class DeviceMessage {
  const DeviceMessage();

  Message toMessage();

  Map<String, Object?> toJson() => toMessage().toJson();

  String encode() => toMessage().encode();
}

/// `ack` — the result of a server command.
///
/// Every command that carries an `id` **must** be acked, success or failure.
/// The server never waits for it and never validates it, but an operator has
/// no other way to learn that a command was refused.
class AckMessage extends DeviceMessage {
  const AckMessage({required this.id, required this.ok, this.error});

  /// The exact `id` of the command being acknowledged.
  final String id;

  final bool ok;

  /// Human-readable failure reason, present when [ok] is false.
  final String? error;

  @override
  Message toMessage() => Message(
    channel: WireChannel.control,
    type: 'ack',
    id: id,
    payload: {'ok': ok, if (error != null) 'error': error},
  );

  @override
  String toString() => 'AckMessage($id, ok=$ok, error=$error)';
}

/// `pong` — keepalive answer to a server `ping`.
///
/// Any inbound frame refreshes the server's 60-second read deadline, so the
/// payload is informational only; [ts] echoes the ping verbatim.
class PongMessage extends DeviceMessage {
  const PongMessage({this.ts});

  final String? ts;

  @override
  Message toMessage() => Message(
    channel: WireChannel.control,
    type: 'pong',
    payload: {if (ts != null) 'ts': ts},
  );

  @override
  String toString() => 'PongMessage($ts)';
}

/// `status` — a device-initiated state report.
///
/// The server logs it at info level and stores nothing. We send one while
/// idle so the 60-second silence deadline never trips.
class StatusMessage extends DeviceMessage {
  const StatusMessage({required this.report});

  /// Free-form; the server imposes no schema.
  final Map<String, Object?> report;

  @override
  Message toMessage() =>
      Message(channel: WireChannel.control, type: 'status', payload: report);

  @override
  String toString() => 'StatusMessage($report)';
}

/// `error` — a problem that does not belong to a pending command.
///
/// For a failure of a specific command, prefer `ack` with `ok: false`.
class ErrorMessage extends DeviceMessage {
  const ErrorMessage({this.id, required this.message});

  /// The command id when the error belongs to one; null otherwise.
  final String? id;

  final String message;

  @override
  Message toMessage() => Message(
    channel: WireChannel.control,
    type: 'error',
    id: id,
    payload: {'message': message},
  );

  @override
  String toString() => 'ErrorMessage($id, $message)';
}

/// Header for one `recording.frame`.
///
/// The bytes after the header are one encoded video frame — for `mjpeg`, one
/// JPEG picture. The server stores payloads byte for byte, so each message
/// must be exactly one frame: there is no container and no reassembly.
class RecordingFrameMeta {
  const RecordingFrameMeta({
    required this.cameraEnum,
    required this.streamId,
    required this.seq,
    required this.ts,
  });

  final int cameraEnum;

  /// Must equal the `stream_id` delivered by `start_recording`.
  final String streamId;

  /// Monotonic counter per stream, starting at 0. The server stores frames in
  /// arrival order regardless, but consumers use `seq` to detect gaps.
  final int seq;

  final DateTime ts;

  Message toMessage() => Message(
    channel: WireChannel.recording,
    type: 'frame',
    payload: {
      'camera_enum': cameraEnum,
      'stream_id': streamId,
      'seq': seq,
      'ts': rfc3339(ts),
    },
  );

  Map<String, Object?> toJson() => toMessage().toJson();

  @override
  String toString() => 'RecordingFrameMeta($cameraEnum, $streamId, #$seq)';
}

/// Header for one `photo.photo`.
class PhotoMeta {
  const PhotoMeta({
    required this.cameraEnum,
    required this.ts,
    this.requestId,
    this.contentType = 'image/jpeg',
  });

  final int cameraEnum;

  /// The `request_id` from the `take_photo` command this photo answers, when
  /// there is one. It is the only link back to the operator's call.
  final String? requestId;

  /// Canonical value is `image/jpeg`; the server stores it verbatim.
  final String contentType;

  final DateTime ts;

  Message toMessage() => Message(
    channel: WireChannel.photo,
    type: 'photo',
    payload: {
      'camera_enum': cameraEnum,
      if (requestId != null) 'request_id': requestId,
      'content_type': contentType,
      'ts': rfc3339(ts),
    },
  );

  Map<String, Object?> toJson() => toMessage().toJson();

  @override
  String toString() => 'PhotoMeta($cameraEnum, requestId=$requestId)';
}
