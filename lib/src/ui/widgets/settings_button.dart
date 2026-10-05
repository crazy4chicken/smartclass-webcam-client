import 'package:flutter/material.dart';

/// Settings entry point, pinned to the bottom-left of the kiosk screen.
///
/// Bottom-left rather than top-right: on Android the system status bar owns the
/// top-right corner and swallowed this control's tap target, which is the same
/// reason the preview switch lives at the bottom.
///
/// Deliberately **not** locked. The whole point is that an installer standing
/// in front of the device can fix a wrong address without a build toolchain;
/// a lock would just move the problem back to the developer.
class SettingsButton extends StatelessWidget {
  const SettingsButton({
    super.key,
    required this.onPressed,
    this.showAlert = false,
  });

  /// Key for tests and for the accessibility tree.
  static const Key buttonKey = Key('settings-button');

  /// Key for the "no credentials" dot.
  static const Key alertDotKey = Key('settings-alert-dot');

  final VoidCallback onPressed;

  /// Draws a red dot when the device has no usable credentials — an
  /// unprovisioned device can never connect, and that has to be visible
  /// without opening anything.
  final bool showAlert;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '设置',
      child: Material(
        color: Colors.black.withValues(alpha: 0.62),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: buttonKey,
          onTap: onPressed,
          // Generous target: this is a kiosk, people tap it standing up.
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.settings, color: Colors.white, size: 22),
                if (showAlert)
                  Positioned(
                    right: -3,
                    top: -3,
                    // A plain container rather than `Badge`: a `Badge` brings
                    // its own widget type and text into the tree, which makes
                    // "how many of these are on screen?" assertions brittle.
                    child: Container(
                      key: alertDotKey,
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFFE53935),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
