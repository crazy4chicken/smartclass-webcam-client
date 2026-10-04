import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/protocol/binary_frame.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';

void main() {
  Message recordingHeader() => const Message(
    channel: WireChannel.recording,
    type: 'frame',
    payload: <String, Object?>{
      'camera_enum': 0,
      'seq': 42,
      'stream_id': '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
      'ts': '2026-10-04T10:00:00Z',
    },
  );

  test('encodes a recording frame exactly as the server decodes it', () {
    final frame = encodeBinaryFrame(
      recordingHeader(),
      Uint8List.fromList([0xAA, 0xBB]),
    );

    final n = ByteData.view(
      frame.buffer,
      frame.offsetInBytes,
      4,
    ).getUint32(0, Endian.big);

    expect(n, 144);
    expect(n, lessThanOrEqualTo(maxHeaderBytes));
    expect(frame.length, 4 + n + 2);

    final decoded = tryDecodeBinaryFrame(frame);
    expect(decoded, isNotNull);
    expect(decoded!.header.type, 'frame');
    expect(decoded.header.channel, WireChannel.recording);
    expect(decoded.header.payload!['stream_id'], '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
    expect(decoded.data, [0xAA, 0xBB]);
  });

  test('the payload may be empty', () {
    final frame = encodeBinaryFrame(recordingHeader(), Uint8List(0));
    final decoded = tryDecodeBinaryFrame(frame);
    expect(decoded, isNotNull);
    expect(decoded!.data, isEmpty);
  });

  test('a photo frame round-trips on the photo channel', () {
    final frame = encodeBinaryFrame(
      const Message(channel: WireChannel.photo, type: 'photo'),
      Uint8List.fromList([0xFF, 0xD8]),
    );
    final decoded = tryDecodeBinaryFrame(frame);
    expect(decoded!.header.channel, WireChannel.photo);
    expect(decoded.data, [0xFF, 0xD8]);
  });

  group('decode rejections mirror the server', () {
    test('rejects frames shorter than the length prefix', () {
      expect(tryDecodeBinaryFrame(Uint8List.fromList([0, 0])), isNull);
      expect(tryDecodeBinaryFrame(Uint8List(0)), isNull);
    });

    test('rejects a declared header length of zero', () {
      expect(
        tryDecodeBinaryFrame(Uint8List.fromList([0, 0, 0, 0, 0x7b])),
        isNull,
      );
    });

    test('rejects a header length beyond the frame', () {
      expect(
        tryDecodeBinaryFrame(Uint8List.fromList([0, 0, 0, 99, 0x7b])),
        isNull,
      );
    });

    test('rejects a header length above 65536', () {
      // 0x00010001 = 65537, one past the limit.
      expect(
        tryDecodeBinaryFrame(Uint8List.fromList([0, 1, 0, 1, 0x7b])),
        isNull,
      );
    });

    test('rejects a header that is not valid JSON', () {
      expect(
        tryDecodeBinaryFrame(
          Uint8List.fromList([0, 0, 0, 3, 0x20, 0x20, 0x20]),
        ),
        isNull,
      );
    });

    test('never throws, whatever the bytes are', () {
      for (final bytes in <List<int>>[
        [0, 0, 0, 1, 0x7b],
        [0xFF, 0xFF, 0xFF, 0xFF],
        [0, 0, 0, 4, 0x7B, 0x7D, 0x00, 0x00],
      ]) {
        expect(
          () => tryDecodeBinaryFrame(Uint8List.fromList(bytes)),
          returnsNormally,
        );
      }
    });
  });

  group('encode guards', () {
    test('refuses to frame a control message as binary', () {
      expect(
        () => encodeBinaryFrame(
          const Message(channel: WireChannel.control, type: 'ack'),
          Uint8List(0),
        ),
        throwsA(isA<BinaryFrameError>()),
      );
    });

    test('refuses a type that does not match its channel', () {
      // The server dispatches binary frames on channel and then requires the
      // type to match, so a mismatch would be dropped silently.
      expect(
        () => encodeBinaryFrame(
          const Message(channel: WireChannel.recording, type: 'photo'),
          Uint8List(0),
        ),
        throwsA(isA<BinaryFrameError>()),
      );
      expect(
        () => encodeBinaryFrame(
          const Message(channel: WireChannel.photo, type: 'frame'),
          Uint8List(0),
        ),
        throwsA(isA<BinaryFrameError>()),
      );
    });

    test('refuses a frame above the 16 MiB read limit', () {
      expect(
        () => encodeBinaryFrame(recordingHeader(), Uint8List(maxFrameBytes)),
        throwsA(isA<BinaryFrameError>()),
      );
    });

    test('accepts a frame just under the limit', () {
      expect(
        () => encodeBinaryFrame(
          recordingHeader(),
          Uint8List(maxFrameBytes - 4 - 144),
        ),
        returnsNormally,
      );
    });
  });
}
