// Exercises the encoder-budget rules, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// `check` and `eq` are the harness's, imported from there so every section
// lands in the one pass/fail count.
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/encode_budget.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

import 'verify_pure.dart';

// --- fixtures ---------------------------------------------------------------

const _p1080 = CameraResolution(width: 1920, height: 1080);
const _p720 = CameraResolution(width: 1280, height: 720);
const _ladder = <int>[5, 10, 15, 20, 24, 25, 30, 50, 60];

EncodeSample _sample(
  CaptureCodec codec,
  CameraResolution resolution,
  int fps,
) => EncodeSample(codec: codec, resolution: resolution, measuredFps: fps);

/// Canonical rendering, because Dart's `Map` has no value equality: a map is
/// compared as text with keys in `CaptureCodec.values` order.
String _fmt(Map<CaptureCodec, List<int>> rates) => <String>[
  for (final codec in CaptureCodec.values)
    if (rates.containsKey(codec)) '${codec.wireName}=${rates[codec]}',
].join(' ');

String _fmtCodecs(List<CaptureCodec> codecs) =>
    codecs.map((c) => c.wireName).join(',');

Future<void> runEncodeBudgetChecks() async {
  // --- 58 measured: declares up to 58, never 60 -----------------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[_sample(CaptureCodec.h265, _p1080, 58)],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq(
      '58 held: rounds down, never up to 60',
      _fmt(rates),
      'h265=[50, 30, 25, 24, 20, 15, 10, 5]',
    );
    check(
      '58 held: 60 is not declared',
      !rates[CaptureCodec.h265]!.contains(60),
    );
  }

  // --- exactly a candidate: that candidate is in ----------------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[_sample(CaptureCodec.h264, _p1080, 30)],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq(
      'exactly 30: the candidate is included',
      _fmt(rates),
      'h264=[30, 25, 24, 20, 15, 10, 5]',
    );
  }

  // --- below the lowest candidate: omitted entirely -------------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[_sample(CaptureCodec.vp9, _p1080, 4)],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq('below the floor: empty map', _fmt(rates), '');
    check(
      'below the floor: key absent, not an empty list',
      !rates.containsKey(CaptureCodec.vp9),
    );
    eq(
      'below the floor: no codec announced',
      _fmtCodecs(sustainableCodecs(rates)),
      '',
    );
  }

  // --- several samples for one codec: the maximum wins ---------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 12),
        _sample(CaptureCodec.h265, _p1080, 45),
        _sample(CaptureCodec.h265, _p1080, 27),
      ],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq(
      'three runs: the fastest is the evidence',
      _fmt(rates),
      'h265=[30, 25, 24, 20, 15, 10, 5]',
    );
    eq(
      'three runs: max is 45',
      maxSustainableFps(
        samples: <EncodeSample>[
          _sample(CaptureCodec.h265, _p1080, 12),
          _sample(CaptureCodec.h265, _p1080, 45),
        ],
        resolution: _p1080,
        codec: CaptureCodec.h265,
      ),
      45,
    );
  }

  // --- other geometries are ignored ----------------------------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[_sample(CaptureCodec.h265, _p720, 60)],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq('720p sample: not used for 1080p', _fmt(rates), '');
    eq(
      '720p sample: no 1080p rate for that codec',
      maxSustainableFps(
        samples: <EncodeSample>[_sample(CaptureCodec.h265, _p720, 60)],
        resolution: _p1080,
        codec: CaptureCodec.h265,
      ),
      null,
    );

    final mixed = sustainableRates(
      samples: <EncodeSample>[
        _sample(CaptureCodec.h265, _p720, 60),
        _sample(CaptureCodec.h265, _p1080, 30),
        _sample(CaptureCodec.mjpeg, _p720, 15),
      ],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq(
      'mixed geometries: only 1080p counts',
      _fmt(mixed),
      'h265=[30, 25, 24, 20, 15, 10, 5]',
    );
  }

  // --- sorted descending, no duplicates ------------------------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[_sample(CaptureCodec.mjpeg, _p1080, 60)],
      resolution: _p1080,
      candidates: <int>[15, 60, 15, 30, 60, 5, 30],
    );
    eq('dedup + descending', _fmt(rates), 'mjpeg=[60, 30, 15, 5]');
  }

  // --- sustainableCodecs follows CaptureCodec.values -----------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[
        _sample(CaptureCodec.av1, _p1080, 30),
        _sample(CaptureCodec.mjpeg, _p1080, 30),
        _sample(CaptureCodec.h265, _p1080, 15),
        _sample(CaptureCodec.vp8, _p1080, 1), // held nothing: omitted
      ],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq(
      'codec order is declaration order',
      _fmtCodecs(sustainableCodecs(rates)),
      'h265,mjpeg,av1',
    );
    check(
      'codecs with no rate are absent',
      !sustainableCodecs(rates).contains(CaptureCodec.vp8),
    );
  }

  // --- maxSustainableFps ----------------------------------------------------
  {
    eq(
      'no sample: null',
      maxSustainableFps(
        samples: const <EncodeSample>[],
        resolution: _p1080,
        codec: CaptureCodec.h265,
      ),
      null,
    );
    eq(
      'sample at another geometry: null',
      maxSustainableFps(
        samples: <EncodeSample>[_sample(CaptureCodec.h264, _p720, 30)],
        resolution: _p1080,
        codec: CaptureCodec.h264,
      ),
      null,
    );
    eq(
      'sample present: its rate, unrounded',
      maxSustainableFps(
        samples: <EncodeSample>[_sample(CaptureCodec.h264, _p1080, 47)],
        resolution: _p1080,
        codec: CaptureCodec.h264,
      ),
      47,
    );
  }

  // --- non-positive measurements held nothing -------------------------------
  {
    final rates = sustainableRates(
      samples: <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 0),
        _sample(CaptureCodec.h264, _p1080, -30),
      ],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq('zero and negative: empty map', _fmt(rates), '');
    eq(
      'zero measurement: max is null',
      maxSustainableFps(
        samples: <EncodeSample>[_sample(CaptureCodec.h265, _p1080, 0)],
        resolution: _p1080,
        codec: CaptureCodec.h265,
      ),
      null,
    );
    eq(
      'negative measurement: max is null',
      maxSustainableFps(
        samples: <EncodeSample>[_sample(CaptureCodec.h265, _p1080, -30)],
        resolution: _p1080,
        codec: CaptureCodec.h265,
      ),
      null,
    );
    // A dead run must not lower a good one.
    eq(
      'dead run does not erase a real one',
      maxSustainableFps(
        samples: <EncodeSample>[
          _sample(CaptureCodec.h265, _p1080, 30),
          _sample(CaptureCodec.h265, _p1080, 0),
        ],
        resolution: _p1080,
        codec: CaptureCodec.h265,
      ),
      30,
    );
  }

  // --- nothing measured: nothing declared ----------------------------------
  {
    final rates = sustainableRates(
      samples: const <EncodeSample>[],
      resolution: _p1080,
      candidates: _ladder,
    );
    eq('no samples: empty map', _fmt(rates), '');
    eq('no samples: no codecs', _fmtCodecs(sustainableCodecs(rates)), '');
    check('no samples: map is empty', rates.isEmpty);
  }

  // --- canServeMode: the question is per mode, not per device ---------------
  //
  // The trap this closes: an H.265 encoder that holds 1080p30 being published
  // as "H.265 works", and then handed a 1080p60 stream it cannot feed. A codec
  // is only eligible for the mode it measured at.
  {
    final samples = <EncodeSample>[
      _sample(CaptureCodec.h265, _p1080, 30),
      _sample(CaptureCodec.h264, _p1080, 60),
    ];
    check(
      'hevc that held 30 does not serve 60',
      !canServeMode(
        samples: samples,
        codec: CaptureCodec.h265,
        resolution: _p1080,
        fps: 60,
      ),
    );
    check(
      'hevc that held 30 does serve 30',
      canServeMode(
        samples: samples,
        codec: CaptureCodec.h265,
        resolution: _p1080,
        fps: 30,
      ),
    );
    check(
      'avc that held 60 serves 60',
      canServeMode(
        samples: samples,
        codec: CaptureCodec.h264,
        resolution: _p1080,
        fps: 60,
      ),
    );
    check(
      'a codec with no sample serves nothing',
      !canServeMode(
        samples: samples,
        codec: CaptureCodec.av1,
        resolution: _p1080,
        fps: 5,
      ),
    );
    check(
      'a rate measured at another geometry serves nothing',
      !canServeMode(
        samples: <EncodeSample>[_sample(CaptureCodec.h265, _p720, 60)],
        codec: CaptureCodec.h265,
        resolution: _p1080,
        fps: 60,
      ),
    );
    check(
      'a non-positive rate is not a mode',
      !canServeMode(
        samples: samples,
        codec: CaptureCodec.h264,
        resolution: _p1080,
        fps: 0,
      ),
    );
  }

  // --- sustainableCodecsAt: preference order, filtered by the mode ---------
  {
    final samples = <EncodeSample>[
      _sample(CaptureCodec.h265, _p1080, 30),
      _sample(CaptureCodec.h264, _p1080, 60),
      _sample(CaptureCodec.mjpeg, _p1080, 60),
    ];
    eq(
      'at 60: hevc drops out, avc leads',
      _fmtCodecs(
        sustainableCodecsAt(samples: samples, resolution: _p1080, fps: 60),
      ),
      'h264,mjpeg',
    );
    eq(
      'at 30: hevc is available again and leads',
      _fmtCodecs(
        sustainableCodecsAt(samples: samples, resolution: _p1080, fps: 30),
      ),
      'h265,h264,mjpeg',
    );
    // 50 is *below* what avc and mjpeg held, so holding 60 does cover it —
    // "can serve" is a ceiling test, not an exact match.
    eq(
      'at 50: everything that held 60 still qualifies',
      _fmtCodecs(
        sustainableCodecsAt(samples: samples, resolution: _p1080, fps: 50),
      ),
      'h264,mjpeg',
    );
    eq(
      'above every measurement: nothing is offered',
      _fmtCodecs(
        sustainableCodecsAt(samples: samples, resolution: _p1080, fps: 120),
      ),
      '',
    );
    eq(
      'no samples: nothing is offered',
      _fmtCodecs(
        sustainableCodecsAt(
          samples: const <EncodeSample>[],
          resolution: _p1080,
          fps: 30,
        ),
      ),
      '',
    );
    // A thermal downshift leaves two runs for one codec; the faster one is
    // still the evidence, so the mode is not lost to one bad minute.
    eq(
      'a slow run does not erase a fast one',
      _fmtCodecs(
        sustainableCodecsAt(
          samples: <EncodeSample>[
            _sample(CaptureCodec.h265, _p1080, 12),
            _sample(CaptureCodec.h265, _p1080, 60),
          ],
          resolution: _p1080,
          fps: 60,
        ),
      ),
      'h265',
    );
  }

  // --- EncodeEvidence: matching -------------------------------------------
  {
    const evidence = EncodeEvidence(
      version: kEncodeEvidenceVersion,
      cameraFingerprint: 'cam-A',
      encoderIdentity: 'c2.qcom.hevc',
      samples: <EncodeSample>[
        EncodeSample(
          codec: CaptureCodec.h265,
          resolution: _p1080,
          measuredFps: 60,
        ),
      ],
    );
    check(
      'same camera and encoder: a hit',
      evidence.matches(
        cameraFingerprint: 'cam-A',
        encoderIdentity: 'c2.qcom.hevc',
      ),
    );
    check(
      'a different camera set: a miss',
      !evidence.matches(
        cameraFingerprint: 'cam-B',
        encoderIdentity: 'c2.qcom.hevc',
      ),
    );
    check(
      'the same camera through a different encoder: a miss',
      !evidence.matches(
        cameraFingerprint: 'cam-A',
        encoderIdentity: 'c2.qcom.avc',
      ),
    );
    check(
      'an encoder that stopped naming itself: a miss',
      !evidence.matches(cameraFingerprint: 'cam-A', encoderIdentity: ''),
    );
  }

  // --- EncodeEvidence: round trip -----------------------------------------
  {
    const evidence = EncodeEvidence(
      version: kEncodeEvidenceVersion,
      cameraFingerprint: 'cam-A',
      encoderIdentity: 'c2.qcom.hevc',
      samples: <EncodeSample>[
        EncodeSample(
          codec: CaptureCodec.h265,
          resolution: _p1080,
          measuredFps: 60,
        ),
      ],
    );
    final back = EncodeEvidence.fromJson(evidence.toJson());
    check('a round trip is not invalid', !back.isInvalid);
    eq('and keeps the fingerprint', back.cameraFingerprint, 'cam-A');
    eq('and the encoder', back.encoderIdentity, 'c2.qcom.hevc');
    eq('and the sample count', back.samples.length, 1);
    if (back.samples.length == 1) {
      eq('and the codec', back.samples[0].codec, CaptureCodec.h265);
      eq('and the rate', back.samples[0].measuredFps, 60);
    }
  }

  // --- EncodeEvidence: a corrupt cache is a miss, not a crash --------------
  {
    for (final Object? bad in <Object?>[
      null,
      42,
      'not json',
      <int>[],
      <String, Object?>{}, // no version
      <String, Object?>{'version': 999, 'samples': <Object?>[]}, // newer format
      <String, Object?>{'version': kEncodeEvidenceVersion}, // no samples key
      <String, Object?>{
        'version': kEncodeEvidenceVersion,
        'samples': <Object?>[42],
      },
      <String, Object?>{
        'version': kEncodeEvidenceVersion,
        'samples': <Object?>[
          <String, Object?>{
            'codec': 'hevc',
            'resolution': '1920x1080',
            'fps': 60,
          },
        ],
      }, // hevc is not a wire name
      <String, Object?>{
        'version': kEncodeEvidenceVersion,
        'samples': <Object?>[
          <String, Object?>{'codec': 'h265', 'resolution': '1080p', 'fps': 60},
        ],
      }, // 1080p is not WxH
      <String, Object?>{
        'version': kEncodeEvidenceVersion,
        'samples': <Object?>[
          <String, Object?>{
            'codec': 'h265',
            'resolution': '1920x1080',
            'fps': '60',
          },
        ],
      }, // fps is a string
      <String, Object?>{
        'version': kEncodeEvidenceVersion,
        'samples': <Object?>[
          <String, Object?>{
            'codec': 'h265',
            'resolution': '1920x1080',
            'fps': 60,
          },
          <String, Object?>{'codec': 'nonsense'},
        ],
      }, // one bad entry spoils the set
    ]) {
      final parsed = EncodeEvidence.fromJson(bad);
      check('unusable payload is invalid: $bad', parsed.isInvalid);
      eq('and carries no samples: $bad', parsed.samples.length, 0);
    }
    // Empty-but-valid is a measurement result, not damage.
    final none = EncodeEvidence.fromJson(
      const EncodeEvidence(
        version: kEncodeEvidenceVersion,
        cameraFingerprint: 'cam-A',
        encoderIdentity: '',
        samples: <EncodeSample>[],
      ).toJson(),
    );
    check('measured nothing is not invalid', !none.isInvalid);
    check('measured nothing is empty', none.isEmpty);
  }

  // --- the store: hits, misses and self-healing ---------------------------
  {
    final store = InMemoryEncodeEvidenceStore();
    eq(
      'an empty store is a miss',
      await store.load(cameraFingerprint: 'cam-A', encoderIdentity: 'enc'),
      null,
    );

    const evidence = EncodeEvidence(
      version: kEncodeEvidenceVersion,
      cameraFingerprint: 'cam-A',
      encoderIdentity: 'enc',
      samples: <EncodeSample>[
        EncodeSample(
          codec: CaptureCodec.h265,
          resolution: _p1080,
          measuredFps: 60,
        ),
      ],
    );
    await store.save(evidence);
    final hit = await store.load(
      cameraFingerprint: 'cam-A',
      encoderIdentity: 'enc',
    );
    check('the same camera and encoder is a hit', hit != null);
    eq('and carries the sample', hit?.samples.length ?? 0, 1);

    eq(
      'a re-probe after a hardware change is a miss',
      await store.load(cameraFingerprint: 'cam-B', encoderIdentity: 'enc'),
      null,
    );
    eq(
      'a different encoder is a miss',
      await store.load(cameraFingerprint: 'cam-A', encoderIdentity: 'other'),
      null,
    );

    // A corrupt value cannot be produced through the typed API, so this is
    // what a bad payload from disk looks like by the time it is stored.
    store.value = EncodeEvidence.invalid;
    eq(
      'a corrupt value is a miss, not a crash',
      await store.load(cameraFingerprint: 'cam-A', encoderIdentity: 'enc'),
      null,
    );

    await store.clear();
    eq(
      'cleared is a miss',
      await store.load(cameraFingerprint: 'cam-A', encoderIdentity: 'enc'),
      null,
    );
  }
}
