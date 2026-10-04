import '../capture/camera_resolution.dart';
import '../capture/stream_settings.dart';

/// Metadata for one still frame.
///
/// A `frame_meta` text frame **must** precede the JPEG binary, otherwise the
/// backend cannot associate the bytes with an identity or a point in time.
class FrameMeta {
  const FrameMeta({
    required this.frameId,
    required this.deviceId,
    required this.timestampMs,
    required this.width,
    required this.height,
    required this.quality,
  });

  final int frameId;
  final String deviceId;
  final int timestampMs;
  final int width;
  final int height;
  final int quality;
}

/// Metadata for one recorded video chunk.
class VideoMeta {
  const VideoMeta({
    required this.chunkId,
    required this.deviceId,
    required this.timestampMs,
    required this.codec,
    required this.sequence,
    required this.durationMs,
    required this.width,
    required this.height,
  });

  final int chunkId;
  final String deviceId;
  final int timestampMs;
  final VideoCodec codec;
  final int sequence;
  final int durationMs;
  final int width;
  final int height;
}

/// What this client can actually do, reported on `register`.
///
/// The backend uses it to decide the stream mode instead of guessing.
class ClientCapabilities {
  const ClientCapabilities({
    required this.platform,
    required this.modes,
    required this.videoCodecs,
    required this.maxFps,
    required this.hasPreview,
    required this.supportedResolutions,
    required this.cameras,
  });

  final String platform;
  final List<StreamMode> modes;
  final List<VideoCodec> videoCodecs;
  final double maxFps;
  final bool hasPreview;
  final List<CameraResolution> supportedResolutions;
  final List<String> cameras;

  Map<String, Object?> toJson() => {
        'platform': platform,
        'modes': modes.map((m) => m.wireName).toList(),
        'videoCodecs': videoCodecs.map((c) => c.wireName).toList(),
        'maxFps': maxFps,
        'hasPreview': hasPreview,
        'supportedResolutions': supportedResolutions
            .map((r) => {'width': r.width, 'height': r.height})
            .toList(),
        'cameras': cameras,
      };
}

/// Every outbound message, as a domain object.
sealed class ClientSignal {
  const ClientSignal();
}

/// `register` — announce identity and capabilities.
class RegisterSignal extends ClientSignal {
  const RegisterSignal({required this.deviceId, required this.capabilities});

  final String deviceId;
  final ClientCapabilities capabilities;
}

/// `heartbeat` — liveness. The type name is `heartbeat`, never `ping`.
class HeartbeatSignal extends ClientSignal {
  const HeartbeatSignal({required this.deviceId});

  final String deviceId;
}

/// `state_sync` — full state re-announcement after a reconnect.
///
/// Sent right after `register` so a reconnected backend learns everything that
/// changed while it was away.
class StateSyncSignal extends ClientSignal {
  const StateSyncSignal({
    required this.width,
    required this.height,
    required this.quality,
    required this.fps,
    required this.cameraIndex,
    required this.streaming,
    required this.mode,
    required this.codec,
    required this.chunkSeconds,
    required this.previewEnabled,
  });

  final int width;
  final int height;
  final int quality;
  final double fps;
  final int cameraIndex;
  final bool streaming;
  final StreamMode mode;
  final VideoCodec codec;
  final int chunkSeconds;
  final bool previewEnabled;
}

/// `frame_meta` — the text frame that precedes a JPEG binary frame.
class FrameMetaSignal extends ClientSignal {
  const FrameMetaSignal({required this.meta});

  final FrameMeta meta;
}

/// `video_meta` — the text frame that precedes an mp4 chunk binary frame.
class VideoMetaSignal extends ClientSignal {
  const VideoMetaSignal({required this.meta});

  final VideoMeta meta;
}

/// `capability_mismatch` — the backend asked for something we cannot do.
///
/// Silent degradation is forbidden: we report what actually ran and why.
class CapabilityMismatchSignal extends ClientSignal {
  const CapabilityMismatchSignal({
    required this.requested,
    required this.applied,
    required this.reason,
  });

  final String requested;
  final String applied;
  final String reason;
}
