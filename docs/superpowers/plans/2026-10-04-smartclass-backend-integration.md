# 接入 smartclass-webcam-server（重写后端连接层）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把已完成的客户端接入真实的 `smartclass-webcam-server`。后端定稿的协议与原计划**完全不同**，本计划按后端实现重写 `lib/src/backend/` 全部内容，并连带改造协调器、采集侧 codec 词汇与配置装配。摄像头四层抽象（`CameraProvider` → `CameraBackend` → `CameraService` → `FrameSource`）保持不变。

**Spec（权威）:** `smartclass-webcam-server/docs/protocol/` 五篇文档 —— index / registration / transport / control / media。后端仓库在工作区内仅作参考，**不修改、不提交**。

---

## ⚠️ 三个阻断性差异（需先确认，影响任务范围）

### 阻断 1：人脸识别结果没有来源，`RecognitionHud` 成了死功能

设备协议里 server→device 只有 `switch_camera` / `start_recording` / `stop_recording` / `take_photo` / `ping` 五种。全后端仓库 grep `face` / `recogni` / `person` **零命中**。后端只做设备注册与媒体落盘，AI 是另一个通过管理面 REST（`cam:read:<scope>` 权限）拉录制分片的服务。

设备侧拿不到识别结果，只能三选一：

- **(a) 移除 `RecognitionHud`**（推荐）—— 识别结果归运营侧查看，客户端不再展示。
- **(b) 给后端加一条 server→device 结果消息** —— 需要改后端协议，且后端已定稿。
- **(c) 客户端轮询管理面 REST** —— 需要给设备发 `cam:read` 操作员凭据，破坏权限模型，不建议。

**本计划按 (a) 编写。** 若选 (b)，需先改后端，再回到本计划加一个命令分支。

### 阻断 2：后端没有实时通道，录制由运营侧 HTTP 触发

录制不是客户端自发的：运营侧 `POST /api/devices/{id}/recording/start` → 后端建 stream → 下发 `start_recording{camera_enum, stream_id}` → 客户端才开始推帧。服务端按 **5 秒定时器 / 150 帧** 缓冲刷写分片。

所以「实时活体检测」在这个后端上不成立，最短可见粒度是 5 秒。客户端的角色从「自主推流」变成**按需被调用的从属设备**：没有 `start_recording` 就什么都不推。

### 阻断 3：mp4 分片与后端存储格式不兼容 → 编码按 `h265 → h264 → mjpeg` 偏好选择

后端把每个 `recording.frame` 的裸负载**按 `[uint32 BE len][frame]...` 拼接**成 `.bin` 片段，无容器、无头信息。它期望的是「一个编码访问单元 / 一帧」，**不是 mp4 文件**。我们现成的 `CameraPluginVideoChunkRecorder` 产出的是自带 `moov` 的完整 mp4 —— 直接发过去会得到无法解码的垃圾片段，故停用（保留文件，标注废弃）。

后端 codec 词汇是闭集：`h264` / `h265` / `mjpeg` / `mpeg4` / `vp8` / `vp9` / `av1`，精确小写。**协议里没有 `hevc` 这个词 —— 它只是 H.265 的别称，线上必须写 `h265`**。后端**不做协商**：它把 `supported_codec` 原样存进 `metadata.codecs`，从不挑一个。

**选择策略（本计划采用）**：偏好顺序 `h265 → h264 → mjpeg`，由客户端探测决定实际用哪个。

| 优先级 | 条件 | v1 状态 |
|---|---|---|
| 1 `h265` | 平台存在可用的 HEVC 编码器 | 需原生编码通道（见 T9） |
| 2 `h264` | 平台存在可用的 AVC 编码器 | 需原生编码通道（见 T9） |
| 3 `mjpeg` | 永远可用：`takePicture()` 产出的 JPEG 直接就是 mjpeg 帧 | **已实现，v1 保底** |

`mjpeg` 是保底而不是妥协 —— 后端对它的定义就是「每个 `recording.frame` 一张 JPEG」，正好匹配 `takePicture()`，且天然满足「后端需要时序信息」。所以即使原生编码器还没接上，链路也是完整可用的。

**编码走 ffmpeg，不写原生编码器。** 原版 `ffmpeg_kit_flutter` 已退役，但存在活跃维护的 fork **`ffmpeg_kit_flutter_new` 4.6.4**（2026-10-02 发布，FFmpeg 8.1.2，verified publisher），覆盖 **Android / iOS / macOS / Windows / Linux** 五端，预编译二进制。Full GPL 变体含 `x264` + `x265`，iOS/macOS 另有 VideoToolbox 硬件编码。→ 一套 Dart 实现搞定五端，见 T9。

**两个代价必须接受：**

1. **GPL 传染**：`x264` / `x265` 是 GPL-3.0 组件，用了它们整个应用按 GPL-3.0 分发（后端本身是 AGPL-3.0，可能无所谓，但属于法律事实）。规避路径：用 `ffmpeg_kit_flutter_new_video` 变体（含 **kvazaar**，另一个 HEVC 编码器，作者归类为非 GPL），或 iOS/macOS 直接用 `hevc_videotoolbox` 硬件编码器绕开 x265。
2. **FFmpegKit 是命令式的，没有 stdin 流式 API**，所以做不了边喂帧边取输出的真·实时编码，只能**分块编码**：攒一批帧 → 转成 h265 基本流 → 按 Annex-B 起始码切成访问单元 → 逐个发送。这不构成实质损失 —— **后端本就按 5 秒刷分片、不是实时的**，1–2 秒的分块叠在已 5 秒的管道上边际延迟很小。

若日后确需真·实时（<1s）且只在移动端，再考虑自写 MediaCodec / VideoToolbox 原生通道 —— 那是 T9 之外的增量，不在本计划内。

---

## 真实协议要点（实现必须逐条对齐）

| 项目 | 值 |
|---|---|
| 设备凭据 | `device_id` = 服务端下发的 26 字符 ULID；`Authorization: Bearer wdt_` + 43 个 base64url 字符 |
| 注册 | **`GET`**（带 JSON body）`{base}/ws/register`，body `{device_id, cameras[]}` |
| 注册响应 | `{device_websocket_id(64 hex), expires_at(RFC3339Nano), websocket_path}` |
| 挂载 WS | `GET {base}/ws/device/{ticket}`，ticket 一次性、TTL 60s |
| 信封 | `{channel, type, id?, payload?}`，`channel ∈ control/recording/photo` |
| 二进制帧 | `uint32 BE N` + N 字节 UTF-8 JSON 信封 + 裸媒体字节；`1 ≤ N ≤ 65536`；整帧 ≤ 16 MiB |
| Server→device | `switch_camera` / `start_recording` / `stop_recording` / `take_photo` / `ping` |
| Device→server | `ack` / `pong` / `status` / `error`（text）；`frame`（recording binary）；`photo`（photo binary） |
| `frame` payload | `camera_enum`(number, 必填)、`stream_id`(非空 string, 必填)、`seq`(单调整数)、`ts`(RFC3339Nano) |
| `photo` payload | `camera_enum`(必填)、`request_id`、`content_type`(填 `image/jpeg`)、`ts` |
| codec 名称 | 闭集且精确小写：`h264` / `h265` / `mjpeg` / `mpeg4` / `vp8` / `vp9` / `av1`。**`hevc` 只是别称，线上必须写 `h265`**；`H264` 同样被拒 |
| 摄像头声明 | `camera_enum` 必须等于数组下标；`resolution` 非空字符串（`WIDTHxHEIGHT`）；`fps` 必须 >0 的**整数**（`29.97` 直接 400）；`supported_codec` 非空、闭集、不可重复 |
| 保活 | 服务端每 30s 发协议 Ping + 应用 `ping`；设备回 `pong`。**静默 60s 被断连** |
| 重连 | 无 session resume。ticket 随连接死亡，每次重连必须重新 `GET /ws/register` |
| 关闭码 | `1008` ticket 已被挂载 → 重新注册；`1009` 单帧超 16 MiB；`1006` 异常关闭属**正常现象**（被新连接替换） |
| 命令确认 | 每条带 `id` 的命令都要回 `ack`（回显 `id`）；失败回 `ok:false` + `error` 字符串 |

**客户端必须补的两处行为**：① 空闲时（无录制）也要周期性发 `status`，否则 60s 静默被踢；② `stop_recording` 后立刻停推，继续推的帧会被丢弃。

---

## File Structure（相对现有代码的增量）

```
新增
lib/src/backend/protocol/envelope.dart            Message{channel,type,id,payload} + codec 词汇常量
lib/src/backend/protocol/device_command.dart      ServerCommand 密封类（5 种）
lib/src/backend/protocol/device_message.dart      ClientMessage 密封类（ack/pong/status/error）
lib/src/backend/protocol/binary_frame.dart        二进制帧编解码（uint32 BE + JSON + bytes）
lib/src/backend/device_credentials.dart           device_id + wdt_ token 值对象与校验
lib/src/backend/registration_client.dart          GET /ws/register 的 HTTP 客户端
lib/src/backend/registration_request.dart         cameras[] 构造与本地预校验
lib/src/backend/smartclass_backend_gateway.dart   注册→挂载→保活→退避重注册 的完整链路

重写
lib/src/backend/backend_gateway.dart              接口改为设备协议语义
lib/src/backend/websocket_backend_gateway.dart    删除（由 smartclass_backend_gateway 取代）
lib/src/backend/command_codec.dart                删除（信封解析移入 protocol/envelope）
lib/src/backend/client_signal.dart                删除（改 device_message）
lib/src/backend/server_command.dart               删除（改 device_command）
lib/src/backend/mock_backend_gateway.dart         改为下发真实协议命令
lib/src/backend/unrecognized_command_log.dart     保留，接入点改为信封解析
lib/src/agent/agent_coordinator.dart              改为命令驱动状态机
lib/src/capture/stream_settings.dart               VideoCodec 改为 7 值闭集；fps 改 int
lib/src/config/app_config.dart                    BASE_URL / DEVICE_ID / DEVICE_TOKEN

停用（保留文件，加 @Deprecated 注释）
lib/src/capture/video_chunk_recorder.dart         mp4 分片与后端存储格式不兼容

改动
lib/src/ui/widgets/status_bar_overlay.dart        显示链路状态 / stream_id / 采集帧率
lib/src/ui/widgets/recognition_hud.dart           删除（无数据来源，见阻断 1）
lib/src/ui/screens/agent_screen.dart              移除 HUD
test/                                             对应新增与重写
```

---

### Task 1: 协议信封、消息模型与二进制帧编解码

**Files:**
- Create: `lib/src/backend/protocol/envelope.dart`
- Create: `lib/src/backend/protocol/device_command.dart`
- Create: `lib/src/backend/protocol/device_message.dart`
- Create: `lib/src/backend/protocol/binary_frame.dart`
- Test: `test/backend/protocol/envelope_test.dart`
- Test: `test/backend/protocol/binary_frame_test.dart`

**Interfaces:**
- Produces:
  - `enum WireChannel { control, recording, photo }`，`wireName` → `control`/`recording`/`photo`
  - `Message({required WireChannel channel, required String type, String? id, Map<String,Object?>? payload})`，`Map<String,Object?> toJson()`、`static Message? tryParseJson(String raw)`
  - `enum WireCodec { h264, h265, mjpeg, mpeg4, vp8, vp9, av1 }`，`wireName` 精确小写；`static WireCodec? tryParse(String)`
  - `sealed class DeviceCommand`，子类：`SwitchCameraCommand({id, cameraEnum})`、`StartRecordingCommand({id, cameraEnum, streamId})`、`StopRecordingCommand({id, cameraEnum, streamId})`、`TakePhotoCommand({id, cameraEnum, requestId})`、`PingCommand({ts})`
  - `sealed class DeviceMessage`，子类：`AckMessage({id, ok, error?})`、`PongMessage({ts})`、`StatusMessage({Map<String,Object?> report})`、`ErrorMessage({id?, message})`
  - `RecordingFrameMeta({cameraEnum, streamId, seq, ts})`、`PhotoMeta({cameraEnum, requestId?, contentType, ts})`
  - `Uint8List encodeBinaryFrame(Message header, Uint8List data)`、`({Message header, Uint8List data})? tryDecodeBinaryFrame(Uint8List raw)`

- [ ] **Step 1: Write failing tests**

```dart
// test/backend/protocol/binary_frame_test.dart
void main() {
  test('encodes a recording frame exactly as the server decodes it', () {
    final header = Message(
      channel: WireChannel.recording,
      type: 'frame',
      payload: {
        'camera_enum': 0,
        'seq': 42,
        'stream_id': '01J8ZKQ3B5N7P9R1T3V5X7Z9B2',
        'ts': '2026-10-04T10:00:00Z',
      },
    );
    final frame = encodeBinaryFrame(header, Uint8List.fromList([0xAA, 0xBB]));
    final n = ByteData.view(frame.buffer, frame.offsetInBytes, 4).getUint32(0, Endian.big);
    expect(n, greaterThan(0));
    expect(n, lessThanOrEqualTo(65536));
    expect(frame.length, 4 + n + 2);
    final decoded = tryDecodeBinaryFrame(frame);
    expect(decoded, isNotNull);
    expect(decoded!.header.type, 'frame');
    expect(decoded.header.payload!['stream_id'], '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
    expect(decoded.data, [0xAA, 0xBB]);
  });

  test('rejects frames shorter than the length prefix', () {
    expect(tryDecodeBinaryFrame(Uint8List.fromList([0, 0])), isNull);
  });

  test('rejects a declared header length of zero or beyond the frame', () {
    expect(tryDecodeBinaryFrame(Uint8List.fromList([0, 0, 0, 0, 0x7b])), isNull);
    expect(tryDecodeBinaryFrame(Uint8List.fromList([0, 0, 0, 99, 0x7b])), isNull);
  });

  test('rejects a header that is not valid JSON', () {
    final raw = Uint8List.fromList([0, 0, 0, 3, 0x20, 0x20, 0x20]);
    expect(tryDecodeBinaryFrame(raw), isNull);
  });
}
```

```dart
// test/backend/protocol/envelope_test.dart
void main() {
  test('parses start_recording into its command', () {
    final cmd = parseDeviceCommand(
        '{"channel":"control","type":"start_recording","id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B1",'
        '"payload":{"camera_enum":0,"stream_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B2"}}');
    expect(cmd, isA<StartRecordingCommand>());
    final c = cmd! as StartRecordingCommand;
    expect(c.id, '01J8ZKQ3B5N7P9R1T3V5X7Z9B1');
    expect(c.cameraEnum, 0);
    expect(c.streamId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
  });

  test('parses ping which carries no id', () {
    final cmd = parseDeviceCommand(
        '{"channel":"control","type":"ping","payload":{"ts":"2026-10-04T10:00:30.512384921Z"}}');
    expect(cmd, isA<PingCommand>());
    expect((cmd! as PingCommand).ts, isNotNull);
  });

  test('unknown command types are ignored, not errors', () {
    expect(parseDeviceCommand('{"channel":"control","type":"cmd_do_a_backflip"}'), isNull);
    expect(parseDeviceCommand('not json'), isNull);
  });

  test('ack echoes the command id verbatim', () {
    final json = AckMessage(id: '01J8ZKQ3B5N7P9R1T3V5X7Z9B1', ok: false, error: 'camera 0 is busy').toJson();
    expect(json['type'], 'ack');
    expect(json['id'], '01J8ZKQ3B5N7P9R1T3V5X7Z9B1');
    expect(json['payload']['ok'], false);
    expect(json['payload']['error'], 'camera 0 is busy');
  });

  test('codec vocabulary is the closed set and rejects the hevc alias', () {
    expect(WireCodec.tryParse('h264'), WireCodec.h264);
    expect(WireCodec.tryParse('h265'), WireCodec.h265);
    expect(WireCodec.tryParse('mjpeg'), WireCodec.mjpeg);
    expect(WireCodec.tryParse('hevc'), isNull);
    expect(WireCodec.tryParse('H264'), isNull);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/backend/protocol`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

`parseDeviceCommand` 必须永不抛出：非法 JSON、未知 `type`、缺字段一律返回 `null` 并记一条 `UnrecognizedCommandLog`。信封 `channel` 在文本帧上不校验（后端也不校验），但发送时一律写 `control`。二进制帧的 `type` 与 `channel` 必须匹配（`frame`↔`recording`，`photo`↔`photo`）。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/backend/protocol`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend/protocol test/backend/protocol
git commit -m "feat: add smartclass wire envelope, commands, and binary framing"
```

---

### Task 2: 设备凭据与 HTTP 注册

**Files:**
- Create: `lib/src/backend/device_credentials.dart`
- Create: `lib/src/backend/registration_request.dart`
- Create: `lib/src/backend/registration_client.dart`
- Test: `test/backend/registration_client_test.dart`
- Test: `test/backend/registration_request_test.dart`

**Interfaces:**
- Consumes: `WireCodec` from Task 1；`CameraResolution` / `CameraDescriptor` 来自既有采集层
- Produces:
  - `DeviceCredentials({required String deviceId, required String deviceToken})`，`bool get looksValid`（deviceId 26 字符 ULID 形；token 形如 `wdt_` + 43 个 base64url）
  - `CameraAnnouncement({required int cameraEnum, required String resolution, required int fps, required List<WireCodec> supportedCodec, Map<String,Object?> attrs})`
  - `List<CameraAnnouncement> buildAnnouncements({required List<String> cameraNames, required List<CameraResolution> resolutions, required int fps, required List<WireCodec> codecs})`
  - `RegistrationResult({required String ticket, required DateTime expiresAt, required String websocketPath})`
  - `abstract interface class RegistrationClient`：`Future<RegistrationResult> register(Uri base, DeviceCredentials credentials, List<CameraAnnouncement> cameras)`
  - `HttpRegistrationClient({http.Client? client})`
  - `enum RegistrationFailure { badRequest, unauthorized, tooLarge, serverError, network, ticketMissing }`

- [ ] **Step 1: Write failing tests**

```dart
// test/backend/registration_request_test.dart
void main() {
  test('camera_enum always equals the array index', () {
    final list = buildAnnouncements(
      cameraNames: const ['front', 'back'],
      resolutions: const [CameraResolution(width: 1280, height: 720), CameraResolution(width: 640, height: 480)],
      fps: 5,
      codecs: const [WireCodec.mjpeg],
    );
    expect(list.map((c) => c.cameraEnum), [0, 1]);
    expect(list.first.resolution, '1280x720');
    expect(list.first.supportedCodec, [WireCodec.mjpeg]);
  });

  test('fps is coerced to a positive integer because the server rejects fractions', () {
    final list = buildAnnouncements(
      cameraNames: const ['front'],
      resolutions: const [CameraResolution(width: 1280, height: 720)],
      fps: 0,
      codecs: const [WireCodec.mjpeg],
    );
    expect(list.single.fps, greaterThan(0));
    expect(list.single.fps, isA<int>());
  });

  test('serialises to the shape the server decodes', () {
    final body = buildRegisterBody('01J8ZK9WQ7X3YV0M4N5P6Q7R8S', buildAnnouncements(
      cameraNames: const ['front'],
      resolutions: const [CameraResolution(width: 1280, height: 720)],
      fps: 5,
      codecs: const [WireCodec.mjpeg],
    ));
    expect(body['device_id'], '01J8ZK9WQ7X3YV0M4N5P6Q7R8S');
    expect((body['cameras'] as List).single['camera_enum'], 0);
    expect((body['cameras'] as List).single['supported_codec'], ['mjpeg']);
  });
}
```

```dart
// test/backend/registration_client_test.dart
void main() {
  test('mints a ticket from a 200 response and parses sub-second expires_at', () async {
    final client = _FakeClient(status: 200, body: jsonEncode({
      'device_websocket_id': '0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186',
      'expires_at': '2026-10-04T10:01:00.512384921Z',
      'websocket_path': '/ws/device/0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186',
    }));
    final result = await HttpRegistrationClient(client: client).register(
      Uri.parse('http://localhost:8080'),
      const DeviceCredentials(deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S', deviceToken: 'wdt_${'A' * 43}'),
      [const CameraAnnouncement(cameraEnum: 0, resolution: '1280x720', fps: 5, supportedCodec: [WireCodec.mjpeg])],
    );
    expect(result.ticket.length, 64);
    expect(result.websocketPath, startsWith('/ws/device/'));
    expect(result.expiresAt.millisecond, isNotNull);
  });

  test('sends an Authorization bearer header and a GET with a JSON body', () async {
    final client = _FakeClient(status: 200, body: _okTicketBody);
    await HttpRegistrationClient(client: client).register(
      Uri.parse('http://localhost:8080'), _creds(), [_camera()]);
    expect(client.lastRequest!.method, 'GET');
    expect(client.lastRequest!.headers['Authorization'], startsWith('Bearer wdt_'));
    expect(client.lastBody, contains('"device_id"'));
  });

  test('maps 401 to unauthorized and 413 to tooLarge', () async {
    expect(await _failureOf(401), RegistrationFailure.unauthorized);
    expect(await _failureOf(413), RegistrationFailure.tooLarge);
    expect(await _failureOf(400), RegistrationFailure.badRequest);
    expect(await _failureOf(500), RegistrationFailure.serverError);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/backend/registration_client_test.dart test/backend/registration_request_test.dart`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

注册是 **`GET` 带 body**：`client.send(Request('GET', uri)..headers[...]..body = jsonEncode(...))`（`http` 包的 `get` 不接受 body，必须用 `Request`）。`expires_at` 用完整 RFC 3339 解析（`DateTime.parse`，保留亚秒）。`fps` 在构造时就夹到 `>= 1` 的整数。

`401` 意味着令牌作废或被轮换 —— **重试无意义**，要作为「需要运营重新下发凭据」上报，不进退避重试。

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/backend`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend/device_credentials.dart lib/src/backend/registration_request.dart lib/src/backend/registration_client.dart test/backend
git commit -m "feat: add device credentials and http registration client"
```

---

### Task 3: BackendGateway 接口改版与 Mock 后端

**Files:**
- Rewrite: `lib/src/backend/backend_gateway.dart`
- Rewrite: `lib/src/backend/mock_backend_gateway.dart`
- Delete: `lib/src/backend/websocket_backend_gateway.dart`、`command_codec.dart`、`client_signal.dart`、`server_command.dart`
- Test: `test/backend/mock_backend_gateway_test.dart`

**Interfaces:**
- Consumes: `DeviceCommand` / `DeviceMessage` / `RecordingFrameMeta` / `PhotoMeta` from Task 1；`DeviceCredentials` from Task 2
- Produces:
  - `enum LinkState { idle, registering, attaching, live, backoff, failed }`
  - `abstract interface class BackendGateway`：`Future<void> start(DeviceCredentials credentials)`、`Future<void> stop()`、`Stream<DeviceCommand> commands`、`Stream<LinkState> states`、`void send(DeviceMessage message)`、`void sendRecordingFrame(RecordingFrameMeta meta, Uint8List bytes)`、`void sendPhoto(PhotoMeta meta, Uint8List bytes)`、`LinkState get state`、`UnrecognizedCommandLog get unrecognizedCommands`
  - `MockBackendGateway({Duration? commandInterval})`：按节奏下发 `StartRecordingCommand` → `TakePhotoCommand` → `StopRecordingCommand` → `PingCommand`

- [ ] **Step 1: Write failing test**

```dart
// test/backend/mock_backend_gateway_test.dart
void main() {
  test('drives a full command cycle with server-issued ids', () async {
    final gw = MockBackendGateway(commandInterval: const Duration(milliseconds: 1));
    gw.start(const DeviceCredentials(deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S', deviceToken: 'wdt_x'));
    final seen = <DeviceCommand>[];
    await for (final c in gw.commands.take(4)) { seen.add(c); }
    expect(seen.whereType<StartRecordingCommand>().single.streamId.length, 26);
    expect(seen.whereType<TakePhotoCommand>().single.requestId.length, 26);
    expect(seen.whereType<StopRecordingCommand>(), isNotEmpty);
    expect(seen.whereType<PingCommand>(), isNotEmpty);
  });

  test('records what the device would have uploaded', () async {
    final gw = MockBackendGateway();
    gw.start(_creds());
    gw.sendRecordingFrame(RecordingFrameMeta(cameraEnum: 0, streamId: 's', seq: 1, ts: DateTime.utc(2026)),
        Uint8List.fromList([1]));
    gw.sendPhoto(PhotoMeta(cameraEnum: 0, requestId: 'r', contentType: 'image/jpeg', ts: DateTime.utc(2026)),
        Uint8List.fromList([2]));
    expect(gw.recordedFrames, 1);
    expect(gw.recordedPhotos, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/backend/mock_backend_gateway_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement**

接口语义整体换成设备协议：不再有 `sendSignal` / `sendFrameMeta` / `sendVideoMeta`，改为 `send`（控制消息）与两条媒体方法。Mock 端的 `stream_id` / `request_id` 用 26 字符 ULID 形字符串生成，便于校验客户端真的原样回传。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/backend/mock_backend_gateway_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend test/backend
git commit -m "refactor: reshape backend gateway around the smartclass device protocol"
```

---

### Task 4: SmartClassBackendGateway（注册 → 挂载 → 保活 → 退避重注册）

**Files:**
- Create: `lib/src/backend/smartclass_backend_gateway.dart`
- Test: `test/backend/smartclass_backend_gateway_test.dart`

**Interfaces:**
- Consumes: `RegistrationClient`(T2)、`BackendGateway`(T3)、`DeviceCommand`(T1)
- Produces: `SmartClassBackendGateway({required Uri base, required RegistrationClient registration, required WebSocketChannelFactory channelFactory, required List<CameraAnnouncement> cameras, Duration? idleStatusInterval})`
- 内部状态机：`idle → registering → attaching → live`，关闭后 → `backoff → registering`

- [ ] **Step 1: Write failing tests**

```dart
// test/backend/smartclass_backend_gateway_test.dart
void main() {
  test('registers then attaches with the ticket in the path', () async {
    final reg = _FakeRegistration();
    final gw = SmartClassBackendGateway(
      base: Uri.parse('http://localhost:8080'),
      registration: reg,
      channelFactory: (_) => _FakeChannel(const Stream.empty(), FakeSink()),
      cameras: [_camera()],
    );
    gw.start(_creds());
    await pumpEventQueue();
    expect(reg.calls, 1);
    expect(gw.state, LinkState.live);
  });

  test('answers a ping with a pong carrying the same ts', () async {
    final sink = FakeSink();
    final incoming = StreamController<dynamic>();
    final gw = _gateway(incoming, sink);
    gw.start(_creds());
    await pumpEventQueue();
    incoming.add('{"channel":"control","type":"ping","payload":{"ts":"2026-10-04T10:00:30Z"}}');
    await pumpEventQueue();
    final pong = sink.records.whereType<String>().map(jsonDecode).last as Map<String, dynamic>;
    expect(pong['type'], 'pong');
    expect(pong['payload']['ts'], '2026-10-04T10:00:30Z');
  });

  test('emits start_recording to the command stream', () async {
    final incoming = StreamController<dynamic>();
    final gw = _gateway(incoming, FakeSink());
    gw.start(_creds());
    await pumpEventQueue();
    incoming.add('{"channel":"control","type":"start_recording","id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B1",'
        '"payload":{"camera_enum":0,"stream_id":"01J8ZKQ3B5N7P9R1T3V5X7Z9B2"}}');
    await expectLater(gw.commands, emits(isA<StartRecordingCommand>()));
  });

  test('a malformed frame is logged and the link survives the next valid frame', () async {
    final incoming = StreamController<dynamic>();
    final gw = _gateway(incoming, FakeSink());
    gw.start(_creds());
    await pumpEventQueue();
    incoming.add('<<garbage>>');
    await pumpEventQueue();
    expect(gw.unrecognizedCommands.entries.single.raw, '<<garbage>>');
    expect(gw.state, LinkState.live);
    incoming.add('{"channel":"control","type":"ping","payload":{"ts":"2026-10-04T10:00:30Z"}}');
    await pumpEventQueue();
    expect(gw.state, LinkState.live);
  });

  test('a close sends the link to backoff and re-registers rather than reusing the ticket', () async {
    final reg = _FakeRegistration();
    final gw = _gatewayWith(StreamController<dynamic>(), FakeSink(), reg);
    gw.start(_creds());
    await pumpEventQueue();
    gw.simulateClose();
    await pumpEventQueue();
    expect(gw.state, LinkState.backoff);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(reg.calls, 2);
  });

  test('a 401 during registration is fatal and is not retried', () async {
    final reg = _FakeRegistration(failure: RegistrationFailure.unauthorized);
    final gw = _gatewayWith(StreamController<dynamic>(), FakeSink(), reg);
    gw.start(_creds());
    await pumpEventQueue();
    expect(gw.state, LinkState.failed);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(reg.calls, 1);
  });

  test('sends a status message while idle so the 60s read deadline never trips', () async {
    final sink = FakeSink();
    final gw = _gateway(StreamController<dynamic>(), sink,
        idleStatusInterval: const Duration(milliseconds: 10));
    gw.start(_creds());
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final types = sink.records.whereType<String>().map((s) => (jsonDecode(s) as Map)['type']).toList();
    expect(types, contains('status'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/backend/smartclass_backend_gateway_test.dart`
Expected: FAIL with "Undefined name 'SmartClassBackendGateway'"

- [ ] **Step 3: Implement**

链路规则，逐条对齐后端：

1. `start()` → `registering`：`GET /ws/register` 拿 ticket。
2. `attaching`：用 `websocket_path` 拼 URI 挂载 WS。**ticket 不复用**。
3. `live`：收帧 → `parseDeviceCommand`；`ping` 自动回 `pong`（不等协调器）；其余命令推入 `commands`。
4. 关闭 → `backoff`：退避 1s/2s/4s…封顶 16s，**加抖动**，然后回到第 1 步重新注册。
5. 注册返回 `401` → `failed` 且**不再重试**（令牌作废，需运营重发）。
6. 挂载阶段 `404`（ticket 过期/未知）或 `409`（仍是 live session）→ 直接重新注册。
7. 升级后收到 `1008` → 丢弃该 ticket，重新注册。收到 `1009` → 说明单帧超 16 MiB，记 `error` 并重新注册。
8. 空闲时按 `idleStatusInterval`（默认 30s）发一次 `status`，避免 60s 静默被断。
9. `1006` 视为正常关闭，不特殊处理。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/backend/smartclass_backend_gateway_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/backend/smartclass_backend_gateway.dart test/backend
git commit -m "feat: add smartclass gateway with register, attach, keepalive, and backoff"
```

---

### Task 5: 编码能力探测、编码器接缝与 mjpeg 帧泵

**Files:**
- Modify: `lib/src/capture/stream_settings.dart`
- Create: `lib/src/capture/video_encoder.dart`
- Create: `lib/src/capture/codec_probe.dart`
- Create: `lib/src/capture/frame_pump.dart`
- Deprecate: `lib/src/capture/video_chunk_recorder.dart`
- Test: `test/capture/codec_probe_test.dart`
- Test: `test/capture/frame_pump_test.dart`

**Interfaces:**
- Consumes: `CameraService.captureFrame`（既有）、`WireCodec` from Task 1
- Produces:
  - `enum CaptureCodec { h265, h264, mjpeg, mpeg4, vp8, vp9, av1 }`，`wireName` 与 `WireCodec` 逐字相同（`h265` / `h264` / `mjpeg` …，**绝不产出 `hevc`**）
  - `static const List<CaptureCodec> CaptureCodec.preference = [h265, h264, mjpeg]`
  - `abstract interface class CodecProbe`：`Future<Set<CaptureCodec>> availableCodecs()`
  - `CompositeCodecProbe({required List<CodecProbe> probes})` —— 组合多个探测源（T9 的原生探测插进来即可）
  - `BaselineCodecProbe implements CodecProbe` —— 恒返回 `{mjpeg}`：JPEG 抓帧在任何平台都可用
  - `CodecSelector({required CodecProbe probe})`：`Future<CaptureCodec> select()` —— 按 `preference` 顺序取第一个可用者
  - `abstract interface class VideoEncoder`：`CaptureCodec get codec`、`Future<void> start({required int width, required int height, required int fps, required int quality})`、`Future<void> stop()`、`Stream<EncodedFrame> get frames`
  - `EncodedFrame({required int seq, required DateTime ts, required Uint8List bytes, required bool isKeyFrame})`
  - `MjpegEncoder implements VideoEncoder` —— 包装 `TakePictureFramePump`，`isKeyFrame` 恒为 `true`
  - `abstract interface class FramePump`：`Future<void> start({required int cameraEnum, required String streamId, required int fps, required int quality})`、`Future<void> stop()`、`Stream<CapturedFrame> get frames`
  - `CapturedFrame({required int seq, required DateTime ts, required Uint8List bytes})`
  - `TakePictureFramePump implements FramePump`（按 fps 定时 `captureFrame`，`seq` 从 0 单调递增）
  - `StreamSettings` 的 `fps` 改为 `int`，`codec` 改为 `CaptureCodec`

- [ ] **Step 1: Write failing tests**

```dart
// test/capture/codec_probe_test.dart
void main() {
  test('preference puts h265 ahead of h264 ahead of mjpeg', () {
    expect(CaptureCodec.preference.first, CaptureCodec.h265);
    expect(CaptureCodec.preference, [CaptureCodec.h265, CaptureCodec.h264, CaptureCodec.mjpeg]);
  });

  test('selects h265 when the device offers it', () async {
    final selector = CodecSelector(probe: _FixedProbe({CaptureCodec.h265, CaptureCodec.h264, CaptureCodec.mjpeg}));
    expect(await selector.select(), CaptureCodec.h265);
  });

  test('falls back to h264 when h265 is unavailable', () async {
    final selector = CodecSelector(probe: _FixedProbe({CaptureCodec.h264, CaptureCodec.mjpeg}));
    expect(await selector.select(), CaptureCodec.h264);
  });

  test('falls back to mjpeg when no video encoder exists', () async {
    final selector = CodecSelector(probe: _FixedProbe({CaptureCodec.mjpeg}));
    expect(await selector.select(), CaptureCodec.mjpeg);
  });

  test('wire names are the closed set and never emit the hevc alias', () {
    expect(CaptureCodec.h265.wireName, 'h265');
    expect(CaptureCodec.h264.wireName, 'h264');
    expect(CaptureCodec.mjpeg.wireName, 'mjpeg');
    expect(CaptureCodec.values.map((c) => c.wireName), isNot(contains('hevc')));
  });

  test('composite probe unions every source', () async {
    final probe = CompositeCodecProbe(probes: [
      _FixedProbe({CaptureCodec.h265}),
      _FixedProbe({CaptureCodec.mjpeg}),
    ]);
    expect(await probe.availableCodecs(), {CaptureCodec.h265, CaptureCodec.mjpeg});
  });
}
```

```dart
// test/capture/frame_pump_test.dart
void main() {
  test('emits monotonically increasing seq starting at zero', () async {
    final camera = MockCameraService();
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenAnswer((_) async => Uint8List.fromList([1]));
    final pump = TakePictureFramePump(camera: camera);
    await pump.start(cameraEnum: 0, streamId: 's', fps: 20, quality: 80);
    final seen = await pump.frames.take(3).toList();
    await pump.stop();
    expect(seen.map((f) => f.seq), [0, 1, 2]);
    expect(seen.first.ts, isA<DateTime>());
  });

  test('stop ends the stream and no further frames are produced', () async {
    final camera = MockCameraService();
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenAnswer((_) async => Uint8List.fromList([1]));
    final pump = TakePictureFramePump(camera: camera);
    await pump.start(cameraEnum: 0, streamId: 's', fps: 20, quality: 80);
    await pump.stop();
    await pump.stop();
    expect(await pump.frames.isEmpty, isTrue);
  });

  test('a failing capture is skipped without killing the pump', () async {
    final camera = MockCameraService();
    var n = 0;
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenAnswer((_) async {
      if (n++ == 0) throw StateError('camera busy');
      return Uint8List.fromList([1]);
    });
    final pump = TakePictureFramePump(camera: camera);
    await pump.start(cameraEnum: 0, streamId: 's', fps: 20, quality: 80);
    final seen = await pump.frames.take(1).toList();
    await pump.stop();
    expect(seen.single.seq, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/capture/frame_pump_test.dart`
Expected: FAIL with "Undefined name 'TakePictureFramePump'"

- [ ] **Step 3: Implement**

`TakePictureFramePump` 用 `Timer.periodic(1000 ~/ fps)` 驱动；上一帧未结束直接跳过（沿用单并发排他锁，锁必须在 `finally` 释放）。`seq` 每个 stream 从 0 开始，只在成功产出时自增。单帧失败记日志后继续，**不让泵停摆**。

`VideoChunkRecorder` 标 `@Deprecated`：它产出带 `moov` 的 mp4，与后端「按长度前缀拼接裸帧」的存储格式不兼容。保留文件以便 v2 做访问单元抽取时复用思路。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/capture/frame_pump_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/capture/stream_settings.dart lib/src/capture/frame_pump.dart lib/src/capture/video_chunk_recorder.dart test/capture
git commit -m "feat: add jpeg frame pump for mjpeg streams, deprecate mp4 chunk recorder"
```

---

### Task 6: AgentCoordinator 改为命令驱动状态机

**Files:**
- Rewrite: `lib/src/agent/agent_coordinator.dart`
- Modify: `lib/src/agent/agent_status.dart`
- Test: `test/agent/agent_coordinator_test.dart`

**Interfaces:**
- Consumes: `BackendGateway`(T3/T4)、`CameraProvider`(既有)、`FramePump`(T5)、`DeviceCredentials`(T2)
- Produces:
  - `AgentCoordinator({required BackendGateway gateway, required CameraProvider cameraProvider, required FramePumpFactory pumpFactory})`
  - `Future<void> start()`、`void stop()`、`Future<void> pause()`、`Future<void> resume()`
  - 采集状态 `enum CaptureState { idle, recording, capturingPhoto }`
  - `CaptureState get captureState`、`String? get activeStreamId`、`int get cameraEnum`、`int get announcedFps`
  - `Stream<AgentStatus> get onStatus`（`linkState` / `captureState` / `activeStreamId` / `cameraName` / `fps` / `previewEnabled`）
  - 命令处理：`void handleCommand(DeviceCommand command)`（测试入口）

- [ ] **Step 1: Write failing tests**

```dart
// test/agent/agent_coordinator_test.dart
void main() {
  test('acks start_recording and begins pumping frames tagged with the stream id', () async {
    final gw = MockBackendGateway();
    final pump = MockFramePump();
    final co = _build(gw, pump);
    when(() => pump.frames).thenAnswer((_) => Stream.fromIterable([
      CapturedFrame(seq: 0, ts: DateTime.utc(2026), bytes: Uint8List.fromList([1])),
    ]));
    co.handleCommand(StartRecordingCommand(
        id: '01J8ZKQ3B5N7P9R1T3V5X7Z9B1', cameraEnum: 0, streamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2'));
    await pumpEventQueue();
    verify(() => gw.send(any(that: isA<AckMessage>()))).called(1);
    verify(() => pump.start(cameraEnum: 0, streamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2', fps: any(named: 'fps'),
        quality: any(named: 'quality'))).called(1);
    expect(co.captureState, CaptureState.recording);
    expect(co.activeStreamId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B2');
    verify(() => gw.sendRecordingFrame(any(), any())).called(greaterThan(0));
  });

  test('stop_recording halts the pump and stops pushing immediately', () async {
    final gw = MockBackendGateway();
    final pump = MockFramePump();
    final co = _build(gw, pump);
    when(() => pump.stop()).thenAnswer((_) async {});
    co.handleCommand(StartRecordingCommand(id: 'a', cameraEnum: 0, streamId: 's'));
    await pumpEventQueue();
    co.handleCommand(StopRecordingCommand(id: 'b', cameraEnum: 0, streamId: 's'));
    await pumpEventQueue();
    verify(() => pump.stop()).called(1);
    expect(co.captureState, CaptureState.idle);
    expect(co.activeStreamId, isNull);
  });

  test('take_photo uploads one photo carrying the request id', () async {
    final gw = MockBackendGateway();
    final camera = MockCameraService();
    final co = _build(gw, MockFramePump(), camera: camera);
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any())).thenAnswer((_) async => Uint8List.fromList([0xFF, 0xD8]));
    co.handleCommand(TakePhotoCommand(id: 'c', cameraEnum: 0, requestId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B3'));
    await pumpEventQueue();
    final meta = verify(() => gw.sendPhoto(captureAny(), any())).captured.single as PhotoMeta;
    expect(meta.requestId, '01J8ZKQ3B5N7P9R1T3V5X7Z9B3');
    expect(meta.contentType, 'image/jpeg');
    verify(() => gw.send(any(that: isA<AckMessage>()))).called(1);
  });

  test('a command the device cannot run is acked with ok false, never dropped', () async {
    final gw = MockBackendGateway();
    final camera = MockCameraService();
    final co = _build(gw, MockFramePump(), camera: camera);
    when(() => camera.isInitialized).thenReturn(false);
    co.handleCommand(TakePhotoCommand(id: 'd', cameraEnum: 0, requestId: 'r'));
    await pumpEventQueue();
    final ack = verify(() => gw.send(captureAny())).captured.single as AckMessage;
    expect(ack.id, 'd');
    expect(ack.ok, isFalse);
    expect(ack.error, isNotNull);
  });

  test('switch_camera reconfigures the active camera and acks', () async {
    final gw = MockBackendGateway();
    final camera = MockCameraService();
    final co = _build(gw, MockFramePump(), camera: camera);
    when(() => camera.switchCamera(any())).thenAnswer((_) async {});
    co.handleCommand(SwitchCameraCommand(id: 'e', cameraEnum: 1));
    await pumpEventQueue();
    verify(() => camera.switchCamera(1)).called(1);
    expect(co.cameraEnum, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/agent/agent_coordinator_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement**

彻底放弃「客户端自主推流」模型，改为**命令驱动**：

- `start()` 只做两件事：打开摄像头、启动网关。**不再自发推任何媒体**。
- `handleCommand` 是唯一入口，每条命令**无论成败都必须 ack**（失败用 `ok:false` + `error`，绝不静默丢弃）。
- `start_recording`：若已在录制，回 `ok:false`（同一 camera 后端不允许并发 active stream）；否则启动 `FramePump`，把 `streamId` 传给泵，并逐帧 `sendRecordingFrame`。
- `stop_recording`：立刻停泵，`activeStreamId` 置空。后端在排队命令时就把 stream 标 `completed`，晚到的帧会被丢弃，所以**必须立刻停**。
- `take_photo`：抓一帧，`sendPhoto`，带 `requestId` 与 `content_type: image/jpeg`。
- `switch_camera`：切换活动摄像头。
- `ping`：网关层已自动回 `pong`，协调器不再处理。

`pause()` / `resume()` 语义不变（切后台暂停采集并断开）。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/agent/agent_coordinator_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/agent test/agent
git commit -m "refactor: make the coordinator command-driven for the smartclass backend"
```

---

### Task 7: UI 调整（移除 HUD、状态条改链路信息）

**Files:**
- Delete: `lib/src/ui/widgets/recognition_hud.dart`、`test/ui/recognition_hud_test.dart`
- Modify: `lib/src/ui/widgets/status_bar_overlay.dart`
- Modify: `lib/src/ui/screens/agent_screen.dart`
- Test: `test/ui/status_bar_overlay_test.dart`

**Interfaces:**
- Consumes: `AgentStatus`(T6)、`LinkState`(T3)
- Produces: `StatusBarOverlay({required AgentStatus status, required ValueChanged<bool> onPreviewToggle})`

- [ ] **Step 1: Write failing test**

```dart
// test/ui/status_bar_overlay_test.dart
void main() {
  testWidgets('shows link state, capture state and the active stream', (tester) async {
    const status = AgentStatus(linkState: LinkState.live, captureState: CaptureState.recording,
        activeStreamId: '01J8ZKQ3B5N7P9R1T3V5X7Z9B2', cameraName: 'Integrated Camera',
        fps: 5, previewEnabled: true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: StatusBarOverlay(status: status, onPreviewToggle: (_) {}))));
    expect(find.textContaining('01J8ZKQ3B5N7P9R1T3V5X7Z9B2'), findsOneWidget);
    expect(find.textContaining('Integrated Camera'), findsOneWidget);
  });

  testWidgets('backoff is legible so an operator can tell it is retrying', (tester) async {
    const status = AgentStatus(linkState: LinkState.backoff, captureState: CaptureState.idle,
        activeStreamId: null, cameraName: 'cam', fps: 5, previewEnabled: true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: StatusBarOverlay(status: status, onPreviewToggle: (_) {}))));
    expect(find.textContaining('重连'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ui`
Expected: FAIL

- [ ] **Step 3: Implement**

删除 `RecognitionHud`（无数据来源，见阻断 1）。状态条改为展示：`LinkState`（live / 重连 / failed）、`CaptureState`（空闲 / 采集中 / 拍照中）、`stream_id` 缩略、摄像头名、声明 fps。预览开关保留为**纯本地功能** —— 后端没有对应命令。

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ui`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/ui test/ui
git commit -m "refactor: drop the recognition hud and surface link state in the status bar"
```

---

### Task 8: 配置、凭据装配与联调门禁

**Files:**
- Modify: `lib/src/config/app_config.dart`
- Modify: `lib/main.dart`
- Create: `lib/src/backend/credential_store.dart`
- Test: `test/app/bootstrap_test.dart`

**Interfaces:**
- Consumes: 全部 T1–T7
- Produces: `AppConfig.baseUrl` / `deviceId` / `deviceToken`（均由 `--dart-define` 注入）；`abstract interface class CredentialStore`：`Future<DeviceCredentials?> load()`、`Future<void> save(DeviceCredentials)`；默认实现基于 `shared_preferences`

- [ ] **Step 1: Write failing test**

```dart
// test/app/bootstrap_test.dart
void main() {
  test('base url and credentials come from dart-define and are not hardcoded', () {
    expect(AppConfig.baseUrl, isNotEmpty);
    expect(AppConfig.baseUrl, startsWith('http'));
  });

  test('an empty credential set is reported as missing rather than blank', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SharedPrefsCredentialStore().load(), isNull);
  });

  test('credentials round-trip through the store', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsCredentialStore();
    await store.save(const DeviceCredentials(deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S', deviceToken: 'wdt_${'A' * 43}'));
    final loaded = await store.load();
    expect(loaded!.deviceId, '01J8ZK9WQ7X3YV0M4N5P6Q7R8S');
    expect(loaded.deviceToken, startsWith('wdt_'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/app`
Expected: FAIL

- [ ] **Step 3: Implement**

`AppConfig` 改为 `BASE_URL`（http/https 基址，注册与 WS 都基于它）、`DEVICE_ID`、`DEVICE_TOKEN`。**凭据不得硬编码进二进制**；`dart-define` 只是开发期便利，正式装配走 `CredentialStore`（首次启动写入）。`main()` 组装顺序：加载凭据 → 打开摄像头 → 构造 `CameraAnnouncement` → 建 `SmartClassBackendGateway` → `AgentCoordinator.start()`。`UnrecognizedCommandLog` 的 sink 接到应用日志出口。

- [ ] **Step 4: Run full suite**

Run: `flutter test`
Expected: ALL PASS

- [ ] **Step 5: 真机联调门禁**

1. 起后端（按 `smartclass-webcam-server/docs/guide/getting-started`）。
2. 运营侧 `POST /api/devices` 建设备，拿到 `device_id` 与 `wdt_` token。
3. Run: `flutter run -d windows --dart-define=BASE_URL=http://<host>:8080 --dart-define=DEVICE_ID=<ulid> --dart-define=DEVICE_TOKEN=wdt_...`
4. 运营侧 `POST /api/devices/{id}/recording/start` → 客户端状态条进入「采集中」并显示 `stream_id`；5 秒后后端出现 segment。
5. `POST .../photo` → 后端 photos 列表出现一条，`request_id` 与命令一致。
6. `POST .../recording/stop` → 客户端立刻停推，stream 变 `completed`。
7. 拔网线 → 客户端进入「重连」，恢复后**重新注册**（register 调用次数 +1）。

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/src/config lib/src/backend/credential_store.dart test/app
git commit -m "feat: wire smartclass credentials, config, and bootstrap"
```

---

### Task 9: ffmpeg 编码通道（偏好链的 `h265` / `h264` 两级）

> 前置：T5 已完成。T1–T8 不依赖本任务 —— 没有它，客户端仍以 `mjpeg` 完整工作。

**依赖**：`flutter pub add ffmpeg_kit_flutter_new`（4.6.4，FFmpeg 8.1.2，Android/iOS/macOS/Windows/Linux）。Linux 另需 `sudo apt-get install libjson-glib-dev`。若不接受 GPL-3.0 传染，改用 `ffmpeg_kit_flutter_new_video`（含 kvazaar 这个非 GPL 的 HEVC 编码器，无 x264/x265）。

**Files:**
- Create: `lib/src/capture/encoders/annex_b_splitter.dart`（纯函数：按起始码切访问单元）
- Create: `lib/src/capture/encoders/ffmpeg_chunk_encoder.dart`（`VideoEncoder` 实现）
- Create: `lib/src/capture/encoders/ffmpeg_codec_probe.dart`（`CodecProbe` 实现）
- Test: `test/capture/encoders/annex_b_splitter_test.dart`
- Test: `test/capture/encoders/ffmpeg_codec_probe_test.dart`

**Interfaces:**
- Consumes: `VideoEncoder` / `CodecProbe` / `EncodedFrame` from Task 5
- Produces:
  - `List<Uint8List> splitAnnexB(Uint8List stream)` —— 按 `00 00 01` / `00 00 00 01` 起始码切出访问单元（**纯函数，必须单测**）
  - `FfmpegChunkEncoder implements VideoEncoder`：`codec` 为 `h265` 或 `h264`；把一批 `CapturedFrame` 落盘为 mjpeg，调 ffmpeg 转基本流，再切成 `EncodedFrame`
  - `FfmpegCodecProbe implements CodecProbe`：执行 `ffmpeg -encoders`，解析输出判断 `libx265` / `hevc_videotoolbox` / `hevc_mediacodec` / `kvazaar`（HEVC）与 `libx264` / `h264_videotoolbox` / `h264_mediacodec`（AVC）是否存在
  - 纯函数：`parseFfmpegEncoders(String out, Set<String> names) -> Set<String>`

**命令形态**（HEVC，分块）：
```sh
ffmpeg -f image2pipe -c:v mjpeg -i chunk.mjpeg \
       -c:v libx265 -preset veryfast -x265-params keyint=30 -f h265 chunk.h265
```
iOS/macOS 用 `-c:v hevc_videotoolbox`，Android 用 `-c:v hevc_mediacodec`（硬件，免 GPL）。

**硬约束**：后端把负载当**裸字节拼接**，无容器、不解析。所以每个 `recording.frame` 必须是一个**完整的访问单元**，且**每块的第一个访问单元必须带 VPS/SPS/PPS 并标记 `isKeyFrame: true`**，否则下游 AI 拿到的是解不开的片段。`-x265-params keyint=N` 保证每块开头有关键帧。

- [ ] **Step 1: Write failing tests**

```dart
// test/capture/encoders/annex_b_splitter_test.dart
void main() {
  test('splits on both 3-byte and 4-byte start codes', () {
    final au1 = Uint8List.fromList([0x26, 0x01, 0xAA]);
    final au2 = Uint8List.fromList([0x28, 0x01, 0xBB]);
    final stream = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x01, ...au1,
      0x00, 0x00, 0x01, ...au2,
    ]);
    final units = splitAnnexB(stream);
    expect(units, [au1, au2]);
  });

  test('a stream with no start code yields nothing', () {
    expect(splitAnnexB(Uint8List.fromList([1, 2, 3])), isEmpty);
  });

  test('a trailing start code produces no empty unit', () {
    expect(splitAnnexB(Uint8List.fromList([0x00, 0x00, 0x00, 0x01, 0x26])), hasLength(1));
  });
}
```

```dart
// test/capture/encoders/ffmpeg_codec_probe_test.dart
void main() {
  test('detects libx265 and the hardware hevc encoders', () {
    const out = ' V..... libx265      libx265 H.265 / HEVC\n'
                ' V..... hevc_videotoolbox  VideoToolbox H.265\n'
                ' V..... hevc_mediacodec    MediaCodec H.265';
    final found = parseFfmpegEncoders(out, {'libx265', 'hevc_videotoolbox', 'hevc_mediacodec'});
    expect(found, {'libx265', 'hevc_videotoolbox', 'hevc_mediacodec'});
  });

  test('an absent encoder is not reported', () {
    expect(parseFfmpegEncoders(' V..... libx264  libx264', {'libx265'}), isEmpty);
  });

  test('a decoder-only line does not count as an encoder', () {
    const out = ' D..... hevc       HEVC (High Efficiency Video Coding)';
    expect(parseFfmpegEncoders(out, {'hevc'}), isEmpty);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/capture/encoders`
Expected: FAIL with "Undefined name"

- [ ] **Step 3: Implement**

解析与切分是纯函数，**必须单测**。编码走 `FFmpegKit.execute(...)`，`getOutput()` 取结果；失败时按偏好链降级到下一档并记一条 `error` 上报后端。每块编码完立即删除临时文件。**只做分块，不要试图用 FFmpegKit 做流式 stdin —— 它不支持。**

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/capture`
Expected: PASS

- [ ] **Step 5: 实机验证（每平台）**

Run: `flutter run -d <platform>`，运营侧下发 `recording/start`，确认：
1. 状态条显示的 codec 是 `h265`（不支持时 `h264`，都不支持时 `mjpeg`）。
2. 后端 segment 的字节能被 `ffprobe` 识别为对应编码格式。
3. 解码出的画面连续、无花屏（验证 VPS/SPS/PPS 确实随每块首帧发出）。
4. 分块编码耗时 < 块长（否则会积压，需调 `-preset` 或改用硬件编码器）。

- [ ] **Step 6: Commit**

```bash
git add lib/src/capture/encoders pubspec.yaml pubspec.lock test/capture
git commit -m "feat: add ffmpeg-backed h265 and h264 chunked encoder"
```

---

## Self-Review Checklist

1. **协议对齐**：注册（GET+body+token）、挂载（ticket in path）、信封（channel/type/id/payload）、二进制帧（uint32 BE + JSON + bytes）、五种服务端命令、四种客户端消息、codec 闭集、fps 整数、seq/ts、ack 规则 —— 全部有对应任务与断言。
2. **行为差异已处理**：ticket 一次性 → T4 每次重连重新注册；60s 静默断连 → T4 空闲发 `status`；`1006` 正常化 → T4；mp4 不兼容 → T5 改 mjpeg；`hevc` 被拒 → T1 闭集解析；无 face result → T7 删除 HUD（阻断 1 待确认）。
3. **类型一致性**：`WireCodec` 与 `CaptureCodec` 的 `wireName` 必须逐字相同（T1 定义、T5 复用）；`DeviceCommand.id` / `streamId` / `requestId` 全程原样透传、不改写；`AgentStatus` 字段在 T6 定义、T7 消费，名字逐字一致。
4. **Review Focus**：畸变帧（T1+T4：留痕且链路存活）、凭据失效（T4：401 不重试）、单帧超 16 MiB（T5：JPEG 帧远低于上限，且 T1 断言 N 的范围）、命令失败必须 ack（T6：`ok:false` 而非丢弃）、空闲静默（T4：`status` 心跳）。
5. **比例**：只给测试与跨任务签名；算法本体（二进制帧布局、退避、帧泵节流）由签名与测试唯一确定，不写函数体。摄像头四层抽象不在本次改动范围内，故不重复描述。
6. **编码偏好**：`h265 → h264 → mjpeg` 落在 T5 的 `CaptureCodec.preference` + `CodecSelector`，T9 只需新增 `VideoEncoder` 与 `CodecProbe` 实现即可让偏好生效，不动选择逻辑。线上 codec 名一律 `h265` / `h264`，**绝不出现 `hevc`**。T9 用 `ffmpeg_kit_flutter_new`（五端统一、预编译、含 x265），不写原生编码器；**GPL-3.0 传染已明确记录**，规避路径（`_video` 变体的 kvazaar / 硬件 hevc_videotoolbox）已给出。
7. **HUD 已删除**：`lib/src/ui/widgets/recognition_hud.dart` 与其测试已移除，`AgentScreen` 不再订阅 `onFaceResult`；`onFaceResult` 本身在 T6 重写协调器时一并删除。
