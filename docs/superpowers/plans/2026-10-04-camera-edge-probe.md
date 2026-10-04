# 跨平台摄像头边缘探针客户端 Implementation Plan

> **⚠️ 已被取代（v1 方案）。** 本文假设的后端协议从未存在过，且**大部分已被推翻**：
> 信令集（`register` / `heartbeat` / `cmd_*` / `state_sync` / `frame_meta` / `video_meta`）、
> `CommandCodec`、`ClientSignal` / `ServerCommand`、`DeviceIdService`（UUIDv4）、
> `VideoChunkRecorder`（mp4 分片）、`RecognitionHud` 均已删除；
> `StreamMode` / `VideoCodec` 已换成 `CaptureCodec`；
> 配置项 **`WS_URL` 已不存在**，现为 `BASE_URL` / `DEVICE_ID` / `DEVICE_TOKEN`。
>
> 现行方案见 `docs/superpowers/plans/2026-10-04-smartclass-backend-integration.md`，
> 现行架构见 `README.md`。协议权威是后端仓库的 `smartclass-webcam-server/docs/protocol/`。
>
> 本文仍有效的是：摄像头四层抽象、绝对像素分辨率、采集严禁排队、
> kiosk 生命周期姿态、预览开关语义。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个在 Windows / macOS / Linux / iOS / Android 上统一运行的**前台 kiosk 式**摄像头探针客户端。启动即用本地默认参数采集，通过 WebSocket 上报自身能力并接受后端下发的采集模式（静态帧 / 视频）、编码格式、启停、切摄、预览开关指令，把画面持续推送给后端 AI 模型（后端**需要时序信息**：活体检测、动作、轨迹），并展示人脸识别结果。**后端协议尚未定稿**，所有后端交互必须收敛在一个可整体替换的网关抽象之后。

**Architecture:** 三层隔离。① 摄像头侧四层：`CameraProvider`（有序降级链）→ `CameraBackend`（能力探测 + 权限申请）→ `CameraService`（单实例生命周期）→ `FrameSource` / `VideoChunkRecorder`（帧与视频分片从哪来）。桌面三端由 `camera` + `camera_desktop` 提供统一实现。② `BackendGateway` + `CommandCodec` 把协议隔离在一层之后，协调器只见 `ServerCommand` 领域模型、永不见 JSON。③ `AgentCoordinator` 持有单并发排他锁的采集循环、命令路由、断线状态重同步与本地自治降级。表现层为全屏预览（可开关）+ 顶部状态条 + 自动淡出的识别 HUD。

**Tech Stack:** Flutter ≥ 3.44 / Dart ≥ 3.12；`camera` ^0.12.1 + `camera_desktop` ^2.0.0（**不加 `camera_windows`**）；`permission_handler`；`wakelock_plus`；`web_socket_channel`；`shared_preferences`；`uuid`；`flutter_test` + `mocktail`。

**Spec:** 原 6 信令（register / heartbeat / cmd_update_config / cmd_control_stream / cmd_switch_camera / event_face_result），叠加本轮问答锁定的决策与新增的 `cmd_set_stream_mode` / `cmd_set_preview` / `state_sync` / `frame_meta` / `video_meta`。

---

## Global Constraints

- **平台支持**：Windows、macOS、Linux、iOS、Android 单代码库全覆盖。
- **产品姿态**：前台 kiosk 应用。切后台或最小化 → 暂停采集 + 释放摄像头 + 断开连接；回前台 → 重建恢复。iOS 与 Android 均**系统级禁止**后台使用摄像头，不可绕过。
- **传输**：原生 WebSocket。文本帧 = JSON 信令，二进制帧 = 裸字节。**每一段二进制之前必须先发一条 meta 文本帧**（`frame_meta` 对应 JPEG 帧，`video_meta` 对应视频分片），否则后端无法关联身份与时序。
- **采集模式由后端决定**：`register` 上报 `ClientCapabilities`，后端下发 `cmd_set_stream_mode`。客户端不自行假设。
- **默认采集参数**：`mode = video`、`codec = avc`（H.264，**跨平台支持最广的一个，故为默认**）、`chunkSeconds = 3`、`previewEnabled = true`、1280×720、1.0 FPS（still 模式下）、JPEG 质量 80。
- **HEVC 现实约束**：`camera_desktop` / `camera_avfoundation` / `camera_android_camerax` **三个实现都硬编码 H.264，无 codec 参数**。要拿到 HEVC 必须绕过插件录制器、自接原生编码器（iOS VideoToolbox / Android MediaCodec / Windows MF / Linux x265）。**v1 不实现 HEVC 编码**，只做能力位与降级回传；接口留好，后续接入只需替换 `VideoChunkRecorder` 实现。
- **分辨率用绝对像素**：协议传 `width` / `height`，客户端选最接近的原生格式，并把**实际生效值**回传。
- **后端地址**：编译期注入 `--dart-define BASE_URL=`，默认 `http://127.0.0.1:8080`。
  （v1 原文是 `WS_URL` / `ws://…/ws`，**该变量已不存在**。）
- **deviceId**：首次启动生成 UUIDv4 并持久化。
- **不商用**：不实现鉴权与 TLS。网关必须保持可替换（接口不得泄漏 `web_socket_channel` 类型），以便后续插入 `wss://` 与 token。
- **运行时策略**：全程 Wakelock；采集严禁排队，前次未结束即丢帧；`takePicture()` 落盘的临时文件必须读完即删。
- **信令命名**：心跳类型名一律为 `heartbeat`，不是 `ping`。
- **未识别信令**：一律**本地记录**（有界环形缓冲 + 控制台输出），不回传后端、不影响连接、不打断后续帧解析。后端协议未定稿期间这是主要排障依据。
- **预览开关语义**：关预览 ≠ 停采集。关预览只是停止渲染与暂停预览纹理，采集循环照常运行。

## Platform Support Matrix

| 平台 | 摄像头实现 | 预览 | 拍照 | 视频录制 | 帧流 | 备注 |
|---|---|---|---|---|---|---|
| Android | `camera` + `camera_android_camerax`（endorsed） | ✅ | ✅ | ✅ AVC | ✅ YUV420/NV21 | |
| iOS | `camera` + `camera_avfoundation`（endorsed） | ✅ | ✅ | ✅ AVC | ✅ BGRA | |
| Windows | `camera` + `camera_desktop`（Media Foundation） | ✅ | ✅ | ✅ AVC | ✅ BGRA | 不加 `camera_windows` |
| macOS | `camera` + `camera_desktop`（AVFoundation） | ✅ | ✅ | ✅ AVC | ✅ BGRA | `camera` 的 plugin map 只有 android/ios/web，**macOS 无官方实现**，必须靠 `camera_desktop` |
| Linux | `camera` + `camera_desktop`（GStreamer + V4L2） | ✅ | ✅ | ✅ AVC | ✅ BGRA | 需 `libgstreamer1.0-dev` + `libgstreamer-plugins-base1.0-dev` + `gstreamer1.0-plugins-good` |

**已知风险**
- `camera_desktop` 锁 `camera_platform_interface ^2.7.0`，`camera` 0.12.1 要 `^2.13.1`，区间重叠但存在接口漂移可能 → T5 含实测门禁。
- open issue #8：Linux 上除 `low` 以外的分辨率报 "Failed to allocate required memory"，**正踩 1280×720 默认值** → T5 含实测门禁。
- `camera_desktop` 2.0.0 发布仅 8 天且含 breaking change（帧格式统一 BGRA）。
- 本机**尚未安装 Flutter**，T0 第一步。

## Review Focus

1. **后端下发未知 / 畸变 JSON**：codec 必须**本地记录原始报文**后返回 null —— 不抛异常、不断开连接、不打崩通道（后续合法帧仍能正常解析）。
2. **断连 / 抖动**：单并发锁必须在 `finally` 释放；指数退避重连；重连成功后补发 `register` + `state_sync` 恢复全部状态（含模式、编码、预览）。
3. **后端请求不可用的编码 / 分辨率**：不得静默降级 —— 必须回传实际生效值并本地留痕，UI 与状态同步可见。
4. **无摄像头 / 权限被拒 / 设备被占用**：显示带重试按钮的差异化引导界面，不白屏、不崩溃。
5. **后端 1 秒内连推多条 `event_face_result`**：HUD 计时器刷新重置，不闪烁、不被旧定时器提前销毁。

---

## File Structure

```
lib/main.dart                                     启动组装：异常隔离、Wakelock、生命周期、依赖注入
lib/src/config/app_config.dart                    编译期常量与采集默认值
lib/src/identity/device_id_service.dart           deviceId 生成与持久化
lib/src/capture/stream_settings.dart              StreamMode / VideoCodec / StreamSettings
lib/src/capture/camera_resolution.dart            CameraResolution 值对象
lib/src/capture/resolution_selector.dart          selectClosestResolution 纯函数
lib/src/capture/frame_store.dart                  落盘帧读取后立即删除
lib/src/capture/frame_source.dart                 FrameSource 接口 + TakePictureFrameSource
lib/src/capture/video_chunk.dart                  VideoChunk 值对象
lib/src/capture/video_chunk_recorder.dart         VideoChunkRecorder 接口 + CameraPluginVideoChunkRecorder
lib/src/capture/camera_service.dart               CameraService 接口（abstract interface class）
lib/src/capture/camera_backend.dart               CameraBackend 接口 + BackendProbe + CameraFailure
lib/src/capture/camera_plugin_backend.dart        camera + camera_desktop 实现（覆盖 5 平台）
lib/src/capture/camera_provider.dart              有序降级链
lib/src/backend/backend_gateway.dart              BackendGateway 接口 + ConnectionState + FrameMeta + VideoMeta
lib/src/backend/client_signal.dart                ClientSignal 密封类
lib/src/backend/server_command.dart               ServerCommand 密封类
lib/src/backend/command_codec.dart                CommandCodec 接口 + JsonCommandCodec
lib/src/backend/unrecognized_command_log.dart     未识别/畸变报文的本地留痕
lib/src/backend/websocket_backend_gateway.dart    WebSocket 实现（心跳、退避重连、文本/二进制分流）
lib/src/backend/mock_backend_gateway.dart         内置假后端，脱机自测与演示
lib/src/agent/agent_coordinator.dart              采集循环、命令路由、状态同步、自治降级
lib/src/agent/agent_status.dart                   AgentStatus 值对象
lib/src/app/lifecycle_controller.dart             生命周期 → 暂停/恢复 的纯映射与绑定
lib/src/ui/screens/agent_screen.dart              主屏（预览 + 状态条 + HUD + 错误态）
lib/src/ui/widgets/status_bar_overlay.dart        顶部半透明状态条（含预览开关）
lib/src/ui/widgets/recognition_hud.dart           自动淡出的识别结果气泡
lib/src/ui/widgets/camera_error_view.dart         无摄像头/权限被拒的引导界面
```

平台文件：`android/app/src/main/AndroidManifest.xml`、`ios/Runner/Info.plist`、`macos/Runner/Info.plist`、`macos/Runner/DebugProfile.entitlements`、`macos/Runner/Release.entitlements`。

---

### Task 0: 环境、脚手架、依赖基线与平台权限声明

**Files:**
- Create: `pubspec.yaml`
- Modify: `android/app/src/main/AndroidManifest.xml`、`ios/Runner/Info.plist`、`macos/Runner/Info.plist`、`macos/Runner/*.entitlements`

**Interfaces:**
- Produces: 包名 `webcam_client`，后续 import 为 `package:webcam_client/src/...`

- [ ] **Step 1: 安装并核对 Flutter 版本**

Run: `flutter --version`
Expected: Flutter ≥ 3.44，Dart ≥ 3.12。`camera` 0.12.1 要求 Flutter ≥ 3.44；`camera_desktop` 2.0.0 要求 Dart ≥ 3.11。版本不足先升级，否则后续全部依赖装不上。

- [ ] **Step 2: 生成脚手架**

Run: `flutter create --project-name webcam_client --platforms=windows,macos,linux,ios,android .`
Expected: 五个平台目录齐全。

- [ ] **Step 3: 添加依赖**

Run: `flutter pub add camera camera_desktop permission_handler wakelock_plus web_socket_channel shared_preferences uuid` 与 `flutter pub add dev:mocktail`

**不要**添加 `camera_windows`（与 `camera_desktop` 在 Windows 上重复实现 `camera`，且 `camera_desktop` 能力更全）。若 `flutter pub get` 报版本冲突，按提示对齐后再继续。

- [ ] **Step 4: 声明平台权限**

Android：`CAMERA`、`INTERNET`、`WAKE_LOCK`。iOS/macOS `Info.plist`：`NSCameraUsageDescription` + `NSMicrophoneUsageDescription`（录视频需要）。macOS entitlements：`com.apple.security.device.camera` + `com.apple.security.device.audio-input` + `com.apple.security.network.client`。Linux 目标机：`sudo apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good`。

- [ ] **Step 5: 冒烟基线**

Run: `flutter test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add . && git commit -m "chore: scaffold webcam_client with camera_desktop and platform permissions"
```

---

### Task 1: 配置、设备标识、采集设置模型与分辨率选择

**Files:**
- Create: `lib/src/config/app_config.dart`
- Create: `lib/src/identity/device_id_service.dart`
- Create: `lib/src/capture/stream_settings.dart`
- Create: `lib/src/capture/camera_resolution.dart`
- Create: `lib/src/capture/resolution_selector.dart`
- Test: `test/capture/resolution_selector_test.dart`
- Test: `test/identity/device_id_service_test.dart`
- Test: `test/capture/stream_settings_test.dart`

**Interfaces:**
- Produces:
  - `AppConfig.baseUrl: String`（`String.fromEnvironment('BASE_URL', defaultValue: 'http://127.0.0.1:8080')`；v1 原文为 `wsUrl` / `WS_URL`，已不存在）
  - `AppConfig.defaultWidth = 1280`、`defaultHeight = 720`、`defaultQuality = 80`、`defaultFps = 1.0`、`defaultChunkSeconds = 3`、`defaultPreviewEnabled = true`、`heartbeatSeconds = 15`、`registerTimeoutSeconds = 5`
  - `DeviceIdService.getOrCreateDeviceId() -> Future<String>`
  - `enum StreamMode { still, video }`、`enum VideoCodec { avc, hevc }`
  - `StreamSettings({StreamMode mode, VideoCodec codec, int chunkSeconds, bool previewEnabled})` + `StreamSettings.defaults()` → `video / avc / 3 / true`
  - `CameraResolution({int width, int height})`，含 `pixelCount` getter
  - `CaptureConfig({int width, int height, int quality})` + `CaptureConfig.defaults()`
  - `selectClosestResolution(List<CameraResolution> available, CameraResolution target) -> CameraResolution`

- [ ] **Step 1: Write failing tests**

```dart
// test/capture/resolution_selector_test.dart
const available = [
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1920, height: 1080),
];

void main() {
  test('returns exact match when the target format exists', () {
    expect(selectClosestResolution(available, const CameraResolution(width: 1280, height: 720)),
        const CameraResolution(width: 1280, height: 720));
  });

  test('never upscales past the target', () {
    expect(selectClosestResolution(available, const CameraResolution(width: 1000, height: 700)),
        const CameraResolution(width: 640, height: 480));
    expect(selectClosestResolution(available, const CameraResolution(width: 3840, height: 2160)),
        const CameraResolution(width: 1920, height: 1080));
  });

  test('falls back to smallest format when every format exceeds target', () {
    expect(selectClosestResolution(available, const CameraResolution(width: 320, height: 240)),
        const CameraResolution(width: 640, height: 480));
  });
}
```

```dart
// test/capture/stream_settings_test.dart
void main() {
  test('defaults to video with the most widely supported codec and preview on', () {
    final s = StreamSettings.defaults();
    expect(s.mode, StreamMode.video);
    expect(s.codec, VideoCodec.avc);
    expect(s.chunkSeconds, 3);
    expect(s.previewEnabled, isTrue);
  });

  test('copyWith changes only what is given', () {
    final s = StreamSettings.defaults().copyWith(codec: VideoCodec.hevc, previewEnabled: false);
    expect(s.mode, StreamMode.video);
    expect(s.codec, VideoCodec.hevc);
    expect(s.previewEnabled, isFalse);
    expect(s.chunkSeconds, 3);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/capture test/identity`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

`selectClosestResolution` 算法：先过滤掉宽或高大于目标的格式（绝不放大），在剩余项中取 `pixelCount` 最大者；若过滤后为空，则取全部中 `pixelCount` 最小者。

`DeviceIdService` 用 `shared_preferences` 存 key `device_id`，缺失时用 `uuid` 的 `v4()` 生成并写回。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/capture test/identity`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/config lib/src/identity lib/src/capture test/capture test/identity
git commit -m "feat: add app config, device id service, stream settings, and resolution selection"
```

---

### Task 2: 命令领域模型与 CommandCodec（后端协议隔离层）

**Files:**
- Create: `lib/src/backend/server_command.dart`
- Create: `lib/src/backend/client_signal.dart`
- Create: `lib/src/backend/command_codec.dart`
- Create: `lib/src/backend/unrecognized_command_log.dart`
- Test: `test/backend/command_codec_test.dart`
- Test: `test/backend/unrecognized_command_log_test.dart`

**Interfaces:**
- Consumes: `CameraResolution`、`CaptureConfig`、`StreamSettings`、`StreamMode`、`VideoCodec` from Task 1
- Produces:
  - `sealed class ServerCommand`，子类：`UpdateConfigCommand({int? width, int? height, int? quality, double? fps})`、`SetStreamModeCommand({StreamMode? mode, VideoCodec? codec, int? chunkSeconds})`、`ControlStreamCommand({required bool enabled})`、`SwitchCameraCommand({required int index})`、`SetPreviewCommand({required bool enabled})`、`FaceResultCommand({required FaceResult result})`
  - `FaceResult({required String name, required String status})`
  - `sealed class ClientSignal`，子类：`RegisterSignal`、`HeartbeatSignal`、`StateSyncSignal`、`FrameMetaSignal`、`VideoMetaSignal`、`CapabilityMismatchSignal`
  - `StateSyncSignal({width, height, quality, fps, cameraIndex, streaming, mode, codec, chunkSeconds, previewEnabled})`
  - `CapabilityMismatchSignal({required String requested, required String applied, required String reason})`
  - `ClientCapabilities({platform, modes, videoCodecs, maxFps, hasPreview, supportedResolutions, cameras})`
  - `FrameMeta({frameId, deviceId, timestampMs, width, height, quality})`
  - `VideoMeta({chunkId, deviceId, timestampMs, codec, sequence, durationMs, width, height})`
  - `abstract interface class CommandCodec`：`ServerCommand? decode(String raw)`、`String encode(ClientSignal signal)`
  - `enum UnrecognizedReason { malformedJson, unknownType, invalidPayload }`
  - `UnrecognizedEntry({raw, reason, timestamp})`
  - `UnrecognizedCommandLog({int capacity = 50, void Function(String)? sink})`：`entries`、`droppedCount`、`record`、`clear`
  - `JsonCommandCodec({UnrecognizedCommandLog? unrecognizedLog})`

- [ ] **Step 1: Write failing tests**

```dart
// test/backend/command_codec_test.dart
void main() {
  final codec = JsonCommandCodec();

  test('decodes cmd_update_config with absolute pixels', () {
    final u = codec.decode(
        '{"type":"cmd_update_config","payload":{"width":1920,"height":1080,"quality":90,"fps":5}}')!
        as UpdateConfigCommand;
    expect(u.width, 1920);
    expect(u.height, 1080);
    expect(u.quality, 90);
    expect(u.fps, 5.0);
  });

  test('decodes cmd_set_stream_mode with an explicit codec', () {
    final c = codec.decode(
        '{"type":"cmd_set_stream_mode","payload":{"mode":"video","codec":"hevc","chunkSeconds":2}}')!
        as SetStreamModeCommand;
    expect(c.mode, StreamMode.video);
    expect(c.codec, VideoCodec.hevc);
    expect(c.chunkSeconds, 2);
  });

  test('decodes cmd_set_preview', () {
    final c = codec.decode('{"type":"cmd_set_preview","payload":{"enabled":false}}')!
        as SetPreviewCommand;
    expect(c.enabled, isFalse);
  });

  test('decodes event_face_result', () {
    final c = codec.decode(
        '{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}')!
        as FaceResultCommand;
    expect(c.result.name, '张三');
  });

  test('records malformed json locally instead of throwing', () {
    final log = UnrecognizedCommandLog(sink: null);
    final c = JsonCommandCodec(unrecognizedLog: log);
    expect(c.decode('this is not json'), isNull);
    expect(c.decode(''), isNull);
    expect(c.decode('[]'), isNull);
    expect(log.entries.length, 3);
    expect(log.entries.first.raw, 'this is not json');
    expect(log.entries.first.reason, UnrecognizedReason.malformedJson);
  });

  test('records unknown command types with the raw payload intact', () {
    final log = UnrecognizedCommandLog(sink: null);
    final raw = '{"type":"cmd_do_a_backflip","payload":{"x":1}}';
    expect(JsonCommandCodec(unrecognizedLog: log).decode(raw), isNull);
    expect(log.entries.single.reason, UnrecognizedReason.unknownType);
    expect(log.entries.single.raw, raw);
  });

  test('records payloads with hostile field types instead of throwing', () {
    final log = UnrecognizedCommandLog(sink: null);
    expect(JsonCommandCodec(unrecognizedLog: log)
        .decode('{"type":"cmd_update_config","payload":{"width":"banana"}}'), isNull);
    expect(log.entries.single.reason, UnrecognizedReason.invalidPayload);
  });

  test('does not record well-formed commands', () {
    final log = UnrecognizedCommandLog(sink: null);
    final c = JsonCommandCodec(unrecognizedLog: log);
    c.decode('{"type":"cmd_control_stream","payload":{"enabled":false}}');
    c.decode('{"type":"cmd_set_preview","payload":{"enabled":true}}');
    expect(log.entries, isEmpty);
  });

  test('encodes state_sync carrying mode, codec and preview', () {
    final map = jsonDecode(codec.encode(StateSyncSignal(
      width: 1280, height: 720, quality: 80, fps: 1.0, cameraIndex: 0, streaming: true,
      mode: StreamMode.video, codec: VideoCodec.avc, chunkSeconds: 3, previewEnabled: false,
    ))) as Map<String, dynamic>;
    expect(map['type'], 'state_sync');
    expect(map['payload']['mode'], 'video');
    expect(map['payload']['codec'], 'avc');
    expect(map['payload']['previewEnabled'], false);
  });

  test('encodes capability mismatch so the backend learns what really ran', () {
    final map = jsonDecode(codec.encode(CapabilityMismatchSignal(
        requested: 'hevc', applied: 'avc', reason: 'codec unavailable'))) as Map<String, dynamic>;
    expect(map['type'], 'capability_mismatch');
    expect(map['payload']['requested'], 'hevc');
    expect(map['payload']['applied'], 'avc');
  });

  test('encodes heartbeat with the agreed type name', () {
    expect(jsonDecode(codec.encode(HeartbeatSignal(deviceId: 'd')))['type'], 'heartbeat');
  });
}
```

```dart
// test/backend/unrecognized_command_log_test.dart
void main() {
  test('is bounded and keeps the newest entries', () {
    final log = UnrecognizedCommandLog(capacity: 3, sink: null);
    for (var i = 0; i < 5; i++) { log.record('raw-$i', UnrecognizedReason.unknownType); }
    expect(log.entries.map((e) => e.raw), ['raw-2', 'raw-3', 'raw-4']);
    expect(log.droppedCount, 2);
  });

  test('truncates oversized raw payloads so one huge frame cannot exhaust memory', () {
    final log = UnrecognizedCommandLog(sink: null);
    log.record('x' * 20000, UnrecognizedReason.malformedJson);
    expect(log.entries.single.raw.length, lessThanOrEqualTo(512));
  });

  test('sink receives a human readable message', () {
    final messages = <String>[];
    UnrecognizedCommandLog(sink: messages.add).record('{"type":"nope"}', UnrecognizedReason.unknownType);
    expect(messages.single, contains('unknownType'));
    expect(messages.single, contains('nope'));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/backend/command_codec_test.dart test/backend/unrecognized_command_log_test.dart`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

`decode` 全程包在 try/catch 内，三类失败**都返回 `null`、都记一条本地留痕、都绝不抛出也不断连**：解析失败 → `malformedJson`；`type` 未知或缺失 → `unknownType`；字段类型不可用 → `invalidPayload`。`mode` / `codec` 用宽松解析，非法值视为未提供。

`UnrecognizedCommandLog` 是有界环形缓冲：`raw` 截断到 512 字符，超 `capacity` 丢最旧并 `droppedCount++`，默认 `sink` 为 `debugPrint`（测试传 `null` 静音）。**只写本地，不回传后端。**

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/backend/command_codec_test.dart test/backend/unrecognized_command_log_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend test/backend
git commit -m "feat: add command model, fault-tolerant codec, and unrecognized command log"
```

---

### Task 3: BackendGateway 接口与 WebSocket 实现

**Files:**
- Create: `lib/src/backend/backend_gateway.dart`
- Create: `lib/src/backend/websocket_backend_gateway.dart`
- Test: `test/backend/websocket_backend_gateway_test.dart`

**Interfaces:**
- Consumes: `CommandCodec`、`ClientSignal`、`ServerCommand`、`FrameMeta`、`VideoMeta` from Task 2
- Produces:
  - `enum ConnectionState { connected, reconnecting, offline }`
  - `abstract interface class BackendGateway`：`connect`、`disconnect`、`sendSignal(ClientSignal)`、`sendFrameMeta(FrameMeta)`、`sendFrameBytes(Uint8List)`、`sendVideoMeta(VideoMeta)`、`sendVideoBytes(Uint8List)`、`Stream<ServerCommand> commands`、`Stream<ConnectionState> connectionChanges`、`bool isConnected`、`UnrecognizedCommandLog unrecognizedCommands`
  - `WebSocketBackendGateway({required CommandCodec codec, required WebSocketChannelFactory channelFactory, Duration? heartbeatInterval})`
  - `typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri)`
  - `Duration backoffFor(int attempt)` — 1s、2s、4s、8s、16s，之后封顶 16s

- [ ] **Step 1: Write failing tests**

```dart
// test/backend/websocket_backend_gateway_test.dart
class FakeSink implements WebSocketSink {
  final records = <Object>[];
  @override void add(dynamic data) => records.add(data);
  @override void close([int? closeCode, String? closeReason]) {}
  @override Future<void> get done => Completer<void>().future;
  @override noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('routes parsed text frames to commands stream', () async {
    final incoming = StreamController<dynamic>();
    final gw = WebSocketBackendGateway(codec: JsonCommandCodec(),
        channelFactory: (_) => _FakeChannel(incoming.stream, FakeSink()));
    await gw.connect('ws://x');
    incoming.add('{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}');
    await expectLater(gw.commands, emits(isA<FaceResultCommand>()));
  });

  test('malformed frame is recorded locally and the channel survives the next valid frame', () async {
    final incoming = StreamController<dynamic>();
    final log = UnrecognizedCommandLog(sink: null);
    final gw = WebSocketBackendGateway(
        codec: JsonCommandCodec(unrecognizedLog: log),
        channelFactory: (_) => _FakeChannel(incoming.stream, FakeSink()));
    await gw.connect('ws://x');
    incoming.add('<<garbage>>');
    await pumpEventQueue();
    expect(log.entries.single.raw, '<<garbage>>');
    expect(log.entries.single.reason, UnrecognizedReason.malformedJson);
    incoming.add('{"type":"cmd_control_stream","payload":{"enabled":false}}');
    await expectLater(gw.commands, emits(isA<ControlStreamCommand>()));
  });

  test('frame upload emits meta text before binary', () async {
    final sink = FakeSink();
    final gw = WebSocketBackendGateway(codec: JsonCommandCodec(),
        channelFactory: (_) => _FakeChannel(const Stream.empty(), sink));
    await gw.connect('ws://x');
    gw.sendFrameMeta(FrameMeta(frameId: 7, deviceId: 'd', timestampMs: 1,
        width: 1280, height: 720, quality: 80));
    gw.sendFrameBytes(Uint8List.fromList([1, 2, 3]));
    expect(sink.records.length, 2);
    expect(jsonDecode(sink.records.first as String)['type'], 'frame_meta');
    expect(sink.records.last, isA<Uint8List>());
  });

  test('video upload emits video_meta text before binary', () async {
    final sink = FakeSink();
    final gw = WebSocketBackendGateway(codec: JsonCommandCodec(),
        channelFactory: (_) => _FakeChannel(const Stream.empty(), sink));
    await gw.connect('ws://x');
    gw.sendVideoMeta(VideoMeta(chunkId: 1, deviceId: 'd', timestampMs: 1,
        codec: VideoCodec.avc, sequence: 0, durationMs: 3000, width: 1280, height: 720));
    gw.sendVideoBytes(Uint8List.fromList([0, 0, 0, 24]));
    expect(jsonDecode(sink.records.first as String)['type'], 'video_meta');
    expect(jsonDecode(sink.records.first as String)['payload']['codec'], 'avc');
  });

  test('backoff grows and caps at 16 seconds', () {
    expect(backoffFor(0), const Duration(seconds: 1));
    expect(backoffFor(2), const Duration(seconds: 4));
    expect(backoffFor(99), const Duration(seconds: 16));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/backend/websocket_backend_gateway_test.dart`
Expected: FAIL with "Undefined name 'WebSocketBackendGateway'"

- [ ] **Step 3: Implement**

`data is String` → `codec.decode` → 非 null 才推入 `commands`；`data is List<int>` → 客户端当前不消费下行二进制，忽略。心跳按 `heartbeatSeconds` 发 `HeartbeatSignal`。断连 → 推 `reconnecting` 并按 `backoffFor(attempt)` 退避重试，成功后归零、推 `connected`。**对外不暴露 `WebSocketChannel` 类型。**

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/backend/websocket_backend_gateway_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend/backend_gateway.dart lib/src/backend/websocket_backend_gateway.dart test/backend
git commit -m "feat: add backend gateway interface and websocket implementation"
```

---

### Task 4: MockBackendGateway（后端未定稿期间的脱机自测后端）

**Files:**
- Create: `lib/src/backend/mock_backend_gateway.dart`
- Test: `test/backend/mock_backend_gateway_test.dart`

**Interfaces:**
- Consumes: `BackendGateway`、`CommandCodec` from Task 3
- Produces: `MockBackendGateway({Duration? commandInterval})` — 定时下发 `SetStreamModeCommand` / `SetPreviewCommand` / `FaceResultCommand`；`sendVideoBytes` 与 `sendFrameBytes` 只计数

- [ ] **Step 1: Write failing test**

```dart
// test/backend/mock_backend_gateway_test.dart
void main() {
  test('emits stream mode, preview and face result commands on cue', () async {
    final gw = MockBackendGateway(commandInterval: const Duration(milliseconds: 1));
    await gw.connect('ws://mock');
    await expectLater(gw.commands, emitsThrough(predicate<ServerCommand>((c) => c is SetStreamModeCommand)));
    await expectLater(gw.commands, emitsThrough(predicate<ServerCommand>((c) => c is SetPreviewCommand)));
    await expectLater(gw.commands, emitsThrough(predicate<ServerCommand>((c) => c is FaceResultCommand)));
    expect(gw.isConnected, isTrue);
  });

  test('counts frames and video chunks it would have sent', () async {
    final gw = MockBackendGateway();
    await gw.connect('ws://mock');
    gw.sendFrameBytes(Uint8List.fromList([1]));
    gw.sendVideoBytes(Uint8List.fromList([2]));
    gw.sendVideoBytes(Uint8List.fromList([3]));
    expect(gw.frameCount, 1);
    expect(gw.videoChunkCount, 2);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/backend/mock_backend_gateway_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement**

内部 `StreamController<ServerCommand>.broadcast()` + `Timer.periodic`。不碰真实网络。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/backend/mock_backend_gateway_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend/mock_backend_gateway.dart test/backend/mock_backend_gateway_test.dart
git commit -m "feat: add mock backend gateway for offline development"
```

---

### Task 5: 摄像头四层抽象与 camera_desktop 实现

**Files:**
- Create: `lib/src/capture/frame_store.dart`
- Create: `lib/src/capture/frame_source.dart`
- Create: `lib/src/capture/camera_service.dart`
- Create: `lib/src/capture/camera_backend.dart`
- Create: `lib/src/capture/camera_plugin_backend.dart`
- Create: `lib/src/capture/camera_provider.dart`
- Test: `test/capture/frame_store_test.dart`
- Test: `test/capture/camera_provider_test.dart`
- Test: `test/capture/failure_message_test.dart`

**Interfaces:**
- Consumes: `CameraResolution`、`CaptureConfig`、`selectClosestResolution`、`StreamSettings` from Task 1
- Produces:
  - `abstract interface class FrameSource`：`Future<void> start(CaptureConfig)`、`Future<void> stop()`、`Future<Uint8List?> nextFrame(int quality)`
  - `TakePictureFrameSource implements FrameSource`（落盘即删；`ImageStreamFrameSource` v1 不实现，仅留接口）
  - `abstract interface class FrameStore`：`Future<Uint8List> readAndDelete(String path)`；默认 `IoFrameStore`
  - `abstract interface class CameraService`：`initialize`、`reconfigure(CaptureConfig)`、`switchCamera(int)`、`captureFrame(int quality)`、`setPreviewEnabled(bool)`、`release()`、`CameraDescriptor descriptor`、`bool isInitialized`、`bool previewEnabled`、`CameraResolution appliedResolution`、`List<CameraResolution> supportedResolutions`、`Stream<CameraHealth> health`
  - `enum CameraUnavailableReason { noDevice, permissionDenied, missingDependency, deviceBusy, initFailed }`
  - `sealed class CameraFailure`：`NoDevice`、`PermissionDenied`、`DeviceBusy`、`InitFailed(Object)`、`CaptureFailed(Object)`、`NoBackendAvailable(List<BackendProbe>)`
  - `String failureMessage(CameraFailure failure) -> String`（纯函数，供 UI 直接展示）
  - `class BackendProbe { bool available; CameraUnavailableReason? reason; List<CameraDescriptor> devices; List<CameraResolution> supportedResolutions; double maxFps; bool supportsPreview; }`
  - `abstract interface class CameraBackend`：`String id`、`Future<BackendProbe> probe()`（永不抛异常）、`Future<CameraService> open(CaptureConfig)`
  - `CameraPluginBackend implements CameraBackend`（`camera` + `camera_desktop`，覆盖 5 平台；`probe()` 内含权限申请）
  - `CameraProvider({required List<CameraBackend> backends})`：`Future<CameraOpenResult> open(CaptureConfig)`
  - `CameraOpenResult { CameraService? service; String? backendId; List<BackendProbe> attempts; CameraFailure? failure; }`

- [ ] **Step 1: Write failing tests**

```dart
// test/capture/frame_store_test.dart
void main() {
  test('reads bytes then removes the file so nothing accumulates', () async {
    final dir = await Directory.systemTemp.createTemp('probe');
    final f = File(p.join(dir.path, 'frame.jpg'))..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9]);
    expect(await const IoFrameStore().readAndDelete(f.path), [0xFF, 0xD8, 1, 0xFF, 0xD9]);
    expect(f.existsSync(), isFalse);
  });
}
```

```dart
// test/capture/camera_provider_test.dart
class FakeBackend implements CameraBackend {
  FakeBackend(this.id, {this.probeResult, this.openError});
  @override final String id;
  final BackendProbe? probeResult;
  final Object? openError;
  @override Future<BackendProbe> probe() async => probeResult!;
  @override Future<CameraService> open(CaptureConfig c) async {
    if (openError != null) throw openError!;
    return _FakeCameraService();
  }
}

void main() {
  test('skips an unavailable backend and opens the next one', () async {
    final provider = CameraProvider(backends: [
      FakeBackend('broken', probeResult: BackendProbe(available: false,
          reason: CameraUnavailableReason.noDevice, devices: const [],
          supportedResolutions: const [], maxFps: 0, supportsPreview: false)),
      FakeBackend('good', probeResult: BackendProbe(available: true, devices: const [],
          supportedResolutions: const [], maxFps: 30, supportsPreview: true)),
    ]);
    final result = await provider.open(CaptureConfig.defaults());
    expect(result.backendId, 'good');
    expect(result.service, isNotNull);
    expect(result.attempts.length, 2);
  });

  test('falls through when a backend probes fine but open throws', () async {
    final provider = CameraProvider(backends: [
      FakeBackend('crashy', probeResult: _okProbe(), openError: CameraFailure.initFailed('boom')),
      FakeBackend('good', probeResult: _okProbe()),
    ]);
    final result = await provider.open(CaptureConfig.defaults());
    expect(result.backendId, 'good');
    expect(result.attempts.length, 2);
  });

  test('reports NoBackendAvailable with the full attempt list when all fail', () async {
    final provider = CameraProvider(backends: [
      FakeBackend('a', probeResult: BackendProbe(available: false,
          reason: CameraUnavailableReason.permissionDenied, devices: const [],
          supportedResolutions: const [], maxFps: 0, supportsPreview: false)),
    ]);
    final result = await provider.open(CaptureConfig.defaults());
    expect(result.service, isNull);
    expect(result.failure, isA<CameraFailureNoBackendAvailable>());
    expect(result.attempts.length, 1);
  });
}
```

```dart
// test/capture/failure_message_test.dart
void main() {
  test('gives distinct guidance per failure type', () {
    expect(failureMessage(const CameraFailure.noDevice()), contains('未检测到摄像头'));
    expect(failureMessage(const CameraFailure.permissionDenied()), contains('权限'));
    expect(failureMessage(const CameraFailure.deviceBusy()), contains('占用'));
    expect(failureMessage(CameraFailure.noBackendAvailable(const [])), isNotEmpty);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/capture`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

`CameraService` 用 `abstract interface class`（可 mocktail `implements`，不可实例化）。**`buildPreview()` 不在这个接口里** —— 预览 widget 归 UI 层。

`reconfigure` / `switchCamera` 必须在串行锁内 `dispose()` 旧 controller 再重建，重建失败回滚上一份 `CaptureConfig` 并保持 `isInitialized == true`。`captureFrame` 走 `takePicture()` → `FrameStore.readAndDelete()`，落盘文件读完立即删除，`initialize` 时清理残留。

`setPreviewEnabled(false)` → `controller.pausePreview()` + 停止渲染；`true` → `resumePreview()`。**采集循环不受影响。**

`CameraPluginBackend.probe()` 内部申请 `Permission.camera`（Android/iOS/macOS），Windows/Linux 跳过；任何异常都转成 `BackendProbe(available: false, reason: ...)`，**永不抛出**。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/capture`
Expected: PASS

- [ ] **Step 5: 实机门禁（不可跳过，三条都要跑）**

1. Run: `flutter run -d windows` —— 预览出画、`takePicture` 成功、录视频成功。
2. Run: `flutter run -d macos` —— 同上。**验证 `camera_desktop` 在 macOS 上确实可用**（`camera` 的 plugin map 无 macOS，这是唯一路径）。
3. Run: `flutter run -d linux` —— 同上，**重点验证 1280×720 是否触发 open issue #8 的内存分配失败**；若失败，把 Linux 默认分辨率改为 640×480 并在 commit message 记录。

任一平台失败 → 先查版本兼容（`camera_platform_interface` 实际解析到的版本），再决定是否加 `dependency_overrides` 或换后端实现。

- [ ] **Step 6: Commit**

```bash
git add lib/src/capture test/capture
git commit -m "feat: add camera backend abstraction and camera_desktop implementation"
```

---

### Task 6: 视频分片录制器（AVC，HEVC 留接口位）

**Files:**
- Create: `lib/src/capture/video_chunk.dart`
- Create: `lib/src/capture/video_chunk_recorder.dart`
- Test: `test/capture/video_chunk_recorder_test.dart`

**Interfaces:**
- Consumes: `VideoCodec`、`StreamSettings` from Task 1
- Produces:
  - `VideoChunk({Uint8List bytes, VideoCodec codec, VideoCodec? requestedCodec, int sequence, int durationMs, int width, int height})`，`bool get isCodecMismatch => requestedCodec != null && requestedCodec != codec`
  - `abstract interface class VideoChunkRecorder`：`Future<void> start({required VideoCodec codec, required int chunkSeconds, required CaptureConfig config})`、`Future<void> stop()`、`Stream<VideoChunk> get chunks`、`Set<VideoCodec> get supportedCodecs`
  - `CameraPluginVideoChunkRecorder implements VideoChunkRecorder` — 周期性 `startVideoRecording()` / `stopVideoRecording()`，`supportedCodecs == {VideoCodec.avc}`

- [ ] **Step 1: Write failing tests**

```dart
// test/capture/video_chunk_recorder_test.dart
class FakeRecorderHost implements RecorderHost {
  int startCalls = 0, stopCalls = 0;
  @override Future<void> startRecording() async { startCalls++; }
  @override Future<XFile> stopRecording() async { stopCalls++; return XFile('x.mp4'); }
  @override Future<Uint8List> readFile(String path) async => Uint8List.fromList([0, 0, 0, 24]);
}

void main() {
  test('produces one chunk per interval and restarts immediately', () async {
    final host = FakeRecorderHost();
    final rec = CameraPluginVideoChunkRecorder(host: host, fileStore: _NoopFileStore());
    await rec.start(codec: VideoCodec.avc, chunkSeconds: 1, config: CaptureConfig.defaults());
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    await rec.stop();
    expect(host.startCalls, 2);
    expect(host.stopCalls, 2);
  });

  test('reports avc as the applied codec when hevc was requested', () async {
    final host = FakeRecorderHost();
    final rec = CameraPluginVideoChunkRecorder(host: host, fileStore: _NoopFileStore());
    final chunk = await rec.start(codec: VideoCodec.hevc, chunkSeconds: 1,
        config: CaptureConfig.defaults()).then((_) => rec.chunks.first);
    expect(chunk.codec, VideoCodec.avc);
    expect(chunk.requestedCodec, VideoCodec.hevc);
    expect(chunk.isCodecMismatch, isTrue);
  });

  test('supportedCodecs only lists what the plugin can really do', () {
    expect(CameraPluginVideoChunkRecorder(host: FakeRecorderHost(), fileStore: _NoopFileStore())
        .supportedCodecs, {VideoCodec.avc});
  });

  test('stop is idempotent and emits no further chunks', () async {
    final host = FakeRecorderHost();
    final rec = CameraPluginVideoChunkRecorder(host: host, fileStore: _NoopFileStore());
    await rec.start(codec: VideoCodec.avc, chunkSeconds: 1, config: CaptureConfig.defaults());
    await rec.stop();
    await rec.stop();
    expect(host.stopCalls, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/capture/video_chunk_recorder_test.dart`
Expected: FAIL with "Undefined name 'CameraPluginVideoChunkRecorder'"

- [ ] **Step 3: Implement**

`RecorderHost` 是对 `CameraController` 录制方法的薄封装（注入点，便于测试）。录制器按 `chunkSeconds` 周期起停，**每个分片是自带 `moov` 的独立 mp4，后端可独立解码**。请求 `hevc` 时仍产出 `avc`，但把 `requestedCodec` 带在 `VideoChunk` 上，由 T7 发 `CapabilityMismatchSignal`。分片读完字节后立即删除文件。

**v1 不实现 HEVC 编码**。接入原生编码器时只需新增一个 `VideoChunkRecorder` 实现并让它进 `CameraPluginBackend` 的 `supportedCodecs`（Android 需 `MediaCodecList` 探测、iOS 用 VideoToolbox、Linux 需 x265），现有代码不动。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/capture/video_chunk_recorder_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/capture/video_chunk.dart lib/src/capture/video_chunk_recorder.dart test/capture
git commit -m "feat: add avc video chunk recorder with codec mismatch reporting"
```

---

### Task 7: AgentCoordinator（采集循环、模式切换、命令路由、状态同步、自治降级）

**Files:**
- Create: `lib/src/agent/agent_status.dart`
- Create: `lib/src/agent/agent_coordinator.dart`
- Test: `test/agent/agent_coordinator_test.dart`

**Interfaces:**
- Consumes: `CameraProvider`(T5)、`VideoChunkRecorder`(T6)、`BackendGateway`(T3/T4)、`DeviceIdService`(T1)、`StreamSettings`(T1)
- Produces:
  - `AgentCoordinator({required CameraProvider cameraProvider, required BackendGateway gateway, required DeviceIdService deviceIdService, VideoChunkRecorder? recorder, StreamSettings? initialSettings})`
  - `Future<void> start()`、`void stop()`、`Future<void> pause()`、`Future<void> resume()`
  - `Future<void> performCaptureTick()`（**测试入口**）
  - `StreamSettings get settings`、`double get currentFps`、`bool get isStreaming`、`bool get isAutonomous`、`String get cameraName`、`String? get backendId`、`UnrecognizedCommandLog get unrecognizedCommands`
  - `Stream<FaceResult> onFaceResult`、`Stream<double> onFpsUpdate`、`Stream<AgentStatus> onStatus`
  - `AgentStatus({connection, fps, cameraName, streaming, autonomous, resolutionLabel, streamModeLabel, previewEnabled, backendId})`

- [ ] **Step 1: Write failing tests**

```dart
// test/agent/agent_coordinator_test.dart
class MockCameraService extends Mock implements CameraService {}
class MockBackendGateway extends Mock implements BackendGateway {}
class MockVideoChunkRecorder extends Mock implements VideoChunkRecorder {}

void main() {
  test('drops the second frame while the first upload is in flight', () async {
    final camera = MockCameraService();
    final gw = MockBackendGateway();
    final co = _build(camera, gw);
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenAnswer((_) async {
      await Future.delayed(const Duration(milliseconds: 200));
      return Uint8List.fromList([1, 2, 3]);
    });
    final f1 = co.performCaptureTick();
    final f2 = co.performCaptureTick();
    await Future.wait([f1, f2]);
    verify(() => camera.captureFrame(any())).called(1);
    verify(() => gw.sendFrameBytes(any())).called(1);
  });

  test('releases the in-flight lock in finally even when capture throws', () async {
    final camera = MockCameraService();
    final co = _build(camera, MockBackendGateway());
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenThrow(StateError('camera died'));
    await expectLater(co.performCaptureTick(), returnsNormally);
    await co.performCaptureTick();
    verify(() => camera.captureFrame(any())).called(2);
  });

  test('sends frame_meta before every binary frame', () async {
    final camera = MockCameraService();
    final gw = MockBackendGateway();
    final co = _build(camera, gw);
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenAnswer((_) async => Uint8List.fromList([1]));
    await co.performCaptureTick();
    verify(() => gw.sendFrameMeta(any())).called(1);
    verify(() => gw.sendFrameBytes(any())).called(1);
  });

  test('video mode uploads chunks with video_meta and reports codec mismatch', () async {
    final gw = MockBackendGateway();
    final recorder = MockVideoChunkRecorder();
    final co = _build(MockCameraService(), gw, recorder: recorder);
    when(() => recorder.supportedCodecs).thenReturn({VideoCodec.avc});
    when(() => recorder.chunks).thenAnswer((_) => Stream<VideoChunk>.fromIterable([
      VideoChunk(bytes: Uint8List.fromList([1]), codec: VideoCodec.avc,
          requestedCodec: VideoCodec.hevc, sequence: 0, durationMs: 3000, width: 1280, height: 720),
    ]));
    co.handleCommand(const SetStreamModeCommand(mode: StreamMode.video, codec: VideoCodec.hevc));
    await pumpEventQueue();
    verify(() => gw.sendVideoMeta(any())).called(greaterThan(0));
    verify(() => gw.sendVideoBytes(any())).called(greaterThan(0));
    verify(() => gw.sendSignal(any(that: isA<CapabilityMismatchSignal>()))).called(1);
  });

  test('preview command toggles the camera service, not the capture loop', () async {
    final camera = MockCameraService();
    final co = _build(camera, MockBackendGateway());
    when(() => camera.setPreviewEnabled(any())).thenAnswer((_) async {});
    co.handleCommand(const SetPreviewCommand(enabled: false));
    await pumpEventQueue();
    verify(() => camera.setPreviewEnabled(false)).called(1);
    expect(co.settings.previewEnabled, isFalse);
  });

  test('routes each command type to the right collaborator', () async {
    final camera = MockCameraService();
    final co = _build(camera, MockBackendGateway());
    when(() => camera.reconfigure(any())).thenAnswer((_) async {});
    when(() => camera.switchCamera(any())).thenAnswer((_) async {});
    co.handleCommand(const UpdateConfigCommand(width: 640, height: 480, fps: 4));
    co.handleCommand(const ControlStreamCommand(enabled: false));
    co.handleCommand(const SwitchCameraCommand(index: 1));
    await pumpEventQueue();
    verify(() => camera.reconfigure(any())).called(1);
    expect(co.isStreaming, isFalse);
    verify(() => camera.switchCamera(1)).called(1);
  });

  test('face results are forwarded to the UI stream', () async {
    final co = _build(MockCameraService(), MockBackendGateway());
    expectLater(co.onFaceResult, emits(predicate<FaceResult>((r) => r.name == '张三')));
    co.handleCommand(FaceResultCommand(result: const FaceResult(name: '张三', status: 'approved')));
  });

  test('re-syncs every mutable setting after a reconnect', () async {
    final gw = MockBackendGateway();
    final camera = MockCameraService();
    final co = _build(camera, gw);
    when(() => camera.appliedResolution).thenReturn(const CameraResolution(width: 1280, height: 720));
    co.onGatewayConnectionChanged(ConnectionState.connected);
    await pumpEventQueue();
    verify(() => gw.sendSignal(any(that: isA<RegisterSignal>()))).called(greaterThan(0));
    final sync = verify(() => gw.sendSignal(captureAny(that: isA<StateSyncSignal>()))).captured.single
        as StateSyncSignal;
    expect(sync.mode, StreamMode.video);
    expect(sync.codec, VideoCodec.avc);
    expect(sync.previewEnabled, isTrue);
  });

  test('goes autonomous when no command arrives within the register timeout', () async {
    final co = _build(MockCameraService(), MockBackendGateway(),
        registerTimeout: const Duration(milliseconds: 10));
    await co.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(co.isAutonomous, isTrue);
    expect(co.isStreaming, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/agent/agent_coordinator_test.dart`
Expected: FAIL with "Undefined name 'AgentCoordinator'"

- [ ] **Step 3: Implement**

`performCaptureTick()`：`if (!_streaming || !camera.isInitialized || _isUploading) return;` → `_isUploading = true` → `try { frame = await camera.captureFrame(quality); if (frame == null) return; gateway.sendFrameMeta(...); gateway.sendFrameBytes(frame); _framesInWindow++; } catch (_) {} finally { _isUploading = false; }`。`_isUploading` 置位必须在任何 `await` 之前。

视频模式下改为订阅 `recorder.chunks`：每收到分片 → `sendVideoMeta` → `sendVideoBytes`；分片 `isCodecMismatch` 为真时**额外**发一条 `CapabilityMismatchSignal`（只发一次，不每个分片都发）。

命令路由订阅 `gateway.commands`。`SetStreamModeCommand` 切换模式：`video` → 启动录制器（`recorder.supportedCodecs` 不含请求值时仍启动，实际 codec 由分片回报）；`still` → 停止录制器、重启 `Timer` 抓拍循环。切换失败时**回退到 `still`** 并保证仍有画面上传。`SetPreviewCommand` → `camera.setPreviewEnabled()`，不动采集循环。

未识别报文在 codec 层已被丢弃并留痕，**永远到不了这里**；协调器只透传 `unrecognizedCommands`。

`onFpsUpdate` 每秒统计上一窗口实际上传数。视频模式下统计的是"每秒上传分片数 × 分片时长折算"。`start()` 立即按本地默认设置开跑，不等后端；`register` 后 `registerTimeoutSeconds` 内无命令 → `isAutonomous = true`，此后每 15s 重发 `register`。`pause()` 取消定时器 + 停录制器 + `camera.release()` + `gateway.disconnect()`；`resume()` 反向恢复。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/agent/agent_coordinator_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/agent test/agent
git commit -m "feat: add agent coordinator with mode switching, routing, and autonomy"
```

---

### Task 8: 表现层 UI（含预览开关）

**Files:**
- Create: `lib/src/ui/widgets/recognition_hud.dart`
- Create: `lib/src/ui/widgets/status_bar_overlay.dart`
- Create: `lib/src/ui/widgets/camera_error_view.dart`
- Create: `lib/src/ui/screens/agent_screen.dart`
- Test: `test/ui/recognition_hud_test.dart`
- Test: `test/ui/status_bar_overlay_test.dart`
- Test: `test/ui/camera_error_view_test.dart`

**Interfaces:**
- Consumes: `AgentCoordinator`、`AgentStatus`(T7)、`FaceResult`(T2)、`CameraService`(T5)、`CameraFailure` + `failureMessage`(T5)
- Produces: `AgentScreen({required AgentCoordinator coordinator})`；`StatusBarOverlay({required AgentStatus status, required ValueChanged<bool> onPreviewToggle})`；`RecognitionHud({required FaceResult result})`；`CameraErrorView({required CameraFailure failure, required VoidCallback onRetry})`

- [ ] **Step 1: Write failing tests**

```dart
// test/ui/recognition_hud_test.dart
void main() {
  testWidgets('shows the name and status label then unmounts after 3 seconds', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
        body: RecognitionHud(result: FaceResult(name: '张三', status: 'approved')))));
    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining('识别成功'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.textContaining('张三'), findsNothing);
  });

  testWidgets('a second result resets the dismiss timer instead of being cut short', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
        body: RecognitionHud(result: FaceResult(name: '张三', status: 'approved')))));
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
        body: RecognitionHud(result: FaceResult(name: '李四', status: 'rejected')))));
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.textContaining('李四'), findsOneWidget);
    expect(find.textContaining('识别失败'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.textContaining('李四'), findsNothing);
  });

  testWidgets('unknown status renders 未识别', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
        body: RecognitionHud(result: FaceResult(name: '王五', status: 'who-dis')))));
    expect(find.textContaining('未识别'), findsOneWidget);
  });
}
```

```dart
// test/ui/status_bar_overlay_test.dart
void main() {
  testWidgets('renders mode, fps, resolution and the preview toggle', (tester) async {
    var toggled = false;
    const status = AgentStatus(connection: ConnectionState.connected, fps: 2.0,
        cameraName: 'Integrated Camera', streaming: true, autonomous: true,
        resolutionLabel: '1280x720', streamModeLabel: '视频·AVC', previewEnabled: true,
        backendId: 'camera_desktop');
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: StatusBarOverlay(status: status, onPreviewToggle: (_) => toggled = true))));
    expect(find.textContaining('1280x720'), findsOneWidget);
    expect(find.textContaining('视频·AVC'), findsOneWidget);
    expect(find.textContaining('Integrated Camera'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preview-toggle')));
    expect(toggled, isTrue);
  });

  testWidgets('keeps a recording indicator visible even when preview is off', (tester) async {
    const status = AgentStatus(connection: ConnectionState.connected, fps: 2.0,
        cameraName: 'cam', streaming: true, autonomous: false, resolutionLabel: '1280x720',
        streamModeLabel: '视频·AVC', previewEnabled: false, backendId: 'camera_desktop');
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: StatusBarOverlay(status: status, onPreviewToggle: (_) {}))));
    expect(find.textContaining('采集进行中'), findsOneWidget);
  });
}
```

```dart
// test/ui/camera_error_view_test.dart
void main() {
  testWidgets('shows typed guidance and forwards retry taps', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: CameraErrorView(failure: const CameraFailure.permissionDenied(),
            onRetry: () => tapped++))));
    expect(find.textContaining('权限'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(tapped, 1);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/ui`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

`RecognitionHud`：内置 `Timer` 3 秒后置 `_visible = false` 并 `setState`，`build` 在 `!_visible` 时**返回 `SizedBox.shrink()`**（`AnimatedOpacity` 只改 opacity 会让 `findsNothing` 永远不成立）。`didUpdateWidget` 检测到 `result` 变化时取消旧 Timer 并重启。状态映射：`approved`→识别成功，`rejected`/`denied`→识别失败，其余→未识别。

`AgentScreen` 用 `Stack` 叠放：底层预览（`previewEnabled` 为 false 时显示"预览已关闭"占位，采集继续）、顶部 `StatusBarOverlay`、居中靠下 `RecognitionHud`。初始化失败或 `cameraService.isInitialized == false` 时整屏切到 `CameraErrorView`，文案由 `failureMessage(failure)` 提供（不再收裸 String）。

`StatusBarOverlay` 的预览开关 `Key('preview-toggle')` 直接调 `coordinator.setPreviewEnabled()`；**`previewEnabled == false` 时必须显示"采集进行中"指示**，避免被拍者误以为没在录。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/ui`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/ui test/ui
git commit -m "feat: add kiosk UI with preview toggle, status overlay, and typed error state"
```

---

### Task 9: 启动组装、Wakelock、生命周期与全局异常隔离

**Files:**
- Create: `lib/src/app/lifecycle_controller.dart`
- Create: `lib/main.dart`
- Test: `test/app/lifecycle_controller_test.dart`
- Test: `test/app/bootstrap_test.dart`

**Interfaces:**
- Consumes: 全部 T1–T8
- Produces: `bool shouldPauseFor(AppLifecycleState state)`；`List<CameraBackend> buildBackendChain()`（按平台组装有序后端列表）

- [ ] **Step 1: Write failing tests**

```dart
// test/app/lifecycle_controller_test.dart
void main() {
  test('pauses when backgrounded, hidden or detached', () {
    expect(shouldPauseFor(AppLifecycleState.paused), isTrue);
    expect(shouldPauseFor(AppLifecycleState.hidden), isTrue);
    expect(shouldPauseFor(AppLifecycleState.detached), isTrue);
  });

  test('keeps running while resumed or merely inactive', () {
    expect(shouldPauseFor(AppLifecycleState.resumed), isFalse);
    expect(shouldPauseFor(AppLifecycleState.inactive), isFalse);
  });
}
```

```dart
// test/app/bootstrap_test.dart
void main() {
  test('AppConfig exposes a usable endpoint and sane capture defaults', () {
    expect(AppConfig.wsUrl, startsWith('ws://'));
    expect(AppConfig.defaultWidth, 1280);
    expect(AppConfig.defaultHeight, 720);
    expect(AppConfig.defaultQuality, inInclusiveRange(1, 100));
    expect(AppConfig.defaultChunkSeconds, 3);
    expect(AppConfig.defaultPreviewEnabled, isTrue);
    expect(AppConfig.heartbeatSeconds, 15);
  });

  test('backend chain starts with camera_desktop', () {
    expect(buildBackendChain().first.id, 'camera_desktop');
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/app`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

`shouldPauseFor`：`inactive` 在桌面端表示"窗口可见但失焦"，kiosk 必须继续推流，故不暂停；`hidden`（最小化）与 `paused`/`detached` 才暂停。

`buildBackendChain()` 返回 `[CameraPluginBackend(), ...]`；后续要加 ffmpeg / 原生编码器后端，只需往这个列表追加。

`main()`：`WidgetsFlutterBinding.ensureInitialized()` → `FlutterError.onError` + `runZonedGuarded` 捕获全局异常 → `WakelockPlus.enable()` → 组装 `DeviceIdService` / `BackendGateway`（`--dart-define USE_MOCK_BACKEND=true` 时切 `MockBackendGateway`）→ `VideoChunkRecorder` → `AgentCoordinator` → `runApp(AgentApp())`，并把 `LifecycleController` 挂到 `WidgetsBindingObserver`。`UnrecognizedCommandLog` 的 `sink` 接到同一日志出口，未识别报文直接出现在 `flutter logs`。

- [ ] **Step 4: Run full suite**

Run: `flutter test`
Expected: ALL PASS

- [ ] **Step 5: 全平台冒烟门禁**

Run each: `flutter run -d windows` / `-d macos` / `-d linux` / `-d android` / `-d ios`

每项 Expected：预览出画且可开关、状态条显示"视频·AVC"、后端（用 `--dart-define USE_MOCK_BACKEND=true` 的假后端）能收到 `video_meta` + mp4 分片、切后台后停止采集、回前台恢复。

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/src/app test/app
git commit -m "feat: wire bootstrap, wakelock, lifecycle handling, and backend chain"
```

---

## Self-Review Checklist

1. **Spec 覆盖**：原始 6 信令 + 新增 `cmd_set_stream_mode` / `cmd_set_preview` / `state_sync` / `frame_meta` / `video_meta` / `capability_mismatch` 全部落在 T2（模型）+ T3（传输）+ T7（路由）。采集模式与编码由后端决定 → `ClientCapabilities` + `cmd_set_stream_mode` 承载，默认 `video / avc`。
2. **平台可行性复核（2026-10-04）**：`camera` 0.12.1 的 plugin map 只有 android/ios/web，桌面全靠 `camera_desktop`；三个插件实现都硬编码 H.264 → HEVC 必须自接原生编码器，v1 只做能力位与降级回传，接口位在 `VideoChunkRecorder.supportedCodecs`。ffmpeg 子进程方案已废弃。
3. **类型一致性**：`StreamMode` / `VideoCodec` / `StreamSettings` 只在 T1 定义，T2 编解码、T6 录制器、T7 协调器、T8 UI 共用同一套；`CameraFailure` 子类与 `failureMessage` 只在 T5 定义、T8 消费；`AgentStatus` 字段（`streamModeLabel` / `previewEnabled` / `backendId`）在 T7 定义、T8 消费，字段名逐字一致。
4. **Review Focus**：5 条分别落在 T2+T3（畸变 JSON 丢弃 + 本地留痕 + 通道存活）、T7（锁的 finally 释放、重连全量重同步）、T6+T7（请求 HEVC 时回传实际 avc 且发 `capability_mismatch`）、T5+T8（`CameraFailure` 差异化引导）、T8（HUD 计时器重置）。
5. **比例**：代码块只保留测试与跨任务必须对齐的签名，未给出完整函数体。T5 与 T9 含实机门禁而非纯单测 —— 摄像头硬件与平台兼容性无法用单测覆盖。
