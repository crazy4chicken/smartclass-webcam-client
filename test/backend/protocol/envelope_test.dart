import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/protocol/device_command.dart';
import 'package:webcam_client/src/backend/protocol/device_message.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';
import 'package:webcam_client/src/backend/unrecognized_command_log.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

void main() {
  group('parseDeviceCommand', () {
    test('parses start_recording into its command', () {
      final cmd = parseDeviceCommand(
        '{"channel":"control","type":"start_recording",'
        '"id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B1",'
        '"payload":{"camera_enum":0,"stream_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B2"}}',
      );

      expect(cmd, isA<StartRecordingCommand>());
      final start = cmd! as StartRecordingCommand;
      expect(start.id, '01J8ZKQ3B5N7P9R1T3V5X7Z9B1');
      expect(start.cameraEnum, 0);
      expect(start.streamId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
    });

    test('parses ping, which carries no id', () {
      final cmd = parseDeviceCommand(
        '{"channel":"control","type":"ping",'
        '"payload":{"ts":"2026-10-04T10:00:30.512384921Z"}}',
      );

      expect(cmd, isA<PingCommand>());
      expect((cmd! as PingCommand).ts, '2026-10-04T10:00:30.512384921Z');
      expect(cmd.id, isNull);
    });

    test('parses take_photo and keeps the request id verbatim', () {
      final cmd =
          parseDeviceCommand(
                '{"channel":"control","type":"take_photo","id":"c",'
                '"payload":{"camera_enum":1,"request_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B3"}}',
              )!
              as TakePhotoCommand;

      expect(cmd.cameraEnum, 1);
      expect(cmd.requestId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B3');
    });

    test('parses switch_camera and stop_recording', () {
      final switchCmd =
          parseDeviceCommand(
                '{"channel":"control","type":"switch_camera","id":"e",'
                '"payload":{"camera_enum":1}}',
              )!
              as SwitchCameraCommand;
      expect(switchCmd.cameraEnum, 1);

      final stop =
          parseDeviceCommand(
                '{"channel":"control","type":"stop_recording","id":"b",'
                '"payload":{"camera_enum":0,"stream_id":"s"}}',
              )!
              as StopRecordingCommand;
      expect(stop.streamId, 's');
    });

    test('truncates a fractional camera_enum the way the server does', () {
      final cmd =
          parseDeviceCommand(
                '{"channel":"control","type":"switch_camera","id":"e",'
                '"payload":{"camera_enum":1.9}}',
              )!
              as SwitchCameraCommand;
      expect(cmd.cameraEnum, 1);
    });

    test('switch_camera carries resolution and fps when they are present', () {
      // Protocol v0.3.0 lets the server name the mode along with the camera.
      final cmd =
          parseDeviceCommand(
                '{"channel":"control","type":"switch_camera","id":"e",'
                '"payload":{"camera_enum":1,"resolution":"1280x720","fps":30}}',
              )!
              as SwitchCameraCommand;

      expect(cmd.cameraEnum, 1);
      expect(cmd.resolution, const CameraResolution(width: 1280, height: 720));
      expect(cmd.fps, 30);
    });

    test('switch_camera leaves them null when the payload omits them', () {
      // Absent means "keep what you are doing", which is also the pre-v0.3.0
      // behaviour — so an older server keeps working unchanged.
      final cmd =
          parseDeviceCommand(
                '{"channel":"control","type":"switch_camera","id":"e",'
                '"payload":{"camera_enum":0}}',
              )!
              as SwitchCameraCommand;

      expect(cmd.resolution, isNull);
      expect(cmd.fps, isNull);
    });

    test('a whitespace-only resolution counts as absent', () {
      // An operator form that leaves the field blank sends `""`.
      for (final blank in <String>['', '   ', '\t']) {
        final cmd =
            parseDeviceCommand(
                  '{"channel":"control","type":"switch_camera","id":"e",'
                  '"payload":{"camera_enum":0,"resolution":"$blank"}}',
                )!
                as SwitchCameraCommand;
        expect(cmd.resolution, isNull, reason: 'value: "$blank"');
      }
    });

    test('a resolution the device cannot parse is treated as absent', () {
      // Lenient on purpose: rejecting the payload would drop the command, and a
      // dropped command is never acked — the server does not retry, so the
      // operator would see nothing at all. The camera switch that came with it
      // is still worth honouring.
      for (final junk in <String>['720p', '1280', '1280x', 'x720', '0x480']) {
        final cmd =
            parseDeviceCommand(
                  '{"channel":"control","type":"switch_camera","id":"e",'
                  '"payload":{"camera_enum":0,"resolution":"$junk"}}',
                )!
                as SwitchCameraCommand;
        expect(cmd.resolution, isNull, reason: 'value: "$junk"');
        expect(cmd.cameraEnum, 0);
      }
    });

    test('a non-positive fps counts as absent', () {
      // The server rejects a non-positive `fps` at registration, so one can
      // never mean a real request.
      for (final value in <String>['0', '-5']) {
        final cmd =
            parseDeviceCommand(
                  '{"channel":"control","type":"switch_camera","id":"e",'
                  '"payload":{"camera_enum":0,"fps":$value}}',
                )!
                as SwitchCameraCommand;
        expect(cmd.fps, isNull, reason: 'value: $value');
      }
    });

    test('start_recording carries the requested codec', () {
      final cmd =
          parseDeviceCommand(
                '{"channel":"control","type":"start_recording","id":"a",'
                '"payload":{"camera_enum":0,"stream_id":"s","codec":"mjpeg"}}',
              )!
              as StartRecordingCommand;

      expect(cmd.codec, CaptureCodec.mjpeg);
      expect(cmd.streamId, 's');
    });

    test('start_recording leaves the codec null when it is absent', () {
      // Null means "the device's preferred codec", which is the *first* entry
      // of the announced `supported_codec` — not necessarily mjpeg.
      final cmd =
          parseDeviceCommand(
                '{"channel":"control","type":"start_recording","id":"a",'
                '"payload":{"camera_enum":0,"stream_id":"s"}}',
              )!
              as StartRecordingCommand;

      expect(cmd.codec, isNull);
    });

    test('an unknown codec string decodes to null rather than throwing', () {
      for (final name in <String>['hevc', 'H264', 'MJPEG', 'garbage', '']) {
        final cmd =
            parseDeviceCommand(
                  '{"channel":"control","type":"start_recording","id":"a",'
                  '"payload":{"camera_enum":0,"stream_id":"s",'
                  '"codec":"$name"}}',
                )!
                as StartRecordingCommand;
        expect(cmd.codec, isNull, reason: 'value: "$name"');
      }

      // A recognised but unavailable codec still decodes — refusing it is the
      // coordinator's job, and it has to know what was asked for to say so.
      final h264 =
          parseDeviceCommand(
                '{"channel":"control","type":"start_recording","id":"a",'
                '"payload":{"camera_enum":0,"stream_id":"s","codec":"h264"}}',
              )!
              as StartRecordingCommand;
      expect(h264.codec, CaptureCodec.h264);
    });

    test('unknown command types are ignored, not errors', () {
      expect(
        parseDeviceCommand('{"channel":"control","type":"cmd_do_a_backflip"}'),
        isNull,
      );
      expect(parseDeviceCommand('not json'), isNull);
      expect(parseDeviceCommand(''), isNull);
      expect(parseDeviceCommand('[]'), isNull);
    });

    test('a known type with an unusable payload is rejected', () {
      expect(
        parseDeviceCommand(
          '{"channel":"control","type":"start_recording",'
          '"payload":{"camera_enum":0}}',
        ),
        isNull,
      );
      expect(
        parseDeviceCommand(
          '{"channel":"control","type":"start_recording",'
          '"payload":{"camera_enum":"zero","stream_id":"s"}}',
        ),
        isNull,
      );
      // An empty stream id is dropped by the server, so it is not a command.
      expect(
        parseDeviceCommand(
          '{"channel":"control","type":"start_recording",'
          '"payload":{"camera_enum":0,"stream_id":""}}',
        ),
        isNull,
      );
    });

    test('records what it could not parse, and never throws', () {
      final log = UnrecognizedCommandLog(sink: null);

      parseDeviceCommand('{"channel":"control","type":"nope"}', log: log);
      parseDeviceCommand('<<garbage>>', log: log);
      parseDeviceCommand(
        '{"channel":"control","type":"take_photo","payload":{"camera_enum":0}}',
        log: log,
      );

      expect(log.entries.map((e) => e.reason).toList(), [
        UnrecognizedReason.unknownType,
        UnrecognizedReason.malformedJson,
        UnrecognizedReason.invalidPayload,
      ]);
      expect(log.entries[1].raw, '<<garbage>>');
    });

    test('a well-formed command is not recorded', () {
      final log = UnrecognizedCommandLog(sink: null);
      parseDeviceCommand(
        '{"channel":"control","type":"ping","payload":{"ts":"t"}}',
        log: log,
      );
      expect(log.entries, isEmpty);
    });
  });

  group('WireCodec', () {
    test('is the closed set and rejects the hevc alias', () {
      expect(WireCodec.tryParse('h264'), WireCodec.h264);
      expect(WireCodec.tryParse('h265'), WireCodec.h265);
      expect(WireCodec.tryParse('mjpeg'), WireCodec.mjpeg);
      expect(WireCodec.tryParse('mpeg4'), WireCodec.mpeg4);
      expect(WireCodec.tryParse('vp8'), WireCodec.vp8);
      expect(WireCodec.tryParse('vp9'), WireCodec.vp9);
      expect(WireCodec.tryParse('av1'), WireCodec.av1);
    });

    test('rejects every alias and case variant the server rejects', () {
      expect(WireCodec.tryParse('hevc'), isNull);
      expect(WireCodec.tryParse('H264'), isNull);
      expect(WireCodec.tryParse('MJPEG'), isNull);
      expect(WireCodec.tryParse('h264 '), isNull);
      expect(WireCodec.tryParse(''), isNull);
      expect(WireCodec.tryParse(null), isNull);
      expect(WireCodec.tryParse(264), isNull);
    });

    test('wire names are exact lowercase', () {
      expect(WireCodec.values.map((c) => c.wireName).toList(), [
        'h264',
        'h265',
        'mjpeg',
        'mpeg4',
        'vp8',
        'vp9',
        'av1',
      ]);
      expect(WireCodec.values.map((c) => c.wireName), isNot(contains('hevc')));
    });
  });

  group('envelope', () {
    test('parses the three channels', () {
      expect(WireChannel.tryParse('control'), WireChannel.control);
      expect(WireChannel.tryParse('recording'), WireChannel.recording);
      expect(WireChannel.tryParse('photo'), WireChannel.photo);
      expect(WireChannel.tryParse('video'), isNull);
    });

    test('a text frame defaults to control when channel is missing', () {
      final message = Message.tryParseJson('{"type":"ping"}');
      expect(message, isNotNull);
      expect(message!.channel, WireChannel.control);
    });

    test('rejects a payload that is not an object', () {
      expect(Message.tryParseJson('{"type":"ping","payload":[]}'), isNull);
      expect(Message.tryParseJson('{"type":123}'), isNull);
      expect(Message.tryParseJson('nonsense'), isNull);
    });

    test('omits id and payload from the encoded form when absent', () {
      final json = const Message(
        channel: WireChannel.control,
        type: 'pong',
      ).toJson();
      expect(json.containsKey('id'), isFalse);
      expect(json.containsKey('payload'), isFalse);
    });
  });

  group('DeviceMessage', () {
    test('ack echoes the command id verbatim', () {
      final json = AckMessage(
        id: '01J8ZKQ3B5N7P9R1T3V5X7Z9B1',
        ok: false,
        error: 'camera 0 is busy',
      ).toJson();

      expect(json['channel'], 'control');
      expect(json['type'], 'ack');
      expect(json['id'], '01J8ZKQ3B5N7P9R1T3V5X7Z9B1');
      expect((json['payload']! as Map)['ok'], false);
      expect((json['payload']! as Map)['error'], 'camera 0 is busy');
    });

    test('a successful ack carries no error key', () {
      final payload = AckMessage(id: 'x', ok: true).toJson()['payload']! as Map;
      expect(payload.containsKey('error'), isFalse);
    });

    test('pong echoes the ping timestamp', () {
      final json = const PongMessage(ts: '2026-10-04T10:00:30Z').toJson();
      expect(json['type'], 'pong');
      expect((json['payload']! as Map)['ts'], '2026-10-04T10:00:30Z');
    });

    test('status carries a free-form report', () {
      final json = const StatusMessage(report: {'recording': false}).toJson();
      expect(json['type'], 'status');
      expect((json['payload']! as Map)['recording'], false);
    });

    test('error carries the message and an optional id', () {
      final json = const ErrorMessage(message: 'camera 1 is unavailable')
          .toJson();
      expect(json['type'], 'error');
      expect(json.containsKey('id'), isFalse);
      expect((json['payload']! as Map)['message'], 'camera 1 is unavailable');
    });
  });

  group('media headers', () {
    test('the protocol doc worked example encodes to a 144-byte header', () {
      // Pins the framing against the server's own example: if this string ever
      // grows, every length prefix changes with it.
      final header = const Message(
        channel: WireChannel.recording,
        type: 'frame',
        payload: <String, Object?>{
          'camera_enum': 0,
          'seq': 42,
          'stream_id': '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
          'ts': '2026-10-04T10:00:00Z',
        },
      );

      expect(
        header.encode(),
        '{"channel":"recording","type":"frame","payload":'
        '{"camera_enum":0,"seq":42,'
        '"stream_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B2",'
        '"ts":"2026-10-04T10:00:00Z"}}',
      );
      expect(header.encode().length, 144);
    });

    test('a recording header carries the four keys the server reads', () {
      final message = RecordingFrameMeta(
        cameraEnum: 0,
        streamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
        seq: 42,
        ts: DateTime.utc(2026, 10, 4, 10),
      ).toMessage();

      expect(message.channel, WireChannel.recording);
      expect(message.type, 'frame');
      // The media channels never use the envelope id.
      expect(message.id, isNull);

      final payload = message.payload!;
      expect(payload['camera_enum'], 0);
      expect(payload['stream_id'], '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
      expect(payload['seq'], 42);
      expect(
        DateTime.parse(payload['ts']! as String),
        DateTime.utc(2026, 10, 4, 10),
      );
    });

    test('a photo header carries the canonical content type', () {
      final message = PhotoMeta(
        cameraEnum: 0,
        requestId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B3',
        ts: DateTime.utc(2026, 10, 4, 10, 0, 5),
      ).toMessage();

      expect(message.channel, WireChannel.photo);
      expect(message.type, 'photo');
      expect(message.payload!['content_type'], 'image/jpeg');
      expect(message.payload!['request_id'], '01J8ZKQ3B5N7P9R1T3V5X7Z9B3');
    });

    test('an unsolicited photo omits request_id', () {
      final message = PhotoMeta(
        cameraEnum: 0,
        ts: DateTime.utc(2026),
      ).toMessage();
      expect(message.payload!.containsKey('request_id'), isFalse);
    });
  });
}
