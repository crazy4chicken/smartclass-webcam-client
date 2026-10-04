import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/client_signal.dart';
import 'package:webcam_client/src/backend/command_codec.dart';
import 'package:webcam_client/src/backend/server_command.dart';
import 'package:webcam_client/src/backend/unrecognized_command_log.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

void main() {
  final codec = JsonCommandCodec();

  test('decodes cmd_update_config with absolute pixels', () {
    final u =
        codec.decode(
              '{"type":"cmd_update_config","payload":{"width":1920,"height":1080,"quality":90,"fps":5}}',
            )!
            as UpdateConfigCommand;
    expect(u.width, 1920);
    expect(u.height, 1080);
    expect(u.quality, 90);
    expect(u.fps, 5.0);
  });

  test('decodes cmd_set_stream_mode with an explicit codec', () {
    final c =
        codec.decode(
              '{"type":"cmd_set_stream_mode","payload":{"mode":"video","codec":"hevc","chunkSeconds":2}}',
            )!
            as SetStreamModeCommand;
    expect(c.mode, StreamMode.video);
    expect(c.codec, VideoCodec.hevc);
    expect(c.chunkSeconds, 2);
  });

  test('decodes cmd_set_preview', () {
    final c =
        codec.decode('{"type":"cmd_set_preview","payload":{"enabled":false}}')!
            as SetPreviewCommand;
    expect(c.enabled, isFalse);
  });

  test('decodes event_face_result', () {
    final c =
        codec.decode(
              '{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}',
            )!
            as FaceResultCommand;
    expect(c.result.name, '张三');
  });

  test('records malformed json locally instead of throwing', () {
    final log = UnrecognizedCommandLog(sink: null);
    final c = JsonCommandCodec(unrecognizedLog: log);
    expect(c.decode('this is not json'), isNull);
    expect(c.decode(''), isNull);
    expect(c.decode('[]'), isNull);
    expect(log.entries.length, 3);
    expect(log.entries.first.raw, 'this is not json');
    expect(log.entries.first.reason, UnrecognizedReason.malformedJson);
  });

  test('records unknown command types with the raw payload intact', () {
    final log = UnrecognizedCommandLog(sink: null);
    final raw = '{"type":"cmd_do_a_backflip","payload":{"x":1}}';
    expect(JsonCommandCodec(unrecognizedLog: log).decode(raw), isNull);
    expect(log.entries.single.reason, UnrecognizedReason.unknownType);
    expect(log.entries.single.raw, raw);
  });

  test('records payloads with hostile field types instead of throwing', () {
    final log = UnrecognizedCommandLog(sink: null);
    expect(
      JsonCommandCodec(unrecognizedLog: log)
          .decode('{"type":"cmd_update_config","payload":{"width":"banana"}}'),
      isNull,
    );
    expect(log.entries.single.reason, UnrecognizedReason.invalidPayload);
  });

  test('does not record well-formed commands', () {
    final log = UnrecognizedCommandLog(sink: null);
    final c = JsonCommandCodec(unrecognizedLog: log);
    c.decode('{"type":"cmd_control_stream","payload":{"enabled":false}}');
    c.decode('{"type":"cmd_set_preview","payload":{"enabled":true}}');
    expect(log.entries, isEmpty);
  });

  test('unknown enum values degrade to "not provided" rather than failing', () {
    final log = UnrecognizedCommandLog(sink: null);
    final c = JsonCommandCodec(unrecognizedLog: log);
    final cmd =
        c.decode(
              '{"type":"cmd_set_stream_mode","payload":{"mode":"teleport","codec":"vp9"}}',
            )!
            as SetStreamModeCommand;
    expect(cmd.mode, isNull);
    expect(cmd.codec, isNull);
    expect(log.entries, isEmpty);
  });

  test('encodes state_sync carrying mode, codec and preview', () {
    final map = jsonDecode(
      codec.encode(
        StateSyncSignal(
          width: 1280,
          height: 720,
          quality: 80,
          fps: 1.0,
          cameraIndex: 0,
          streaming: true,
          mode: StreamMode.video,
          codec: VideoCodec.avc,
          chunkSeconds: 3,
          previewEnabled: false,
        ),
      ),
    ) as Map<String, dynamic>;
    expect(map['type'], 'state_sync');
    expect(map['payload']['mode'], 'video');
    expect(map['payload']['codec'], 'avc');
    expect(map['payload']['previewEnabled'], false);
  });

  test('encodes capability mismatch so the backend learns what really ran', () {
    final map = jsonDecode(
      codec.encode(
        const CapabilityMismatchSignal(
          requested: 'hevc',
          applied: 'avc',
          reason: 'codec unavailable',
        ),
      ),
    ) as Map<String, dynamic>;
    expect(map['type'], 'capability_mismatch');
    expect(map['payload']['requested'], 'hevc');
    expect(map['payload']['applied'], 'avc');
  });

  test('encodes heartbeat with the agreed type name', () {
    expect(
      jsonDecode(codec.encode(const HeartbeatSignal(deviceId: 'd')))['type'],
      'heartbeat',
    );
  });
}
