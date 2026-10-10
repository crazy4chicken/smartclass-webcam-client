// Checks for `lib/src/capture/annexb.dart`, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// `check`, `eq`, `eqBytes` and `section` are the harness's, imported from
// there so every section lands in the one pass/fail count.
//
// Every vector is handcrafted here: no fixture files, no golden blobs.
import 'dart:typed_data';

import 'package:webcam_client/src/capture/annexb.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

import 'verify_pure.dart';

// --- NAL builders -----------------------------------------------------------
//
// A NAL is `start code | header | payload`. Start codes are 4-byte
// `00 00 00 01` by default, 3-byte `00 00 01` with `three: true`.
//
// Payloads are filler **except their first byte when the NAL is a slice**,
// because the splitter reads that one: its top bit is the slice header's
// "this slice opens a picture" flag — H.264's `first_mb_in_slice == 0`,
// HEVC's `first_slice_segment_in_pic_flag`. So slice fixtures below start at
// 0x80 (opens a picture) or below (continues the one before it), and the
// [slice] / [cont] pair is what the multi-slice checks are built from.
// Distinct bytes elsewhere make a wrong slice visible in the byte comparisons
// instead of hiding behind a length check. No payload ends in 0x00, which the
// real stream guarantees too (a NAL may not end in a zero byte) — otherwise a
// 3-byte start code could be misread as a 4-byte one.

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
final List<int> idr = nal(h264Idr, <int>[0x88, 0x66]);
final List<int> slice = nal(h264Slice, <int>[0x9A, 0x88]);

/// A second slice of the picture [idr] opened: top bit clear.
final List<int> idrCont = nal(h264Idr, <int>[0x55, 0x66]);
final List<int> aud = nal(h264Aud, <int>[0x09, 0x0A]);
final List<int> sei = nal(h264Sei, <int>[0x0B, 0x0C]);

final List<int> hSps = nal(hevcSps, <int>[0x11, 0x22]);
final List<int> hPps = nal(hevcPps, <int>[0x33, 0x44]);
final List<int> hVps = nal(hevcVps, <int>[0x0D, 0x0E]);
final List<int> hIdr = nal(hevcIdr, <int>[0x80, 0x66]);
final List<int> hSlice = nal(hevcSlice, <int>[0xC0, 0x88]);

/// A second slice of the HEVC picture [hIdr] opened: top bit clear.
final List<int> hIdrCont = nal(hevcIdr, <int>[0x55, 0x66]);

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
    ...nal(h264Idr, <int>[0x88, 0x66], true),
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
  final List<int> idrNal = nal(h264Idr, <int>[0x88, 0x66]); // 4-byte
  final List<int> sliceNal = nal(h264Slice, <int>[0x9A, 0x88], true); // 3-byte
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

void checkMultiSliceIsOnePicture() {
  section('a picture cut into several slices');

  // The case the old "one VCL NAL is one picture" rule got wrong. Two slices
  // of one picture must reach the server as one unit: it stores frame bodies
  // concatenated with no container, so a half-picture is not a frame a decoder
  // can consume, and there is nothing downstream that would notice.
  final Uint8List stream = u8(<int>[...sps, ...pps, ...idr, ...idrCont]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h264);
  eq('two slices of one picture: one unit', units.length, 1);
  // Guarded per-assertion rather than with one early return: these cases are
  // independent, and a single `return` would hide how many of them a broken
  // splitter gets wrong.
  if (units.length == 1) {
    check('and it is the key frame it opened as', units[0].isKeyFrame);
    eqBytes('carrying every NAL, in order', units[0].bytes, stream);
  }

  // A third slice changes nothing; neither does a slice of a non-IDR picture.
  final List<AccessUnit> three = splitAnnexB(
    u8(<int>[...idr, ...idrCont, ...idrCont]),
    codec: CaptureCodec.h264,
  );
  eq('three slices: still one unit', three.length, 1);

  // Two pictures, each one slice: both open a picture, so two units.
  final List<AccessUnit> twoPictures = splitAnnexB(
    u8(<int>[...idr, ...slice]),
    codec: CaptureCodec.h264,
  );
  eq('two one-slice pictures: two units', twoPictures.length, 2);

  // The flag is per slice, so a continuation ends the picture before it:
  // [picture A][slice of B][slice of B] is two units, not one.
  final List<AccessUnit> thenSliced = splitAnnexB(
    u8(<int>[...slice, ...idr, ...idrCont]),
    codec: CaptureCodec.h264,
  );
  eq('a sliced picture after a plain one: two units', thenSliced.length, 2);
  if (thenSliced.length == 2) {
    eqBytes('the plain picture is alone', thenSliced[0].bytes, slice);
    eqBytes('the sliced one is whole', thenSliced[1].bytes, <int>[
      ...idr,
      ...idrCont,
    ]);
  }

  // Out-of-band NALs after a picture's slices belong to the *next* picture,
  // so they close the one before them rather than being folded into it.
  final List<AccessUnit> separated = splitAnnexB(
    u8(<int>[...idr, ...idrCont, ...sei, ...slice]),
    codec: CaptureCodec.h264,
  );
  eq('a SEI between two pictures: two units', separated.length, 2);
  if (separated.length == 2) {
    eqBytes('the SEI starts the second unit', separated[1].bytes, <int>[
      ...sei,
      ...slice,
    ]);
  }
}

void checkMultiSliceHevc() {
  section('a picture cut into several slices, hevc');

  // Same rule, one byte further in: the HEVC NAL header is two bytes, so
  // `first_slice_segment_in_pic_flag` is the third byte's top bit.
  final Uint8List stream = u8(<int>[
    ...hVps,
    ...hSps,
    ...hPps,
    ...hIdr,
    ...hIdrCont,
  ]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h265);
  eq('hevc: two slices of one picture: one unit', units.length, 1);
  if (units.length == 1) {
    check('hevc: and it is a key frame', units[0].isKeyFrame);
    eqBytes('hevc: carrying every NAL', units[0].bytes, stream);
  }

  final List<AccessUnit> twoPictures = splitAnnexB(
    u8(<int>[...hIdr, ...hSlice]),
    codec: CaptureCodec.h265,
  );
  eq('hevc: two one-slice pictures: two units', twoPictures.length, 2);
}

void checkSliceFlagsAcrossChunks() {
  section('a sliced picture does not cross a chunk boundary');

  // A chunk must hold whole pictures, same as it must hold whole NALs. The
  // boundary closes the picture rather than leaving it open — which is what
  // lets `add` promise that the units it returns are the pictures *this chunk*
  // carried, the count the native encoder checks a packet against. A picture
  // spread over two packets would report zero from the first and one from the
  // second and be dropped whole.
  final AnnexBSplitter whole = AnnexBSplitter(codec: CaptureCodec.h264);
  final List<AccessUnit> together = whole.add(u8(<int>[...idr, ...idrCont]));
  eq('both slices in one chunk: one unit', together.length, 1);

  final AnnexBSplitter split = AnnexBSplitter(codec: CaptureCodec.h264);
  final List<AccessUnit> first = split.add(u8(idr));
  eq('the first slice alone closes its picture', first.length, 1);
  if (first.length == 1)
    eqBytes('carrying only that slice', first[0].bytes, idr);
  final List<AccessUnit> second = split.add(u8(idrCont));
  eq('the second slice is a picture of its own', second.length, 1);
  if (second.length == 1) {
    eqBytes('carrying only its own bytes', second[0].bytes, idrCont);
  }

  // Inside one chunk a parameter-set run still waits for its picture, so the
  // merge must not make a chunk that is nothing but slices emit early.
  final AnnexBSplitter withSets = AnnexBSplitter(codec: CaptureCodec.h265);
  eq(
    'hevc: parameter sets claim nothing',
    withSets.add(u8(<int>[...hVps, ...hSps])).length,
    0,
  );
  final List<AccessUnit> sliced = withSets.add(
    u8(<int>[...hPps, ...hIdr, ...hIdrCont]),
  );
  eq('hevc: the sliced picture claims them all', sliced.length, 1);
  if (sliced.length == 1) {
    eqBytes('into one unit, in order', sliced[0].bytes, <int>[
      ...hVps,
      ...hSps,
      ...hPps,
      ...hIdr,
      ...hIdrCont,
    ]);
  }
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
    ...nal(hevcSliceN, <int>[0x80, 0xAA]),
  ]);
  final List<AccessUnit> units = splitAnnexB(stream, codec: CaptureCodec.h265);
  eq('two units', units.length, 2);
  if (units.length != 2) return;
  check('TRAIL_R is not a key frame', !units[0].isKeyFrame);
  check('TRAIL_N is not a key frame', !units[1].isKeyFrame);

  // The other IDR type, 20, must still count as one.
  final List<AccessUnit> radl = splitAnnexB(
    u8(<int>[
      ...nal(hevcIdrRadl, <int>[0x80, 0x66]),
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
  eq(
    'and yields nothing chunk by chunk either',
    AnnexBSplitter(codec: CaptureCodec.mjpeg)
        .add(u8(<int>[...sps, ...pps, ...idr]))
        .length,
    0,
  );
}

// --- the chunked stream -----------------------------------------------------
//
// The case the module exists for: libavcodec emits SPS and PPS as AVPackets of
// their own, so the run that opens a key frame and the key frame itself arrive
// in two buffers. A stateless splitter drops the first and emits the second
// without it, and the server — which stores frame bodies verbatim, with no
// container — keeps a key frame no decoder can start from.

void checkParameterSetsSurviveAChunk() {
  section('parameter sets survive a chunk boundary');
  final List<int> stream = <int>[...sps, ...pps, ...idr];
  final AnnexBSplitter splitter = AnnexBSplitter(codec: CaptureCodec.h264);

  eq(
    'SPS+PPS alone claim nothing',
    splitter.add(u8(<int>[...sps, ...pps])).length,
    0,
  );
  final List<AccessUnit> units = splitter.add(u8(idr));
  eq('the IDR closes one unit', units.length, 1);
  if (units.length != 1) return;
  check('and it is a key frame', units[0].isKeyFrame);
  eqBytes('carrying SPS+PPS+IDR verbatim', units[0].bytes, stream);

  // Same shape, three chunks: one parameter set per buffer, as libavcodec
  // hands them out.
  final perPacket = AnnexBSplitter(codec: CaptureCodec.h264);
  eq('SPS alone', perPacket.add(u8(sps)).length, 0);
  eq('PPS alone', perPacket.add(u8(pps)).length, 0);
  final key = perPacket.add(u8(idr));
  eq('IDR: one unit', key.length, 1);
  if (key.length == 1) {
    check('still a key frame', key[0].isKeyFrame);
    eqBytes('still carrying all three NALs', key[0].bytes, stream);
  }

  // HEVC spreads the same way, three NALs deep.
  final List<int> hevcStream = <int>[...hVps, ...hSps, ...hPps, ...hIdr];
  final hevc = AnnexBSplitter(codec: CaptureCodec.h265);
  eq(
    'hevc: VPS+SPS+PPS claim nothing',
    hevc.add(u8(<int>[...hVps, ...hSps, ...hPps])).length,
    0,
  );
  final List<AccessUnit> hevcUnits = hevc.add(u8(hIdr));
  eq('hevc: the IDR closes one unit', hevcUnits.length, 1);
  if (hevcUnits.length == 1) {
    check('hevc: and it is a key frame', hevcUnits[0].isKeyFrame);
    eqBytes('hevc: carrying all four NALs', hevcUnits[0].bytes, hevcStream);
  }
}

void checkChunkBoundaryInsideNal() {
  section('a chunk boundary inside a NAL');
  final List<int> stream = <int>[...sps, ...pps, ...idr];

  // Three cuts through the PPS: inside its start code, right after it, and
  // inside its payload. The chunk ends while a parameter set is still
  // arriving, so nothing can be attributed yet — and the unit that comes out
  // once the rest arrives has to be the stream as it was sent.
  final List<int> cuts = <int>[
    sps.length + 2, // mid start code
    sps.length + 3, // start code complete, header still missing
    sps.length + 5, // header in hand, payload cut
  ];
  for (final int cut in cuts) {
    final AnnexBSplitter splitter = AnnexBSplitter(codec: CaptureCodec.h264);
    eq(
      'cut at $cut: the head claims nothing',
      splitter.add(u8(stream.sublist(0, cut))).length,
      0,
    );
    final List<AccessUnit> units = splitter.add(u8(stream.sublist(cut)));
    eq('cut at $cut: one unit once the rest arrives', units.length, 1);
    if (units.length != 1) continue;
    check('cut at $cut: and it is a key frame', units[0].isKeyFrame);
    eqBytes('cut at $cut: the stream comes back whole', units[0].bytes, stream);
  }

  // A start code split across the boundary is the nastiest of the three: the
  // two halves are only a start code once they are back together.
  final acrossCode = AnnexBSplitter(codec: CaptureCodec.h264);
  final int atCode = sps.length + pps.length + 2;
  eq(
    'a split start code: nothing yet',
    acrossCode.add(u8(stream.sublist(0, atCode))).length,
    0,
  );
  final List<AccessUnit> after = acrossCode.add(u8(stream.sublist(atCode)));
  eq('a split start code: one unit', after.length, 1);
  if (after.length == 1)
    eqBytes('and the IDR is inside it, not lost', after[0].bytes, stream);
}

void checkUnclaimedRunIsNeverEmitted() {
  section('a pending run that is never claimed');
  final AnnexBSplitter splitter = AnnexBSplitter(codec: CaptureCodec.h264);

  eq('SPS+PPS alone', splitter.add(u8(<int>[...sps, ...pps])).length, 0);
  eq('more of the same', splitter.add(u8(<int>[...aud, ...sei])).length, 0);
  eq('an empty chunk changes nothing', splitter.add(Uint8List(0)).length, 0);

  // One picture claims the whole run, however many chunks it came in.
  final List<AccessUnit> units = splitter.add(u8(slice));
  eq('a slice closes one unit', units.length, 1);
  if (units.length != 1) return;
  check('and it is not a key frame', !units[0].isKeyFrame);
  eqBytes('with everything held in front of it', units[0].bytes, <int>[
    ...sps,
    ...pps,
    ...aud,
    ...sei,
    ...slice,
  ]);

  // The next key frame's headers, unclaimed when the stream ends: held, and
  // dropped with the splitter rather than emitted as a unit of its own.
  eq(
    'a tail no picture claims is never emitted',
    splitter.add(u8(<int>[...sps, ...pps])).length,
    0,
  );
}

void runAnnexBChecks() {
  checkFourByteStartCodes();
  checkThreeByteStartCodes();
  checkMixedStartCodes();
  checkTwoConsecutiveVcl();
  checkMultiSliceIsOnePicture();
  checkMultiSliceHevc();
  checkSliceFlagsAcrossChunks();
  checkOutOfBandAttachesToNextUnit();
  checkHevcKeyUnit();
  checkHevcNonIdr();
  checkTrailingFragmentDropped();
  checkEmptyAndCodelessInput();
  checkNonAnnexBCodec();
  checkParameterSetsSurviveAChunk();
  checkChunkBoundaryInsideNal();
  checkUnclaimedRunIsNeverEmitted();
}
