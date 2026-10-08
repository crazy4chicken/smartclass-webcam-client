import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../agent/agent_coordinator.dart';
import '../../agent/agent_status.dart';
import '../../app/capability_bootstrap.dart';
import '../../capture/camera_backend.dart';
import '../../capture/camera_service.dart';
import '../../config/connection_settings.dart';
import '../../config/settings_store.dart';
import '../widgets/camera_error_view.dart';
import '../widgets/preview_toggle_button.dart';
import '../widgets/settings_button.dart';
import '../widgets/status_bar_overlay.dart';
import 'settings_screen.dart';

/// The kiosk screen: preview filling the screen, status strip on top, preview
/// switch at the bottom.
///
/// Recognition results are deliberately **not** shown here. The smartclass
/// device protocol has no server-to-device result message (`face`/`recogni` do
/// not exist anywhere in the backend), so there is nothing to render; the
/// separate recognition service reads recordings through the management plane
/// instead.
///
/// When no camera is usable the whole screen becomes [CameraErrorView] — never
/// a white screen and never a crash.
class AgentScreen extends StatelessWidget {
  const AgentScreen({
    super.key,
    required this.coordinator,
    this.settingsStore,
    this.onConnectionChanged,
    this.onRefreshCapabilities,
  });

  final AgentCoordinator coordinator;

  /// Supplied together with [onConnectionChanged] by bootstrap. Both are
  /// optional so a test can build the screen without a store — when either is
  /// missing the settings entry point is simply not rendered.
  final SettingsStore? settingsStore;

  final Future<void> Function(ConnectionSettings next)? onConnectionChanged;

  /// Runs a forced camera re-probe. Null hides the button on the settings
  /// screen, which is what a screen built without a store wants.
  final Future<CameraInventory> Function()? onRefreshCapabilities;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AgentStatus>(
      stream: coordinator.onStatus,
      initialData: coordinator.status,
      builder: (context, statusSnapshot) {
        final status = statusSnapshot.data ?? coordinator.status;
        final service = coordinator.cameraService;

        final Widget body = (service == null || !service.isInitialized)
            ? CameraErrorView(
                failure: coordinator.failure ?? const CameraFailure.noDevice(),
                onRetry: coordinator.retryCamera,
              )
            : Stack(
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
                ],
              );

        return Stack(
          fit: StackFit.expand,
          children: [
            body,
            // Overlaid rather than placed inside either branch: an unconfigured
            // device has to be fixable from the camera-error screen too, and
            // that screen is exactly what a fresh install shows.
            if (settingsStore != null && onConnectionChanged != null)
              Align(
                alignment: Alignment.bottomLeft,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.all(16),
                  child: SettingsButton(
                    showAlert: !coordinator.connection.isProvisioned,
                    onPressed: () => _openSettings(context, status),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _openSettings(BuildContext context, AgentStatus status) async {
    final store = settingsStore;
    final onChanged = onConnectionChanged;
    if (store == null || onChanged == null) return;

    // A form should start from what is on disk; the coordinator's copy covers
    // the mock-backend path, which never persists anything.
    final live = coordinator.connection;
    final storedBaseUrl = await store.loadBaseUrl();
    final storedCredentials = await store.loadCredentials();
    if (!context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          initial: ConnectionSettings(
            baseUrl: storedBaseUrl ?? live.baseUrl,
            credentials: storedCredentials ?? live.credentials,
          ),
          isRecording: status.isRecording,
          linkState: status.linkState,
          onSaved: onChanged,
          onRefreshCapabilities: onRefreshCapabilities,
        ),
      ),
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
