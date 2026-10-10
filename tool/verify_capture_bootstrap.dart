// Exercises the start-up capture plan, folded into the single gate.
//
// `flutter test` cannot run in this environment, so these run on a plain Dart
// VM as part of `tool/verify_pure.dart` — the project's one gate:
//
//   dart run tool/verify_pure.dart
//
// `check`, `eq` and `section` are the harness's, imported from there so every
// section lands in the one pass/fail count.
//
// What is being pinned here is task #14's ordering rule and its sharpest edge:
// a codec the platform *claims* is not a codec the device may *publish*, and
// the only thing that turns a claim into a publication is a measurement at the
// mode being announced.
import 'package:webcam_client/src/app/capture_bootstrap.dart';
import 'package:webcam_client/src/capture/camera_capabilities.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/default_mode.dart';
import 'package:webcam_client/src/capture/encode_budget.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/sustained_rate.dart';

import 'verify_pure.dart';

// --- fixtures ---------------------------------------------------------------

const _p2160 = CameraResolution(width: 3840, height: 2160);
const _p1080 = CameraResolution(width: 1920, height: 1080);
const _p720 = CameraResolution(width: 1280, height: 720);

const String _fp = 'fp-cam-A';
const String _enc = 'mjpeg.takePicture';

CameraCapabilities _caps(List<CameraResolution> resolutions) =>
    CameraCapabilities.of(resolutions: resolutions, framerates: const <int>[]);

EncodeEvidence _evidence(
  String fingerprint,
  String encoder,
  List<EncodeSample> samples,
) => EncodeEvidence(
  version: kEncodeEvidenceVersion,
  cameraFingerprint: fingerprint,
  encoderIdentity: encoder,
  samples: samples,
);

EncodeSample _sample(
  CaptureCodec codec,
  CameraResolution resolution,
  int fps,
) => EncodeSample(codec: codec, resolution: resolution, measuredFps: fps);

/// A probe with a scripted answer. `null` makes it throw.
class _FakeProbe implements EncodeBudgetProbe {
  _FakeProbe(this.result);

  EncodeEvidence? result;

  int calls = 0;
  CameraResolution? atResolution;
  List<CaptureCodec>? atCodecs;
  String? atFingerprint;
  String? atIdentity;

  @override
  Future<EncodeEvidence> measure({
    required int cameraEnum,
    required CameraResolution resolution,
    required List<CaptureCodec> codecs,
    required String cameraFingerprint,
    required String encoderIdentity,
  }) async {
    calls++;
    atResolution = resolution;
    atCodecs = codecs;
    atFingerprint = cameraFingerprint;
    atIdentity = encoderIdentity;
    final answer = result;
    if (answer == null) throw StateError('no encoder could be opened');
    return answer;
  }
}

/// A store that fails on read: a corrupt cache must be a miss, not a crash.
class _UnreadableStore implements EncodeEvidenceStore {
  int saves = 0;

  @override
  Future<EncodeEvidence?> load({
    required String cameraFingerprint,
    required String encoderIdentity,
  }) async {
    throw StateError('shared_preferences is not available');
  }

  @override
  Future<void> save(EncodeEvidence value) async {
    saves++;
  }

  @override
  Future<void> clear() async {}
}

const Set<CaptureCodec> _mjpegOnly = <CaptureCodec>{CaptureCodec.mjpeg};

const Set<CaptureCodec> _withNative = <CaptureCodec>{
  CaptureCodec.h265,
  CaptureCodec.h264,
  CaptureCodec.mjpeg,
};

Future<void> runCaptureBootstrapChecks() async {
  // --- the floor ------------------------------------------------------------
  section('no platform probe: the floor is announced');
  {
    final store = InMemoryEncodeEvidenceStore();
    final plan = await _plan(
      store: store,
      probe: null,
      available: _mjpegOnly,
      measured: _caps(<CameraResolution>[_p2160, _p1080, _p720]),
    );
    eq('a 4K camera still opens at 1080p', plan.resolution, _p1080);
    eq('nothing measured declares the floor', plan.fps, kFpsWithoutEvidence);
    eq(
      'the published list is the floor',
      plan.codecs.map((c) => c.wireName).join(','),
      'mjpeg',
    );
    check('nothing was measured', plan.evidence.isEmpty);
    check('nothing was cached', store.value == null);
  }

  section('a claimed native codec with no measurement is not published');
  {
    // The whole rule. The platform says it has H.265; nothing has measured it
    // at the mode being announced; publishing it would be offering a stream
    // this device has never been seen delivering.
    final plan = await _plan(
      store: InMemoryEncodeEvidenceStore(),
      probe: _FakeProbe(EncodeEvidence.empty),
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq(
      'h265 is claimed but not published',
      plan.codecs.map((c) => c.wireName).join(','),
      'mjpeg',
    );
    eq('the declared rate stays at the floor', plan.fps, kFpsWithoutEvidence);
  }

  section('a codec that held 30 is not published at 60');
  {
    final evidence = _evidence(_fp, _enc, <EncodeSample>[
      _sample(CaptureCodec.h265, _p1080, 30),
    ]);
    eq(
      'at 30 it is published',
      announcedCodecsFor(
        available: _withNative,
        evidence: evidence,
        resolution: _p1080,
        fps: 30,
      ).map((c) => c.wireName).join(','),
      'h265',
    );
    eq(
      'at 60 it is not',
      announcedCodecsFor(
        available: _withNative,
        evidence: evidence,
        resolution: _p1080,
        fps: 60,
      ).map((c) => c.wireName).join(','),
      'mjpeg',
    );
    eq(
      'and not at another geometry either',
      announcedCodecsFor(
        available: _withNative,
        evidence: evidence,
        resolution: _p720,
        fps: 30,
      ).map((c) => c.wireName).join(','),
      'mjpeg',
    );
  }

  // --- measured -------------------------------------------------------------
  section('measured 60 raises the declared rate and narrows the list');
  {
    final probe = _FakeProbe(
      _evidence(_fp, _enc, <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 60),
        _sample(CaptureCodec.mjpeg, _p1080, 8),
      ]),
    );
    final store = InMemoryEncodeEvidenceStore();
    final plan = await _plan(
      store: store,
      probe: probe,
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('the declared rate is what was held', plan.fps, 60);
    eq(
      'mjpeg drops out: it cannot hold the declared rate',
      plan.codecs.map((c) => c.wireName).join(','),
      'h265',
    );
    eq('the probe ran once', probe.calls, 1);
    eq('at the geometry that will be opened', probe.atResolution, _p1080);
    eq(
      'for the codecs the platform claims',
      probe.atCodecs?.map((c) => c.wireName).join(','),
      'h265,h264,mjpeg',
    );
    eq('keyed by this camera', probe.atFingerprint, _fp);
    eq('and this encoder', probe.atIdentity, _enc);
    check('the result was cached', store.value != null);
  }

  section('measured and held nothing reads like never measured');
  {
    final plan = await _plan(
      store: InMemoryEncodeEvidenceStore(),
      probe: _FakeProbe(_evidence(_fp, _enc, const <EncodeSample>[])),
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('the floor is declared', plan.fps, kFpsWithoutEvidence);
    eq(
      'the floor is published',
      plan.codecs.map((c) => c.wireName).join(','),
      'mjpeg',
    );
  }

  section('the declared rate comes from claimed codecs only');
  {
    // A sample for a codec the platform does not have cannot set the declared
    // rate: the published list is filtered by `available`, so a rate taken
    // from elsewhere would describe a different device.
    final probe = _FakeProbe(
      _evidence(_fp, _enc, <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 60),
      ]),
    );
    final plan = await _plan(
      store: InMemoryEncodeEvidenceStore(),
      probe: probe,
      available: _mjpegOnly,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('the unclaimed codec does not set the rate', plan.fps, 5);
    eq(
      'and is not published',
      plan.codecs.map((c) => c.wireName).join(','),
      'mjpeg',
    );
    eq(
      'the probe was not asked for it',
      probe.atCodecs?.map((c) => c.wireName).join(','),
      'mjpeg',
    );
  }

  // --- the cache ------------------------------------------------------------
  section('a cache hit measures nothing');
  {
    final store = InMemoryEncodeEvidenceStore()
      ..value = _evidence(_fp, _enc, <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 60),
      ]);
    final probe = _FakeProbe(EncodeEvidence.empty);
    final plan = await _plan(
      store: store,
      probe: probe,
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('the cached rate is declared', plan.fps, 60);
    eq('nothing was opened or measured', probe.calls, 0);
  }

  section('a different camera re-measures');
  {
    final store = InMemoryEncodeEvidenceStore()
      ..value = _evidence('fp-cam-B', _enc, <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 60),
      ]);
    final probe = _FakeProbe(EncodeEvidence.empty);
    final plan = await _plan(
      store: store,
      probe: probe,
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('the stale evidence is not used', probe.calls, 1);
    eq('so the floor is declared', plan.fps, kFpsWithoutEvidence);
  }

  section('a different encoder re-measures');
  {
    final store = InMemoryEncodeEvidenceStore()
      ..value = _evidence(_fp, 'some.other.encoder', <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 60),
      ]);
    final probe = _FakeProbe(EncodeEvidence.empty);
    final plan = await _plan(
      store: store,
      probe: probe,
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('hardware and software are not interchangeable', probe.calls, 1);
    eq('so the floor is declared', plan.fps, kFpsWithoutEvidence);
  }

  section('re-detecting forces a re-measure');
  {
    final store = InMemoryEncodeEvidenceStore()
      ..value = _evidence(_fp, _enc, <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 30),
      ]);
    final probe = _FakeProbe(
      _evidence(_fp, _enc, <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 60),
      ]),
    );
    final plan = await _plan(
      store: store,
      probe: probe,
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
      forceRemeasure: true,
    );
    eq('the old answer was measured again', probe.calls, 1);
    eq('and the fresh one is declared', plan.fps, 60);
    eq('the cache now holds it', store.value?.samples.single.measuredFps, 60);
  }

  // --- failure --------------------------------------------------------------
  section('a probe that throws measures nothing');
  {
    final store = InMemoryEncodeEvidenceStore();
    final plan = await _plan(
      store: store,
      probe: _FakeProbe(null),
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    check('the plan still exists', plan.resolution == _p1080);
    eq('the floor is declared', plan.fps, kFpsWithoutEvidence);
    eq(
      'the floor is published',
      plan.codecs.map((c) => c.wireName).join(','),
      'mjpeg',
    );
    check('a failure is not cached as a result', store.value == null);
  }

  section('evidence for another device is not used or cached');
  {
    final store = InMemoryEncodeEvidenceStore();
    final plan = await _plan(
      store: store,
      probe: _FakeProbe(
        _evidence('fp-cam-B', _enc, <EncodeSample>[
          _sample(CaptureCodec.h265, _p1080, 60),
        ]),
      ),
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('the floor is declared', plan.fps, kFpsWithoutEvidence);
    check('another camera\'s rate is not cached', store.value == null);
  }

  section('an unreadable cache is a miss, not a failure');
  {
    final store = _UnreadableStore();
    final probe = _FakeProbe(
      _evidence(_fp, _enc, <EncodeSample>[
        _sample(CaptureCodec.h265, _p1080, 60),
      ]),
    );
    final plan = await _plan(
      store: store,
      probe: probe,
      available: _withNative,
      measured: _caps(<CameraResolution>[_p1080]),
    );
    eq('it measured instead', probe.calls, 1);
    eq('and declared what was held', plan.fps, 60);
    eq('and tried to cache it', store.saves, 1);
  }

  section('the published list is never empty');
  {
    // An empty `supported_codec` is a 400, and a device that cannot register
    // is worse than one that publishes only the floor.
    eq(
      'nothing claimed still publishes the floor',
      announcedCodecsFor(
        available: const <CaptureCodec>{},
        evidence: EncodeEvidence.empty,
        resolution: _p1080,
        fps: 30,
      ).map((c) => c.wireName).join(','),
      'mjpeg',
    );
  }

  section('a claimed codec outside the preference list is still published');
  {
    final evidence = _evidence(_fp, _enc, <EncodeSample>[
      _sample(CaptureCodec.av1, _p1080, 30),
      _sample(CaptureCodec.mjpeg, _p1080, 30),
    ]);
    eq(
      'av1 is appended after the preferred ones, not dropped',
      announcedCodecsFor(
        available: <CaptureCodec>{CaptureCodec.av1, CaptureCodec.mjpeg},
        evidence: evidence,
        resolution: _p1080,
        fps: 30,
      ).map((c) => c.wireName).join(','),
      'mjpeg,av1',
    );
  }
}

Future<CapturePlan> _plan({
  required EncodeEvidenceStore store,
  required EncodeBudgetProbe? probe,
  required Set<CaptureCodec> available,
  required CameraCapabilities measured,
  bool forceRemeasure = false,
}) => planCapture(
  store: store,
  probe: probe,
  available: available,
  measured: measured,
  cameraFingerprint: _fp,
  encoderIdentity: _enc,
  fallbackResolution: _p720,
  forceRemeasure: forceRemeasure,
);
