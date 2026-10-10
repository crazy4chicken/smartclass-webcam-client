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

  // --- shape beats pixel count ----------------------------------------------
  section('the default keeps the camera\'s own shape');
  {
    // A 5:4 camera that also reports 16:9 modes: opening it at the largest
    // mode that fits would give 1280x720, which is a different shape from the
    // sensor. Nothing errors — the picture is just wrong.
    final measured = _caps(<CameraResolution>[_p1280x1024, _p720, _p480]);
    eq(
      'a 5:4 camera opens at its own shape',
      defaultResolutionFor(measured: measured, fallback: _p720).label,
      '1280x1024',
    );
    eq(
      'not at the largest fitting mode of another shape',
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

    // A camera whose only measured mode is 16:9 gets 16:9 — the shape rule
    // follows the measurement, it does not hardcode anything.
    eq(
      'a 16:9 camera keeps 16:9',
      defaultResolutionFor(
        measured: _caps(<CameraResolution>[_p1080, _p720]),
        fallback: _p720,
      ).label,
      '1920x1080',
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

  // --- fitsWithin is per axis, not by area ---------------------------------
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
    check('same shape, smaller: same shape', sameAspectRatio(_p720, _p1080));
    check('different shape: not the same', !sameAspectRatio(_p480, _p1080));
    check(
      'cross-multiplication is exact, not rounded',
      sameAspectRatio(_r(1280, 1024), _r(640, 512)),
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
