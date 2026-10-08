import 'package:flutter/material.dart';

import '../../capture/camera_capabilities.dart';
import '../../capture/camera_resolution.dart';
import '../../capture/capability_report.dart';

/// What this device will tell the server its cameras can do.
///
/// This is a **read-only** page, and that is the point rather than an omission.
/// The lists here are the device's registration: the server is told them once
/// per connection and validates `switch_camera` against them, so the only place
/// a mode can legitimately change is a `switch_camera` from the server. A
/// control on this page would make the device and the server disagree about
/// what the camera is doing, and nothing in the protocol would notice.
///
/// What it is for is the two questions an installer actually has: *what did the
/// device find*, and *why was my resolution refused*. Both are answered by
/// seeing the same list the server was given.
class CapabilitiesScreen extends StatelessWidget {
  const CapabilitiesScreen({super.key, required this.cameras});

  /// One entry per announced camera, in canonical order.
  final List<CameraCapabilityReport> cameras;

  static const Key listKey = Key('capabilities-list');
  static const Key emptyKey = Key('capabilities-empty');
  static const Key noteKey = Key('capabilities-note');

  /// Key for one camera's card.
  static Key cameraKey(int cameraEnum) =>
      Key('capabilities-camera-$cameraEnum');

  /// Key for the "current mode" line of one camera.
  static Key currentKey(int cameraEnum) =>
      Key('capabilities-current-$cameraEnum');

  /// Key for the resolution list of one camera.
  static Key resolutionsKey(int cameraEnum) =>
      Key('capabilities-resolutions-$cameraEnum');

  /// Key for the frame-rate list of one camera.
  static Key frameratesKey(int cameraEnum) =>
      Key('capabilities-framerates-$cameraEnum');

  /// Key for one resolution entry, so a test can assert which one is marked as
  /// current without counting positions.
  static Key resolutionKey(int cameraEnum, CameraResolution resolution) =>
      Key('capabilities-resolution-$cameraEnum-${resolution.label}');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('摄像头能力')),
      body: SafeArea(
        child: cameras.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '尚未检测到摄像头。\n回到设置页点「重新检测」再试。',
                    key: emptyKey,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              )
            : ListView(
                key: listKey,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  for (final camera in cameras) _cameraCard(camera),
                  const SizedBox(height: 8),
                  _note(),
                ],
              ),
      ),
    );
  }

  Widget _cameraCard(CameraCapabilityReport camera) {
    return Container(
      key: cameraKey(camera.cameraEnum),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: camera.isActive
              ? const Color(0xFF81C784)
              : Colors.white.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  camera.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (camera.isActive) _tag('使用中', const Color(0xFF81C784)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'camera_enum ${camera.cameraEnum} · ${camera.lensDirection}',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),

          const SizedBox(height: 12),
          Text(
            _currentLine(camera),
            key: currentKey(camera.cameraEnum),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),

          const SizedBox(height: 14),
          _label('声明给服务端的分辨率'),
          const SizedBox(height: 6),
          Wrap(
            key: resolutionsKey(camera.cameraEnum),
            spacing: 6,
            runSpacing: 6,
            children: camera.isEmpty
                ? <Widget>[_muted('未测到')]
                : <Widget>[
                    for (final resolution in camera.resolutions)
                      _chip(
                        resolution.label,
                        highlight: camera.current?.resolution == resolution,
                        key: resolutionKey(camera.cameraEnum, resolution),
                      ),
                  ],
          ),

          const SizedBox(height: 14),
          _label('声明给服务端的帧率'),
          const SizedBox(height: 6),
          Wrap(
            key: frameratesKey(camera.cameraEnum),
            spacing: 6,
            runSpacing: 6,
            children: camera.isEmpty
                ? <Widget>[_muted('未测到')]
                : <Widget>[
                    for (final fps in camera.framerates)
                      _chip('$fps', highlight: camera.current?.fps == fps),
                  ],
          ),
        ],
      ),
    );
  }

  /// Says the current mode, or admits it does not know one.
  ///
  /// `isEmpty` gets its own wording: a camera with no measured capabilities is
  /// still registered, declaring only the mode it is in, and conflating that
  /// with "no camera" would send an installer looking for a hardware fault.
  String _currentLine(CameraCapabilityReport camera) {
    final current = camera.current;
    if (current == null) return '当前模式：未知';
    return '当前模式：${current.resolution.label} · ${current.fps} fps';
  }

  Widget _note() => Container(
    key: noteKey,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Text(
      '这些列表就是注册时发给服务端的内容，服务端也用它校验 switch_camera。\n'
      '本页只读：分辨率与帧率由服务端通过 switch_camera 下发，'
      '设备端改动会让服务端的 metadata 快照与实际情况不符。\n'
      '改分辨率或帧率后设备会重新注册；改动会中断当前录制。',
      style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
    ),
  );

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: Colors.white70,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    ),
  );

  Widget _tag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 11)),
  );

  /// A resolution or frame rate. The one in effect is outlined, because the
  /// declared list is a menu and the operator needs to see where the device is
  /// on it — that is what the server snapshots into `metadata`.
  Widget _chip(String text, {required bool highlight, Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: highlight
          ? const Color(0xFF81C784).withValues(alpha: 0.18)
          : Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: highlight
            ? const Color(0xFF81C784)
            : Colors.white.withValues(alpha: 0.14),
      ),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: highlight ? const Color(0xFF81C784) : Colors.white70,
      ),
    ),
  );

  Widget _muted(String text) =>
      Text(text, style: const TextStyle(color: Colors.white38, fontSize: 12));
}
