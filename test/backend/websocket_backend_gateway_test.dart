import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webcam_client/src/backend/client_signal.dart';
import 'package:webcam_client/src/backend/command_codec.dart';
import 'package:webcam_client/src/backend/server_command.dart';
import 'package:webcam_client/src/backend/unrecognized_command_log.dart';
import 'package:webcam_client/src/backend/websocket_backend_gateway.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

class FakeSink implements WebSocketSink {
  final records = <Object>[];

  @override
  void add(dynamic data) => records.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  Future<void> get done => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChannel implements WebSocketChannel {
  _FakeChannel(this._stream, this._sink);

  final Stream<dynamic> _stream;
  final FakeSink _sink;

  @override
  Stream<dynamic> get stream => _stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('routes parsed text frames to commands stream', () async {
    final incoming = StreamController<dynamic>();
    final gw = WebSocketBackendGateway(
      codec: JsonCommandCodec(),
      channelFactory: (_) => _FakeChannel(incoming.stream, FakeSink()),
    );
    await gw.connect('ws://x');
    incoming.add(
      '{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}',
    );
    await expectLater(gw.commands, emits(isA<FaceResultCommand>()));
    await gw.disconnect();
    await incoming.close();
  });

  test('malformed frame is recorded locally and the channel survives the next valid frame', () async {
    final incoming = StreamController<dynamic>();
    final log = UnrecognizedCommandLog(sink: null);
    final gw = WebSocketBackendGateway(
      codec: JsonCommandCodec(unrecognizedLog: log),
      channelFactory: (_) => _FakeChannel(incoming.stream, FakeSink()),
    );
    await gw.connect('ws://x');
    incoming.add('<<garbage>>');
    await pumpEventQueue();
    expect(log.entries.single.raw, '<<garbage>>');
    expect(log.entries.single.reason, UnrecognizedReason.malformedJson);
    incoming.add('{"type":"cmd_control_stream","payload":{"enabled":false}}');
    await expectLater(gw.commands, emits(isA<ControlStreamCommand>()));
    await gw.disconnect();
    await incoming.close();
  });

  test('frame upload emits meta text before binary', () async {
    final sink = FakeSink();
    final gw = WebSocketBackendGateway(
      codec: JsonCommandCodec(),
      channelFactory: (_) => _FakeChannel(const Stream<dynamic>.empty(), sink),
    );
    await gw.connect('ws://x');
    gw.sendFrameMeta(
      const FrameMeta(
        frameId: 7,
        deviceId: 'd',
        timestampMs: 1,
        width: 1280,
        height: 720,
        quality: 80,
      ),
    );
    gw.sendFrameBytes(Uint8List.fromList([1, 2, 3]));
    expect(sink.records.length, 2);
    expect(jsonDecode(sink.records.first as String)['type'], 'frame_meta');
    expect(sink.records.last, isA<Uint8List>());
    await gw.disconnect();
  });

  test('video upload emits video_meta text before binary', () async {
    final sink = FakeSink();
    final gw = WebSocketBackendGateway(
      codec: JsonCommandCodec(),
      channelFactory: (_) => _FakeChannel(const Stream<dynamic>.empty(), sink),
    );
    await gw.connect('ws://x');
    gw.sendVideoMeta(
      const VideoMeta(
        chunkId: 1,
        deviceId: 'd',
        timestampMs: 1,
        codec: VideoCodec.avc,
        sequence: 0,
        durationMs: 3000,
        width: 1280,
        height: 720,
      ),
    );
    gw.sendVideoBytes(Uint8List.fromList([0, 0, 0, 24]));
    expect(jsonDecode(sink.records.first as String)['type'], 'video_meta');
    expect(jsonDecode(sink.records.first as String)['payload']['codec'], 'avc');
    await gw.disconnect();
  });

  test('backoff grows and caps at 16 seconds', () {
    expect(backoffFor(0), const Duration(seconds: 1));
    expect(backoffFor(2), const Duration(seconds: 4));
    expect(backoffFor(99), const Duration(seconds: 16));
  });
}
