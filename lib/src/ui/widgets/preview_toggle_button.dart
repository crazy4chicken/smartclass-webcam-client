import 'package:flutter/material.dart';

/// Preview on/off control, pinned to the bottom of the kiosk screen.
///
/// It lives at the bottom rather than in the top status strip because on
/// Android the system status bar occupies that corner and swallowed the tap
/// target.
class PreviewToggleButton extends StatelessWidget {
  const PreviewToggleButton({
    super.key,
    required this.previewEnabled,
    required this.onToggle,
  });

  /// Key for tests and for the accessibility tree.
  static const Key toggleKey = Key('preview-toggle');

  final bool previewEnabled;

  /// Called with the *desired* new state.
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: toggleKey,
      color: Colors.black.withValues(alpha: 0.62),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onToggle(!previewEnabled),
        // Generous target: this is a kiosk, people tap it standing up.
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                previewEnabled
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: Colors.white,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                previewEnabled ? '预览开' : '预览关',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
