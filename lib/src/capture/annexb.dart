import 'dart:typed_data';

import 'stream_settings.dart';

/// One coded picture plus everything that has to travel in front of it.
///
/// This is the unit the wire wants. The server stores `recording.frame` bodies
/// verbatim, concatenated, with no container, so a unit must stand on its own:
/// the VPS/SPS/PPS in front of a key frame ride along with it, and a consumer
/// that tunes in mid-stream only has to wait for the next [isKeyFrame].
class AccessUnit {
  const AccessUnit({required this.bytes, required this.isKeyFrame});

  /// The unit exactly as it goes on the wire.
  ///
  /// Still Annex B: it opens with the start code of its first NAL and ends
  /// with the last byte of its last one, so concatenating units reproduces the
  /// original stream. Copied out of the input buffer, so the caller is free to
  /// reuse that buffer.
  final Uint8List bytes;

  /// True when the unit carries an IDR NAL and can therefore start a decode.
  ///
  /// Only these units reset a decoder that joined late; every other unit is
  /// predictive and meaningless without the key frame it follows.
  final bool isKeyFrame;

  @override
  String toString() => 'AccessUnit(${bytes.length}B, key=$isKeyFrame)';
}

/// Splits one complete Annex B stream into access units.
///
/// Start codes are either `00 00 00 01` or `00 00 01`; both are recognised,
/// and a 4-byte code is never mistaken for a 3-byte one. A NAL unit is
/// everything from its first byte up to the next start code (or the end of the
/// buffer), and its type comes from that first byte:
///
/// * H.264 — `type = byte & 0x1F`. VCL (picture data) is 1-5, of which 5 is
///   IDR. The rest are out-of-band: 6 SEI, 7 SPS, 8 PPS, 9 AUD.
/// * HEVC — `type = (byte >> 1) & 0x3F`. VCL is 0-31, of which 19 (IDR_N_LP)
///   and 20 (IDR_W_RADL) are IDR. The rest are out-of-band: 32 VPS, 33 SPS,
///   34 PPS, 39 prefix SEI, 40 suffix SEI.
///
/// A **VCL NAL opens an access unit**. Parameter sets, SEI and AUD carry no
/// picture, so they are held back and prepended to the picture that follows
/// them — which is exactly the in-band behaviour the protocol needs: the bytes
/// a decoder must have before the slices end up inside the same unit as the
/// slices. [AccessUnit.isKeyFrame] is then true when that picture is an IDR.
///
/// Two consequences worth knowing:
///
/// * **Several slices can make one picture.** A picture is not "one VCL NAL":
///   an encoder is free to cut a picture into several slices, and the unit the
///   wire wants is the picture. So consecutive VCL NALs are merged into one
///   unit until a NAL that starts a new picture arrives, which is detected
///   from the slice header's own first-slice flag — H.264's
///   `first_mb_in_slice == 0`, HEVC's `first_slice_segment_in_pic_flag` (see
///   [_startsNewPicture]). A picture is therefore exactly what a decoder
///   consumes at once, whether the encoder used one slice or eight.
///
///   This is **not** inferred from the absence of B-frames. No reordering is
///   one thing; a picture arriving as several NALs is another, and the two are
///   independent — an encoder that emits no B-frames is still free to slice.
///   What is *not* implemented is the full H.264 rule (7.4.1.2.4), which also
///   compares `frame_num`, `pic_parameter_set_id`, `nal_ref_idc`,
///   `field_pic_flag` and the picture order count. The first-slice flag alone
///   is enough for every picture a conforming stream contains, and it is
///   deliberately the conservative test: a continuation NAL with nothing open
///   starts a picture rather than being dropped, so a stream this misreads
///   produces a unit a decoder can still start from, not a lost frame.
/// * **A trailing tail with no VCL in it is dropped.** A stream can end after
///   the parameter sets but before the picture they belong to, and there is no
///   length prefix in Annex B to tell "complete" from "still arriving" — only
///   the next start code does. So such a tail is never emitted: it carries no
///   picture, and the server stores bytes verbatim and cannot spot a broken
///   unit, so a partial one must never reach it. It is **dropped, not held** —
///   this function is stateless and there is no next buffer to hold it for.
///
/// That second point is why a caller whose stream arrives in pieces must use
/// [AnnexBSplitter] instead. libavcodec emits SPS and PPS as AVPackets of
/// their own, so the run that opens a key frame and the key frame itself
/// easily land in two buffers: `splitAnnexB` on each one drops the parameter
/// sets with the first call and emits the IDR without them on the second, and
/// the server keeps a key frame no decoder can start from.
///
/// [codec] selects the NAL header layout. Only [CaptureCodec.h264] and
/// [CaptureCodec.h265] are Annex B; any other codec yields no units, because
/// there is nothing to cut — an `mjpeg` frame is already one whole picture,
/// and the remaining codecs have no Annex B form.
List<AccessUnit> splitAnnexB(Uint8List bytes, {required CaptureCodec codec}) =>
    AnnexBSplitter(codec: codec).add(bytes);

/// Accumulates an Annex B byte *stream* across chunk boundaries.
///
/// [splitAnnexB] is this class fed once and thrown away. Use that when the
/// whole stream is already in one buffer and this when it arrives in pieces —
/// one encoder packet at a time, say. The cutting rules are the ones
/// [splitAnnexB] documents; what [add] adds is memory:
///
/// * A run of parameter sets, SEI and AUD is held until a picture claims it,
///   however many chunks it spans. A `[SPS][PPS]` chunk followed by an `[IDR]`
///   chunk is one key frame, and this is what keeps it that way.
/// * A NAL cut in half by a chunk boundary is put back together before it is
///   classified, so where the boundary fell cannot change what the bytes mean.
///
/// Two things are deliberately *not* carried:
///
/// * **A chunk boundary closes the NAL it ends in.** The last NAL of a chunk
///   is taken as complete, so an `[IDR]` chunk emits its unit straight away
///   rather than waiting for a start code that may never arrive. A chunk must
///   therefore not end inside a *picture* NAL: the rest of that NAL would
///   arrive with no start code in front of it and be dropped. Non-VCL NALs are
///   exempt — they are held as pending bytes, so a boundary inside a parameter
///   set is fine. Chunks are encoder packets here, which is what makes the
///   assumption safe.
///
///   The same boundary closes a *picture*: a picture whose slices span two
///   chunks comes out as two units, not one. That is the same constraint
///   tightened by one level, and it is what lets [add] keep its one guarantee
///   — that the units it returns from one chunk are the pictures that chunk
///   held, which is the count [NativeVideoEncoder] checks a packet against.
/// * **An unclaimed run is dropped.** There is no `flush()`: pending bytes
///   only ever reach the caller as part of a unit, so a run the stream ends on
///   goes away with the splitter. That is the point — bytes with no picture
///   after them are not a unit, and a unit the server cannot decode is worse
///   than a frame that never arrived.
class AnnexBSplitter {
  AnnexBSplitter({required this.codec});

  /// Selects the NAL header layout. Only [CaptureCodec.h264] and
  /// [CaptureCodec.h265] are Annex B; any other codec yields no units.
  final CaptureCodec codec;

  /// Bytes that belong to no emitted unit: the parameter sets, SEI and AUD
  /// still waiting for a picture, and the head of a NAL a chunk boundary cut.
  ///
  /// Copied out of every chunk it is built from, so the caller may reuse the
  /// buffer it passed to [add].
  Uint8List _pending = Uint8List(0);

  /// Feeds the next chunk and returns every access unit completed by it.
  ///
  /// Units come back in stream order and complete: a unit is returned once its
  /// picture NAL is in hand, and bytes still waiting for that picture are held
  /// for the next call.
  List<AccessUnit> add(Uint8List chunk) {
    if (codec != CaptureCodec.h264 && codec != CaptureCodec.h265) {
      return const <AccessUnit>[];
    }
    final bool hevc = codec == CaptureCodec.h265;

    // Whatever is still open goes in front of this chunk, so a NAL the last
    // boundary cut in half is whole again before anything is classified.
    final Uint8List buffer = _pending.isEmpty
        ? chunk
        : Uint8List.fromList(<int>[..._pending, ...chunk]);
    _pending = Uint8List(0);

    // Indexes of every start code, and of the first byte of the NAL after it.
    final List<int> starts = <int>[];
    final List<int> headers = <int>[];
    var i = 0;
    while (i + 3 <= buffer.length) {
      if (buffer[i] == 0 && buffer[i + 1] == 0 && buffer[i + 2] == 1) {
        // A 4-byte code matches here too, one byte late and with a zero in
        // front: claim that zero so it is not read as a 3-byte code. (A NAL may
        // not end in 0x00, so a zero here can only be part of the start code.)
        final bool fourByte = i > 0 && buffer[i - 1] == 0;
        starts.add(fourByte ? i - 1 : i);
        headers.add(i + 3);
        i += 3;
      } else {
        i++;
      }
    }
    // Not one start code in sight: either the tail of a NAL whose start code
    // came in an earlier chunk, or bytes ahead of the first one. Held either
    // way — the next chunk says which, and neither is a unit on its own.
    if (starts.isEmpty) {
      _pending = buffer.sublist(0);
      return const <AccessUnit>[];
    }

    final List<AccessUnit> units = <AccessUnit>[];
    // Where the run of not-yet-emitted non-VCL NALs starts. They belong to the
    // picture that follows them, never to a unit of their own, so they stay
    // pending until a VCL NAL claims them. NALs are contiguous — one ends where
    // the next start code begins — so the pending run plus that picture is one
    // unbroken slice of the input.
    int? pendingStart;
    // The picture being assembled: where it starts, and whether the slice that
    // opened it was an IDR. Open pictures are what merge several slices into
    // one unit; null means no picture is mid-assembly.
    int? pictureStart;
    var pictureKey = false;

    void emitPicture(int end) {
      units.add(
        AccessUnit(
          bytes: buffer.sublist(pictureStart!, end),
          isKeyFrame: pictureKey,
        ),
      );
      pictureStart = null;
      pictureKey = false;
    }

    for (var k = 0; k < starts.length; k++) {
      final int start = starts[k];
      final int header = headers[k];
      final int end = k + 1 < starts.length ? starts[k + 1] : buffer.length;

      // A start code with nothing behind it: the NAL it opens arrives in the
      // next chunk, so there is no type to read and nothing to attribute.
      // Holding the code itself is what makes those bytes land inside it.
      // Whatever picture was open is complete — the next NAL belongs to
      // another one, or to nothing.
      if (header >= end) {
        if (pictureStart != null) emitPicture(start);
        pendingStart ??= start;
        continue;
      }

      final int type = hevc
          ? (buffer[header] >> 1) & 0x3F
          : buffer[header] & 0x1F;
      if (!_isVcl(type, hevc)) {
        // Out-of-band bytes always end the picture: parameter sets and SEI
        // sitting after slices describe what comes next, not what came before.
        if (pictureStart != null) emitPicture(start);
        pendingStart ??= start;
        continue;
      }

      // A continuation slice extends the picture already open. One that says
      // it is the first slice — or one with nothing open, which a stream can
      // only produce by starting mid-picture — opens a new one.
      final bool startsPicture =
          pictureStart == null || _startsNewPicture(buffer, header, end, hevc);
      if (startsPicture) {
        if (pictureStart != null) emitPicture(start);
        // The pending run rides in front: whatever a decoder needs before
        // these slices is inside the same unit as them.
        pictureStart = pendingStart ?? start;
        pendingStart = null;
        pictureKey = _isIdr(type, hevc);
      }
      // Anything else is another slice of the open picture: nothing to do, the
      // unit's end simply moves with the next start code.
    }

    // The chunk boundary closes the picture, same as it closes a NAL: the last
    // unit is emitted rather than held, so the units this returns are the
    // pictures this chunk held.
    if (pictureStart != null) {
      emitPicture(buffer.length);
    } else if (pendingStart != null) {
      // Still pending: parameter sets whose picture has not arrived, or the
      // head of a NAL this chunk ended inside. Carried into the next one; if
      // the stream ends first, it is dropped with the splitter.
      _pending = buffer.sublist(pendingStart);
    }
    return units;
  }
}

/// True when the VCL NAL at [header] opens a new picture.
///
/// The slice header says so in its very first bit, which is why no real
/// parsing is needed:
///
/// * H.264 — the header is one byte, and `first_mb_in_slice` follows as an
///   exp-Golomb code. Zero encodes as the single bit `1`, so the flag is
///   `first_mb_in_slice == 0` exactly when the next byte's top bit is set.
/// * HEVC — the header is two bytes, and `first_slice_segment_in_pic_flag` is
///   the first bit of the byte after it.
///
/// [end] bounds the read because a NAL can be one byte long. Such a NAL has no
/// slice header at all, and claiming it starts a picture is the safe answer:
/// it becomes a unit a decoder may still start from, rather than bytes folded
/// into a picture they do not belong to.
bool _startsNewPicture(Uint8List buffer, int header, int end, bool hevc) {
  final int at = header + (hevc ? 2 : 1);
  if (at >= end) return true;
  return (buffer[at] & 0x80) != 0;
}

/// True for NAL types that carry picture data: 0-31 in HEVC, 1-5 in H.264
/// (2-4 are the data partitions, which no encoder in use here produces).
bool _isVcl(int type, bool hevc) => hevc ? type < 32 : type >= 1 && type <= 5;

/// True for the types a decoder can start from: IDR_N_LP (19) and IDR_W_RADL
/// (20) in HEVC, IDR (5) in H.264.
bool _isIdr(int type, bool hevc) => hevc ? type == 19 || type == 20 : type == 5;
