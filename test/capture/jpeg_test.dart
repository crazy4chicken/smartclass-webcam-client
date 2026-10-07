import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
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

/// A JPEG carrying a real start-of-frame segment: SOI, a 16-byte APP0, a frame
/// header of the given flavour, and EOI.
///
/// The marker is a parameter so the test can cover the whole `C0`-`CF` range
/// rather than only baseline.
Uint8List jpegWithSof({
  required int width,
  required int height,
  int marker = 0xC0,
  int? trailingSegments,
}) {
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF,
    0xE0,
    0x00,
    0x10, // APP0, length 16 (covers itself + 14 payload bytes)
    ...List<int>.filled(14, 0x00),
    if (trailingSegments != null) ...[
      // An optional segment *before* the frame header, so the walker is
      // exercised on something other than a straight APP0 → SOF hop.
      0xFF, 0xDB, 0x00, 0x06, ...List<int>.filled(4, 0x00),
    ],
    0xFF, marker, 0x00, 0x11, // SOF, length 17
    0x08, // sample precision
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    0x03, // three components
    0x01, 0x22, 0x00,
    0x02, 0x11, 0x01,
    0x03, 0x11, 0x01,
    0xFF, 0xD9, // EOI
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

  group('jpegSize', () {
    test('reads the SOF0 dimensions', () {
      expect(
        jpegSize(jpegWithSof(width: 1280, height: 720)),
        const CameraResolution(width: 1280, height: 720),
      );
      // A portrait capture is reported as it really is; the caller normalises.
      expect(
        jpegSize(jpegWithSof(width: 480, height: 640)),
        const CameraResolution(width: 480, height: 640),
      );
      // The full 16-bit range, not just the sizes a webcam happens to use.
      expect(
        jpegSize(jpegWithSof(width: 3840, height: 2160)),
        const CameraResolution(width: 3840, height: 2160),
      );
    });

    test('reads every start-of-frame flavour', () {
      for (final marker in [
        0xC0,
        0xC1,
        0xC2,
        0xC3,
        0xC5,
        0xC6,
        0xC7,
        0xC9,
        0xCA,
        0xCB,
        0xCD,
        0xCE,
        0xCF,
      ]) {
        expect(
          jpegSize(jpegWithSof(width: 640, height: 480, marker: marker)),
          const CameraResolution(width: 640, height: 480),
          reason: 'SOF marker 0x${marker.toRadixString(16)}',
        );
      }
    });

    test('skips the segments before the frame header', () {
      expect(
        jpegSize(jpegWithSof(width: 1024, height: 768, trailingSegments: 1)),
        const CameraResolution(width: 1024, height: 768),
      );
    });

    test('returns null for a buffer that is not a JPEG', () {
      expect(jpegSize(Uint8List(0)), isNull);
      expect(jpegSize(Uint8List.fromList([0xFF])), isNull);
      expect(jpegSize(Uint8List.fromList([0xFF, 0xD8])), isNull);
      expect(jpegSize(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7])), isNull);
      expect(jpegSize(Uint8List.fromList(List<int>.filled(64, 0x41))), isNull);
      // PNG signature: right shape, wrong format.
      expect(
        jpegSize(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])),
        isNull,
      );
    });

    test('returns null when no SOF marker is present', () {
      // The existing minimal fixture: SOI, APP0, EOI — no frame header. Its
      // APP0 length is also nonsense, so the walk runs off the end.
      expect(jpegSize(jpeg()), isNull);

      // A well-formed stream that simply stops before the frame header.
      expect(
        jpegSize(
          Uint8List.fromList([
            0xFF,
            0xD8,
            0xFF,
            0xE0,
            0x00,
            0x10,
            ...List<int>.filled(14, 0x00),
            0xFF,
            0xD9,
          ]),
        ),
        isNull,
      );
    });

    test('stops at the start of scan rather than reading a thumbnail', () {
      // SOS before any SOF: entropy-coded data follows, so a frame header later
      // in the buffer belongs to an embedded thumbnail, not to the picture.
      final withThumbnail = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xDA,
        0x00,
        0x08,
        ...List<int>.filled(6, 0x00),
        ...jpegWithSof(width: 160, height: 120),
      ]);
      expect(jpegSize(withThumbnail), isNull);
    });

    test('returns null rather than throwing on a truncated frame header', () {
      final truncated = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xC0,
        0x00,
        0x11,
        0x08,
        0x02,
        0xD0,
      ]);
      expect(jpegSize(truncated), isNull);
    });
  });
}
