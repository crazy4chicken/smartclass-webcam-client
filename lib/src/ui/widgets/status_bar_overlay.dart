import 'package:flutter/material.dart';

import '../../agent/agent_status.dart';
import '../../backend/backend_gateway.dart';

/// `已连接` / `重连中` / `未连接` / `链路失败`.
///
/// The wording matters: an operator has to be able to tell "retrying, wait"
/// apart from "broken, intervene", and a rejected credential can never fix
/// itself.
///
/// Top-level rather than private so the settings screen shows the same words —
/// an operator comparing the two screens must not have to work out whether
/// "链路失败" and "连接失败" mean the same thing.
String linkStateLabel(LinkState state) => switch (state) {
  LinkState.live => '已连接',
  LinkState.registering => '注册中',
  LinkState.attaching => '连接中',
  LinkState.backoff => '重连中',
  LinkState.failed => '链路失败',
  LinkState.idle => '未连接',
};

/// Translucent status strip pinned to the top of the kiosk screen.
///
/// Informational only — the preview switch lives at the bottom of the screen
/// (see `PreviewToggleButton`), because on Android the system status bar owns
/// the top-right corner and swallowed the tap target.
///
/// What it shows is the **link**, not the camera: the device is a subordinate
/// of the server, so an operator's first question is always "is it connected,
/// and is it pushing?" rather than "what resolution is it capturing".
///
/// The background deliberately extends under the system status bar while the
/// content is pushed below it, so the strip reads as one continuous surface
/// instead of leaving a bare gap at the very top.
class StatusBarOverlay extends StatelessWidget {
  const StatusBarOverlay({super.key, required this.status});

  final AgentStatus status;

  /// Key for tests.
  static const Key streamLineKey = Key('status-stream-line');

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              _linkDot(),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      status.cameraName.isEmpty ? '摄像头未就绪' : status.cameraName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _detailLine(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    if (status.activeStreamId != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        'stream ${status.activeStreamId}',
                        key: streamLineKey,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    if (status.isFailed && status.lastError != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        status.lastError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFF8A80),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _captureChip(),
            ],
          ),
        ),
      ),
    );
  }

  String get _linkLabel => linkStateLabel(status.linkState);

  String get _captureLabel => switch (status.captureState) {
    CaptureState.recording => '采集中',
    CaptureState.capturingPhoto => '拍照中',
    CaptureState.idle => '空闲',
  };

  /// The capture state is **not** repeated here: the chip on the right already
  /// says it, and duplicating it made the strip say `空闲` twice.
  String _detailLine() {
    final parts = <String>[_linkLabel, '${status.fps} fps'];
    if (status.framesSent > 0) parts.add('已推 ${status.framesSent} 帧');
    return parts.join(' · ');
  }

  Widget _linkDot() {
    final Color color = switch (status.linkState) {
      LinkState.live => const Color(0xFF4CAF50),
      LinkState.backoff ||
      LinkState.registering ||
      LinkState.attaching => const Color(0xFFFFB300),
      LinkState.failed => const Color(0xFFE53935),
      LinkState.idle => const Color(0xFF9E9E9E),
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  /// Says what is actually happening: preview off does not stop capture, and
  /// the device is idle until the server asks for something.
  Widget _captureChip() {
    final bool busy = status.captureState.isBusy;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: busy
            ? const Color(0xFFC62828).withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            busy ? Icons.fiber_manual_record : Icons.pause_circle_outline,
            size: 10,
            color: Colors.white,
          ),
          const SizedBox(width: 6),
          Text(
            _captureLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
