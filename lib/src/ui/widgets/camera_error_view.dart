import 'package:flutter/material.dart';

import '../../capture/camera_backend.dart';

/// Full-screen guidance shown when no camera is usable.
///
/// The text comes from [failureMessage], so every failure class gets its own
/// instructions instead of a blank screen or a generic error.
class CameraErrorView extends StatelessWidget {
  const CameraErrorView({
    super.key,
    required this.failure,
    required this.onRetry,
  });

  final CameraFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF121212),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.no_photography_outlined,
            size: 64,
            color: Colors.white54,
          ),
          const SizedBox(height: 20),
          const Text(
            '摄像头不可用',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            failureMessage(failure),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
