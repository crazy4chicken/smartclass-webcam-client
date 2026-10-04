import 'package:flutter/material.dart';

import '../../agent/agent_status.dart';

/// Translucent bar pinned to the top of the kiosk screen.
///
/// Carries the live state and the preview switch. Turning the preview off does
/// not stop capture, so a "采集进行中" chip stays visible to make that obvious
/// to anyone standing in front of the camera.
class StatusBarOverlay extends StatelessWidget {
  const StatusBarOverlay({
    super.key,
    required this.status,
    required this.onPreviewToggle,
  });

  final AgentStatus status;

  /// Called with the *new* desired preview state.
  final ValueChanged<bool> onPreviewToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
      ),
      child: Row(
        children: [
          _connectionDot(),
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
                  '${status.resolutionLabel} · ${status.streamModeLabel} · '
                  '${status.fps.toStringAsFixed(1)} fps',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          if (status.streaming) _captureChip(),
          const SizedBox(width: 6),
          IconButton(
            key: const Key('preview-toggle'),
            tooltip: status.previewEnabled ? '关闭预览' : '开启预览',
            onPressed: () => onPreviewToggle(!status.previewEnabled),
            icon: Icon(
              status.previewEnabled
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectionDot() {
    final Color color;
    if (status.isConnected) {
      color = const Color(0xFF4CAF50);
    } else if (status.isReconnecting) {
      color = const Color(0xFFFFB300);
    } else {
      color = const Color(0xFF9E9E9E);
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _captureChip() {
    final label = status.previewEnabled ? '预览中' : '采集进行中';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFC62828).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record, size: 10, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
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
