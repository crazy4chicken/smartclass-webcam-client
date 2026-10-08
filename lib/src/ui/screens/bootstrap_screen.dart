import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/capability_bootstrap.dart';

/// What a kiosk shows while it works out what its cameras can do.
///
/// The probe is not instant — it opens every camera once to rank them and then
/// walks six presets on each — so a device that boots to a black screen for ten
/// seconds looks broken. This says what is happening instead.
///
/// [onDone] is called **exactly once**, whatever happens, including when the
/// probe finds nothing at all. A start-up screen that can strand the kiosk on a
/// spinner is worse than any message it could show.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key, required this.run, required this.onDone});

  /// Runs the probe. Called once, from `initState`.
  final Future<CameraInventory> Function() run;

  /// Called once, when [run] settles. Never with a thrown error.
  final ValueChanged<CameraInventory> onDone;

  static const Key progressKey = Key('bootstrap-progress');
  static const Key statusKey = Key('bootstrap-status');

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  String _status = '正在检测摄像头能力…';
  bool _running = true;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    CameraInventory inventory;
    String status;
    try {
      inventory = await widget.run();
      status = inventory.isEmpty
          ? '未检测到摄像头，仍以当前配置启动。'
          : '检测到 ${inventory.descriptors.length} 个摄像头，正在启动…';
    } catch (error) {
      // The probe is not supposed to throw, but a kiosk must not be able to get
      // stuck here because something it does not control misbehaved.
      inventory = CameraInventory.empty;
      status = '摄像头检测失败（$error），仍以当前配置启动。';
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _status = status;
    });
    widget.onDone(inventory);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_running)
              const SizedBox(
                key: BootstrapScreen.progressKey,
                width: 42,
                height: 42,
                child: CircularProgressIndicator(strokeWidth: 3),
              )
            else
              const Icon(
                Icons.videocam_outlined,
                key: BootstrapScreen.progressKey,
                size: 42,
                color: Colors.white54,
              ),
            const SizedBox(height: 20),
            Text(
              _status,
              key: BootstrapScreen.statusKey,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
