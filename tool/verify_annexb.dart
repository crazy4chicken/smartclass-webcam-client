// Gate for `lib/src/capture/annexb.dart` on a plain Dart VM.
//
// `flutter test` cannot run in this environment, so this is a standalone
// harness in the shape of `tool/verify_pure.dart`, trimmed to the ~10 lines of
// preamble it needs. It exits non-zero if anything fails:
//
//   dart run tool/verify_annexb.dart
//
// Every vector is handcrafted here: no fixture files, no golden blobs.
import 'dart:io';
import 'dart:typed_data';

import 'package:webcam_client/src/capture/annexb.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

// --- harness ----------------------------------------------------------------

int passed = 0;
final List<String> failures = <String>[];

void check(String name, bool condition) {
  if (condition) {
    passed++;
  } else {
    failures.add(name);
    print('  FAIL: $name');
  }
}

void eq(String name, Object? actual, Object? expected) =>
    check('$name  (got: $actual, want: $expected)', actual == expected);

void eqBytes(String name, List<int> actual, List<int> expected) {
  var same = actual.length == expected.length;
  if (same) {
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) same = false;
    }
  }
  check('$name  (got: $actual, want: $expected)', same);
}

void section(String name) => print(name);

// --- NAL builders -----------------------------------------------------------
//
// A NAL is `start code | header | payload`. Start codes are 4-byte
// `00 00 00 01` by default, 3-byte `00 00 01` with `three: true`. Payloads are
// filler: this splitter never looks past the first header byte, but distinct
// bytes make a wrong slice visible in the byte comparisons instead of hiding
// behind a length check. No payload ends in 0x00, which the real stream
// guarantees too (a NAL may not end in a zero byte) — otherwise a 3-byte start
// code could be misread as a 4-byte one.

List<int> nal(
  List<int> header, [
  List<int> payload = const <int>[],
  bool three = false,
]) => <int>[if (!three) 0x00, 0x00, 0x00, 0x01, ...header, ...payload];

Uint8List u8(List<int> source) => Uint8List.fromList(source);

// H.264: first byte is 1 forbidden-zero bit, 2 nal_ref_idc bits, 5 type bits.
const List<int> h264Aud = <int>[0x09]; // type 9
const List<int> h264Sei = <int>[0x06]; // type 6
const List<int> h264Sps = <int>[0x67]; // type 7
const List<int> h264Pps = <int>[0x68]; // type 8
const List<int> h264Idr = <int>[0x65]; // type 5
const List<int> h264Slice = <int>[0x41]; // type 1, non-IDR

// HEVC: first byte is 1 forbidden-zero bit + 6 type bits, second byte is
// layer id + temporal id (0 / 1 here, i.e. 0x01).
const List<int> hevcVps = <int>[0x40, 0x01]; // type 32
const List<int> hevcSps = <int>[0x42, 0x01]; // type 33
const List<int> hevcPps = <int>[0x44, 0x01]; // type 34
const List<int> hevcIdr = <int>[0x26, 0x01]; // type 19, IDR_N_LP
const List<int> hevcIdrRadl = <int>[0x28, 0x01]; // type 20, IDR_W_RADL
const List<int> hevcSlice = <int>[0x02, 0x01]; // type 1, TRAIL_R
const List<int> hevcSliceN = <int>[0x00, 0x01]; // type 0, TRAIL_N
const List<int> hevcSei = <int>[0x4E, 0x01]; // type 39, prefix SEI

final List<int> sps = nal(h264Sps, <int>[0x11, 0x22]);
final List<int> pps = nal(h264Pps, <int>[0x33, 0x44]);
final List<int> idr = nal(h264Idr, <int>[0x55, 0x66]);
final List<int> slice = nal(h264Slice, <int>[0x77, 0x88]);
final List<int> aud = nal(h264Aud, <int>[0x09, 0x0A]);
final List<int> sei = nal(h264Sei, <int>[0x0B, 0x0C]);

final List<int> hSps = nal(hevcSps, <int>[0x11, 0x22]);
final List<int> hPps = nal(hevcPps, <int>[0x33, 0x44]);
final List<int> hVps = nal(hevcVps, <int>[0x0D, 0x0E]);
final List<int> hIdr = nal(hevcIdr, <int>[0x55, 0x66]);
final List<int> hSlice = nal(hevcSlice, <int>[0x77, 0x88]);

// --- checks -----------------------------------------------------------------

void checkFourByteStartCodes() {
  section('h264, 4-byte start codes');
  final Uint8List stream = u8(<int>[...sps, ...pps, ...idr]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h264);
  eq('one unit', units.length, 1);
  if (units.length != 1) return;
  check('is a key frame', units[0].isKeyFrame);
  eqBytes('carries SPS+PPS+IDR verbatim', units[0].bytes, stream);
  eq(
    'opens on a 4-byte start code',
    units[0].bytes.sublist(0, 4).toString(),
    '[0, 0, 0, 1]',
  );
}

void checkThreeByteStartCodes() {
  section('h264, 3-byte start codes');
  final List<int> three = <int>[
    ...nal(h264Sps, <int>[0x11, 0x22], true),
    ...nal(h264Pps, <int>[0x33, 0x44], true),
    ...nal(h264Idr, <int>[0x55, 0x66], true),
  ];
  final Uint8List stream = u8(three);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h264);
  eq('one unit', units.length, 1);
  if (units.length != 1) return;
  check('is a key frame', units[0].isKeyFrame);
  eqBytes('carries SPS+PPS+IDR verbatim', units[0].bytes, stream);
  eq(
    'opens on a 3-byte start code',
    units[0].bytes.sublist(0, 3).toString(),
    '[0, 0, 1]',
  );
}

void checkMixedStartCodes() {
  section('h264, mixed 4-byte and 3-byte start codes');
  final List<int> spsNal = nal(h264Sps, <int>[0x11, 0x22]); // 4-byte
  final List<int> ppsNal = nal(h264Pps, <int>[0x33, 0x44], true); // 3-byte
  final List<int> idrNal = nal(h264Idr, <int>[0x55, 0x66]); // 4-byte
  final List<int> sliceNal = nal(h264Slice, <int>[0x77, 0x88], true); // 3-byte
  final Uint8List stream = u8(<int>[
    ...spsNal,
    ...ppsNal,
    ...idrNal,
    ...sliceNal,
  ]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h264);
  eq('two units', units.length, 2);
  if (units.length != 2) return;
  check('first is a key frame', units[0].isKeyFrame);
  check('second is not', !units[1].isKeyFrame);
  eqBytes('first keeps SPS+PPS+IDR', units[0].bytes, <int>[
    ...spsNal,
    ...ppsNal,
    ...idrNal,
  ]);
  eqBytes('second is the slice alone', units[1].bytes, sliceNal);
}

void checkTwoConsecutiveVcl() {
  section('two consecutive VCL NALs');
  final Uint8List stream = u8(<int>[...idr, ...slice]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h264);
  eq('two units', units.length, 2);
  if (units.length != 2) return;
  check('IDR is a key frame', units[0].isKeyFrame);
  check('non-IDR is not', !units[1].isKeyFrame);
  eqBytes('first unit is the IDR NAL', units[0].bytes, idr);
  eqBytes('second unit is the slice NAL', units[1].bytes, slice);
}

void checkOutOfBandAttachesToNextUnit() {
  section('SEI/AUD attach to the following unit');
  final Uint8List stream = u8(<int>[
    ...aud,
    ...sei,
    ...slice,
    ...aud,
    ...sei,
    ...idr,
  ]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h264);
  eq('two units, not six', units.length, 2);
  if (units.length != 2) return;
  check('AUD+SEI+slice is not a key frame', !units[0].isKeyFrame);
  check('AUD+SEI+IDR is', units[1].isKeyFrame);
  eqBytes('AUD+SEI prepended to the slice', units[0].bytes, <int>[
    ...aud,
    ...sei,
    ...slice,
  ]);
  eqBytes('AUD+SEI prepended to the IDR', units[1].bytes, <int>[
    ...aud,
    ...sei,
    ...idr,
  ]);
}

void checkHevcKeyUnit() {
  section('hevc VPS+SPS+PPS+IDR');
  final Uint8List stream = u8(<int>[...hVps, ...hSps, ...hPps, ...hIdr]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h265);
  eq('one unit', units.length, 1);
  if (units.length != 1) return;
  check('type 19 is a key frame', units[0].isKeyFrame);
  eqBytes('carries all four NALs verbatim', units[0].bytes, stream);
}

void checkHevcNonIdr() {
  section('hevc non-IDR VCL');
  final Uint8List stream = u8(<int>[
    ...hSlice,
    ...nal(hevcSliceN, <int>[0x99, 0xAA]),
  ]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h265);
  eq('two units', units.length, 2);
  if (units.length != 2) return;
  check('TRAIL_R is not a key frame', !units[0].isKeyFrame);
  check('TRAIL_N is not a key frame', !units[1].isKeyFrame);

  // The other IDR type, 20, must still count as one.
  final List<AccessUnit> radl = splitAnnexB(
    u8(<int>[
      ...nal(hevcIdrRadl, <int>[0x55, 0x66]),
    ]),
    codec: CaptureCodec.h265,
  );
  eq('IDR_W_RADL: one unit', radl.length, 1);
  if (radl.length == 1) check('IDR_W_RADL is a key frame', radl[0].isKeyFrame);

  // And a prefix SEI must not start a unit of its own.
  final List<AccessUnit> withSei = splitAnnexB(
    u8(<int>[
      ...nal(hevcSei, <int>[0x0B, 0x0C]),
      ...hIdr,
    ]),
    codec: CaptureCodec.h265,
  );
  eq('SEI+IDR: one unit', withSei.length, 1);
}

void checkTrailingFragmentDropped() {
  section('trailing fragment with no VCL is dropped');
  // Headers arrived, their picture has not: nothing is emitted.
  eq(
    'SPS+PPS alone',
    splitAnnexB(u8(<int>[...sps, ...pps]), codec: CaptureCodec.h264).length,
    0,
  );
  // A start code whose NAL has not arrived yet.
  final List<AccessUnit> bareCode = splitAnnexB(
    u8(<int>[...idr, 0x00, 0x00, 0x00, 0x01]),
    codec: CaptureCodec.h264,
  );
  eq('IDR + bare start code: one unit', bareCode.length, 1);
  if (bareCode.length == 1)
    eqBytes('and it is the IDR alone', bareCode[0].bytes, idr);
  // Next key frame's headers, cut off before its slices.
  final List<AccessUnit> nextHeaders = splitAnnexB(
    u8(<int>[...idr, ...sps, ...pps]),
    codec: CaptureCodec.h264,
  );
  eq('IDR + trailing SPS+PPS: one unit', nextHeaders.length, 1);
  if (nextHeaders.length == 1) {
    eqBytes('and the pending headers are dropped', nextHeaders[0].bytes, idr);
  }
}

void checkEmptyAndCodelessInput() {
  section('empty and start-code-less input');
  eq(
    'empty input',
    splitAnnexB(Uint8List(0), codec: CaptureCodec.h264).length,
    0,
  );
  eq(
    'empty input, hevc',
    splitAnnexB(Uint8List(0), codec: CaptureCodec.h265).length,
    0,
  );
  eq(
    'no start code',
    splitAnnexB(
      u8(<int>[0x01, 0x02, 0x03, 0x04, 0x05]),
      codec: CaptureCodec.h264,
    ).length,
    0,
  );
  eq(
    'only zero bytes',
    splitAnnexB(
      u8(<int>[0x00, 0x00, 0x00, 0x00]),
      codec: CaptureCodec.h264,
    ).length,
    0,
  );
  eq(
    'start code that is one byte short',
    splitAnnexB(u8(<int>[0x00, 0x00]), codec: CaptureCodec.h264).length,
    0,
  );
  // Bytes before the first start code are the tail of a NAL split across
  // buffers: not a unit, dropped.
  final List<AccessUnit> leading = splitAnnexB(
    u8(<int>[0xDE, 0xAD, ...idr]),
    codec: CaptureCodec.h264,
  );
  eq('leading bytes dropped: one unit', leading.length, 1);
  if (leading.length == 1)
    eqBytes('and it starts at the start code', leading[0].bytes, idr);
}

void checkNonAnnexBCodec() {
  section('codecs that are not Annex B');
  for (final CaptureCodec codec in <CaptureCodec>[
    CaptureCodec.mjpeg,
    CaptureCodec.mpeg4,
    CaptureCodec.vp8,
    CaptureCodec.vp9,
    CaptureCodec.av1,
  ]) {
    eq(
      '${codec.wireName} yields nothing',
      splitAnnexB(u8(<int>[...sps, ...pps, ...idr]), codec: codec).length,
      0,
    );
  }
}

void main() {
  checkFourByteStartCodes();
  checkThreeByteStartCodes();
  checkMixedStartCodes();
  checkTwoConsecutiveVcl();
  checkOutOfBandAttachesToNextUnit();
  checkHevcKeyUnit();
  checkHevcNonIdr();
  checkTrailingFragmentDropped();
  checkEmptyAndCodelessInput();
  checkNonAnnexBCodec();

  print('');
  print('passed: $passed, failed: ${failures.length}');
  if (failures.isNotEmpty) exitCode = 1;
}
