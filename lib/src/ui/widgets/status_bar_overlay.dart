import 'package:flutter/material.dart';

import '../../agent/agent_status.dart';

/// Translucent status strip pinned to the top of the kiosk screen.
///
/// Informational only — the preview switch lives at the bottom of the screen
/// (see `PreviewToggleButton`), because on Android the system status bar owns
/// the top-right corner and swallowed the tap target.
///
/// The background deliberately extends under the system status bar while the
/// content is pushed below it, so the strip reads as one continuous surface
/// instead of leaving a bare gap at the very top.
class StatusBarOverlay extends StatelessWidget {
  const StatusBarOverlay({super.key, required this.status});

  final AgentStatus status;

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
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (status.streaming) _captureChip(),
            ],
          ),
        ),
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

  /// Says what is actually happening: preview off does not stop capture, so
  /// this chip stays visible either way.
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
