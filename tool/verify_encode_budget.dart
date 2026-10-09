// Exercises the encoder-budget rules on a plain Dart VM.
//
// `flutter test` cannot run in this environment, so this is a standalone
// harness for the one module it covers. It is merged into
// `tool/verify_pure.dart` separately — that file is one big `main()` with no
// parts, so its helpers cannot be reused from here.
//
//   dart run tool/verify_encode_budget.dart
//
// Exits non-zero if anything fails.
import 'dart:io';

import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/encode_budget.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

// --- harness ----------------------------------------------------------------

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool condition) {
  if (condition) {
    _passed++;
  } else {
    _failures.add(name);
    print('  FAIL: $name');
  }
}

void eq(String name, Object? actual, Object? expected) {
  check('$name  (got: $actual, want: $expected)', actual == expected);
}

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

void main() {
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

  // --- ---------------------------------------------------------------------
  if (_failures.isEmpty) {
    print('encode_budget: $_passed checks passed.');
  } else {
    print('encode_budget: ${_failures.length} FAILED, $_passed passed.');
    for (final failure in _failures) {
      print('  - $failure');
    }
    exit(1);
  }
}
