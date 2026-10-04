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
- **不引入 `permission_handler`**（原因见下）。

界面上的两条硬约束（都是 Android 真机上踩出来的）：

- **预览开关在底部**（`PreviewToggleButton`），顶部状态条只放信息。Android 的系统状态栏占着
  右上角，放上面会被盖住、点不到。
- **预览必须保持原始宽高比**：`CameraPreview` 内部用 `AspectRatio`，而
  `Stack(fit: StackFit.expand)` 会传**紧约束**，`RenderAspectRatio` 遇到紧约束会直接返回
  `constraints.smallest` —— 宽高比被无视，画面被拉伸变形。所以 `_PreviewArea` 外面套了一层
  `Center`（`Center` 会把约束放松），画面按 contain 居中、留黑边。
  手机竖屏下源是 9:16、屏约 9:20，用 contain 只留很窄的上下黑边；如果改成 cover，
  要横向裁掉约 75% 的画面，人脸会直接被裁没，所以这里必须用 contain。


## 构建环境

Windows 端需要 Visual Studio（Desktop development with C++ 工作负载）。
已在 VS 18 / MSVC 14.51 / Windows SDK 10.0.26100 上验证构建通过。

### 为什么没有 permission_handler

`permission_handler_windows` 0.2.2 强制 `/await` 并拉取 C++/WinRT 2.0.210806.1，其头文件包含
`<experimental/coroutine>`。MSVC 14.51 已把它变成硬错误：

```
error C2338: static assertion failed: 'error STL1011: The /await compiler option,
<experimental/coroutine>, <experimental/generator>, and <experimental/resumable>
are deprecated by Microsoft and will be REMOVED SOON.'
```

理论上可用 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` 压掉，但微软明确说这套 API
会被移除，而该依赖本身是**冗余**的：

- `camera_android_camerax` 自带 `CameraPermissionsManager`（`ActivityCompat.requestPermissions`），
  且在自己的 manifest 里声明了 `android.permission.CAMERA`；
- `camera_avfoundation` 自带 `CameraPermissionManager`（`AVCaptureDevice.requestAccess`）。

两者都在 `initialize()` 时申请权限，插件抛出的 `CameraException` 由
`cameraFailureFrom()` 映射成带类型的 `CameraFailure`。删掉后 Windows 端只剩 `camera_desktop`
一个原生插件（纯 Media Foundation C++，不碰 C++/WinRT）。

### 关于本机 Flutter CLI

`C:\Users\Lhui\AppData\Local\flutter` 可正常使用。另注：在**助手工具的 shell** 里 Dart VM 无法
创建子进程（`ProcessException: All pipe instances are busy`，`process_win.cc:744`），
所以 `flutter run/test/analyze` 在那个 shell 里会失败；用户自己的终端不受影响，与项目无关。
