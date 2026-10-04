import '../backend/backend_gateway.dart';

/// What the device is doing right now.
///
/// The device is a **subordinate**: it never streams on its own initiative, so
/// [idle] is the normal resting state and [recording] only happens between a
/// `start_recording` and its `stop_recording`.
enum CaptureState {
  /// Nothing is being pushed. The camera may still be open and previewing.
  idle,

  /// Pushing `recording.frame` messages into the server's active stream.
  recording,

  /// Answering one `take_photo` command.
  capturingPhoto;

  bool get isBusy => this != CaptureState.idle;
}

/// Everything the status bar needs, as one immutable snapshot.
class AgentStatus {
  const AgentStatus({
    required this.linkState,
    required this.captureState,
    required this.activeStreamId,
    required this.cameraName,
    required this.fps,
    required this.previewEnabled,
    this.framesSent = 0,
    this.lastError,
  });

  final LinkState linkState;
  final CaptureState captureState;

  /// The stream the server asked us to feed, while we are feeding it.
  final String? activeStreamId;

  final String cameraName;

  /// The frame rate announced at registration, in whole frames per second.
  ///
  /// The server rejects a fractional `fps` outright and snapshots this value
  /// into the stream metadata, so it is the number that governs how the server
  /// estimates segment durations — not a local measurement.
  final int fps;

  /// Purely local: the server has no command for the preview.
  final bool previewEnabled;

  /// Frames handed to the gateway for the current session.
  final int framesSent;

  /// The most recent link-level problem, if any.
  final String? lastError;

  bool get isLive => linkState == LinkState.live;

  bool get isFailed => linkState == LinkState.failed;

  /// True while the link is down but recovery is still being attempted.
  bool get isReconnecting =>
      linkState == LinkState.backoff ||
      linkState == LinkState.registering ||
      linkState == LinkState.attaching;

  bool get isRecording => captureState == CaptureState.recording;

  static const AgentStatus initial = AgentStatus(
    linkState: LinkState.idle,
    captureState: CaptureState.idle,
    activeStreamId: null,
    cameraName: '',
    fps: 0,
    previewEnabled: true,
  );

  AgentStatus copyWith({
    LinkState? linkState,
    CaptureState? captureState,
    String? activeStreamId,
    bool clearActiveStreamId = false,
    String? cameraName,
    int? fps,
    bool? previewEnabled,
    int? framesSent,
    String? lastError,
  }) => AgentStatus(
    linkState: linkState ?? this.linkState,
    captureState: captureState ?? this.captureState,
    activeStreamId: clearActiveStreamId
        ? null
        : (activeStreamId ?? this.activeStreamId),
    cameraName: cameraName ?? this.cameraName,
    fps: fps ?? this.fps,
    previewEnabled: previewEnabled ?? this.previewEnabled,
    framesSent: framesSent ?? this.framesSent,
    lastError: lastError ?? this.lastError,
  );

  @override
  String toString() =>
      'AgentStatus(${linkState.name}/${captureState.name}, '
      'stream=$activeStreamId, ${fps}fps, sent=$framesSent)';
}
