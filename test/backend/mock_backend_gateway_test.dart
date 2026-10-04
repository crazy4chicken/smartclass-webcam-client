import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/mock_backend_gateway.dart';
import 'package:webcam_client/src/backend/server_command.dart';

void main() {
  test('emits stream mode, preview and face result commands on cue', () async {
    final gw = MockBackendGateway(
      commandInterval: const Duration(milliseconds: 1),
    );
    await gw.connect('ws://mock');
    await expectLater(
      gw.commands,
      emitsThrough(predicate<ServerCommand>((c) => c is SetStreamModeCommand)),
    );
    await expectLater(
      gw.commands,
      emitsThrough(predicate<ServerCommand>((c) => c is SetPreviewCommand)),
    );
    await expectLater(
      gw.commands,
      emitsThrough(predicate<ServerCommand>((c) => c is FaceResultCommand)),
    );
    expect(gw.isConnected, isTrue);
    await gw.disconnect();
  });

  test('counts frames and video chunks it would have sent', () async {
    final gw = MockBackendGateway();
    await gw.connect('ws://mock');
    gw.sendFrameBytes(Uint8List.fromList([1]));
    gw.sendVideoBytes(Uint8List.fromList([2]));
    gw.sendVideoBytes(Uint8List.fromList([3]));
    expect(gw.frameCount, 1);
    expect(gw.videoChunkCount, 2);
    await gw.disconnect();
  });

  test('reports connected and offline transitions', () async {
    final gw = MockBackendGateway();
    final seen = <ConnectionState>[];
    final sub = gw.connectionChanges.listen(seen.add);
    await gw.connect('ws://mock');
    await gw.disconnect();
    await Future<void>.delayed(Duration.zero);
    expect(seen, contains(ConnectionState.connected));
    expect(seen, contains(ConnectionState.offline));
    await sub.cancel();
  });
}
