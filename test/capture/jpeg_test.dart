import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/jpeg.dart';

/// A minimal but structurally real JPEG: SOI, an APP0 segment, and EOI.
Uint8List jpeg({int filler = 8, int pad = 0, int padByte = 0}) {
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    ...List<int>.filled(filler, 0x11),
    0xFF,
    0xD9,
    ...List<int>.filled(pad, padByte),
  ]);
}

void main() {
  test('a clean JPEG is returned untouched', () {
    final clean = jpeg();
    expect(trimJpegPadding(clean), clean);
  });

  test('the observed device padding is trimmed', () {
    // One frame in twenty came back like this at 5 fps: EOI present, then a
    // few zero bytes appended by the camera HAL.
    for (final padding in [1, 6, 8, 64]) {
      expect(
        trimJpegPadding(jpeg(pad: padding)),
        jpeg(),
        reason: '$padding trailing zero bytes should be trimmed',
      );
    }
  });

  test('anything that is not short zero padding is left alone', () {
    // Too long to be padding.
    expect(trimJpegPadding(jpeg(pad: 65)), jpeg(pad: 65));
    // Padding must be zeros, not arbitrary trailing bytes.
    expect(
      trimJpegPadding(jpeg(pad: 4, padByte: 0x7A)),
      jpeg(pad: 4, padByte: 0x7A),
    );
    // Not a JPEG at all.
    final notJpeg = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
    expect(trimJpegPadding(notJpeg), notJpeg);
    // No EOI: a truncated capture must stay visible as malformed.
    final truncated = Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      1,
      2,
      3,
      4,
      5,
    ]);
    expect(trimJpegPadding(truncated), truncated);
  });

  test('the outermost EOI wins over an embedded EXIF thumbnail', () {
    final withThumbnail = Uint8List.fromList([
      0xFF, 0xD8,
      0xFF, 0xE1, 0x00, 0x10,
      0xFF, 0xD8, 0xAA, 0xBB, 0xFF, 0xD9, // thumbnail
      0xCC, 0xDD, 0xFF, 0xD9, // the real end
      0x00, 0x00,
    ]);
    expect(
      trimJpegPadding(withThumbnail),
      Uint8List.sublistView(withThumbnail, 0, withThumbnail.length - 2),
    );
  });

  test('tiny and empty payloads are handled without throwing', () {
    expect(trimJpegPadding(Uint8List(0)), Uint8List(0));
    expect(
      trimJpegPadding(Uint8List.fromList([0xFF])),
      Uint8List.fromList([0xFF]),
    );
    expect(
      trimJpegPadding(Uint8List.fromList([0xFF, 0xD8])),
      Uint8List.fromList([0xFF, 0xD8]),
    );
  });
}
