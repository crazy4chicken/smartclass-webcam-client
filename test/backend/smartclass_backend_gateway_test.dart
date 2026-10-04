import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/protocol/binary_frame.dart';
import 'package:webcam_client/src/backend/protocol/device_command.dart';
import 'package:webcam_client/src/backend/protocol/device_message.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';
import 'package:webcam_client/src/backend/registration_client.dart';
import 'package:webcam_client/src/backend/smartclass_backend_gateway.dart';

import '../support/doubles.dart';

/// A gateway wired to a fake channel, with the timing knobs shortened so the
/// tests are deterministic rather than merely probably-fast.
({
  SmartClassBackendGateway gateway,
  FakeRegistrationClient registration,
  StreamController<dynamic> incoming,
  FakeChannelSink sink,
  List<StreamController<dynamic>> opened,
})
_build({
  RegistrationFailure? failure,
  Duration Function(int)? backoff,
  Duration? idleStatusInterval,
  Object? readyError,
  String? websocketPath,
}) {
  final registration = FakeRegistrationClient(
    failure: failure,
    websocketPath: websocketPath,
  );
  final sink = FakeChannelSink();

  // The first socket is created up front so a test can push frames into it;
  // every later attach gets a fresh one, because a retry must never reuse the
  // previous connection.
  final first = StreamController<dynamic>();
  final opened = <StreamController<dynamic>>[];

  final gateway = SmartClassBackendGateway(
    base: Uri.parse('http://localhost:8080'),
    registration: registration,
    channelFactory: (_) {
      final controller = opened.isEmpty ? first : StreamController<dynamic>();
      opened.add(controller);
      return FakeChannel(controller.stream, sink, readyError: readyError);
    },
    cameras: const [testCamera],
    backoff: backoff ?? (_) => const Duration(milliseconds: 5),
    idleStatusInterval: idleStatusInterval,
  );

  return (
    gateway: gateway,
    registration: registration,
    incoming: first,
    sink: sink,
    opened: opened,
  );
}

Map<String, dynamic> _lastJson(FakeChannelSink sink) =>
    jsonDecode(sink.text.last) as Map<String, dynamic>;

void main() {
  test('registers then attaches with the ticket in the path', () async {
    Uri? attached;
    final registration = FakeRegistrationClient();
    final incoming = StreamController<dynamic>();
    final gateway = SmartClassBackendGateway(
      base: Uri.parse('http://localhost:8080'),
      registration: registration,
      channelFactory: (uri) {
        attached = uri;
        return FakeChannel(incoming.stream, FakeChannelSink());
      },
      cameras: const [testCamera],
    );

    await gateway.start(testCredentials);

    expect(registration.calls, 1);
    expect(gateway.state, LinkState.live);
    expect(attached!.scheme, 'ws');
    expect(attached!.path, '/ws/device/$testTicket');
    expect(registration.lastCredentials, testCredentials);
    expect(registration.lastCameras, const [testCamera]);

    await gateway.stop();
    unawaited(incoming.close());
  });

  test('an https base attaches over wss', () async {
    Uri? attached;
    final incoming = StreamController<dynamic>();
    final gateway = SmartClassBackendGateway(
      base: Uri.parse('https://cameras.example.test'),
      registration: FakeRegistrationClient(),
      channelFactory: (uri) {
        attached = uri;
        return FakeChannel(incoming.stream, FakeChannelSink());
      },
      cameras: const [testCamera],
    );

    await gateway.start(testCredentials);
    expect(attached!.scheme, 'wss');

    await gateway.stop();
    unawaited(incoming.close());
  });

  test('answers a ping with a pong carrying the same ts', () async {
    final harness = _build();
    await harness.gateway.start(testCredentials);

    harness.incoming.add(
      '{"channel":"control","type":"ping","payload":{"ts":"2026-10-04T10:00:30Z"}}',
    );
    await pumpEventQueue();

    final pong = _lastJson(harness.sink);
    expect(pong['type'], 'pong');
    expect((pong['payload']! as Map)['ts'], '2026-10-04T10:00:30Z');

    // `ping` is answered inside the gateway, so it never reaches the
    // coordinator's command stream.
    expect(harness.gateway.unrecognizedCommands.entries, isEmpty);

    await harness.gateway.stop();
    unawaited(harness.incoming.close());
  });

  test('emits start_recording to the command stream', () async {
    final harness = _build();
    await harness.gateway.start(testCredentials);

    final next = harness.gateway.commands.first;
    harness.incoming.add(
      '{"channel":"control","type":"start_recording",'
      '"id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B1",'
      '"payload":{"camera_enum":0,"stream_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B2"}}',
    );

    final command = await next;
    expect(command, isA<StartRecordingCommand>());
    expect(
      (command as StartRecordingCommand).streamId,
      '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
    );

    await harness.gateway.stop();
    unawaited(harness.incoming.close());
  });

  test(
    'a malformed frame is logged and the link survives the next one',
    () async {
      final harness = _build();
      await harness.gateway.start(testCredentials);

      harness.incoming.add('<<garbage>>');
      await pumpEventQueue();

      expect(harness.gateway.unrecognizedCommands.entries, hasLength(1));
      expect(
        harness.gateway.unrecognizedCommands.entries.single.raw,
        '<<garbage>>',
      );
      expect(harness.gateway.state, LinkState.live);

      harness.incoming.add(
        '{"channel":"control","type":"ping","payload":{"ts":"2026-10-04T10:00:30Z"}}',
      );
      await pumpEventQueue();

      expect(harness.gateway.state, LinkState.live);
      expect(_lastJson(harness.sink)['type'], 'pong');

      await harness.gateway.stop();
      unawaited(harness.incoming.close());
    },
  );

  test('a close goes to backoff and re-registers rather than reusing the '
      'ticket', () async {
    final harness = _build();
    await harness.gateway.start(testCredentials);
    expect(harness.registration.calls, 1);
    expect(harness.opened, hasLength(1));

    harness.gateway.simulateClose();
    expect(harness.gateway.state, LinkState.backoff);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    // The ticket is single-use and died with the connection, so the only way
    // back is a fresh registration.
    expect(harness.registration.calls, 2);
    expect(harness.opened, hasLength(2));
    expect(harness.gateway.state, LinkState.live);

    await harness.gateway.stop();
    for (final controller in harness.opened) {
      // Not awaited: a single-subscription controller that was never listened
      // to only completes its done future once someone listens.
      unawaited(controller.close());
    }
  });

  test('a 401 during registration is fatal and is not retried', () async {
    final harness = _build(failure: RegistrationFailure.unauthorized);
    await harness.gateway.start(testCredentials);

    expect(harness.gateway.state, LinkState.failed);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    // A rotated or deleted credential needs an operator, not a retry.
    expect(harness.registration.calls, 1);
    expect(harness.gateway.lastError, isNotNull);
  });

  test('a 500 is retried with backoff', () async {
    final harness = _build(failure: RegistrationFailure.serverError);
    await harness.gateway.start(testCredentials);

    expect(harness.gateway.state, LinkState.backoff);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(harness.registration.calls, greaterThan(1));
  });

  test('a failed attach mints a fresh ticket instead of reusing one', () async {
    final harness = _build(
      readyError: StateError('404 device websocket not found'),
    );
    await harness.gateway.start(testCredentials);

    expect(harness.gateway.state, LinkState.backoff);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(harness.registration.calls, greaterThan(1));
    expect(harness.opened.length, greaterThan(1));
  });

  test('a 1009 close is reported as an oversized frame', () async {
    final harness = _build();
    await harness.gateway.start(testCredentials);

    harness.gateway.simulateClose(closeCode: 1009);
    await pumpEventQueue();

    expect(harness.gateway.lastError, contains('16 MiB'));
  });

  test('a 1006 close is treated as normal operation', () async {
    final harness = _build();
    await harness.gateway.start(testCredentials);

    harness.gateway.simulateClose(closeCode: 1006);
    await pumpEventQueue();

    // A replaced connection is closed without a handshake, so 1006 is expected
    // and must not be reported as a problem.
    expect(harness.gateway.lastError, isNull);
    expect(harness.gateway.state, LinkState.backoff);
  });

  test(
    'sends a status while idle so the 60s read deadline never trips',
    () async {
      final harness = _build(
        idleStatusInterval: const Duration(milliseconds: 5),
      );
      await harness.gateway.start(testCredentials);

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final types = harness.sink.text
          .map((s) => (jsonDecode(s) as Map)['type'])
          .toList();
      expect(types, contains('status'));

      await harness.gateway.stop();
      unawaited(harness.incoming.close());
    },
  );

  test('the idle status carries the coordinator report', () async {
    final incoming = StreamController<dynamic>();
    final sink = FakeChannelSink();
    final gateway = SmartClassBackendGateway(
      base: Uri.parse('http://localhost:8080'),
      registration: FakeRegistrationClient(),
      channelFactory: (_) => FakeChannel(incoming.stream, sink),
      cameras: const [testCamera],
      idleStatusInterval: const Duration(milliseconds: 5),
      statusReport: () => {'recording': true, 'frames_sent': 7},
    );

    await gateway.start(testCredentials);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final status = sink.text
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .lastWhere((m) => m['type'] == 'status');
    expect((status['payload']! as Map)['recording'], true);
    expect((status['payload']! as Map)['frames_sent'], 7);

    await gateway.stop();
    unawaited(incoming.close());
  });

  test('nothing is pushed before the link is live', () async {
    final harness = _build();

    harness.gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: 0,
        streamId: 's',
        seq: 1,
        ts: DateTime.utc(2026),
      ),
      Uint8List.fromList([9]),
    );
    harness.gateway.send(AckMessage(id: 'x', ok: true));
    expect(harness.sink.records, isEmpty);

    await harness.gateway.start(testCredentials);
    // Attaching sends nothing on its own — the idle `status` is on a 30-second
    // timer, so a freshly attached link is silent until something happens.
    expect(harness.sink.records, isEmpty);

    // The same push that was dropped before now goes out.
    harness.gateway.send(AckMessage(id: 'y', ok: true));
    expect(harness.sink.records, hasLength(1));

    await harness.gateway.stop();
    unawaited(harness.incoming.close());
  });

  test('frames are framed exactly as the server reads them', () async {
    final harness = _build();
    await harness.gateway.start(testCredentials);
    harness.sink.records.clear();

    harness.gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: 0,
        streamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
        seq: 1,
        ts: DateTime.utc(2026),
      ),
      Uint8List.fromList([9]),
    );

    final decoded = tryDecodeBinaryFrame(harness.sink.binary.single)!;
    expect(decoded.header.channel, WireChannel.recording);
    expect(decoded.header.type, 'frame');
    expect(decoded.header.payload!['stream_id'], '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
    expect(decoded.data, [9]);

    await harness.gateway.stop();
    unawaited(harness.incoming.close());
  });

  test(
    'a frame that would exceed the read limit is dropped, not sent',
    () async {
      final harness = _build();
      await harness.gateway.start(testCredentials);
      harness.sink.records.clear();

      harness.gateway.sendRecordingFrame(
        RecordingFrameMeta(
          cameraEnum: 0,
          streamId: 's',
          seq: 1,
          ts: DateTime.utc(2026),
        ),
        Uint8List(maxFrameBytes),
      );

      // Sending it would make the server close with 1009, which takes the whole
      // link down over one frame.
      expect(harness.sink.records, isEmpty);
      expect(harness.gateway.lastError, isNotNull);

      await harness.gateway.stop();
      unawaited(harness.incoming.close());
    },
  );

  test('stop cancels the idle timer and the retries', () async {
    final harness = _build(idleStatusInterval: const Duration(milliseconds: 5));
    await harness.gateway.start(testCredentials);
    await harness.gateway.stop();

    harness.sink.records.clear();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(harness.gateway.state, LinkState.idle);
    expect(harness.sink.records, isEmpty);
  });

  test('a stale connection cannot tear down the new one', () async {
    final harness = _build();
    await harness.gateway.start(testCredentials);

    // The first socket closes; a retry attaches a second one.
    harness.gateway.simulateClose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(harness.gateway.state, LinkState.live);

    // The dead socket's onDone arrives late. It must not be mistaken for the
    // live connection closing.
    unawaited(harness.opened.first.close());
    await pumpEventQueue();

    expect(harness.gateway.state, LinkState.live);

    await harness.gateway.stop();
    for (final controller in harness.opened) {
      // Not awaited: a single-subscription controller that was never listened
      // to only completes its done future once someone listens.
      unawaited(controller.close());
    }
  });
}
