import 'dart:typed_data';

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
