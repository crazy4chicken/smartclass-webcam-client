# webcam_client

前台 kiosk 式跨平台摄像头边缘探针客户端，接入 **`smartclass-webcam-server`** 的设备协议。

设备是**从属角色**：它不主动推流。运营侧在管理面 `POST /api/devices/{id}/recording/start`
之后，服务端才下发 `start_recording`，客户端此时才开始推帧；`stop_recording` 一到立刻停。

实现依据：`docs/superpowers/plans/2026-10-04-smartclass-backend-integration.md`（T1–T8）。
**协议权威文档**是后端仓库的 `smartclass-webcam-server/docs/protocol/`
（index / registration / transport / control / media），本客户端逐条对齐。

## 平台

Windows / macOS / Linux / iOS / Android 单代码库覆盖。桌面三端由 `camera` + `camera_desktop`
提供（Media Foundation / AVFoundation / GStreamer+V4L2），移动端走 `camera_android_camerax`
与 `camera_avfoundation`。**不使用 `camera_windows`**。

## 运行

```bash
flutter pub get

# 脱机自测：内置假后端，不需要服务端也不需要凭据
flutter run -d windows --dart-define=USE_MOCK_BACKEND=true

# 接真后端（BASE_URL 是注册与 WebSocket 的共同基址）
flutter run -d windows \
  --dart-define=BASE_URL=http://192.168.1.10:8080 \
  --dart-define=DEVICE_ID=01J8ZK9WQ7X3YV0M4N5P6Q7R8S \
  --dart-define=DEVICE_TOKEN=wdt_...
```

`DEVICE_ID` / `DEVICE_TOKEN` 由管理面 `POST /api/devices` 下发，**不是客户端生成的**
（`device_id` 是 26 字符 ULID，token 是 `wdt_` + 43 个 base64url 字符）。
用 `--dart-define` 传只是为了开发方便 —— 那是明文编译进二进制的；首次启动后凭据会写进
`CredentialStore`（`shared_preferences`），后续启动不再需要这两个参数。

测试：

```bash
flutter test
dart run tool/verify_pure.dart    # 纯 Dart 层的完整自检（不需要 Flutter 引擎）
```

## 架构

```
UI (agent_screen / status_bar_overlay / preview_toggle_button / camera_error_view)
        │  AgentStatus
AgentCoordinator ── 命令驱动的状态机：每条命令都 ack，没收到 start_recording 就不推任何媒体
        │
        ├── BackendGateway ── SmartClassBackendGateway（注册 → 挂载 → 保活 → 退避重注册）
        │        protocol/envelope ── Message 信封 / WireCodec 闭集 / parseDeviceCommand
        │        protocol/binary_frame ── uint32 BE + JSON + 裸字节
        │        registration_client ── GET /ws/register（带 JSON body）
        │      MockBackendGateway（离线用，下发真实协议词汇）
        └── CameraProvider ── CameraBackend ── CameraService ── FramePump ── VideoEncoder
               CameraPluginBackend (camera + camera_desktop, 5 平台)
```

### 协议要点（改之前请先读后端 `docs/protocol/`）

- **注册是 `GET /ws/register` 带 JSON body**，`Authorization: Bearer wdt_…`，返回一次性 ticket
  （64 位小写 hex）、`expires_at`（RFC3339**Nano**，60s TTL）、`websocket_path`。
- **挂载是 `GET {base}/ws/device/{ticket}`**。ticket 一次性、随连接死亡，**没有 session resume**，
  所以每次重连都要重新注册。
- 信封 `{channel,type,id?,payload?}`，`channel ∈ control/recording/photo`。
  **二进制帧 = `uint32 BE N` + N 字节 UTF-8 JSON + 裸媒体字节**，`N ∈ 1..65536`，整帧 ≤ 16 MiB。
- server→device 只有 5 种：`switch_camera` / `start_recording` / `stop_recording` / `take_photo` / `ping`。
- device→server：`ack` / `pong` / `status` / `error`（文本）+ `frame` / `photo`（二进制）。
- **每条带 `id` 的命令都必须 ack**，失败回 `ok:false` + `error`。服务端不等待、不重试，
  ack 是运营侧唯一的确认手段 —— 所以**绝不静默丢弃**。
- **codec 是闭集且精确小写**：`h264` / `h265` / `mjpeg` / `mpeg4` / `vp8` / `vp9` / `av1`。
  **`hevc` 只是别称，服务端拒收**，线上必须写 `h265`。
- `camera_enum` 必须等于注册数组下标；`fps` 必须是 **>0 的整数**（`29.97` 直接 400）。
- **空闲时也要周期性发 `status`**，否则 60s 静默被服务端断开（默认 30s 一次）。
- **`stop_recording` 之后继续推的帧会被丢弃**，所以收到就立刻停泵。
- `1008` = ticket 已被别的连接挂载 → 重新注册；`1009` = 单帧超 16 MiB；`1006` 是**正常现象**
  （被新连接替换时服务端不握手直接关）。
- **服务端没有人脸识别结果回推**，AI 是另一个走管理面 REST 拉录制分片的服务，
  所以客户端不展示识别结果（`RecognitionHud` 已删除）。

### 编码选择

偏好链 `h265 → h264 → mjpeg`，由 `CodecProbe` 实测决定，选择逻辑在 `CodecSelector`。
**v1 实际落在 `mjpeg`**，这不是妥协：服务端对 `mjpeg` 的定义就是"每个 `recording.frame`
一张 JPEG"，而 `takePicture()` 产出的正好是 JPEG，天然满足"需要时序信息"。
`h265`/`h264` 需要编码器（计划中的 T9，走 `ffmpeg_kit_flutter_new`），尚未实现。

### 存储格式决定了不能用 mp4

服务端把每个 `recording.frame` 的裸负载按 `[uint32 BE len][frame]…` **拼接**成 `.bin` 片段，
**无容器、无头信息**，期望的是"一个编码访问单元 / 一帧"。所以原来的
`CameraPluginVideoChunkRecorder`（产出带 `moov` 的完整 mp4）**已删除** —— 发过去只会得到
无法解码的垃圾片段。持续推帧走 `FramePump`。

### 代码分层

- `lib/src/backend` 与 `lib/src/capture` 的非插件部分**不依赖 Flutter**，所以能在纯 Dart VM 上
  直接跑 `tool/verify_pure.dart`（273 项断言，覆盖协议、注册、两个网关、采集管线、协调器）。
  新增代码请保持这条边界：一旦引入 `package:flutter/*`，该模块就再也无法在本机验证。
- `unrecognized_command_log.dart` 的默认 sink 是 `print` 而不是 `debugPrint`
  （`main.dart` 显式传 `debugPrint`），就是为了上面那条边界。
- 摄像头四层抽象（`CameraProvider → CameraBackend → CameraService → FramePump`）不泄漏插件类型；
  预览走窄接口 `CameraPreviewProvider.previewController`（`Object?`），UI 层再窄化为 `CameraController`。
- **不引入 `permission_handler`**（原因见下）。

### 界面上的两条硬约束（Android 真机踩出来的）

- **预览开关在底部**（`PreviewToggleButton`），顶部状态条只放信息。Android 的系统状态栏占着
  右上角，放上面会被盖住、点不到。
- **预览必须保持原始宽高比**：`CameraPreview` 内部用 `AspectRatio`，而
  `Stack(fit: StackFit.expand)` 会传**紧约束**，`RenderAspectRatio` 遇到紧约束直接返回
  `constraints.smallest` —— 宽高比被无视，画面被拉伸变形。所以 `_PreviewArea` 外面套了一层
  `Center`（`Center` 会把约束放松），画面按 contain 居中、留黑边。
  手机竖屏下源是 9:16、屏约 9:20，用 contain 只留很窄的上下黑边；改成 cover 要横向裁掉
  约 75% 的画面，人脸会被裁没，所以这里必须用 contain。

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

### Android

`AndroidManifest.xml` 里必须有 `android:usesCleartextTraffic="true"`：targetSdk 36 时
Android 9+ 默认禁止明文流量，而网关是 `ws://`，不开的话连接会被系统直接拒掉。
将来上 TLS 时要和 `ws://` 默认值一起撤掉。真机步骤见 `docs/android-setup.md`。

### 关于本机 Flutter CLI

`C:\Users\Lhui\AppData\Local\flutter` 可正常使用。另注：在**助手工具的 shell** 里 Dart VM 无法
创建子进程（`ProcessException: All pipe instances are busy`，`process_win.cc:744`），
所以 `flutter run/test/analyze` 在那个 shell 里会失败；用户自己的终端不受影响，与项目无关。
助手侧改用两条替代路径验证：`dart run tool/verify_pure.dart`（进程内执行），
以及用 Python 直接驱动 `frontend_server_aot` 做单次编译（等价于 `flutter test` 的类型检查）。
