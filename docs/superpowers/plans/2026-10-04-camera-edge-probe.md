# 跨平台摄像头边缘探针客户端 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个在 Windows / macOS / Linux / iOS / Android 上统一运行的**前台 kiosk 式**摄像头客户端：启动即用本地默认参数抓帧，通过 WebSocket 上报自身能力并接受后端下发的采集参数、启停、切摄指令，把 JPEG 帧流式推送给后端 AI 模型，并展示人脸识别结果。**后端协议尚未定稿**，因此所有后端交互必须收敛在一个可整体替换的网关抽象之后。

**Architecture:** 三层隔离。① `CameraService` 接口把五平台差异收敛为两个实现：联邦插件实现覆盖 Android/iOS/Windows/macOS，ffmpeg 子进程实现覆盖 Linux（Flutter 官方无 Linux 摄像头实现）。② `BackendGateway` + `CommandCodec` 把协议隔离在一层之后，协调器只见 `ServerCommand` 领域模型、永不见 JSON，后端改协议只改 codec 一个文件。③ `AgentCoordinator` 持有单并发排他锁的采集循环、命令路由、断线状态重同步与本地自治降级。表现层为全屏预览 + 顶部状态条 + 自动淡出的识别 HUD。

**Tech Stack:** Flutter 3.x / Dart 3.x；`camera` ^0.12 + 显式 `camera_windows`；`permission_handler`；`wakelock_plus`；`web_socket_channel`；`shared_preferences`；`uuid`；Linux 侧用 `dart:io` 的 `Process` 调 ffmpeg（无需额外插件）；`flutter_test` + `mocktail`。

**Spec:** 原 `plan.md` 的 6 信令（register / heartbeat / cmd_update_config / cmd_control_stream / cmd_switch_camera / event_face_result），叠加本轮问答锁定的决策。

---

## Global Constraints

- **平台支持**：Windows、macOS、Linux、iOS、Android 单代码库全覆盖。
- **产品姿态**：前台 kiosk 应用。切后台或最小化 → 暂停抓拍 + 释放摄像头 + 断开连接；回前台 → 重建并恢复。iOS 与 Android 均**禁止**后台使用摄像头，此限制不可绕过。
- **传输**：原生 WebSocket。文本帧 = JSON 信令，二进制帧 = 裸 JPEG。**每帧二进制之前必须先发一条 `frame_meta` 文本帧**（frameId / deviceId / ts / 实际宽高 / quality）。
- **上传模式由后端决定**：`register` 上报 `ClientCapabilities`，后端据此下发 `cmd_update_config`。客户端不自行假设。
- **分辨率用绝对像素**：协议传 `width` / `height`，客户端选最接近的相机原生格式，并把**实际生效值**回传给后端。
- **采集默认值**：1280×720、1.0 FPS、JPEG 质量 80。这是本地自治起点，不是上限（帧率后端可调至 `maxFps`）。
- **后端地址**：编译期注入 `--dart-define WS_URL=`，默认 `ws://127.0.0.1:8080/ws`。
- **deviceId**：首次启动生成 UUIDv4 并持久化。
- **不商用**：不实现鉴权与 TLS。但网关必须保持可替换（接口不得泄漏 `web_socket_channel` 类型），以便后续插入 `wss://` 与 token。
- **运行时策略**：全程 Wakelock；抓拍严禁排队，前次未结束即丢帧；Windows 落盘的临时帧文件必须读完即删。
- **信令命名**：心跳类型名一律为 `heartbeat`，不是 `ping`。
- **未识别信令**：一律**本地记录**（有界环形缓冲 + 控制台输出），不回传后端、不影响连接、不打断后续帧解析。后端协议未定稿期间这是主要的排障依据。

## Platform Support Matrix

| 平台            | CameraService 实现                                                        | 本地预览 | 可用采集模式  | 备注                                                                                                       |
| ------------- | ----------------------------------------------------------------------- | ---- | ------- | -------------------------------------------------------------------------------------------------------- |
| Android / iOS | `CameraPluginService`（`camera_android_camerax` / `camera_avfoundation`） | ✅    | `still` | 官方 endorsed                                                                                              |
| Windows       | `CameraPluginService`（`camera` + 显式 `camera_windows`）                   | ✅    | `still` | `startImageStream` 抛 `UnimplementedError`，**只能 `takePicture()` 落盘再读**；release 模式有初始化崩溃 issue #161288，需实测 |
| macOS         | `CameraPluginService`（`camera_avfoundation`）                            | 待验证  | `still` | pubspec 只声明 ios，macOS 支持**未经官方承诺**，Task 5 含实测门禁，失败则降级 ffmpeg 实现                                          |
| Linux         | `FfmpegCameraService`（v4l2 via ffmpeg 子进程）                              | ❌    | `still` | Flutter 官方无 Linux 摄像头实现（flutter/flutter#41710 仍 open）；需系统预装 `ffmpeg`                                     |

## Review Focus

1. **后端下发未知 / 畸变 JSON**：codec 必须**本地记录原始报文**后返回 null —— 不抛异常、不断开连接、不打崩通道（后续合法帧仍能正常解析），且被丢弃的报文可在本地查到。
2. **断连 / 抖动**：单并发锁必须在 `finally` 释放；指数退避重连；重连成功后补发 `register` + `state_sync` 恢复状态。
3. **动态改分辨率**：异步重建摄像头管线，失败回滚旧配置，且重建期间与抓拍循环互斥，不崩。
4. **无摄像头 / 权限被拒**：显示带重试按钮的友好引导界面，不白屏、不崩溃。
5. **后端 1 秒内连推多条 `event_face_result`**：HUD 计时器刷新重置，不闪烁、不被旧定时器提前销毁。

---

## File Structure

```
lib/main.dart                                  启动组装：异常隔离、Wakelock、生命周期、依赖注入
lib/src/config/app_config.dart                 编译期常量与采集默认值
lib/src/identity/device_id_service.dart        deviceId 生成与持久化
lib/src/camera/camera_service.dart             CameraService 接口（abstract interface class）
lib/src/camera/camera_resolution.dart          CameraResolution 值对象
lib/src/camera/resolution_selector.dart        selectClosestResolution 纯函数
lib/src/camera/frame_store.dart                落盘帧读取后立即删除（Windows 磁盘回收）
lib/src/camera/camera_plugin_service.dart      camera 联邦插件实现（Android/iOS/Windows/macOS）
lib/src/camera/ffmpeg_camera_service.dart      Linux ffmpeg 子进程实现
lib/src/camera/mjpeg_frame_splitter.dart       从 mjpeg 字节流按 FFD8/FFD9 边界切帧
lib/src/backend/backend_gateway.dart           BackendGateway 接口 + ConnectionState + FrameMeta
lib/src/backend/client_signal.dart             ClientSignal 密封类（register/heartbeat/state_sync/frame_meta）
lib/src/backend/server_command.dart            ServerCommand 密封类（协调器唯一可见的命令模型）
lib/src/backend/command_codec.dart             CommandCodec 接口 + JsonCommandCodec
lib/src/backend/unrecognized_command_log.dart  未识别/畸变报文的本地留痕（有界环形缓冲）
lib/src/backend/websocket_backend_gateway.dart WebSocket 实现（心跳、退避重连、文本/二进制分流）
lib/src/backend/mock_backend_gateway.dart      内置假后端，脱机自测与演示
lib/src/agent/agent_coordinator.dart           采集循环、命令路由、状态同步、自治降级
lib/src/agent/agent_status.dart                AgentStatus 值对象（状态条数据源）
lib/src/app/lifecycle_controller.dart          生命周期 → 暂停/恢复 的纯映射与绑定
lib/src/ui/screens/agent_screen.dart           主屏（预览 + 状态条 + HUD + 错误态）
lib/src/ui/widgets/status_bar_overlay.dart     顶部半透明状态条
lib/src/ui/widgets/recognition_hud.dart        自动淡出的识别结果气泡
lib/src/ui/widgets/camera_error_view.dart      无摄像头/权限被拒的引导界面
```

创建与修改平台文件：`android/app/src/main/AndroidManifest.xml`、`ios/Runner/Info.plist`、`macos/Runner/Info.plist`、`macos/Runner/DebugProfile.entitlements`、`macos/Runner/Release.entitlements`。

---

### Task 0: 项目脚手架、依赖基线与平台权限声明

**Files:**

- Create: `pubspec.yaml`（`flutter create --project-name webcam_client --platforms=windows,macos,linux,ios,android .`）
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `ios/Runner/Info.plist`、`macos/Runner/Info.plist`、`macos/Runner/*.entitlements`

**Interfaces:**

- [ ] Produces: 包名 `webcam_client`，所有后续 import 为 `package:webcam_client/src/...`
- [ ] **Step 1: 生成脚手架**

Run: `flutter create --project-name webcam_client --platforms=windows,macos,linux,ios,android .`  
Expected: 五个平台目录齐全，`flutter doctor` 无阻塞项。

- [ ] **Step 2: 添加依赖**

Run: `flutter pub add camera camera_windows permission_handler wakelock_plus web_socket_channel shared_preferences uuid` 与 `flutter pub add dev:mocktail`

`camera_windows` **必须显式声明**（官方未 endorse）。若与 `camera` 传递的 `camera_platform_interface` 版本冲突，按 `flutter pub get` 的报错对齐版本后再继续。

- [ ] **Step 3: 声明平台权限**

Android：`CAMERA`、`INTERNET`、`WAKE_LOCK`。iOS/macOS `Info.plist`：`NSCameraUsageDescription`（用途写"采集画面用于 AI 人脸识别"）。macOS entitlements：`com.apple.security.device.camera` + `com.apple.security.network.client`。Linux：目标机预装 `ffmpeg`（`ffmpeg -version` 可返回）。

- [ ] **Step 4: 冒烟基线**

Run: `flutter test`  
Expected: PASS（仅脚手架自带测试）

- [ ] **Step 5: Commit**

```bash
git add . && git commit -m "chore: scaffold webcam_client with platform permissions"
```

---

### Task 1: 配置、设备标识、分辨率模型与选择算法

**Files:**

- Create: `lib/src/config/app_config.dart`
- Create: `lib/src/identity/device_id_service.dart`
- Create: `lib/src/camera/camera_resolution.dart`
- Create: `lib/src/camera/resolution_selector.dart`
- Test: `test/camera/resolution_selector_test.dart`
- Test: `test/identity/device_id_service_test.dart`

**Interfaces:**

- [ ] Produces:
  - `AppConfig.wsUrl: String`（`String.fromEnvironment('WS_URL', defaultValue: 'ws://127.0.0.1:8080/ws')`）
  - `AppConfig.defaultWidth = 1280`、`defaultHeight = 720`、`defaultQuality = 80`、`defaultFps = 1.0`、`heartbeatSeconds = 15`、`registerTimeoutSeconds = 5`
  - `DeviceIdService.getOrCreateDeviceId() -> Future<String>`
  - `CameraResolution({int width, int height})`，含 `pixelCount` getter
  - `CaptureConfig({int width, int height, int quality})` + `CaptureConfig.defaults()`
  - `selectClosestResolution(List<CameraResolution> available, CameraResolution target) -> CameraResolution`
- [ ] **Step 1: Write failing tests**

```dart
// test/camera/resolution_selector_test.dart
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
// test/identity/device_id_service_test.dart
void main() {
  test('returns the same id across calls and is a valid uuid v4', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = DeviceIdService();
    final first = await svc.getOrCreateDeviceId();
    final second = await svc.getOrCreateDeviceId();
    expect(first, second);
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
        .hasMatch(first), isTrue);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/camera/resolution_selector_test.dart test/identity/device_id_service_test.dart`  
Expected: FAIL with "Undefined name 'selectClosestResolution' / 'DeviceIdService'"

- [ ] **Step 3: Implement**

`selectClosestResolution` 算法（签名与测试未决定实现，故给出）：先过滤掉所有宽或高大于目标的格式（绝不放大），在剩余项中取 `pixelCount` 最大者；若过滤后为空，则取全部中 `pixelCount` 最小者。

`DeviceIdService` 用 `shared_preferences` 存 key `device_id`，缺失时用 `uuid` 的 `v4()` 生成并写回。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/camera/resolution_selector_test.dart test/identity/device_id_service_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/config lib/src/identity lib/src/camera/camera_resolution.dart lib/src/camera/resolution_selector.dart test/camera test/identity
git commit -m "feat: add app config, device id service, and resolution selection"
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

- Consumes: `CameraResolution`、`CaptureConfig` from Task 1
- Produces:
  - `sealed class ServerCommand`，子类：`UpdateConfigCommand({int? width, int? height, int? quality, double? fps})`、`ControlStreamCommand({required bool enabled})`、`SwitchCameraCommand({required int index})`、`FaceResultCommand({required FaceResult result})`
  - `FaceResult({required String name, required String status})`
  - `sealed class ClientSignal`，子类：`RegisterSignal({required String deviceId, required ClientCapabilities capabilities})`、`HeartbeatSignal({required String deviceId})`、`StateSyncSignal({required int width, required int height, required int quality, required double fps, required int cameraIndex, required bool streaming})`、`FrameMetaSignal({required FrameMeta meta})`
  - `ClientCapabilities({required String platform, required List<String> modes, required double maxFps, required bool hasPreview, required List<CameraResolution> supportedResolutions, required List<String> cameras})`
  - `FrameMeta({required int frameId, required String deviceId, required int timestampMs, required int width, required int height, required int quality})`
  - `abstract interface class CommandCodec`：`ServerCommand? decode(String raw)`、`String encode(ClientSignal signal)`
  - `enum UnrecognizedReason { malformedJson, unknownType, invalidPayload }`
  - `UnrecognizedEntry({required String raw, required UnrecognizedReason reason, required DateTime timestamp})`
  - `UnrecognizedCommandLog({int capacity = 50, void Function(String message)? sink})`：`List<UnrecognizedEntry> get entries`（最旧 → 最新的不可变视图）、`int get droppedCount`、`void record(String raw, UnrecognizedReason reason)`、`void clear()`
  - `JsonCommandCodec({UnrecognizedCommandLog? unrecognizedLog})` — 未传入时自建默认实例（`capacity = 50`、`sink` 默认 `debugPrint`）。**被丢弃的报文只进这个 log，不回传后端。**


- [ ] **Step 1: Write failing tests**

```dart
// test/backend/command_codec_test.dart
void main() {
  final codec = JsonCommandCodec();

  test('decodes cmd_update_config with absolute pixels', () {
    final cmd = codec.decode(
        '{"type":"cmd_update_config","payload":{"width":1920,"height":1080,"quality":90,"fps":5}}');
    expect(cmd, isA<UpdateConfigCommand>());
    final u = cmd! as UpdateConfigCommand;
    expect(u.width, 1920);
    expect(u.height, 1080);
    expect(u.quality, 90);
    expect(u.fps, 5.0);
  });

  test('decodes partial config leaving unspecified fields null', () {
    final u = codec.decode('{"type":"cmd_update_config","payload":{"fps":2}}')! as UpdateConfigCommand;
    expect(u.fps, 2.0);
    expect(u.width, isNull);
  });

  test('decodes event_face_result', () {
    final cmd = codec.decode(
        '{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}');
    expect(cmd, isA<FaceResultCommand>());
    expect((cmd! as FaceResultCommand).result.name, '张三');
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
    final c = JsonCommandCodec(unrecognizedLog: log);
    final raw = '{"type":"cmd_do_a_backflip","payload":{"x":1}}';
    expect(c.decode(raw), isNull);
    expect(log.entries.single.reason, UnrecognizedReason.unknownType);
    expect(log.entries.single.raw, raw);
    expect(log.entries.single.timestamp, isA<DateTime>());
  });

  test('records payloads with hostile field types instead of throwing', () {
    final log = UnrecognizedCommandLog(sink: null);
    final c = JsonCommandCodec(unrecognizedLog: log);
    expect(c.decode('{"type":"cmd_update_config","payload":{"width":"banana","fps":null}}'), isNull);
    expect(log.entries.single.reason, UnrecognizedReason.invalidPayload);
  });

  test('does not record well-formed commands', () {
    final log = UnrecognizedCommandLog(sink: null);
    final c = JsonCommandCodec(unrecognizedLog: log);
    c.decode('{"type":"cmd_control_stream","payload":{"enabled":false}}');
    c.decode('{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}');
    expect(log.entries, isEmpty);
  });

  test('encodes register with capabilities', () {
    final raw = codec.encode(RegisterSignal(
      deviceId: 'dev-1',
      capabilities: ClientCapabilities(
        platform: 'windows', modes: const ['still'], maxFps: 10, hasPreview: true,
        supportedResolutions: const [CameraResolution(width: 1280, height: 720)],
        cameras: const ['0'],
      ),
    ));
    final map = jsonDecode(raw) as Map<String, dynamic>;
    expect(map['type'], 'register');
    expect(map['payload']['deviceId'], 'dev-1');
    expect(map['payload']['capabilities']['modes'], ['still']);
    expect(map['payload']['capabilities']['hasPreview'], true);
  });

  test('encodes heartbeat with the agreed type name', () {
    expect(jsonDecode(codec.encode(HeartbeatSignal(deviceId: 'dev-1')))['type'], 'heartbeat');
  });
}
```

```dart
// test/backend/unrecognized_command_log_test.dart
void main() {
  test('is bounded and keeps the newest entries', () {
    final log = UnrecognizedCommandLog(capacity: 3, sink: null);
    for (var i = 0; i < 5; i++) {
      log.record('raw-$i', UnrecognizedReason.unknownType);
    }
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
    final log = UnrecognizedCommandLog(sink: messages.add);
    log.record('{"type":"nope"}', UnrecognizedReason.unknownType);
    expect(messages.single, contains('unknownType'));
    expect(messages.single, contains('nope'));
  });

  test('clear resets entries and keeps the dropped counter readable', () {
    final log = UnrecognizedCommandLog(sink: null);
    log.record('a', UnrecognizedReason.malformedJson);
    log.clear();
    expect(log.entries, isEmpty);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/backend/command_codec_test.dart test/backend/unrecognized_command_log_test.dart`
Expected: FAIL with "Undefined name 'JsonCommandCodec' / 'UnrecognizedCommandLog'"

- [ ] **Step 3: Implement**

`decode` 全程包在 try/catch 内，三类失败**都返回 `null`、都记一条本地留痕、都绝不抛出也不断连**：JSON 解析失败 → `UnrecognizedReason.malformedJson`；`type` 缺失或不在已知集合 → `unknownType`；JSON 合法但字段类型不可用（如 `width` 是字符串）→ `invalidPayload`。数值字段用宽松解析（非数字或越界的 quality 视为未提供）。

`UnrecognizedCommandLog` 是有界环形缓冲：`raw` 入库前截断到 512 字符，超过 `capacity` 时丢弃最旧的并 `droppedCount++`，默认 `sink` 为 `debugPrint`（测试传 `null` 静音）。**它只写本地，绝不回传后端。** `encode` 输出 UTF-8 JSON 字符串，行为不受 log 影响。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/backend/command_codec_test.dart test/backend/unrecognized_command_log_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend test/backend
git commit -m "feat: add server command model, fault-tolerant json codec, and unrecognized command log"
```

---

### Task 3: BackendGateway 接口与 WebSocket 实现

**Files:**

- Create: `lib/src/backend/backend_gateway.dart`
- Create: `lib/src/backend/websocket_backend_gateway.dart`
- Test: `test/backend/websocket_backend_gateway_test.dart`

**Interfaces:**

- [ ] Consumes: `CommandCodec`、`ClientSignal`、`ServerCommand`、`FrameMeta` from Task 2
- [ ] Produces:
  - `enum ConnectionState { connected, reconnecting, offline }`
  - `abstract interface class BackendGateway`：`Future<void> connect(String url)`、`Future<void> disconnect()`、`void sendSignal(ClientSignal signal)`、`void sendFrameMeta(FrameMeta meta)`、`void sendFrameBytes(Uint8List bytes)`、`Stream<ServerCommand> get commands`、`Stream<ConnectionState> get connectionChanges`、`bool get isConnected`、`UnrecognizedCommandLog get unrecognizedCommands`（透传 codec 的本地留痕）
  - `WebSocketBackendGateway({required CommandCodec codec, required WebSocketChannelFactory channelFactory, Duration? heartbeatInterval})`
  - `typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri)`（**注入点**，测试与后续换 wss 都靠它）
  - `Duration backoffFor(int attempt)` — 纯函数：1s、2s、4s、8s、16s，之后封顶 16s
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
    final sink = FakeSink();
    final gw = WebSocketBackendGateway(codec: JsonCommandCodec(),
        channelFactory: (_) => _FakeChannel(incoming.stream, sink));
    await gw.connect('ws://x');
    incoming.add('{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}');
    await expectLater(gw.commands, emits(isA<FaceResultCommand>()));
  });

  test('malformed frame is recorded locally and the channel survives the next valid frame',
      () async {
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

  test('sendFrameMeta then sendFrameBytes emits text before binary', () async {
    final sink = FakeSink();
    final gw = WebSocketBackendGateway(codec: JsonCommandCodec(),
        channelFactory: (_) => _FakeChannel(const Stream.empty(), sink));
    await gw.connect('ws://x');
    gw.sendFrameMeta(FrameMeta(frameId: 7, deviceId: 'd', timestampMs: 1,
        width: 1280, height: 720, quality: 80));
    gw.sendFrameBytes(Uint8List.fromList([1, 2, 3]));
    expect(sink.records.length, 2);
    expect(sink.records.first, isA<String>());
    expect(jsonDecode(sink.records.first as String)['type'], 'frame_meta');
    expect(sink.records.last, isA<Uint8List>());
  });

  test('backoff grows and caps at 16 seconds', () {
    expect(backoffFor(0), const Duration(seconds: 1));
    expect(backoffFor(1), const Duration(seconds: 2));
    expect(backoffFor(2), const Duration(seconds: 4));
    expect(backoffFor(5), const Duration(seconds: 16));
    expect(backoffFor(99), const Duration(seconds: 16));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/backend/websocket_backend_gateway_test.dart`  
Expected: FAIL with "Undefined name 'WebSocketBackendGateway'"

- [ ] **Step 3: Implement**

`data is String` → `codec.decode` → 非 null 才推入 `commands`；`data is List<int>` → 客户端当前不消费下行二进制，忽略。心跳按 `heartbeatSeconds` 定时发 `HeartbeatSignal`。连接断开（`done` 完成或 `onError`）→ 推 `reconnecting` 并按 `backoffFor(attempt)` 退避重试，成功后 attempt 归零、推 `connected`。**对外不暴露 `WebSocketChannel` 类型**，只暴露 `WebSocketChannelFactory`。

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

- [ ] Consumes: `BackendGateway`、`CommandCodec` from Task 3
- [ ] Produces: `MockBackendGateway({Duration? commandInterval})` — 定时下发 `UpdateConfigCommand` 与 `FaceResultCommand`，`sendFrameBytes` 只做计数
- [ ] **Step 1: Write failing test**

```dart
// test/backend/mock_backend_gateway_test.dart
void main() {
  test('emits an update config command and a face result on cue', () async {
    final gw = MockBackendGateway(commandInterval: const Duration(milliseconds: 1));
    await gw.connect('ws://mock');
    await expectLater(gw.commands,
        emitsThrough(predicate<ServerCommand>((c) => c is UpdateConfigCommand)));
    await expectLater(gw.commands,
        emitsThrough(predicate<ServerCommand>((c) => c is FaceResultCommand)));
    expect(gw.isConnected, isTrue);
  });

  test('counts frames it would have sent', () async {
    final gw = MockBackendGateway();
    await gw.connect('ws://mock');
    gw.sendFrameBytes(Uint8List.fromList([1, 2, 3]));
    gw.sendFrameBytes(Uint8List.fromList([4, 5, 6]));
    expect(gw.frameCount, 2);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/backend/mock_backend_gateway_test.dart`  
Expected: FAIL with "Undefined name 'MockBackendGateway'"

- [ ] **Step 3: Implement**

内部 `StreamController<ServerCommand>.broadcast()` + `Timer.periodic`。帧计数用 `int frameCount` getter。不碰真实网络。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/backend/mock_backend_gateway_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend/mock_backend_gateway.dart test/backend/mock_backend_gateway_test.dart
git commit -m "feat: add mock backend gateway for offline development"
```

---

### Task 5: CameraService 接口与联邦插件实现

**Files:**

- Create: `lib/src/camera/camera_service.dart`
- Create: `lib/src/camera/frame_store.dart`
- Create: `lib/src/camera/camera_plugin_service.dart`
- Test: `test/camera/frame_store_test.dart`
- Test: `test/camera/camera_plugin_service_test.dart`

**Interfaces:**

- Consumes: `CameraResolution`、`CaptureConfig`、`selectClosestResolution` from Task 1
- Produces:
  - `abstract interface class CameraService`：`Future<void> initialize({required CaptureConfig config})`、`Future<void> reconfigure(CaptureConfig config)`、`Future<void> switchCamera(int index)`、`Future<Uint8List?> captureFrame(int quality)`、`Future<void> release()`、`Widget? buildPreview()`、`String get cameraName`、`bool get isInitialized`、`CameraResolution get appliedResolution`、`List<String> get availableCameras`、`List<CameraResolution> get supportedResolutions`、`bool get hasPreview`
  - `CameraPluginService implements CameraService({FrameStore? frameStore})`
  - `abstract interface class FrameStore`：`Future<Uint8List> readAndDelete(String path)`；默认实现 `IoFrameStore`


- [ ] **Step 1: Write failing tests**

```dart
// test/camera/frame_store_test.dart
void main() {
  test('reads bytes then removes the file so nothing accumulates', () async {
    final dir = await Directory.systemTemp.createTemp('probe');
    final f = File(p.join(dir.path, 'frame.jpg'))..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9]);
    final bytes = await const IoFrameStore().readAndDelete(f.path);
    expect(bytes, [0xFF, 0xD8, 1, 0xFF, 0xD9]);
    expect(f.existsSync(), isFalse);
  });

  test('still deletes when the read fails', () async {
    final dir = await Directory.systemTemp.createTemp('probe');
    final p2 = p.join(dir.path, 'missing.jpg');
    await expectLater(const IoFrameStore().readAndDelete(p2), throwsA(isA<Exception>()));
  });
}
```

```dart
// test/camera/camera_plugin_service_test.dart
class FakeFrameStore implements FrameStore {
  int calls = 0;
  @override
  Future<Uint8List> readAndDelete(String path) async {
    calls++;
    return Uint8List.fromList([9]);
  }
}

void main() {
  test('captureFrame deletes the temp file it just read', () async {
    final store = FakeFrameStore();
    final svc = CameraPluginService(frameStore: store);
    final bytes = await svc.grabVia(store, '/tmp/frame.jpg');
    expect(bytes, [9]);
    expect(store.calls, 1);
  });

  test('applied resolution reports what the selector chose, not what was asked', () {
    // 用注入的 supportedResolutions 验证：请求 1000x700 时 appliedResolution 为 640x480
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/camera/frame_store_test.dart test/camera/camera_plugin_service_test.dart`  
Expected: FAIL with "Undefined name 'IoFrameStore' / 'CameraPluginService'"

- [ ] **Step 3: Implement**

`CameraService` 用 `abstract interface class`（可被 mocktail `implements`，**且不可被实例化**）。`CameraPluginService` 封装 `CameraController`：`reconfigure` 与 `switchCamera` 必须先 `await _lock.synchronized(...)`，再 `dispose()` 旧 controller 并用 `selectClosestResolution` 挑格式后重建；重建抛异常则回滚到上一份 `CaptureConfig` 并保留 `isInitialized == true`。**Windows 路径只有 `takePicture()`**——`captureFrame` 固定走 `takePicture()` → `FrameStore.readAndDelete(x.path)`，落盘文件读完立刻删除，`initialize` 时清理残留 `probe_frame_*.jpg`。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/camera/frame_store_test.dart test/camera/camera_plugin_service_test.dart`  
Expected: PASS

- [ ] **Step 5: macOS 实测门禁（不可跳过）**

Run: `flutter run -d macos`  
Expected: 预览出画 + 抓拍成功。**`camera_avfoundation` 的 pubspec 只声明 ios，macOS 支持未经官方承诺**。若预览或 `takePicture` 在 macOS 失败：把 macOS 切到 `FfmpegCameraService`（macOS 可用 `brew install ffmpeg`），并在 Platform Support Matrix 中把 macOS 的"本地预览"改为 ❌。把实测结论写进 commit message。

- [ ] **Step 6: Commit**

```bash
git add lib/src/camera test/camera
git commit -m "feat: add camera service interface and federated plugin implementation"
```

---

### Task 6: FfmpegCameraService（Linux）

**Files:**

- Create: `lib/src/camera/mjpeg_frame_splitter.dart`
- Create: `lib/src/camera/ffmpeg_camera_service.dart`
- Test: `test/camera/mjpeg_frame_splitter_test.dart`

**Interfaces:**

- [ ] Consumes: `CameraService` from Task 5
- [ ] Produces: `FfmpegCameraService implements CameraService({String device = '/dev/video0', int? targetFps})`；`hasPreview == false`，`buildPreview()` 返回 `null`；`MjpegFrameSplitter`
- [ ] **Step 1: Write failing test**

```dart
// test/camera/mjpeg_frame_splitter_test.dart
void main() {
  test('splits a chunked mjpeg stream on SOI/EOI boundaries', () {
    final frame1 = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
    final frame2 = Uint8List.fromList([0xFF, 0xD8, 4, 5, 0xFF, 0xD9]);
    final out = <Uint8List>[];
    final splitter = MjpegFrameSplitter();
    // 第一帧完整 + 第二帧被切断在中间
    splitter.consume(Uint8List.fromList([...frame1, ...frame2.sublist(0, 3)]), out.add);
    expect(out.length, 1);
    splitter.consume(frame2.sublist(3), out.add);
    expect(out.length, 2);
    expect(out.last, frame2);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/camera/mjpeg_frame_splitter_test.dart`  
Expected: FAIL with "Undefined name 'MjpegFrameSplitter'"

- [ ] **Step 3: Implement**

`FfmpegCameraService.initialize` 启动 `ffmpeg -f v4l2 -input_format mjpeg -video_size WxH -i /dev/video0 -f image2pipe -vcodec copy -`，把 stdout 字节喂给 `MjpegFrameSplitter`，最新一帧存入 `_latest`；`captureFrame` 直接返回 `_latest` 快照。`release()` 杀掉子进程并清理。`supportedResolutions` 用 `v4l2-ctl --list-formats-ext` 解析，解析失败时回退为单个设备默认分辨率。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/camera/mjpeg_frame_splitter_test.dart`  
Expected: PASS

- [ ] **Step 5: Linux 实测门禁**

Run: `flutter run -d linux`  
Expected: 无预览（黑屏占位属预期），抓拍帧字节数 > 0 且能被后端/假后端接收。

- [ ] **Step 6: Commit**

```bash
git add lib/src/camera/mjpeg_frame_splitter.dart lib/src/camera/ffmpeg_camera_service.dart test/camera/mjpeg_frame_splitter_test.dart
git commit -m "feat: add ffmpeg-backed camera service for linux"
```

---

### Task 7: AgentCoordinator（采集循环、命令路由、状态同步、自治降级）

**Files:**

- Create: `lib/src/agent/agent_status.dart`
- Create: `lib/src/agent/agent_coordinator.dart`
- Test: `test/agent/agent_coordinator_test.dart`

**Interfaces:**

- [ ] Consumes: `CameraService`(T5/T6)、`BackendGateway`(T3/T4)、`DeviceIdService`(T1)、`CaptureConfig`(T1)
- [ ] Produces:
  - `AgentCoordinator({required CameraService cameraService, required BackendGateway gateway, required DeviceIdService deviceIdService, CaptureConfig? initialConfig})`
  - `Future<void> start()`、`void stop()`、`Future<void> pause()`、`Future<void> resume()`
  - `Future<void> performCaptureTick()`（**测试入口**）
  - `double get currentFps`、`CaptureConfig get currentConfig`、`bool get isStreaming`、`bool get isAutonomous`、`String get cameraName`
  - `Stream<FaceResult> get onFaceResult`、`Stream<double> get onFpsUpdate`、`Stream<AgentStatus> get onStatus`
  - `UnrecognizedCommandLog get unrecognizedCommands`（透传自 `BackendGateway`，供调试读取与可选 UI 展示）
  - `AgentStatus({required ConnectionState connection, required double fps, required String cameraName, required bool streaming, required bool autonomous, required String resolutionLabel})`
- [ ] **Step 1: Write failing tests**

```dart
// test/agent/agent_coordinator_test.dart
class MockCameraService extends Mock implements CameraService {}
class MockBackendGateway extends Mock implements BackendGateway {}
class MockDeviceIdService extends Mock implements DeviceIdService {}

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

  test('re-syncs state after a reconnect', () async {
    final gw = MockBackendGateway();
    final co = _build(MockCameraService(), gw);
    co.onGatewayConnectionChanged(ConnectionState.connected);
    await pumpEventQueue();
    verify(() => gw.sendSignal(any(that: isA<RegisterSignal>()))).called(greaterThan(0));
    verify(() => gw.sendSignal(any(that: isA<StateSyncSignal>()))).called(1);
  });

  test('goes autonomous when no command arrives within the register timeout', () async {
    final gw = MockBackendGateway();
    final co = _build(MockCameraService(), gw,
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

`performCaptureTick()`：`if (!_streaming || !camera.isInitialized || _isUploading) return;` → `_isUploading = true` → `try { frame = await camera.captureFrame(quality); if (frame == null) return; gateway.sendFrameMeta(...); gateway.sendFrameBytes(frame); _framesInWindow++; } catch (_) {} finally { _isUploading = false; }`。


`_isUploading` 的置位必须在任何 `await` 之前完成，否则丢帧判定失效。

命令路由订阅 `gateway.commands`。**未识别报文在 codec 层已被丢弃并留痕，永远到不了这里**，协调器只做透传：`unrecognizedCommands` 直接返回 `gateway.unrecognizedCommands`，不额外处理、不回传后端。`UpdateConfigCommand` 更新 `CaptureConfig` → 调 `camera.reconfigure()` → 重启采集定时器 → 把**实际生效分辨率**（`camera.appliedResolution`）写入 `AgentStatus` 并回传后端。`onFpsUpdate` 每秒统计上一窗口内实际发出的帧数（不是配置帧率）。`start()` 立即按本地默认配置开跑，不等后端；`register` 后若 `registerTimeoutSeconds` 内无任何命令 → `isAutonomous = true`，此后每 15s 重发一次 `register` 直到收到首条命令。`pause()` 取消定时器 + `camera.release()` + `gateway.disconnect()`；`resume()` 反向恢复。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/agent/agent_coordinator_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/agent test/agent
git commit -m "feat: add agent coordinator with in-flight lock, routing, and autonomy"
```

---

### Task 8: 表现层 UI

**Files:**

- Create: `lib/src/ui/widgets/recognition_hud.dart`
- Create: `lib/src/ui/widgets/status_bar_overlay.dart`
- Create: `lib/src/ui/widgets/camera_error_view.dart`
- Create: `lib/src/ui/screens/agent_screen.dart`
- Test: `test/ui/recognition_hud_test.dart`
- Test: `test/ui/status_bar_overlay_test.dart`
- Test: `test/ui/camera_error_view_test.dart`

**Interfaces:**

- [ ] Consumes: `AgentCoordinator`、`AgentStatus`(T7)、`FaceResult`(T2)、`CameraService.buildPreview()`(T5)
- [ ] Produces: `AgentScreen({required AgentCoordinator coordinator})`；`StatusBarOverlay({required AgentStatus status})`；`RecognitionHud({required FaceResult result})`；`CameraErrorView({required String message, required VoidCallback onRetry})`
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

  testWidgets('a second result resets the dismiss timer instead of being cut short',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
        body: RecognitionHud(result: FaceResult(name: '张三', status: 'approved')))));
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
        body: RecognitionHud(result: FaceResult(name: '李四', status: 'rejected')))));
    await tester.pump(const Duration(milliseconds: 2000)); // 距首帧已 4s，但计时器已重置
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
  testWidgets('renders connection, fps, resolution and autonomy flag', (tester) async {
    const status = AgentStatus(connection: ConnectionState.connected, fps: 2.0,
        cameraName: 'Integrated Camera', streaming: true, autonomous: true,
        resolutionLabel: '1280x720');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StatusBarOverlay(status: status))));
    expect(find.textContaining('1280x720'), findsOneWidget);
    expect(find.textContaining('Integrated Camera'), findsOneWidget);
    expect(find.textContaining('2.0'), findsOneWidget);
    expect(find.textContaining('自治'), findsOneWidget);
  });
}
```

```dart
// test/ui/camera_error_view_test.dart
void main() {
  testWidgets('shows guidance and forwards retry taps', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: CameraErrorView(message: '未检测到摄像头', onRetry: () => tapped++))));
    expect(find.textContaining('未检测到摄像头'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(tapped, 1);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/ui`  
Expected: FAIL with "Undefined name 'RecognitionHud'"

- [ ] **Step 3: Implement**

`RecognitionHud` 关键实现约束：内置 `Timer` 3 秒后置 `_visible = false` 并 `setState`，`build` 在 `!_visible` 时**返回 `SizedBox.shrink()`**（`AnimatedOpacity` 只改 opacity 会让测试里的 `findsNothing` 永远不成立，且真实场景会残留不可见 widget）。`didUpdateWidget` 检测到 `result` 变化时**取消旧 Timer 并重启**。状态映射：`approved`→识别成功，`rejected`/`denied`→识别失败，其余→未识别。

`AgentScreen` 用 `Stack` 叠放：底层 `cameraService.buildPreview()`（为 `null` 时显示"本机无预览"占位）、顶部 `StatusBarOverlay`、居中靠下 `RecognitionHud`；`cameraService.isInitialized == false` 或初始化抛异常时整屏切到 `CameraErrorView`（带"重试"按钮，点击重新 `initialize`）。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/ui`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/ui test/ui
git commit -m "feat: add kiosk UI with status overlay, recognition hud, and error state"
```

---

### Task 9: 启动组装、Wakelock、生命周期与全局异常隔离

**Files:**

- Create: `lib/src/app/lifecycle_controller.dart`
- Create: `lib/main.dart`
- Create: `lib/src/app/platform_camera_factory.dart`
- Test: `test/app/lifecycle_controller_test.dart`
- Test: `test/app/bootstrap_test.dart`

**Interfaces:**

- [ ] Consumes: 全部 T1–T8
- [ ] Produces: `bool shouldPauseFor(AppLifecycleState state)`；`CameraService createPlatformCameraService()`（按 `Platform` 选 `CameraPluginService` 或 `FfmpegCameraService`）
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
    expect(AppConfig.defaultFps, greaterThan(0));
    expect(AppConfig.heartbeatSeconds, 15);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/app`  
Expected: FAIL with "Undefined name 'shouldPauseFor'"

- [ ] **Step 3: Implement**

`shouldPauseFor`：`inactive` 在桌面端表示"窗口可见但失焦"，kiosk 场景必须继续推流，故不暂停；`hidden`（最小化）与 `paused`/`detached` 才暂停。

`main()`：`WidgetsFlutterBinding.ensureInitialized()` → `FlutterError.onError` + `runZonedGuarded` 捕获全局异常并记录（绝不静默吞掉也绝不让应用白屏退出）→ `WakelockPlus.enable()` → `createPlatformCameraService()` → 组装 `DeviceIdService` / `BackendGateway`（`--dart-define USE_MOCK_BACKEND=true` 时切 `MockBackendGateway`）→ `AgentCoordinator` → `runApp(AgentApp())`，并把 `LifecycleController` 挂到 `WidgetsBindingObserver`。

未识别报文的 `UnrecognizedCommandLog` 在组装时把 `sink` 接到应用级日志（复用同一个 `runZonedGuarded` 的日志出口），这样后端下发未定义指令时能直接在控制台/`flutter logs` 里看到原始报文与原因，而**不需要改代码或抓包**。

- [ ] **Step 4: Run full suite**

Run: `flutter test`  
Expected: ALL PASS

- [ ] **Step 5: 全平台冒烟门禁**

Run each: `flutter run -d windows` / `-d macos` / `-d linux` / `-d android` / `-d ios`  
Expected 每项：预览（Linux 除外）出画、状态条显示 `自治`、抓拍帧被假后端计数（`--dart-define USE_MOCK_BACKEND=true`）、切后台后抓拍停止、回前台恢复。

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/src/app test/app
git commit -m "feat: wire bootstrap, wakelock, lifecycle handling, and platform factory"
```

---

## Self-Review Checklist

1. **Spec 覆盖**：6 个原始信令全部落在 T2（模型）+ T3（传输）+ T7（路由）；新增 `state_sync` 与 `frame_meta` 解决原方案的帧归属与重连漂移。上传模式由后端决定 → 由 `ClientCapabilities` + `cmd_update_config` 承载。
2. **原方案 8 条硬伤**：Linux 无实现（T6 补 ffmpeg 实现）；Windows 无图像流（T5 固定走 `takePicture` + 落盘即删）；`ResolutionPreset` 相对档位错误（T1 改绝对像素 + `selectClosestResolution`）；抽象类被实例化（T5 改 `abstract interface class`）；`ping`/`heartbeat` 不一致（T2/T3 统一为 `heartbeat`）；无脚手架（T0）；`onFpsUpdate` 只声明不实现（T7 定义为实际窗口帧率）；HUD `findsNothing` 不可能成立（T8 改为条件卸载）。另补：重连不重同步（T7 `StateSyncSignal`）、重初始化与抓拍无互斥（T5 串行锁）、无全局异常隔离（T9）。
3. **类型一致性**：`CaptureConfig` / `CameraResolution` 只在 T1 定义一次；`ServerCommand` 子类名在 T2 定义、T7 路由与 T8 HUD 使用同一套；`FrameMeta` 只在 T2 定义、T3 与 T7 共用；`UnrecognizedReason` / `UnrecognizedEntry` / `UnrecognizedCommandLog` 只在 T2 定义，T3 网关与 T7 协调器逐级透传、不重新定义；`AgentStatus` 字段（`fps` / `cameraName` / `resolutionLabel` / `autonomous`）在 T7 定义、T8 消费，字段名逐字一致。
4. **Review Focus**：5 条分别落在 T2（畸变 JSON：丢弃 + 本地留痕，含"通道活着"断言）、T3（网关层同样不崩且留痕）、T7（锁的 finally 释放与重连重同步）、T5（分辨率回滚与重建互斥）、T8（`CameraErrorView`）、T8（HUD 计时器重置），每条都有对应断言。
5. **比例**：代码块只保留测试与跨任务必须对齐的签名，未给出完整函数体（除 `selectClosestResolution` 与 `MjpegFrameSplitter` 这类签名无法决定的算法）。
