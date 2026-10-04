import 'dart:convert';
import 'dart:typed_data';

import 'envelope.dart';

/// A decoded binary media frame: the JSON envelope plus the raw media bytes.
typedef DecodedBinaryFrame = ({Message header, Uint8List data});

/// Largest header the framing allows, in bytes.
const int maxHeaderBytes = 65536;

/// Largest whole frame the server's read limit accepts (16 MiB).
///
/// Exceeding it makes the server close with `1009`; there is no continuation
/// and no reassembly beyond one WebSocket message.
const int maxFrameBytes = 16 * 1024 * 1024;

/// Thrown by [encodeBinaryFrame] for a frame that cannot be sent.
///
/// Encoding failures are programmer errors (a header that cannot be encoded),
/// not protocol events, so they are loud — unlike decoding, which is silent.
class BinaryFrameError extends Error {
  BinaryFrameError(this.message);

  final String message;

  @override
  String toString() => 'BinaryFrameError: $message';
}

/// Encodes one binary media frame.
///
/// ```text
/// +--------------------+------------------------------+------------------+
/// | uint32 BE N        | N bytes UTF-8 JSON envelope  | raw media bytes  |
/// +--------------------+------------------------------+------------------+
/// ```
///
/// The envelope must be a `recording`/`frame` or `photo`/`photo` pair: the
/// server dispatches binary frames on `channel` and then requires the `type`
/// to match, so a mismatch would be silently dropped.
Uint8List encodeBinaryFrame(Message header, Uint8List data) {
  if (header.channel == WireChannel.control) {
    throw BinaryFrameError('control frames are text, not binary');
  }

  final expectedType = header.channel == WireChannel.recording
      ? 'frame'
      : 'photo';
  if (header.type != expectedType) {
    throw BinaryFrameError(
      'channel ${header.channel.wireName} requires type "$expectedType", '
      'got "${header.type}"',
    );
  }

  final headerBytes = utf8.encode(header.encode());
  if (headerBytes.isEmpty || headerBytes.length > maxHeaderBytes) {
    throw BinaryFrameError(
      'header must be 1..$maxHeaderBytes bytes, got ${headerBytes.length}',
    );
  }

  final total = 4 + headerBytes.length + data.length;
  if (total > maxFrameBytes) {
    throw BinaryFrameError(
      'frame would be $total bytes, above the $maxFrameBytes limit',
    );
  }

  final frame = Uint8List(total);
  ByteData.view(
    frame.buffer,
    frame.offsetInBytes,
    4,
  ).setUint32(0, headerBytes.length, Endian.big);
  frame.setRange(4, 4 + headerBytes.length, headerBytes);
  frame.setRange(4 + headerBytes.length, total, data);
  return frame;
}

/// Decodes one binary media frame, or null if it is not decodable.
///
/// Mirrors the server's own decoder exactly, including every rejection case:
/// a frame shorter than the length prefix, a declared length of `0` or above
/// [maxHeaderBytes], a length that runs past the end of the frame, and a
/// header that is not a JSON object. All of them return null; none throws.
DecodedBinaryFrame? tryDecodeBinaryFrame(Uint8List raw) {
  if (raw.length < 4) return null;

  final headerLength = ByteData.view(
    raw.buffer,
    raw.offsetInBytes,
    4,
  ).getUint32(0, Endian.big);

  if (headerLength == 0 || headerLength > maxHeaderBytes) return null;
  if (4 + headerLength > raw.length) return null;

  final header = Message.tryParseJson(
    utf8.decode(raw.sublist(4, 4 + headerLength), allowMalformed: true),
  );
  if (header == null) return null;

  // `sublist` copies, so the caller owns the bytes even if the read buffer is
  // reused for the next WebSocket message.
  return (header: header, data: raw.sublist(4 + headerLength));
}
