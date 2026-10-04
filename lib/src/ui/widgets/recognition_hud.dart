import 'dart:async';

import 'package:flutter/material.dart';

import '../../backend/server_command.dart';

/// Auto-dismissing bubble that shows the backend's recognition result.
///
/// A second result arriving while the first is still on screen **resets** the
/// timer rather than letting the older timer cut the new result short — the
/// backend can push several results inside one second.
class RecognitionHud extends StatefulWidget {
  const RecognitionHud({
    super.key,
    required this.result,
    this.visibleFor = const Duration(seconds: 3),
  });

  final FaceResult result;

  /// How long the bubble stays up before unmounting itself.
  final Duration visibleFor;

  @override
  State<RecognitionHud> createState() => _RecognitionHudState();
}

class _RecognitionHudState extends State<RecognitionHud> {
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _scheduleDismiss();
  }

  @override
  void didUpdateWidget(covariant RecognitionHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      // Restart from a clean slate: the new result gets the full window.
      setState(() => _visible = true);
      _scheduleDismiss();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleDismiss() {
    _timer?.cancel();
    _timer = Timer(widget.visibleFor, () {
      if (!mounted) return;
      setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Returning an empty box (rather than animating opacity to zero) is what
    // actually removes the text from the tree.
    if (!_visible) return const SizedBox.shrink();

    final approved = widget.result.status == 'approved';
    final accent = approved ? const Color(0xFF2E7D32) : const Color(0xFFC62828);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.result.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _statusLabel(widget.result.status),
            style: TextStyle(
              color: accent == const Color(0xFF2E7D32)
                  ? const Color(0xFF81C784)
                  : const Color(0xFFEF9A9A),
              fontSize: 17,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'approved':
        return '识别成功';
      case 'rejected':
      case 'denied':
        return '识别失败';
      default:
        return '未识别';
    }
  }
}
