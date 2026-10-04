import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../agent/agent_coordinator.dart';
import '../../agent/agent_status.dart';
import '../../backend/server_command.dart';
import '../../capture/camera_backend.dart';
import '../../capture/camera_service.dart';
import '../widgets/camera_error_view.dart';
import '../widgets/preview_toggle_button.dart';
import '../widgets/recognition_hud.dart';
import '../widgets/status_bar_overlay.dart';

/// The kiosk screen: preview filling the screen, status strip on top, preview
/// switch at the bottom, recognition bubble near the middle.
///
/// When no camera is usable the whole screen becomes [CameraErrorView] — never
/// a white screen and never a crash.
class AgentScreen extends StatelessWidget {
  const AgentScreen({super.key, required this.coordinator});

  final AgentCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AgentStatus>(
      stream: coordinator.onStatus,
      initialData: coordinator.status,
      builder: (context, statusSnapshot) {
        final status = statusSnapshot.data ?? coordinator.status;
        final service = coordinator.cameraService;

        if (service == null || !service.isInitialized) {
          return CameraErrorView(
            failure: coordinator.failure ?? const CameraFailure.noDevice(),
            onRetry: coordinator.retryCamera,
          );
        }

        return StreamBuilder<FaceResult>(
          stream: coordinator.onFaceResult,
          builder: (context, faceSnapshot) {
            final faceResult = faceSnapshot.data;
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: Colors.black,
                  child: _PreviewArea(
                    service: service,
                    previewEnabled: status.previewEnabled,
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: StatusBarOverlay(status: status),
                ),
                // Bottom, not top: the Android system status bar sits in the
                // top-right corner and swallowed this control's tap target.
                Align(
                  alignment: Alignment.bottomRight,
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.all(16),
                    child: PreviewToggleButton(
                      previewEnabled: status.previewEnabled,
                      onToggle: coordinator.setPreviewEnabled,
                    ),
                  ),
                ),
                if (faceResult != null)
                  Align(
                    alignment: const Alignment(0, 0.55),
                    child: RecognitionHud(result: faceResult),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PreviewArea extends StatelessWidget {
  const _PreviewArea({required this.service, required this.previewEnabled});

  final CameraService service;
  final bool previewEnabled;

  @override
  Widget build(BuildContext context) {
    // Preview off is not capture off — say so instead of showing black.
    if (!previewEnabled) {
      return const _PreviewPlaceholder(
        icon: Icons.visibility_off_outlined,
        text: '预览已关闭（采集继续）',
      );
    }

    final source = service;
    // Pattern-based narrowing keeps this independent of local promotion rules.
    if (source case final CameraPreviewProvider provider) {
      final controller = provider.previewController;
      if (controller is CameraController && controller.value.isInitialized) {
        // Center is load-bearing: it hands the child LOOSE constraints.
        // CameraPreview wraps itself in an AspectRatio, and tight constraints
        // (which `Stack(fit: StackFit.expand)` would otherwise impose) override
        // that ratio and stretch the texture to the screen — which is exactly
        // the "people look squashed" bug.
        return Center(child: CameraPreview(controller));
      }
    }

    return const _PreviewPlaceholder(
      icon: Icons.videocam_off_outlined,
      text: '预览不可用',
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.white38),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}
