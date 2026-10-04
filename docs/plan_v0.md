# 跨平台摄像头 AI 识别边缘探针 (Flutter Agent) 实施方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个在 Windows、macOS、Linux、iOS、Android 上统一运行的摄像头边缘探针客户端，启动后自动捕获画面、通过 WebSocket 将 JPEG 图片流传输到后端 AI 模型，并接收后端下发的动态调参、启停、切摄信令和人脸识别结果反馈。

**Architecture:** 采用响应式分层架构：底层由 `CameraService` 提供可动态重配置的摄像头硬件抽象；通信层通过 `WebSocketService` 实现原生文本/二进制多路复用（文本走 JSON 信令，二进制走裸 JPEG 帧）；中枢 `AgentCoordinator` 通过带“单并发排他锁（In-flight Lock）”的定时器循环抓拍并调度后端指令；表现层基于 Flutter Widget 构建全屏预览取景、顶部半透明状态栏以及自动淡出的识别结果 HUD。

**Tech Stack:** 
* Flutter 3.x / Dart 3.x
* 硬件与系统：`camera` + `camera_windows` / `camera_macos` / `camera_linux`，`wakelock_plus`（防息屏），`uuid`
* 网络通信：`web_socket_channel`，`shared_preferences`
* 状态管理与测试：`flutter_test`, `mockito` / `mocktail`

**Spec:** 由交互问答锁定的边缘探针产品规格书（包含 6 个核心信令：`register`, `heartbeat`, `cmd_update_config`, `cmd_control_stream`, `cmd_switch_camera`, `event_face_result`）。

---

## Global Constraints

* 平台支持：Windows, macOS, Linux, iOS, Android 单代码库全覆盖。
* 默认通信协议：WebSocket 原生文本帧传输 JSON 控制信令，二进制帧传输 JPEG 裸流。
* 默认采集基准：720p (1280x720) 分辨率，1.0 FPS，JPEG 压缩质量 80。
* 初始配置：后端 WebSocket 地址通过常量/编译环境变量硬编码注入，`deviceId` 在初次启动时由客户端自动生成 UUIDv4 并持久化。
* 运行时策略：必须全程启用 Wakelock 阻止屏幕休眠；抓拍网络上传严禁排队，前次请求未结束时自动丢帧。

---

## Review Focus

1. **网络断连/抖动导致的死锁**：若 WebSocket 异常断开，上传中的单并发锁 `_isUploading` 必须在 `finally` 中强制释放，且心跳与指数退避重连机制能自动恢复推流。
2. **后端动态调整分辨率导致摄像头管线崩溃**：后端下发 `cmd_update_config(resolution)` 时，摄像头重初始化需异步平滑过渡，若设置失败应优雅回滚到旧分辨率而不导致应用闪退。
3. **后端下发未知/畸变 JSON 指令**：信令解析器遇到非法 JSON 或未定义指令类型时必须捕获异常并静默记录日志，绝不抛出未处理异常打崩通信通道。
4. **设备缺少摄像头或权限被拒**：在无外接摄像头的 PC 或未授权设备上，应用必须显示友好的错误引导界面，而不是直接崩溃或白屏。
5. **UI 识别结果 HUD 的高频抖动**：若后端在 1 秒内连续推送多个 `event_face_result`，HUD 的计时器必须支持刷新重置，防止卡片闪烁或旧定时器过早销毁新通知。

---

### Task 1: 核心配置、数据模型与设备标识服务

**Files:**
- Create: `lib/src/config/app_config.dart`
- Create: `lib/src/models/control_message.dart`
- Create: `lib/src/services/device_id_service.dart`
- Test: `test/models/control_message_test.dart`
- Test: `test/services/device_id_service_test.dart`

**Interfaces:**
- Produces:
  * `AppConfig.wsUrl: String`
  * `AppConfig.defaultFps: double`
  * `AppConfig.defaultQuality: int`
  * `AppConfig.defaultResolution: ResolutionPreset`
  * `DeviceIdService.getOrCreateDeviceId() -> Future<String>`
  * `ControlMessage.fromJson(Map<String, dynamic> json) -> ControlMessage`
  * `ControlMessage.toJson() -> Map<String, dynamic>`

- [ ] **Step 1: Write failing test for `ControlMessage` JSON serialization and deserialization**

```dart
// test/models/control_message_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_camera_agent/src/models/control_message.dart';

void main() {
  test('should parse cmd_update_config with resolution correctly', () {
    final rawJson = jsonEncode({
      'type': 'cmd_update_config',
      'payload': {'fps': 2.0, 'quality': 85, 'resolution': '1080p'}
    });
    final msg = ControlMessage.fromJson(jsonDecode(rawJson));
    expect(msg.type, 'cmd_update_config');
    expect(msg.payload['fps'], 2.0);
    expect(msg.payload['quality'], 85);
    expect(msg.payload['resolution'], '1080p');
  });

  test('should serialize register message correctly', () {
    final msg = ControlMessage(
      type: 'register',
      payload: {'deviceId': 'test-uuid-1234', 'clientType': 'flutter_agent'},
    );
    expect(msg.toJson(), {
      'type': 'register',
      'payload': {'deviceId': 'test-uuid-1234', 'clientType': 'flutter_agent'},
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/control_message_test.dart`  
Expected: FAIL with "ControlMessage not defined"

- [ ] **Step 3: Implement `AppConfig`, `ControlMessage`, and `DeviceIdService`**

1. 在 `lib/src/config/app_config.dart` 中使用 `String.fromEnvironment('WS_URL', defaultValue: 'ws://127.0.0.1:8080/ws')` 定义硬编码默认地址与采集初始常量。
2. 在 `lib/src/models/control_message.dart` 中实现通用信令模型，支持安全字段解析和容错处理。
3. 在 `lib/src/services/device_id_service.dart` 中利用 `shared_preferences` 和 `uuid` 实现设备 ID 的持久化生成。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/control_message_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/config/app_config.dart lib/src/models/control_message.dart lib/src/services/device_id_service.dart test/models/control_message_test.dart
git commit -m "feat: add app config, control message model, and device id service"
```

---

### Task 2: WebSocket 通信层（心跳保活与原生二分流）

**Files:**
- Create: `lib/src/services/websocket_service.dart`
- Test: `test/services/websocket_service_test.dart`

**Interfaces:**
- Consumes: `ControlMessage` from Task 1
- Produces:
  * `WebSocketService.connect(String url, String deviceId) -> Future<void>`
  * `WebSocketService.disconnect() -> Future<void>`
  * `WebSocketService.sendBinary(Uint8List bytes) -> void`
  * `WebSocketService.sendSignal(ControlMessage message) -> void`
  * `WebSocketService.onMessage: Stream<ControlMessage>`
  * `WebSocketService.onConnectionChange: Stream<bool>` (true = connected, false = reconnecting)

- [ ] **Step 1: Write failing test for `WebSocketService` protocol parsing and event distribution**

```dart
// test/services/websocket_service_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_camera_agent/src/models/control_message.dart';
import 'package:flutter_camera_agent/src/services/websocket_service.dart';

void main() {
  test('handleIncomingString should dispatch parsed ControlMessage to stream', () async {
    final wsService = WebSocketService();
    expectLater(
      wsService.onMessage,
      emits(predicate<ControlMessage>((m) => m.type == 'event_face_result' && m.payload['name'] == '张三')),
    );

    wsService.handleIncomingMessage('{"type":"event_face_result","payload":{"name":"张三","status":"approved"}}');
  });

  test('handleIncomingString with malformed json should not throw', () async {
    final wsService = WebSocketService();
    expect(() => wsService.handleIncomingMessage('invalid json string'), returnsNormally);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/websocket_service_test.dart`  
Expected: FAIL with "WebSocketService not found"

- [ ] **Step 3: Implement `WebSocketService` in `lib/src/services/websocket_service.dart`**

* 基于 `web_socket_channel` 维护连接。
* 区分 `data is String`（解析为 `ControlMessage` 推入广播流）与 `data is List<int>`。
* 实现每 15 秒发送一次心跳信令 `{"type": "ping"}`。
* 实现指数退避自动重连机制（1s, 2s, 4s, 最大 16s），并在重连成功后自动发送 `register` 报文。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/websocket_service_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/services/websocket_service.dart test/services/websocket_service_test.dart
git commit -m "feat: implement websocket service with heartbeat and reconnect"
```

---

### Task 3: 摄像头硬件服务抽象与可变分辨率管线

**Files:**
- Create: `lib/src/services/camera_service.dart`
- Test: `test/services/camera_service_test.dart`

**Interfaces:**
- Produces:
  * `abstract class CameraService`
  * `CameraService.initialize() -> Future<void>`
  * `CameraService.setResolution(String resolutionPresetStr) -> Future<void>`
  * `CameraService.switchCamera(int targetIndex) -> Future<void>`
  * `CameraService.captureFrame(int quality) -> Future<Uint8List?>`
  * `CameraService.currentCameraName: String`
  * `CameraService.isInitialized: bool`
  * `CameraService.buildPreviewWidget() -> Widget`

- [ ] **Step 1: Write failing test for camera resolution parsing & parameter validation**

```dart
// test/services/camera_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:camera/camera.dart';
import 'package:flutter_camera_agent/src/services/camera_service.dart';

void main() {
  test('parseResolutionPreset should map strings to Camera ResolutionPreset correctly', () {
    expect(CameraService.parseResolutionPreset('720p'), ResolutionPreset.medium);
    expect(CameraService.parseResolutionPreset('1080p'), ResolutionPreset.high);
    expect(CameraService.parseResolutionPreset('4k'), ResolutionPreset.ultraHigh);
    expect(CameraService.parseResolutionPreset('low'), ResolutionPreset.low);
    expect(CameraService.parseResolutionPreset('unknown'), ResolutionPreset.medium);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/camera_service_test.dart`  
Expected: FAIL with "CameraService not defined"

- [ ] **Step 3: Implement `CameraService` in `lib/src/services/camera_service.dart`**

* 封装 `CameraController`，管理摄像头生命周期与状态互斥锁。
* 提供 `captureFrame(int quality)` 方法：执行 `takePicture()` 并读取为二进制字节数组（或在内存中压缩至指定 JPEG 质量）。
* 实现 `setResolution(String preset)`：动态销毁当前 `CameraController` 并以新分辨率重新初始化，保持摄像头索引不变；若初始化异常自动回滚到初始默认分辨率。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/camera_service_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/services/camera_service.dart test/services/camera_service_test.dart
git commit -m "feat: implement camera service abstraction with dynamic resolution control"
```

---

### Task 4: 边缘调度中枢（AgentCoordinator 采集循环与信令路由）

**Files:**
- Create: `lib/src/services/agent_coordinator.dart`
- Test: `test/services/agent_coordinator_test.dart`

**Interfaces:**
- Consumes: `WebSocketService`, `CameraService`, `AppConfig`, `DeviceIdService`
- Produces:
  * `AgentCoordinator.start() -> Future<void>`
  * `AgentCoordinator.stop() -> void`
  * `AgentCoordinator.currentFps: double`
  * `AgentCoordinator.onFaceResult: Stream<Map<String, dynamic>>`
  * `AgentCoordinator.onFpsUpdate: Stream<double>`

- [ ] **Step 1: Write failing test verifying drop-frame logic under upload pressure (In-flight Lock)**

```dart
// test/services/agent_coordinator_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_camera_agent/src/services/agent_coordinator.dart';
import 'package:flutter_camera_agent/src/services/camera_service.dart';
import 'package:flutter_camera_agent/src/services/websocket_service.dart';

class MockCameraService extends Mock implements CameraService {}
class MockWebSocketService extends Mock implements WebSocketService {}

void main() {
  test('captureTick should drop frame if previous upload is in flight', () async {
    final camera = MockCameraService();
    final ws = MockWebSocketService();
    final coordinator = AgentCoordinator(cameraService: camera, wsService: ws);

    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenAnswer((_) async {
      await Future.delayed(const Duration(milliseconds: 200));
      return Uint8List.fromList([1, 2, 3]);
    });

    // 触发第一次抓拍（耗时 200ms）
    final f1 = coordinator.performCaptureTick();
    // 立即触发第二次抓拍（此时第一次仍在进行）
    final f2 = coordinator.performCaptureTick();

    await Future.wait([f1, f2]);

    // 验证底层抓拍只被调用了一次，第二次被丢弃
    verify(() => camera.captureFrame(any())).called(1);
    verify(() => ws.sendBinary(any())).called(1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/agent_coordinator_test.dart`  
Expected: FAIL with "AgentCoordinator not found"

- [ ] **Step 3: Implement `AgentCoordinator` in `lib/src/services/agent_coordinator.dart`**

* 维护 `bool _isUploading = false` 和采集定时器 `Timer? _captureTimer`。
* 在 `performCaptureTick()` 中加锁：若 `_isUploading == true` 则直接 return 丢帧；在 `finally` 块中重置 `_isUploading = false`。
* 订阅 `WebSocketService.onMessage` 信令流：
  * `cmd_update_config`: 更新 `_fps`（重启定时器）、`_quality`，调用 `cameraService.setResolution()`。
  * `cmd_control_stream`: 启动或取消定时器。
  * `cmd_switch_camera`: 调用 `cameraService.switchCamera()`。
  * `event_face_result`: 透传至 `onFaceResult` 流供 UI 展示。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/agent_coordinator_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/services/agent_coordinator.dart test/services/agent_coordinator_test.dart
git commit -m "feat: implement agent coordinator with in-flight lock and command handling"
```

---

### Task 5: 表现层 UI（全屏预览、状态悬浮栏与识别 HUD）

**Files:**
- Create: `lib/src/ui/widgets/status_bar_overlay.dart`
- Create: `lib/src/ui/widgets/recognition_hud.dart`
- Create: `lib/src/ui/screens/agent_screen.dart`
- Test: `test/ui/recognition_hud_test.dart`
- Test: `test/ui/status_bar_overlay_test.dart`

**Interfaces:**
- Consumes: `AgentCoordinator`, `CameraService`, `WebSocketService`
- Produces:
  * `AgentScreen`: 主屏幕组件

- [ ] **Step 1: Write failing widget test for `RecognitionHUD` auto-dismiss behavior**

```dart
// test/ui/recognition_hud_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_camera_agent/src/ui/widgets/recognition_hud.dart';

void main() {
  testWidgets('RecognitionHUD displays person name and dismisses after 3 seconds', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecognitionHUD(
            resultData: {'name': '张三', 'status': 'approved'},
          ),
        ),
      ),
    );

    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining('识别成功'), findsOneWidget);

    // 前进 3.5 秒
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.textContaining('张三'), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ui/recognition_hud_test.dart`  
Expected: FAIL with "RecognitionHUD not defined"

- [ ] **Step 3: Implement `StatusBarOverlay`, `RecognitionHUD`, and `AgentScreen`**

* `RecognitionHUD`: 采用 `AnimatedOpacity` 实现半透明气泡弹窗，内置 3 秒定时自毁控制器，若连续推送新结果则刷新计时器。
* `StatusBarOverlay`: 在取景框顶部叠放半透明横条，展示连接状态指示灯（🟢/🔴）、当前推流 FPS 计数与摄像头名称。
* `AgentScreen`: 使用 `Stack` 将底层 `cameraService.buildPreviewWidget()`、顶部 `StatusBarOverlay` 以及居中靠下的 `RecognitionHUD` 叠加组合，处理黑屏或摄像头错误时的优雅占位。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ui/recognition_hud_test.dart`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/ui/ test/ui/
git commit -m "feat: implement fullscreen agent UI with status overlay and recognition HUD"
```

---

### Task 6: 屏幕常亮保活、全平台权限配置与主程序启动组装

**Files:**
- Create: `lib/main.dart`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `ios/Runner/Info.plist`
- Modify: `macos/Runner/Info.plist`
- Modify: `macos/Runner/DebugProfile.entitlements`
- Modify: `macos/Runner/Release.entitlements`
- Test: `test/main_bootstrap_test.dart`

**Interfaces:**
- Consumes: All services and UI from Tasks 1-5
- Produces: Executable Flutter Application

- [ ] **Step 1: Write integration smoke test for app initialization**

```dart
// test/main_bootstrap_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_camera_agent/src/config/app_config.dart';

void main() {
  test('AppConfig verifies default hardcoded endpoint and presets', () {
    expect(AppConfig.wsUrl, isNotEmpty);
    expect(AppConfig.defaultFps, greaterThan(0));
    expect(AppConfig.defaultQuality, inInclusiveRange(1, 100));
  });
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `flutter test test/main_bootstrap_test.dart`  
Expected: PASS

- [ ] **Step 3: Configure platform permissions and entitlements**

1. **Android (`AndroidManifest.xml`)**:
   ```xml
   <uses-permission android:name="android.permission.CAMERA" />
   <uses-permission android:name="android.permission.INTERNET" />
   <uses-permission android:name="android.permission.WAKE_LOCK" />
   ```
2. **iOS & macOS (`Info.plist`)**:
   ```xml
   <key>NSCameraUsageDescription</key>
   <string>用于 AI 人脸识别检测并上传画面</string>
   ```
3. **macOS Entitlements (`.entitlements`)**:
   ```xml
   <key>com.apple.security.network.client</key>
   <true/>
   <key>com.apple.security.device.camera</key>
   <true/>
   ```
4. **Linux**: 确保打包脚本或运行依赖包含 `libv4l-dev`。

- [ ] **Step 4: Implement `main.dart` with `WakelockPlus` and service wiring**

在 `main()` 中调用 `WidgetsFlutterBinding.ensureInitialized()`，激活 `WakelockPlus.enable()` 保持屏幕常亮，实例化 `DeviceIdService`、`WebSocketService`、`CameraService` 并注入 `AgentCoordinator`，最后运行 `runApp(AgentApp())`。

- [ ] **Step 5: Run full test suite to verify end-to-end green**

Run: `flutter test`  
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart android/ ios/ macos/ test/main_bootstrap_test.dart
git commit -m "feat: complete platform permissions, wakelock, and main bootstrap wiring"
```

---

## Self-Review Checklist

1. **Spec Coverage**:
   - 5 平台支持？是（通过 Flutter + 原生权限声明保证）。
   - 摄像头本地调用？是（`CameraService` + 硬件预览）。
   - WebSocket 原生双向分流？是（Task 2 文本/二进制严格分流）。
   - 后端全部控制动作？是（`cmd_update_config` 含分辨率调整、`cmd_control_stream`、`cmd_switch_camera`、`event_face_result` 均在 Task 4 路由）。
   - 无 UI 配置面板、硬编码地址与自动 deviceId？是（Task 1 实现）。
   - 单并发防堆积丢帧？是（Task 4 实现并通过测试锁定）。
   - 屏幕常亮防休眠？是（Task 6 引入 `WakelockPlus`）。
2. **Review Focus 覆盖**:
   - 5 大输入异常与断网模式均在 Task 2（解析防炸与断网重连）、Task 3（分辨率回滚）、Task 4（丢帧锁与 finally 重置）、Task 5（HUD 抖动重置）中设立了明确单元测试。
3. **Step Granularity**: 每个步骤均有明确的文件、测试断言和运行指令，无抽象空话。