// Exercises the default-mode rules, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// `check`, `eq` and `section` are the harness's, imported from there so every
// section lands in the one pass/fail count.
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/default_mode.dart';
import 'package:webcam_client/src/capture/encode_budget.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

import 'verify_pure.dart';

// --- fixtures ---------------------------------------------------------------

const _p2160 = CameraResolution(width: 3840, height: 2160);
const _p1440 = CameraResolution(width: 2560, height: 1440);
const _p1080 = CameraResolution(width: 1920, height: 1080);
const _p720 = CameraResolution(width: 1280, height: 720);
const _p480 = CameraResolution(width: 640, height: 480);

/// 5:4, deliberately off every ladder rung: it is what catches a selector that
/// sorts by pixel count and calls the winner a default.
const _p1280x1024 = CameraResolution(width: 1280, height: 1024);

/// The vivo V2405A's **measured** set, exactly as its probe reported it.
///
/// Every geometry is portrait: the plugin enumerates in display orientation,
/// and the device was held portrait. The transposed landscape forms are still
/// real, openable sizes — they are just not what was measured. This is the set
/// the regression was measured on.
const List<CameraResolution> _deviceMeasured = <CameraResolution>[
  CameraResolution(width: 3072, height: 4096),
  CameraResolution(width: 2160, height: 3840),
  CameraResolution(width: 1080, height: 1920),
  CameraResolution(width: 720, height: 1280),
  CameraResolution(width: 480, height: 720),
  CameraResolution(width: 240, height: 320),
];

/// The same device's **declared** list as the cache holds it: the measured set
/// with the common ladder merged in. The ladder entries below the ceiling are
/// the transposed landscape forms of shapes the camera measured, which is why
/// they survive the shape rule.
const List<CameraResolution> _deviceDeclared = <CameraResolution>[
  CameraResolution(width: 3072, height: 4096),
  CameraResolution(width: 2160, height: 3840),
  CameraResolution(width: 3840, height: 2160),
  CameraResolution(width: 2560, height: 1440),
  CameraResolution(width: 1080, height: 1920),
  CameraResolution(width: 1920, height: 1080),
  CameraResolution(width: 720, height: 1280),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1024, height: 768),
  CameraResolution(width: 800, height: 600),
  CameraResolution(width: 480, height: 720),
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 240, height: 320),
  CameraResolution(width: 320, height: 240),
];

CameraResolution _r(int w, int h) => CameraResolution(width: w, height: h);

CameraCapabilities _caps(List<CameraResolution> resolutions) =>
    CameraCapabilities.of(resolutions: resolutions, framerates: const <int>[]);

void runDefaultModeChecks() {
  // --- the 1080p cap --------------------------------------------------------
  section('a 4K camera opens at 1080p');
  {
    // The whole point of the cap: a 4K camera is not opened at 4K just because
    // it can. 4K stays declared — an operator can switch to it — but the
    // default is what this client can actually sustain.
    final measured = _caps(<CameraResolution>[_p2160, _p1440, _p1080, _p720]);
    eq(
      '4K measured: 1080p is the default',
      defaultResolutionFor(measured: measured, fallback: _p720).label,
      '1920x1080',
    );
    check('and 4K is still measured', measured.resolutions.contains(_p2160));
    check(
      'the cap is not a claim about the ceiling',
      measured.highestResolution == _p2160,
    );
  }

  // --- below the target: the highest real geometry --------------------------
  {
    final measured = _caps(<CameraResolution>[_p720, _p480]);
    eq(
      'a 720p camera opens at 720p',
      defaultResolutionFor(measured: measured, fallback: _p1080).label,
      '1280x720',
    );
    eq(
      'a 480p camera opens at 480p',
      defaultResolutionFor(
        measured: _caps(<CameraResolution>[_p480]),
        fallback: _p1080,
      ).label,
      '640x480',
    );
  }

  // --- the default follows the camera's own geometry ------------------------
  section('the default follows the camera\'s own geometry');
  {
    // A 5:4 camera that also reports 16:9 modes. Its own 5:4 geometry is the
    // largest mode that fits, so that is what it opens at — not a 16:9 mode of
    // another shape. Nothing errors either way; the picture is just wrong when
    // the shapes disagree.
    final measured = _caps(<CameraResolution>[_p1280x1024, _p720, _p480]);
    eq(
      'a 5:4 camera opens at its own shape',
      defaultResolutionFor(measured: measured, fallback: _p720).label,
      '1280x1024',
    );
    eq(
      'not at a fitting mode of another shape',
      defaultResolutionFor(measured: measured, fallback: _p720) == _p720,
      false,
    );

    // Same rule one level down: the largest 5:4 mode that fits, not the
    // largest mode of any shape.
    final withSmaller = _caps(<CameraResolution>[
      _r(1280, 1024),
      _r(1024, 819),
      _r(1280, 720),
    ]);
    eq(
      'and the largest one of that shape',
      defaultResolutionFor(measured: withSmaller, fallback: _p720).label,
      '1280x1024',
    );

    // A camera whose only measured mode is 16:9 gets 16:9 — the rule follows
    // the measurement, it does not hardcode anything.
    eq(
      'a 16:9 camera keeps 16:9',
      defaultResolutionFor(
        measured: _caps(<CameraResolution>[_p1080, _p720]),
        fallback: _p720,
      ).label,
      '1920x1080',
    );
  }

  // --- the measured device: portrait must not open at 240x320 ---------------
  section('a portrait camera keeps a portrait default');
  {
    // vivo V2405A, held portrait. Before this rule `fitsWithin` compared the
    // target axis-wise against a landscape box, so every sane portrait geometry
    // (1080x1920, 720x1280, …) was judged too large and discarded; the shape
    // filter then kept only the 3:4 survivors, and the only one left was the
    // smallest — 240x320 at 0.077 MP.
    final measuredOnly = _caps(_deviceMeasured);
    eq(
      'the measured portrait set opens at 1080x1920',
      defaultResolutionFor(measured: measuredOnly, fallback: _p720).label,
      '1080x1920',
    );
    check(
      'and never at the 240x320 regression',
      defaultResolutionFor(measured: measuredOnly, fallback: _p720) !=
          _r(240, 320),
    );

    // The declared list from the cache — measured plus the ladder — must give
    // the same answer, since that is what production actually feeds the
    // selector.
    final declared = _caps(_deviceDeclared);
    eq(
      'the cached declared set opens at 1080x1920 too',
      defaultResolutionFor(measured: declared, fallback: _p720).label,
      '1080x1920',
    );
    check(
      'and never at 240x320 either',
      defaultResolutionFor(measured: declared, fallback: _p720) != _r(240, 320),
    );

    // The transposed landscape geometry the HAL also advertises is a real size,
    // just the same one held the other way up — and it fits the target.
    check(
      'the landscape transposition is still a size that fits',
      fitsWithin(_p1080, kTargetResolution) &&
          fitsWithin(_r(1080, 1920), kTargetResolution),
    );
  }

  // --- the ladder only fills gaps the camera can actually produce -----------
  section('the ladder does not invent a shape the camera never produced');
  {
    // A 5:4 sensor. The common ladder is 16:9 and 4:3 only, so none of it
    // describes a geometry this camera produced. Advertising it would put a
    // shape in the operator's menu — and, now that the selector trusts the
    // list, in the default — that the camera opens to a stretched picture.
    final measured = _caps(<CameraResolution>[_r(1280, 1024)]);
    final declared = measured.withCommonBaseline();

    eq(
      'a 5:4 sensor keeps exactly its own geometry',
      declared.resolutions.map((r) => r.label).join(','),
      '1280x1024',
    );
    check(
      'no 16:9 rung is invented',
      !declared.resolutions.any((r) => sameAspectRatio(r, _p1080)),
    );
    check(
      'no 4:3 rung is invented',
      !declared.resolutions.any((r) => sameAspectRatio(r, _p480)),
    );
    eq(
      'and its default is its own geometry',
      defaultResolutionFor(measured: declared, fallback: _p720).label,
      '1280x1024',
    );

    // A camera that really did produce both shapes keeps the ladder for both:
    // the rule follows the measurement, it does not ban the ladder.
    final both = _caps(<CameraResolution>[_p1080, _p480]).withCommonBaseline();
    check(
      'a camera that produced 16:9 and 4:3 still gets both ladders',
      both.resolutions.any((r) => sameAspectRatio(r, _p1080)) &&
          both.resolutions.any((r) => sameAspectRatio(r, _r(1024, 768))),
    );
  }

  // --- nothing measured ------------------------------------------------------
  {
    eq(
      'an empty probe falls back to the configured geometry',
      defaultResolutionFor(
        measured: CameraCapabilities.empty,
        fallback: _p720,
      ).label,
      '1280x720',
    );
    // And the fallback is a candidate even when something was measured, so a
    // probe that only found geometries the pipeline was not built for still
    // produces an openable mode.
    eq(
      'the fallback is always a candidate',
      defaultResolutionFor(
        measured: _caps(<CameraResolution>[_r(3840, 2160)]),
        fallback: _p720,
      ).label,
      '1280x720',
    );
    // Every measured geometry above the target: the smallest overshoot.
    eq(
      'a camera that only offers 4K opens at the least oversized mode',
      defaultResolutionFor(
        measured: _caps(<CameraResolution>[_r(3840, 2160), _r(4096, 2160)]),
        fallback: _r(4096, 2160),
      ).label,
      '3840x2160',
    );
  }

  // --- fitsWithin is per axis, not by area, and orientation-blind -----------
  {
    check(
      'same area, too wide: does not fit',
      !fitsWithin(_r(2560, 1080), _p1080),
    );
    check(
      'same area, too tall: does not fit',
      !fitsWithin(_r(1440, 1440), _p1080),
    );
    check('exactly the target: fits', fitsWithin(_p1080, _p1080));
    check('smaller in both: fits', fitsWithin(_p720, _p1080));
    check(
      'wider in one only: does not fit',
      !fitsWithin(_r(1920, 1440), _p1080),
    );

    // A target is a *size*, not an orientation: the same geometry transposed
    // fits exactly as well, and a larger portrait one still does not.
    check(
      'a portrait target is the same size transposed',
      fitsWithin(_r(1080, 1920), _p1080),
    );
    check(
      'exactly the target, transposed: fits',
      fitsWithin(_r(1080, 1920), _r(1080, 1920)),
    );
    check(
      'too large in both axes: does not fit, whichever way up',
      !fitsWithin(_r(2160, 3840), _p1080),
    );

    check('same shape, smaller: same shape', sameAspectRatio(_p720, _p1080));
    check('different shape: not the same', !sameAspectRatio(_p480, _p1080));
    check(
      'cross-multiplication is exact, not rounded',
      sameAspectRatio(_r(1280, 1024), _r(640, 512)),
    );
    // 1080x1920 and 1920x1080 are one shape rotated, not two.
    check(
      'the transposed pair is one shape',
      sameAspectRatio(_r(1080, 1920), _p1080),
    );
    check(
      'a genuinely different shape is still not the same',
      !sameAspectRatio(_r(1080, 1920), _r(1280, 1024)),
    );
  }

  // --- fps: highest measured rung, capped at 60 -----------------------------
  section('the announced rate is a measured rate, capped at 60');
  {
    eq(
      'held 60: announces 60',
      defaultFpsFor(
        resolution: _p1080,
        samples: <EncodeSample>[
          EncodeSample(
            codec: CaptureCodec.h265,
            resolution: _p1080,
            measuredFps: 60,
          ),
        ],
        unmeasuredFps: 5,
      ),
      60,
    );
    eq(
      'held 120: still announces 60',
      defaultFpsFor(
        resolution: _p1080,
        samples: <EncodeSample>[
          EncodeSample(
            codec: CaptureCodec.h265,
            resolution: _p1080,
            measuredFps: 120,
          ),
        ],
        unmeasuredFps: 5,
      ),
      60,
    );
    // Rounds DOWN to a rung on the ladder, never up to the next one.
    eq(
      'held 58: announces 50, not 60',
      defaultFpsFor(
        resolution: _p1080,
        samples: <EncodeSample>[
          EncodeSample(
            codec: CaptureCodec.h265,
            resolution: _p1080,
            measuredFps: 58,
          ),
        ],
        unmeasuredFps: 5,
      ),
      50,
    );
    eq(
      'held 30 with h264 and 60 with mjpeg: 60',
      defaultFpsFor(
        resolution: _p1080,
        samples: <EncodeSample>[
          EncodeSample(
            codec: CaptureCodec.h264,
            resolution: _p1080,
            measuredFps: 30,
          ),
          EncodeSample(
            codec: CaptureCodec.mjpeg,
            resolution: _p1080,
            measuredFps: 60,
          ),
        ],
        unmeasuredFps: 5,
      ),
      60,
    );
    // A rate measured at another geometry is not evidence for this one.
    eq(
      'held 60 at 720p: no evidence at 1080p',
      defaultFpsFor(
        resolution: _p1080,
        samples: <EncodeSample>[
          EncodeSample(
            codec: CaptureCodec.h265,
            resolution: _p720,
            measuredFps: 60,
          ),
        ],
        unmeasuredFps: 5,
      ),
      5,
    );
    // Held something below the lowest rung: the floor, not zero.
    eq(
      'held 2: announces the floor, not zero',
      defaultFpsFor(
        resolution: _p1080,
        samples: <EncodeSample>[
          EncodeSample(
            codec: CaptureCodec.h265,
            resolution: _p1080,
            measuredFps: 2,
          ),
        ],
        unmeasuredFps: 5,
      ),
      kMinDeclaredFramerate,
    );
  }

  // --- fps: no evidence is not evidence for the target ----------------------
  section('no measurement is not a claim');
  {
    // The rule #4 exists for. A device that never measured must not announce
    // the target on the strength of nothing: the server trusts `fps` to
    // estimate segment durations, so an invented rate overstates every segment.
    eq(
      'nothing measured: the caller\'s justified fallback',
      defaultFpsFor(
        resolution: _p1080,
        samples: const <EncodeSample>[],
        unmeasuredFps: 5,
      ),
      5,
    );
    // A probe that ran and held nothing reaches the same branch — and must not
    // be treated as "no probe, so assume 60".
    eq(
      'measured and held nothing: the same fallback',
      defaultFpsFor(
        resolution: _p1080,
        samples: <EncodeSample>[
          EncodeSample(
            codec: CaptureCodec.h265,
            resolution: _p1080,
            measuredFps: 0,
          ),
          EncodeSample(
            codec: CaptureCodec.h264,
            resolution: _p1080,
            measuredFps: -1,
          ),
        ],
        unmeasuredFps: 5,
      ),
      5,
    );
    // The fallback itself cannot be an unusable rate.
    eq(
      'a fallback below the floor is raised to the floor',
      defaultFpsFor(
        resolution: _p1080,
        samples: const <EncodeSample>[],
        unmeasuredFps: 0,
      ),
      kMinDeclaredFramerate,
    );
  }

  // --- defaultModeFor ties the two together --------------------------------
  section('the default mode is one decision');
  {
    final mode = defaultModeFor(
      measured: _caps(<CameraResolution>[_p2160, _p1080, _p720]),
      samples: <EncodeSample>[
        EncodeSample(
          codec: CaptureCodec.h264,
          resolution: _p1080,
          measuredFps: 60,
        ),
      ],
      fallbackResolution: _p720,
      unmeasuredFps: 5,
    );
    eq(
      'a 4K camera opens at 1080p60',
      mode.toString(),
      'CameraMode(1920x1080 @ 60fps)',
    );

    // The rate is chosen *for the resolution the selector picked*, not for one
    // the caller had in mind: a 720p camera with only 720p evidence is fine,
    // but 1080p evidence must not be used to justify 60 at 720p by accident.
    final slow = defaultModeFor(
      measured: _caps(<CameraResolution>[_p720]),
      samples: <EncodeSample>[
        EncodeSample(
          codec: CaptureCodec.h264,
          resolution: _p720,
          measuredFps: 30,
        ),
      ],
      fallbackResolution: _p720,
      unmeasuredFps: 5,
    );
    eq(
      'a 720p30 camera opens at 720p30',
      slow.toString(),
      'CameraMode(1280x720 @ 30fps)',
    );

    // Same camera, evidence only at another geometry: the honest fallback.
    final none = defaultModeFor(
      measured: _caps(<CameraResolution>[_p720]),
      samples: <EncodeSample>[
        EncodeSample(
          codec: CaptureCodec.h264,
          resolution: _p1080,
          measuredFps: 60,
        ),
      ],
      fallbackResolution: _p720,
      unmeasuredFps: 5,
    );
    eq(
      'evidence at another geometry does not carry over',
      none.toString(),
      'CameraMode(1280x720 @ 5fps)',
    );
  }
}
