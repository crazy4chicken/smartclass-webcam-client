import 'dart:convert';

import '../../capture/camera_capabilities.dart';
import '../../capture/camera_resolution.dart';
import '../../capture/stream_settings.dart';
import '../unrecognized_command_log.dart';
import 'device_command.dart';

/// The three logical channels multiplexed over one WebSocket.
///
/// `control` carries text frames in both directions; `recording` and `photo`
/// carry binary frames from the device to the server only. The server never
/// sends binary frames.
enum WireChannel {
  control,
  recording,
  photo;

  String get wireName => name;

  static WireChannel? tryParse(Object? raw) {
    switch (raw) {
      case 'control':
        return WireChannel.control;
      case 'recording':
        return WireChannel.recording;
      case 'photo':
        return WireChannel.photo;
      default:
        return null;
    }
  }
}

/// The closed codec vocabulary the server accepts in `supported_codec`.
///
/// Exact lowercase FFmpeg-style names, no aliases: `hevc` is **not** accepted
/// as a synonym for `h265`, and `H264` is rejected too. The server performs no
/// negotiation — it stores the announced list verbatim in `metadata.codecs`.
enum WireCodec {
  h264,
  h265,
  mjpeg,
  mpeg4,
  vp8,
  vp9,
  av1;

  /// The exact string that must appear on the wire.
  String get wireName => name;

  static WireCodec? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final codec in WireCodec.values) {
      if (codec.wireName == raw) return codec;
    }
    return null;
  }
}

/// The shared `Message` envelope used by text frames and binary headers.
///
/// ```json
/// {"channel":"control","type":"start_recording","id":"01J8…","payload":{…}}
/// ```
class Message {
  const Message({
    required this.channel,
    required this.type,
    this.id,
    this.payload,
  });

  final WireChannel channel;
  final String type;

  /// Command identifier. Present on the four operator-triggered commands,
  /// absent on `ping` and on media messages.
  final String? id;

  final Map<String, Object?>? payload;

  Map<String, Object?> toJson() => {
    'channel': channel.wireName,
    'type': type,
    if (id != null) 'id': id,
    if (payload != null) 'payload': payload,
  };

  String encode() => jsonEncode(toJson());

  /// Returns null for anything that is not a JSON object envelope.
  ///
  /// Never throws — a malformed frame must not be able to kill the channel.
  static Message? tryParseJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    final type = decoded['type'];
    if (type is! String) return null;

    final rawPayload = decoded['payload'];
    if (rawPayload != null && rawPayload is! Map) return null;

    final rawId = decoded['id'];

    return Message(
      // The server ignores `channel` on text frames, so an absent or unknown
      // value is not an error; `control` is the correct default.
      channel: WireChannel.tryParse(decoded['channel']) ?? WireChannel.control,
      type: type,
      id: rawId is String ? rawId : null,
      payload: rawPayload == null
          ? null
          : Map<String, Object?>.from(rawPayload as Map),
    );
  }

  @override
  String toString() => 'Message(${channel.wireName}/$type, id=$id)';
}

/// Parses one inbound control text frame into a [DeviceCommand].
///
/// Never throws. A malformed JSON body, an unknown `type`, or a payload with
/// an unusable field all return null and are recorded in [log] (when given),
/// which keeps the connection alive and the next frame parseable.
DeviceCommand? parseDeviceCommand(String raw, {UnrecognizedCommandLog? log}) {
  final message = Message.tryParseJson(raw);
  if (message == null) {
    log?.record(raw, UnrecognizedReason.malformedJson);
    return null;
  }

  final payload = message.payload ?? const <String, Object?>{};

  try {
    switch (message.type) {
      case 'switch_camera':
        return SwitchCameraCommand(
          id: message.id,
          cameraEnum: _requireInt(payload, 'camera_enum'),
          resolution: _optionalResolution(payload, 'resolution'),
          fps: _optionalPositiveInt(payload, 'fps'),
        );

      case 'start_recording':
        return StartRecordingCommand(
          id: message.id,
          cameraEnum: _requireInt(payload, 'camera_enum'),
          streamId: _requireNonEmptyString(payload, 'stream_id'),
          codec: _optionalCodec(payload, 'codec'),
        );

      case 'stop_recording':
        return StopRecordingCommand(
          id: message.id,
          cameraEnum: _requireInt(payload, 'camera_enum'),
          streamId: _requireNonEmptyString(payload, 'stream_id'),
        );

      case 'take_photo':
        return TakePhotoCommand(
          id: message.id,
          cameraEnum: _requireInt(payload, 'camera_enum'),
          requestId: _requireNonEmptyString(payload, 'request_id'),
        );

      case 'ping':
        // `ping` is the one server message with no `id`.
        return PingCommand(ts: _optionalString(payload, 'ts'));

      default:
        log?.record(raw, UnrecognizedReason.unknownType);
        return null;
    }
  } on _InvalidPayload {
    log?.record(raw, UnrecognizedReason.invalidPayload);
    return null;
  } catch (_) {
    // Belt and braces: an unexpected failure is still a local note, never a
    // thrown exception and never a dropped connection.
    log?.record(raw, UnrecognizedReason.invalidPayload);
    return null;
  }
}

class _InvalidPayload implements Exception {
  const _InvalidPayload();
}

/// Numbers arrive as JSON numbers; the server truncates fractions toward zero
/// for `camera_enum`, so we do the same rather than rejecting.
int _requireInt(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw const _InvalidPayload();
}

String _requireNonEmptyString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is String && value.isNotEmpty) return value;
  throw const _InvalidPayload();
}

String? _optionalString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  return value is String ? value : null;
}

/// The `WIDTHxHEIGHT` the server asked for, or null.
///
/// **Lenient on purpose**, and the leniency is the whole design: an absent
/// field, an empty string, and a string that is not a `WIDTHxHEIGHT` all mean
/// "no resolution was requested", which leaves the camera where it is. The
/// alternative — rejecting the payload — would drop the command, and a dropped
/// command is never acked: the server does not retry, so the operator would see
/// a `switch_camera` that produced nothing at all.
///
/// The trade is deliberate and narrow. A *usable* value the camera cannot do is
/// still a refusal, acked `ok:false` by the coordinator — that is the case the
/// protocol actually has to guard. An unusable string can only come from a
/// version mismatch or a server bug, and the camera switch that came with it is
/// still worth honouring.
///
/// A whitespace-only value counts as absent because an operator form that
/// leaves the field blank sends `""`.
CameraResolution? _optionalResolution(
  Map<String, Object?> payload,
  String key,
) {
  final value = payload[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return parseResolutionLabel(trimmed);
}

/// A positive frame rate, or null.
///
/// Zero and negatives are treated as "not requested" for the same reason as
/// [_optionalResolution]: the server rejects a non-positive `fps` at
/// registration, so one can never mean a real request.
int? _optionalPositiveInt(Map<String, Object?> payload, String key) {
  final value = payload[key];
  final parsed = switch (value) {
    final int v => v,
    final num v => v.toInt(),
    _ => null,
  };
  if (parsed == null || parsed < 1) return null;
  return parsed;
}

/// The codec the server asked for, or null.
///
/// `CaptureCodec.tryParse` answers null for anything outside the closed set —
/// including `hevc`, which is H.265's other name and is rejected rather than
/// aliased — so an unrecognised name cannot throw. Same reasoning as
/// [_optionalResolution]: the device keeps working rather than dropping the
/// command, and a codec it recognises but cannot produce is refused later with
/// an ack.
CaptureCodec? _optionalCodec(Map<String, Object?> payload, String key) =>
    CaptureCodec.tryParse(payload[key]);
