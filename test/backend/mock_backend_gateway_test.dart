import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/mock_backend_gateway.dart';
import 'package:webcam_client/src/backend/protocol/device_command.dart';
import 'package:webcam_client/src/backend/protocol/device_message.dart';

import '../support/doubles.dart';

void main() {
  test('drives a full command cycle with server-issued ids', () async {
    final gateway = MockBackendGateway(
      commandInterval: const Duration(milliseconds: 1),
    );
    await gateway.start(testCredentials);

    final seen = <DeviceCommand>[];
    await for (final command in gateway.commands.take(4)) {
      seen.add(command);
    }

    final start = seen.whereType<StartRecordingCommand>().single;
    final photo = seen.whereType<TakePhotoCommand>().single;

    // The server mints 26-character ULIDs; the mock must too, otherwise
    // "does the client echo them back verbatim?" proves nothing.
    expect(start.streamId.length, 26);
    expect(start.id!.length, 26);
    expect(photo.requestId.length, 26);
    expect(seen.whereType<StopRecordingCommand>(), isNotEmpty);
    expect(seen.whereType<PingCommand>(), isNotEmpty);
  });

  test('stop_recording names the stream that was started', () async {
    final gateway = MockBackendGateway(
      commandInterval: const Duration(milliseconds: 1),
    );
    await gateway.start(testCredentials);

    final seen = <DeviceCommand>[];
    await for (final command in gateway.commands.take(3)) {
      seen.add(command);
    }

    expect(
      seen.whereType<StopRecordingCommand>().single.streamId,
      seen.whereType<StartRecordingCommand>().single.streamId,
    );
  });

  test('records what the device would have uploaded', () async {
    final gateway = MockBackendGateway();
    await gateway.start(testCredentials);

    gateway.sendRecordingFrame(
      RecordingFrameMeta(
        cameraEnum: 0,
        streamId: 's',
        seq: 1,
        ts: DateTime.utc(2026),
      ),
      Uint8List.fromList([1]),
    );
    gateway.sendPhoto(
      PhotoMeta(cameraEnum: 0, requestId: 'r', ts: DateTime.utc(2026)),
      Uint8List.fromList([2]),
    );
    gateway.send(AckMessage(id: 'x', ok: true));

    expect(gateway.recordedFrames, 1);
    expect(gateway.recordedPhotos, 1);
    expect(gateway.sentMessages, hasLength(1));
    await gateway.stop();
  });

  test('the link is live while started and idle after stop', () async {
    final gateway = MockBackendGateway();
    expect(gateway.state, LinkState.idle);

    await gateway.start(testCredentials);
    expect(gateway.state, LinkState.live);

    await gateway.stop();
    expect(gateway.state, LinkState.idle);
  });

  test('reports its link transitions', () async {
    final gateway = MockBackendGateway();
    final seen = <LinkState>[];
    final subscription = gateway.states.listen(seen.add);

    await gateway.start(testCredentials);
    await gateway.stop();
    await Future<void>.delayed(Duration.zero);

    expect(seen, contains(LinkState.live));
    expect(seen, contains(LinkState.idle));
    await subscription.cancel();
  });

  test('generateUlid produces a 26-character Crockford string', () {
    final ulid = generateUlid();
    expect(ulid.length, 26);
    expect(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(ulid), isTrue);
  });

  test('generateUlid sorts by time', () {
    final earlier = generateUlid(DateTime.utc(2026, 1, 1));
    final later = generateUlid(DateTime.utc(2027, 1, 1));
    expect(earlier.compareTo(later), lessThan(0));
  });
}
