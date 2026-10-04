# webcam_client

前台 kiosk 式跨平台摄像头边缘探针客户端。启动即用本地默认参数采集，通过 WebSocket 把画面
推给后端 AI 模型，并接受后端下发的采集模式 / 编码 / 启停 / 切摄 / 预览指令。

实现依据：`docs/superpowers/plans/2026-10-04-camera-edge-probe.md`（T0–T9）。

## 平台

Windows / macOS / Linux / iOS / Android 单代码库覆盖。桌面三端由 `camera` + `camera_desktop`
提供（Media Foundation / AVFoundation / GStreamer+V4L2），移动端走 `camera_android_camerax`
与 `camera_avfoundation`。**不使用 `camera_windows`**。

## 运行

```bash
flutter pub get
flutter run -d windows            # 或 macos / linux / android / ios

# 脱机自测（不连真后端，用内置假后端）
flutter run -d windows --dart-define=USE_MOCK_BACKEND=true

# 指定后端地址
flutter run -d windows --dart-define=WS_URL=ws://192.168.1.10:8080/ws
```

测试：

```bash
flutter test
dart run tool/verify_pure.dart    # 纯 Dart 层的快速自检（不需要 Flutter 引擎）
```

## 架构

三层隔离，后端协议未定稿，所有交互收敛在一个可整体替换的网关之后。

```
UI (agent_screen / status_bar_overlay / recognition_hud / camera_error_view)
        │  AgentStatus / FaceResult
AgentCoordinator ── 单并发排他锁采集循环、命令路由、断线重同步、本地自治
        │
        ├── BackendGateway ── CommandCodec ── JSON ⇄ 领域模型
        │      WebSocketBackendGateway / MockBackendGateway
        └── CameraProvider ── CameraBackend ── CameraService ── FrameSource / VideoChunkRecorder
               CameraPluginBackend (camera + camera_desktop, 5 平台)
```

关键约束（改动前请先读 `docs/superpowers/plans/` 里的方案）：

- **分辨率一律绝对像素**，`ResolutionPreset` 只是相对档位；实际生效值从 controller 读回并回传。
- **二进制帧前必须先发 meta 文本帧**（`frame_meta` / `video_meta`）。
- **采集严禁排队**：单并发锁，前次未结束即丢帧，锁在 `finally` 释放。
- **心跳类型名是 `heartbeat`**。
- **未识别 / 畸变 JSON 静默降级 + 本地留痕**（`UnrecognizedCommandLog`），不抛、不断连、不回传。
- **v1 只编码 AVC**（三个插件实现都硬编码 H.264）；请求 HEVC 会回传 `capability_mismatch`。
- **关预览 ≠ 停采集**；关预览时状态条仍显示"采集进行中"。
- `lib/src/backend` 与 `lib/src/capture` 的非插件部分**不依赖 Flutter**，因此可在纯 Dart VM 上
  直接跑 `tool/verify_pure.dart`。新增代码请保持这个边界。

## 本机环境注意事项

这台机器上 Flutter CLI 目前**不可用**，原因与项目无关，是环境缺陷：

1. **Dart VM 无法创建子进程**。`Process.run / runSync / start` 全部抛
   `ProcessException: All pipe instances are busy`（`process_win.cc:744` / Win32 231）。
   `flutter`、`flutter test`、`dart analyze` 都需要 spawn 子进程，因此全部失败。
   Python 的 `subprocess` 正常，`.NET` 命名管道也正常 —— 只有 Dart 的进程创建受影响。
2. `C:\Program Files\Flutter\flutter\bin\cache` 当前用户**不可写**（owner 是 Administrators，
   且未提权），flutter_tools 会报 `Flutter failed to open a file at ...\lockfile`。
   本次工作用的是复制到 `C:\Users\Lhui\flutter-sdk` 的可写副本。
3. flutter_tools 启动时会 `whichAll('aapt')`，该 spawn 会崩。绕法：把 `ANDROID_HOME` 指向一个
   含 `licenses/` 子目录的假 SDK（仓库内 `.tooling/android-sdk/licenses`，已 gitignore）。

在这台机器上可用的替代验证手段：`dart run tool/verify_pure.dart`（进程内运行）、
`dart format --output=none`（语法）、以及用 Python 直接驱动 analysis server 的 LSP
（`--protocol=lsp` + `didOpen` + `publishDiagnostics`）。

修好 Dart 的进程创建（或换一台机器）后，`flutter test` 即可正常运行。
