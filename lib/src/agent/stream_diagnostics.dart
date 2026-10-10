import 'dart:collection';

import '../capture/stream_settings.dart';

/// Which stage of the pipeline is holding the rate down.
///
/// The device is a chain — camera → encoder → transport — and a low delivery
/// rate has one cause and three look-alikes. Without naming the stage, "we are
/// only pushing 12 fps" is not actionable: an operator cannot tell a slow
/// sensor from a slow encoder from a slow link, and those have three different
/// fixes. This is the classification that makes the difference sayable.
///
/// The stages are checked **in pipeline order**, and the first shortfall wins.
/// That is deliberate: an upstream bottleneck drags every downstream number
/// down with it, so a camera delivering 5 fps makes the encoder and the
/// transport look slow too. Blaming the last stage would send an operator to
/// the network for a problem in the sensor.
enum PipelineBottleneck {
  /// Nothing is being pushed, so there is no rate to explain.
  idle,

  /// Recording, but no measurement window has produced a number yet.
  unknown,

  /// The camera did not produce what was asked of it.
  camera,

  /// The camera kept up; the encoder did not.
  encoder,

  /// The encoder kept up; the frames did not reach the gateway.
  network,

  /// Every stage met the target.
  healthy,
}

/// A stage running below this fraction of the stage before it counts as the
/// bottleneck.
///
/// Not 1.0 on purpose: rates are sampled over separate rolling windows and
/// floored, so two stages that are keeping up still disagree by a frame or two
/// on any given read. A strict comparison would report a bottleneck on a
/// perfectly healthy pipeline.
const double kBottleneckTolerance = 0.8;

/// Names the stage holding the rate down, from the five rates alone.
///
/// Pure and total, so the rule can be exercised without a camera: this is the
/// part of #23 that is worth pinning down, because it is the part an operator
/// actually reads.
PipelineBottleneck classifyBottleneck({
  required bool recording,
  required int targetFps,
  required int? capturedFps,
  required int? encodedFps,
  required int? sentFps,
  double tolerance = kBottleneckTolerance,
}) {
  if (!recording) return PipelineBottleneck.idle;

  final captured = capturedFps;
  // No window has closed yet: "not measured" is not "measured and slow", and
  // calling it a camera problem on the first frame would be a false alarm on
  // every recording.
  if (captured == null) return PipelineBottleneck.unknown;

  // The camera is the first constraint: if the sensor did not produce the rate,
  // nothing downstream could have delivered it.
  if (targetFps > 0 && captured < targetFps * tolerance) {
    return PipelineBottleneck.camera;
  }

  final encoded = encodedFps;
  if (encoded != null && encoded < captured * tolerance) {
    return PipelineBottleneck.encoder;
  }

  final sent = sentFps;
  if (sent != null && sent < (encoded ?? captured) * tolerance) {
    return PipelineBottleneck.network;
  }

  return PipelineBottleneck.healthy;
}

/// Counts events over a sliding wall-clock window and reports a floored rate.
///
/// A rolling window rather than a one-shot measurement like
/// [SustainedRateMeter]: that one answers "what can this device hold", and
/// closes after its window on purpose so the first answer cannot be overwritten
/// by a later burst. This one answers "what is happening right now", which is
/// the opposite question — it has to keep moving, or a diagnostics display
/// would freeze on the first second of a recording.
///
/// Events carry a **weight**, because not every event is one frame. The camera
/// is measured from how far its own sequence advanced, and a producer that
/// emits every picture advances it by one — but a producer whose sequence
/// jumps by five has told us five pictures happened, and the stage comparison
/// only works if all five are counted.
///
/// Floored, like every other rate in this project: 29.7 fps is evidence for 29.
class RollingRate {
  RollingRate({this.window = const Duration(seconds: 2)});

  /// How far back an event still counts.
  final Duration window;

  final ListQueue<({DateTime at, int weight})> _events =
      ListQueue<({DateTime at, int weight})>();

  int _total = 0;

  /// Weight inside the window ending at the most recent [record] call.
  int get count => _total;

  /// Records [weight] events at [at], dropping anything that has fallen out of
  /// the window. A non-positive weight records nothing.
  void record(DateTime at, {int weight = 1}) {
    if (weight <= 0) return;
    _events.addLast((at: at, weight: weight));
    _total += weight;
    _trim(at);
  }

  /// The rate at [now], in whole events per second.
  ///
  /// [now] is passed rather than read from a clock so a test can drive this
  /// without waiting; it is also what lets a stalled pipeline report zero, as
  /// the events age out of the window.
  int rateAt(DateTime now) {
    _trim(now);
    final seconds = window.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return 0;
    return (_total / seconds).floor();
  }

  void clear() {
    _events.clear();
    _total = 0;
  }

  void _trim(DateTime now) {
    final cutoff = now.subtract(window);
    while (_events.isNotEmpty && _events.first.at.isBefore(cutoff)) {
      _total -= _events.removeFirst().weight;
    }
  }
}

/// Everything an operator needs to tell a slow camera from a slow encoder from
/// a slow link, as one immutable snapshot.
///
/// Deliberately **local**: none of this goes into the periodic `status` report.
/// The protocol defines that payload's fields, and inventing new ones would
/// mean a device sending keys the server has no definition for. This is for
/// the on-device status bar.
///
/// It also carries no credentials, and cannot: every field is a number, a codec
/// name, a geometry or a platform-supplied encoder identity.
class StreamDiagnostics {
  const StreamDiagnostics({
    this.recording = false,
    this.targetFps = 0,
    this.selectedFps = 0,
    this.capturedFps,
    this.encodedFps,
    this.sentFps,
    this.codec,
    this.encoderIdentity = '',
    this.width = 0,
    this.height = 0,
    this.droppedFrames = 0,
    this.repeatedFrames = 0,
    this.degradationReason,
  });

  /// Nothing to report: the device is idle and has never recorded.
  static const StreamDiagnostics idle = StreamDiagnostics();

  /// True while a stream is being fed.
  final bool recording;

  /// The rate the pipeline is **asked** to run at (`AppConfig.defaultFps`).
  ///
  /// The pump's tick ceiling, not a promise: it is allowed to exceed what is
  /// delivered, and deliberately is not throttled down to the declared rate.
  final int targetFps;

  /// The rate the device **declared** at registration for this mode.
  ///
  /// What the server snapshots into `metadata.fps` and estimates segment
  /// durations from, so it may never exceed what has been demonstrated.
  final int selectedFps;

  /// New pictures per second the camera produced. Null until measured.
  ///
  /// "New" is the operative word: a repeated picture does not count, which is
  /// what keeps a padded stream from reading as a fast one.
  final int? capturedFps;

  /// Access units per second out of the encoder. Null until measured.
  final int? encodedFps;

  /// Access units per second handed to the gateway. Null until measured.
  final int? sentFps;

  final CaptureCodec? codec;

  /// What the platform calls the encoder, empty when it did not say.
  final String encoderIdentity;

  final int width;
  final int height;

  /// Access units the encoder produced that never reached the gateway.
  ///
  /// Expected to be near zero while a stream is live — the send is synchronous
  /// — so a number that keeps climbing is a real finding. The tail a native
  /// encoder flushes *after* a stop lands here too, because the stream is gone
  /// by then and the server would discard those frames anyway.
  final int droppedFrames;

  /// Access units that carried no new picture.
  ///
  /// The signature of a producer padding its output to hit a rate it cannot
  /// really deliver, and the reason `capturedFps` counts sequences rather than
  /// arrivals.
  final int repeatedFrames;

  /// Why the device is not at [targetFps], when it knows.
  final String? degradationReason;

  /// The stage holding the rate down, from the rates above.
  PipelineBottleneck get bottleneck => classifyBottleneck(
    recording: recording,
    targetFps: targetFps,
    capturedFps: capturedFps,
    encodedFps: encodedFps,
    sentFps: sentFps,
  );

  StreamDiagnostics copyWith({
    bool? recording,
    int? targetFps,
    int? selectedFps,
    int? capturedFps,
    int? encodedFps,
    int? sentFps,
    CaptureCodec? codec,
    String? encoderIdentity,
    int? width,
    int? height,
    int? droppedFrames,
    int? repeatedFrames,
    String? degradationReason,
  }) => StreamDiagnostics(
    recording: recording ?? this.recording,
    targetFps: targetFps ?? this.targetFps,
    selectedFps: selectedFps ?? this.selectedFps,
    capturedFps: capturedFps ?? this.capturedFps,
    encodedFps: encodedFps ?? this.encodedFps,
    sentFps: sentFps ?? this.sentFps,
    codec: codec ?? this.codec,
    encoderIdentity: encoderIdentity ?? this.encoderIdentity,
    width: width ?? this.width,
    height: height ?? this.height,
    droppedFrames: droppedFrames ?? this.droppedFrames,
    repeatedFrames: repeatedFrames ?? this.repeatedFrames,
    degradationReason: degradationReason ?? this.degradationReason,
  );

  @override
  String toString() =>
      'StreamDiagnostics(${recording ? 'recording' : 'idle'}, '
      'target=$targetFps/selected=$selectedFps, '
      'cap=$capturedFps/enc=$encodedFps/sent=$sentFps, '
      '${codec?.wireName ?? '-'} ${width}x$height, '
      'dropped=$droppedFrames repeated=$repeatedFrames)';
}
