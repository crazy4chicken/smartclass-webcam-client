import 'dart:typed_data';

import 'camera_resolution.dart';

/// Start of image.
const int _soi0 = 0xFF;
const int _soi1 = 0xD8;

/// End of image.
const int _eoi0 = 0xFF;
const int _eoi1 = 0xD9;

/// Largest run of trailing zeros still treated as padding.
///
/// Deliberately small. A truncated capture has no EOI at all (or one far from
/// the end), and that must stay visible as a malformed frame rather than be
/// quietly trimmed into something that merely looks valid.
const int _maxPadding = 64;

/// Strips trailing zero padding that some camera HALs append to a JPEG.
///
/// Observed on a real device: at 5 fps, roughly one frame in twenty came back
/// a few bytes longer than the picture it contained — `FF D9` present, then
/// six to eight zero bytes. Forwarding those puts bytes on the wire that are
/// not part of the frame, and the server's byte-level check reads the frame as
/// malformed. The same capture taken once, on demand, was always clean, which
/// is why only the streaming path showed it.
///
/// A JPEG ends at its EOI marker, so anything after it is not picture data.
/// This only ever **trims**, and only when what follows is a short run of
/// zeros:
///
/// - not a JPEG (no SOI) → returned untouched,
/// - no EOI at all → returned untouched, so a truncated frame stays detectable,
/// - more than [_maxPadding] bytes after the EOI → returned untouched,
/// - any non-zero byte after the EOI → returned untouched.
Uint8List trimJpegPadding(Uint8List bytes) {
  if (bytes.length < 4) return bytes;
  if (bytes[0] != _soi0 || bytes[1] != _soi1) return bytes;

  final eoi = _lastEoi(bytes);
  if (eoi < 0) return bytes;

  final padding = bytes.length - (eoi + 2);
  if (padding == 0 || padding > _maxPadding) return bytes;

  for (var i = eoi + 2; i < bytes.length; i++) {
    if (bytes[i] != 0) return bytes;
  }

  return Uint8List.sublistView(bytes, 0, eoi + 2);
}

/// Index of the final `FF D9`, or -1.
///
/// Scanning backwards is safe: inside entropy-coded data every `FF` is either
/// followed by `00` (byte stuffing) or starts a marker, so the last `FF D9` in
/// the buffer is the outermost end-of-image — any `FF D9` inside an embedded
/// EXIF thumbnail necessarily appears earlier.
int _lastEoi(Uint8List bytes) {
  for (var i = bytes.length - 2; i >= 2; i--) {
    if (bytes[i] == _eoi0 && bytes[i + 1] == _eoi1) return i;
  }
  return -1;
}

/// True for the eight start-of-frame markers.
///
/// `C4`, `C8` and `CC` are excluded on purpose — they are the Huffman table,
/// JPEG extension and arithmetic-coding-conditioning markers, which carry no
/// dimensions. Everything else in `C0`-`CF` is a frame header: baseline,
/// progressive, lossless, differential, and the arithmetic-coded variants.
bool _isStartOfFrame(int marker) =>
    (marker >= 0xC0 && marker <= 0xC3) ||
    (marker >= 0xC5 && marker <= 0xC7) ||
    (marker >= 0xC9 && marker <= 0xCB) ||
    (marker >= 0xCD && marker <= 0xCF);

/// The pixel dimensions of a JPEG, or null if they cannot be read.
///
/// This is how the capability probe learns what a camera *really* produced. The
/// plugin's `ResolutionPreset` is a relative tier — the docs say outright that
/// it does not guarantee pixel dimensions — and `controller.value.previewSize`
/// reports the preview surface rather than the still. A still picture is the
/// only thing on any of the five platforms that states the truth, so the probe
/// takes one and reads the size out of the bytes.
///
/// Walks the marker segments from the SOI, skipping the stand-alone markers
/// (which carry no length), and reads height/width out of the first start-of-
/// frame segment. Stops at `SOS`: entropy-coded data follows it, and no frame
/// header appears after it in a baseline stream.
///
/// Returns null rather than throwing for anything that is not a readable JPEG —
/// a probe that fails must drop one rung of the ladder, never abort the run.
///
/// Pure; no Flutter import.
CameraResolution? jpegSize(Uint8List bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] != _soi0 || bytes[1] != _soi1) return null;

  var offset = 2;
  while (offset + 1 < bytes.length) {
    // Every segment is introduced by `FF`. Losing that synchronisation means
    // the buffer is not what we think it is, so stop rather than guess.
    if (bytes[offset] != 0xFF) return null;

    var marker = bytes[offset + 1];

    // A run of `FF` is padding: the marker is the last byte of the run.
    while (marker == 0xFF && offset + 2 < bytes.length) {
      offset++;
      marker = bytes[offset + 1];
    }

    // Stand-alone markers carry no length field: SOI, EOI, TEM and the
    // restart markers.
    if (marker == 0xD8 ||
        marker == 0xD9 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }

    // Anything else has a two-byte big-endian length covering itself.
    if (offset + 3 >= bytes.length) return null;
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) return null;

    if (_isStartOfFrame(marker)) {
      // FF Cx | len(2) | precision(1) | height(2) | width(2)
      if (offset + 8 >= bytes.length) return null;
      final height = (bytes[offset + 5] << 8) | bytes[offset + 6];
      final width = (bytes[offset + 7] << 8) | bytes[offset + 8];
      if (width <= 0 || height <= 0) return null;
      return CameraResolution(width: width, height: height);
    }

    // Entropy-coded scan data follows the start-of-scan; a frame header after
    // this point would belong to a thumbnail, not to the picture.
    if (marker == 0xDA) return null;

    offset += 2 + length;
  }

  return null;
}
