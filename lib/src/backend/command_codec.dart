import 'dart:convert';

import '../capture/stream_settings.dart';
import 'client_signal.dart';
import 'server_command.dart';
import 'unrecognized_command_log.dart';

/// Translates between raw wire frames and the domain model.
///
/// This is the **only** place that knows the backend's JSON shape. The backend
/// protocol is not final, so replacing this implementation must be enough to
/// adopt a new one.
abstract interface class CommandCodec {
  /// Returns null for anything we cannot understand — never throws.
  ServerCommand? decode(String raw);

  String encode(ClientSignal signal);

  /// Local record of inbound messages the codec could not understand.
  UnrecognizedCommandLog get unrecognizedCommands;
}

class _InvalidPayload implements Exception {
  const _InvalidPayload();
}

/// JSON implementation of [CommandCodec].
///
/// Fault tolerance is the point: a malformed or hostile inbound frame must not
/// throw, must not kill the channel, and must not stop later valid frames from
/// being parsed. It is recorded in [unrecognizedLog] instead.
class JsonCommandCodec implements CommandCodec {
  JsonCommandCodec({UnrecognizedCommandLog? unrecognizedLog})
    : unrecognizedLog = unrecognizedLog ?? UnrecognizedCommandLog();

  final UnrecognizedCommandLog unrecognizedLog;

  @override
  UnrecognizedCommandLog get unrecognizedCommands => unrecognizedLog;

  @override
  ServerCommand? decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      unrecognizedLog.record(raw, UnrecognizedReason.malformedJson);
      return null;
    }

    if (decoded is! Map) {
      unrecognizedLog.record(raw, UnrecognizedReason.malformedJson);
      return null;
    }

    final type = decoded['type'];
    if (type is! String) {
      unrecognizedLog.record(raw, UnrecognizedReason.unknownType);
      return null;
    }

    final rawPayload = decoded['payload'];
    final payload = rawPayload is Map ? rawPayload : const <Object?, Object?>{};

    try {
      switch (type) {
        case 'cmd_update_config':
          return UpdateConfigCommand(
            width: _optInt(payload, 'width'),
            height: _optInt(payload, 'height'),
            quality: _optInt(payload, 'quality'),
            fps: _optDouble(payload, 'fps'),
          );

        case 'cmd_set_stream_mode':
          return SetStreamModeCommand(
            mode: _optMode(payload['mode']),
            codec: _optCodec(payload['codec']),
            chunkSeconds: _optInt(payload, 'chunkSeconds'),
          );

        case 'cmd_control_stream':
          return ControlStreamCommand(enabled: _reqBool(payload, 'enabled'));

        case 'cmd_switch_camera':
          return SwitchCameraCommand(index: _reqInt(payload, 'index'));

        case 'cmd_set_preview':
          return SetPreviewCommand(enabled: _reqBool(payload, 'enabled'));

        case 'event_face_result':
          return FaceResultCommand(
            result: FaceResult(
              name: _reqString(payload, 'name'),
              status: _reqString(payload, 'status'),
            ),
          );

        default:
          unrecognizedLog.record(raw, UnrecognizedReason.unknownType);
          return null;
      }
    } on _InvalidPayload {
      unrecognizedLog.record(raw, UnrecognizedReason.invalidPayload);
      return null;
    } catch (_) {
      // Belt and braces: any unexpected failure is still a local note, never a
      // thrown exception and never a dropped connection.
      unrecognizedLog.record(raw, UnrecognizedReason.invalidPayload);
      return null;
    }
  }

  @override
  String encode(ClientSignal signal) {
    switch (signal) {
      case RegisterSignal():
        return jsonEncode({
          'type': 'register',
          'payload': {
            'deviceId': signal.deviceId,
            'capabilities': signal.capabilities.toJson(),
          },
        });

      case HeartbeatSignal():
        return jsonEncode({
          'type': 'heartbeat',
          'payload': {'deviceId': signal.deviceId},
        });

      case StateSyncSignal():
        return jsonEncode({
          'type': 'state_sync',
          'payload': {
            'width': signal.width,
            'height': signal.height,
            'quality': signal.quality,
            'fps': signal.fps,
            'cameraIndex': signal.cameraIndex,
            'streaming': signal.streaming,
            'mode': signal.mode.wireName,
            'codec': signal.codec.wireName,
            'chunkSeconds': signal.chunkSeconds,
            'previewEnabled': signal.previewEnabled,
          },
        });

      case FrameMetaSignal():
        final m = signal.meta;
        return jsonEncode({
          'type': 'frame_meta',
          'payload': {
            'frameId': m.frameId,
            'deviceId': m.deviceId,
            'timestampMs': m.timestampMs,
            'width': m.width,
            'height': m.height,
            'quality': m.quality,
          },
        });

      case VideoMetaSignal():
        final m = signal.meta;
        return jsonEncode({
          'type': 'video_meta',
          'payload': {
            'chunkId': m.chunkId,
            'deviceId': m.deviceId,
            'timestampMs': m.timestampMs,
            'codec': m.codec.wireName,
            'sequence': m.sequence,
            'durationMs': m.durationMs,
            'width': m.width,
            'height': m.height,
          },
        });

      case CapabilityMismatchSignal():
        return jsonEncode({
          'type': 'capability_mismatch',
          'payload': {
            'requested': signal.requested,
            'applied': signal.applied,
            'reason': signal.reason,
          },
        });
    }
  }

  // --- lenient readers -----------------------------------------------------

  static int? _optInt(Map payload, String key) {
    if (!payload.containsKey(key)) return null;
    final value = payload[key];
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw const _InvalidPayload();
  }

  static double? _optDouble(Map payload, String key) {
    if (!payload.containsKey(key)) return null;
    final value = payload[key];
    if (value == null) return null;
    if (value is num) return value.toDouble();
    throw const _InvalidPayload();
  }

  static int _reqInt(Map payload, String key) =>
      _optInt(payload, key) ?? (throw const _InvalidPayload());

  static bool _reqBool(Map payload, String key) {
    final value = payload[key];
    if (value is bool) return value;
    throw const _InvalidPayload();
  }

  static String _reqString(Map payload, String key) {
    final value = payload[key];
    if (value is String) return value;
    throw const _InvalidPayload();
  }

  /// Enums are parsed leniently: an unknown name means "not provided", not a
  /// malformed message.
  static StreamMode? _optMode(Object? value) =>
      value is String ? StreamMode.tryParse(value) : null;

  static VideoCodec? _optCodec(Object? value) =>
      value is String ? VideoCodec.tryParse(value) : null;
}
