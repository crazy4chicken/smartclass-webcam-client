# 计划实施状态

> 覆盖 `docs/plan_v0.md` 与 `docs/superpowers/plans/` 下的八个计划。
> 记录每个计划**实现了什么、有意偏离了什么、明确没做什么、验证到什么程度**。
>
> **最后更新：2026-10-10。**
> 双模式取画面（照片 + 编码视频流）的整体方案见
> `docs/superpowers/plans/2026-10-10-dual-mode-capture.md`；
> Linux 原生编码分支已**暂停**，交接见 `docs/linux-encoded-stream-status.md`。
> 权威架构说明见 `README.md`；协议权威是后端仓库的 `smartclass-webcam-server/docs/protocol/`。

---

## 一、总览

| # | 计划 | 状态 | 关键提交 |
| --- | --- | --- | --- |
| 1 | `docs/plan_v0.md` | ⛔ **已作废** | — |
| 2 | `…/2026-10-04-camera-edge-probe.md` | ⛔ **已取代**（协议层整体推翻，抽象层沿用） | `ea5968c` |
| 3 | `…/2026-10-04-smartclass-backend-integration.md` | ✅ **已实现（T1–T8）**，T9 未做 | `db0f495` 起 |
| 4 | `…/2026-10-04-android-server-e2e-test.md` | ✅ **已通过（T0–T8）** | `e49be97` `9763c18` |
| 5 | `…/2026-10-05-runtime-backend-settings.md` | ✅ **已实现（T1–T8）** | `81a0d1f` `c8262de` `95ca378` |
| 6 | `…/2026-10-07-camera-capability-probe.md` | ✅ **已实现（T1–T9）** | `23e7495`…`8be70c7`，`8c2b709` `dbd1135` `61504e9` |
| 7 | `…/2026-10-09-recording-correctness-and-native-encoder.md` | ⚠️ **Phase A 完成（T1–T4）、T5 完成**；Phase B 原生端进行中 | `87f6fe0` `a438a74` `604316d` `36f55a8` `6ca637c` `f2341e5` |
| 8 | `…/2026-10-09-linux-encoded-stream.md` | ⏸ **已暂停**（Task 1–4 已写，**未编译**） | `f10f86c` `83df291` |
| 9 | `…/2026-10-10-dual-mode-capture.md` | 🚧 **已开工**：共享 Dart 层落地（任务清单 #1/#4/#5部分/#10部分/#11部分） | 见第 10 节 |
| 10 | `…/2026-10-10-dual-mode-task-list.md` | 🚧 **清单 #1/#4/#5(协调器侧)/#10(部分)/#11(模型+缓存+校验) 已完成**，原生平台项未动 | 见第 10 节 |

状态记号：✅ 按计划完成 · ⚠️ 完成但有待验证项 · ⏸ 暂停 · 📋 方案已定未开工 · ⛔ 作废 / 取代 · ❌ 未实现

---

## 二、逐计划

### 1. `docs/plan_v0.md` — ⛔ 已作废

v0 草案，**技术选型每一条都已被推翻**，仅作历史留档：`camera_windows` / `camera_macos` /
`camera_linux` 三件套（现统一为 `camera` + `camera_desktop`）、`WebSocketService`、
`ControlMessage` 模型、`DeviceIdService`（UUIDv4）、`WS_URL` 配置项，均已不存在。

**没有按此实现任何东西。**

---

### 2. `2026-10-04-camera-edge-probe.md` — ⛔ 已取代

- **实现过。** `ea5968c feat: implement cross-platform camera edge probe client (T0-T9)`
  按此计划落地过一版完整客户端（T0–T9）。
- **随后被整体推翻。** 该计划假设的后端协议**从未存在过**。已删除：信令集
  （`register` / `heartbeat` / `cmd_*` / `state_sync` / `frame_meta` / `video_meta`）、
  `CommandCodec`、`ClientSignal` / `ServerCommand`、`DeviceIdService`（UUIDv4）、
  `VideoChunkRecorder`（mp4 分片）、`RecognitionHud`（已 grep 确认全仓库零命中）。
  `StreamMode` / `VideoCodec` 换成 `CaptureCodec`；配置项换成
  `BASE_URL` / `DEVICE_ID` / `DEVICE_TOKEN`。
- **仍然有效并被现行代码沿用**（这四条是它真正的遗产）：
  1. 摄像头四层抽象 `CameraProvider` → `CameraBackend` → `CameraService` → `FrameSource`；
  2. 分辨率**一律绝对像素**，禁止假设 `ResolutionPreset.medium == 720p`；
  3. 采集**严禁排队**（单并发排他锁，前次未结束即丢帧）；
  4. kiosk 生命周期姿态（常亮、全屏、切后台停推释放）与预览开关语义。

---

### 3. `2026-10-04-smartclass-backend-integration.md` — ✅ T1–T8，❌ T9

**T1–T8 全部实现**，这是现行后端层的来源：

| 任务 | 产物 |
| --- | --- |
| T1 协议信封 / 消息模型 / 二进制帧 | `lib/src/backend/protocol/{envelope,device_message,device_command,binary_frame}.dart` |
| T2 设备凭据与 HTTP 注册 | `device_credentials.dart` `credential_store.dart` `registration_client.dart` `registration_request.dart` |
| T3 `BackendGateway` 接口与 Mock 后端 | `backend_gateway.dart` `mock_backend_gateway.dart` |
| T4 `SmartClassBackendGateway` | 注册 → 挂载 → 保活 → 退避重注册 |
| T5 编码探测 / 编码器接缝 / mjpeg 帧泵 | `codec_probe.dart` `video_encoder.dart`（`MjpegEncoder`）`frame_pump.dart` |
| T6 协调器改命令驱动状态机 | `agent_coordinator.dart` |
| T7 UI 调整（移除 HUD、状态条改链路信息） | `ui/widgets/status_bar_overlay.dart` 等 |
| T8 配置、凭据装配与联调门禁 | `app_config.dart` `main.dart` |

#### ❌ T9（ffmpeg 编码通道）未实现 —— **有意为之**

- **原因**：`ffmpeg_kit_flutter_new`（原版已退役）是**命令式 API、没有 stdin 流式接口**，
  只能分块编码；且 GPL-3.0 传染。当前帧泵每帧一张自包含 JPEG，没有它的位置。
- **接入点已留**：`VideoEncoder` 抽象 + `CodecProbe`，`lib/main.dart:39` 的注释标了
  「ffmpeg encoder is added here and nowhere else」。
- **后果（是设计的一部分，不是缺陷）**：`supported_codec` 目前只有 `mjpeg`；
  请求 `h264` / `h265` 会被 ack `ok:false`，绝不「照跑但假装成功」。

---

### 4. `2026-10-04-android-server-e2e-test.md` — ✅ 已通过（T0–T8）

真机（`V2405A`，Android 16）× 真实 `smartclass-webcam-server` 跑通一整轮：
注册 / 挂载 / 保活 / `switch_camera` / `start_recording` / `stop_recording` / `take_photo` /
断线重连 / **字节级校验**（落盘 segment 解出来逐帧验 JPEG）。T8（ticket 一次性）是纯 curl 项，可选。

落地产物：

- `docs/android-setup.md` —— 真机 runbook（含「不用 `flutter run` 也能驱动真机」一节）
- `tool/e2e/` —— segment 字节校验脚本、无对象存储时的最小 S3 替身
- `README.md` 的「端到端联调环境」一节

这一轮**发现并修掉的真 bug**：`2c46c7f`（先认领 stream 再启动泵，否则每次录制丢第一帧）、
`d81992b`、`45364b2`（相机 HAL 追加在 EOI 之后的 0 字节）、`5f40a4c`、`aed8263`。

---

### 5. `2026-10-05-runtime-backend-settings.md` — ✅ 已实现（T1–T8）

目标达成：**换后端 / 换凭据不再需要重新打包。**

| 任务 | 产物 |
| --- | --- |
| T1 纯 Dart 配置层 | `lib/src/config/connection_settings.dart` |
| T2 持久化 | `settings_store.dart` + `shared_prefs_settings_store.dart` |
| T3 协调器支持重配 | `AgentCoordinator.reconfigure()` + `BackendGatewayFactory` |
| T4 装配 | `lib/main.dart` |
| T5 UI | `settings_screen.dart` `settings_button.dart` |
| T6 测试 | 见下「验证」 |
| T7「测试连接」按钮 | `lib/src/backend/health_probe.dart`（`GET /healthz`，无鉴权、不消耗 ticket） |
| T8 真机验收 | ⚠️ **部分**：设置界面本身在真机上用过（凭据就是通过它填进去的），但计划里 T8.3 的「401 恢复」没有单独走一遍 |

#### 偏离计划的 2 处（都是 bug 修复，不是取舍）

1. **`SettingsStore.load()` 拆成 `loadBaseUrl()` / `loadCredentials()`**（`95ca378`）。
   计划设计的是单个 `load()`，返回 null 触发播种。但老版本只写过凭据、没写过 `base_url`：
   单值读取返回 null → 播种算出的 settings **不带凭据** → `save()`（**替换语义**）
   → **把好设备的身份删掉了**。真机上真的发生过（prefs 里只剩 `base_url`）。
   拆成两个问题后，播种只补不删。
2. **`pause()` / `resume()` 改成对称的 unbind / bind**（`c8262de`）。
   原实现 `pause` 只停 gateway 不解绑、`resume` 也不重新绑定。加了 `reconfigure` 之后
   这成了真 bug：**后台重配会换掉 gateway 但没人订阅它**，`resume()` 起来的是个「聋」实例。

#### 有意不做

**采集参数（fps / 分辨率 / 质量）不在设置界面。** 它们不是「换个后端就要改」的东西，
而且 fps 与分辨率是注册时 announce 的，改动必须连带重建 announcements。
（这一条在 2026-10-07 的能力探测计划里以另一种方式补齐了：现在服务端可以通过
`switch_camera` 参数驱动模式。）

---

### 6. `2026-10-07-camera-capability-probe.md` — ✅ 已实现（T1–T9）

> **逐任务实施报告见 `docs/2026-10-07-camera-capability-probe-implementation.md`**
> （含计划步骤级别的对照、18 步本机无法执行的 `flutter test`、8 处偏离的完整理由）。
> 本节只是总览。

九个任务全部落地。设备现在**先测出每个摄像头真能干什么**，排成规范顺序，注册时声明出来，
并按服务端下发的参数切换模式。

| 任务 | 产物 |
| --- | --- |
| T1 能力模型 / 常见阶梯 / JPEG 尺寸读取 | `camera_capabilities.dart`、`jpeg.dart` 的 `jpegSize()` |
| T2 规范摄像头顺序 | `camera_order.dart`（纯）+ `plugin_camera_ranker.dart`（插件）+ `CameraPluginBackend` 置换 |
| T3 能力探测 | `capability_probe.dart`（契约）+ `plugin_capability_probe.dart`（实现） |
| T4 能力持久化 | `capabilities_store.dart` + `shared_prefs_capabilities_store.dart` |
| T5 声明 supported 列表 | `registration_request.dart` 的 `CameraDeclaration` / `buildAnnouncements` |
| T6 新命令参数 | `SwitchCameraCommand.resolution/fps`、`StartRecordingCommand.codec`、`envelope.dart` 解析 |
| T7 协调器模式状态 | `AgentCoordinator._modes`、`declaredCapabilities()`、`reportStatus()` |
| T8 启动探测与装配 | `lib/src/app/capability_bootstrap.dart`、`bootstrap_screen.dart`、`main.dart` |
| T9 手动重新检测 | `settings_screen.dart` 的「重新检测」按钮 |

#### 有意偏离计划的 8 处

| # | 计划写的 | 实际做的 | 为什么 |
| --- | --- | --- | --- |
| 1 | T4：**两个键** `camera_capabilities_fingerprint` + `camera_capabilities_json` | **一个键 `camera_capabilities`**，存一个 JSON 对象 | `SharedPreferences.setString` 是**整份重写**，两次调用就是两次写盘，中间掉电会留下「新指纹 + 旧能力」—— 正是两键布局要防的错配。合成一个对象才真的原子。 |
| 2 | T4：解析失败返回**空能力** | 返回 **null（= 重探）** | 空会让设备永远只声明「我正在用的那一对」并且**不再刷新**（命中一直在）。null 能自愈。 |
| 3 | T2：`CameraRanker` 接口放在 `plugin_camera_ranker.dart` | 接口放在纯的 `camera_order.dart` | `ensureInventory` 要编排排序，必须保持 Flutter-free 才能在 `tool/verify_pure.dart` 里跑 —— 而编排逻辑（缓存命中、退化、排序失败回退）恰恰最值得跑。同样处理了 `CapabilityProbe` 与 `CameraEnumerator`。 |
| 4 | T8：缓存命中「skips **both** the ranking and the probe」 | ~~跳不过排序~~ → **已按计划实现** | 首版只省了探测（键是有序集合，而顺序来自排序，构成循环）。**已关闭**：改为对无序集合指纹化 + 把规范顺序存进缓存内容，命中时按名字映射回当前枚举、重算置换。现在命中零开合。 |
| 5 | T8：指纹 = 有序摄像头名 | **有序名字 + enum** | 两台同型号 USB 摄像头在 Windows 上**枚举出同一个名字**，只用名字会让 1 号拿到 0 号的能力。这不是假设，是教室里的常见配置。 |
| 6 | T7：codec 检查 = 是否在 `supported_codec` 里 | 用 `CaptureCodec.isIntraOnly` | 帧泵每帧都是一张自包含的图，需要帧间状态的 codec 根本编不出来。**声明是主张，错误的主张不能让设备 ack 一个它做不到的事。** |
| 7 | T6：绝不静默忽略被请求的 codec / 分辨率 | `resolution` / `fps` / `codec` 一律**宽松解析成 null** | 拒绝 payload 会让命令**消失** → 协调器看不到 → **永远不 ack**，而服务端不重试 —— 运营侧只看到一个毫无反应的命令。**能用但设备做不到**的值仍然 `ok:false` 拒绝，那才是协议真正要防的。 |
| 8 | T8：`ensureInventory({required CameraLister listCameras, …})` | `required CameraEnumerator enumerate` | `CameraLister` 返回 `CameraDescription`（来自 `package:camera`），用它会让 `capability_bootstrap.dart` 不再是纯 Dart，与 T8 Step 6「新纯文件要被 `tool/verify_pure.dart` 覆盖」矛盾。改成返回领域模型 `CameraDescriptor` 的 `CameraEnumerator`，插件侧由 `pluginCameraEnumerator()` 适配。连带 `CameraInventory` 多了 `order`（announced enum → physical index）。 |

> 第 7 条是**与计划明确冲突**的一处，不是执行疏漏 —— 已写在 `01f95c6` 的 commit message 里，
> 没有偷偷选一个。计划对 codec 的指示本身就是「未识别 → null」，对 `resolution` 采取相反规则
> 会更糟。

#### 计划外的额外修复（执行中发现）

- **`61504e9` 构造环 —— 真机上卡在 splash 页。** `AgentCoordinator` 在自己的构造函数里调用
  gateway 工厂，而工厂里 `_declarations(…, coordinator, …)` 是**急切求值**的，
  读了一个还没赋值的 `late final` → `LateInitializationError` → 被 await 链吞掉 →
  **不崩、不打日志、splash 永远挂着**。修法：`SmartClassBackendGateway.cameras` 从
  `List` 改成 `List<CameraAnnouncement> Function()`，**注册时才读**。
- **`BootstrapRoot` 不再吞掉启动失败** —— 捕获、打栈、渲染失败页 + 重试按钮。
  真正的教训不是那个异常，而是**「起不来的设备看起来像起来了」**。
- **`T9` 的 `adoptInventory` 改走 `reconfigure()`。** 最初直接 `start()`，但摄像头清单是
  在构造 gateway 时烘进去的 —— 在同一个实例上重新注册只会把**旧清单再发一遍**，
  新测出来的能力被缓存、却永远不会被公布。断言 `factory.built.length` 从 1 变 2 才抓住它。

#### Deferred（计划自己列为「separate plans」）

- **原生编码管线** —— 让原始帧不进 Dart：fork/vend `camera_desktop`，在同进程的
  GStreamer / Media Foundation 管线里编码，只有压缩字节跨进 Dart。
- **H.264 / H.265** —— 原生层接 ffmpeg（x264/x265 的 GPL 构建，或仅 H.264 的 `libopenh264`），
  硬件编码器作为同一 `NativeEncoder` 接口后的第二个后端。
- **无磁盘帧通路** —— 依赖上一条；在此之前 `TakePictureFrameSource` 保持原位。
  → **三条都已开工**，见下面第 7、8 节。

---

### 7. `2026-10-09-recording-correctness-and-native-encoder.md` — ⚠️ Phase A + T5 完成，Phase B 进行中

两阶段：先修两个被 Feature 1 从「潜在」变成「活的」的录制正确性 bug，再给设备一个真编码器。

| 任务 | 状态 | 产物 |
| --- | --- | --- |
| T1 `start_recording` 必须激活它点名的摄像头 | ✅ `604316d` | `agent_coordinator.dart` 抽出 `_activateCamera()` |
| T2 裸切到不同上限的摄像头必须重建几何 | ✅ `6ca637c` | 比较对象从「目标摄像头自己的 mode」换成**管线实际所处的 `_config`** |
| T3 Annex B 切分 | ✅ `36f55a8` `d910ea0` | `annexb.dart`，且从无状态函数改成有状态的 `AnnexBSplitter`（libavcodec 会把 SPS/PPS 单独打成包，无状态切分会把参数集丢了） |
| T4 可持续帧率模型 | ✅ `a438a74` | `encode_budget.dart`：`sustainableRates` / `sustainableCodecs` / `maxSustainableFps` |
| T5 Dart 侧编码器契约 | ✅ `f2341e5` | `native_video_encoder.dart` |
| T6–T9 四端原生编码流 | ⏸ **Linux 已暂停**，其余未开始 | 见第 8 节 |
| T10 协调器换 `EncoderFactory` + per-mode codec | ❌ 未开始 | 纯 Dart，可独立做 |
| T11 许可 / 打包 / 文档 | ❌ 未开始 | 用户已确认接受 GPLv2+ |

#### T5 的两处偏离（有意）

1. 计划写的通道是 `Stream<Uint8List>`，实际是 `Stream<EncodedPacket>`，多一个 `pictures`。
   因为计划自己的验收项里有「count mismatch 就整批丢」，而 **Annex B 没有长度前缀** ——
   只有字节根本无从判断「本来该有几帧」，那条检查写不出来。native 侧一次喂一帧，所以它知道。
2. 「`stop()` flushes」落实为 **`close()` 先于 `cancel()`，且 `_running` 要等 `close()` 完成
   才置 false**。反过来的话插件 flush 出来的尾巴会被判成 late packet 丢掉 —— 录制少几帧，
   而服务端完全无法察觉。另加了 `_opened` 标志：`start()` 内部会先调 `stop()`，
   没开过的 channel 不该被 close。

#### Feature 1（用户自己的提交 `bf998a8`，我补了测试）

默认分辨率 = 各摄像头实测上限。提交时是红的（三条断言还写着旧的 720p 播种值），
`87f6fe0` 改成 `1920x1080`。**依据不是"让测试变绿"，而是 fixture 注释本身就写着
「The device seeds at the measured ceiling — 1920x1080 @ 5fps」** —— 断言与 fixture
互相矛盾，改的是断言。

> ⚠️ 2026-10-10 补记：同一条根因在 `test/` 下还留了两条（`a28d144`），
> 因为当时只扫了 `tool/verify_pure.dart`。**改播种/默认值的提交必须两处一起扫。**

---

### 8. `2026-10-09-linux-encoded-stream.md` — ⏸ 已暂停

> **完整交接见 `docs/linux-encoded-stream-status.md`。** 本节只是总览。

- **已落地**：`441df72` vendor `camera_desktop` 进仓库（`packages/camera_desktop/`）、
  `f10f86c` 编码器可用性探测、`83df291` 编码分支本体 + 字节交给 Dart + 接进 `Camera`。
- **停在这里的原因**：这一批全是 Linux C++，而本机（Windows）编译不了 ——
  `flutter build` / `analyze` / `test` 在助手 shell 里全部失败，Linux 的 GStreamer 与
  `flutter_linux` 头文件在本机也不存在。**一行都没有编译过。**
- **为什么不再往下写另外三端**：上游计划 T6 Step 1 那个闸就是为这个设的 ——
  攒一批没人编译过的原生代码，等于把成本推给后面。
- **⚠️ 顺序已改**（2026-10-10）：原顺序 Linux → Windows → macOS → Android 是错的 ——
  它把**谁都编不了**的 Linux 排在了第一站。新顺序 **Android → Windows → macOS → Linux**，
  依据是"用户能编能跑"：Android 有真机、Windows 就是这台机器。详见第 9 个计划。
- **恢复时先查四件事**（详见交接文档）：`h264parse config-interval=-1` 的语义、
  `queue leaky=2` 的丢帧方向、`fl_value_new_uint8_list` 的签名（**唯一会直接挡住编译的**）、
  caps 是否真的协商上了（断言没写）。

---

### 10. `2026-10-10-dual-mode-task-list.md` — 🚧 共享 Dart 层已落地

**现行决策入口是 `docs/adr/0001-dual-mode-capture-decisions.md`**，本节只记进度。

2026-10-10 第一批完成的项（全部有 `dart run tool/verify_pure.dart` 断言 + 变异验证；
当时 `passed: 945`。**断言数以实跑输出为准**，第二批见下方 #9 两行）：

| 任务 | 状态 | 内容 |
| --- | --- | --- |
| #1 门禁接线 | ✅ 全部 | `runAnnexBChecks` / `runEncodeBudgetChecks` 由主入口调用，不再是只写未运行；新增 `verify_default_mode.dart` 同样接入 |
| #4 默认模式 | ✅ 2/3 | `default_mode.dart` 唯一选择器；main 的 `openConfig`、协调器 `seedModes`、`adoptInventory` 三处同源。4K→1080p、形状保持（交叉相乘）、帧率只降不升。**未闭合：无证据时的 fps 仍是 60（#26 开放决策）** |
| #5 协调器编码工厂 | ✅ 协调器侧 | `VideoEncoderFactory` 替代裸泵路径；`codecsForMode()` 按模式过滤（证据∩公告）；工厂拒绝 → `ack ok:false`；`isIntraOnly` 不再作可用性判据；点名 codec 不偷换 |
| #10 AU 切分 | ⚠️ 部分 | 多 slice 合并为一个 AU（H.264/HEVC 首 slice 标志）；chunk 边界收口语义文档化；**pending 字节量有上限**（`kMaxPendingBytes` = 1 MiB，超限丢弃并计数 `pendingOverflows`/`droppedPendingBytes`，随后按下一个起始码重新同步）；残缺/非法 slice 头系统用例（无 slice 头、单字节 HEVC NAL、未知类型、相邻起始码、孤立 continuation、后缀 SEI）。**缺：真实样本解码证明（B 类）** |
| #11 吞吐证据 | ⚠️ 模型层 | `EncodeSample` 证据模型 + `EncodeEvidence` 缓存（版本/指纹/编码器身份，损坏自愈）+ `canServeMode`/`sustainableCodecsAt` 按模式校验 + `SustainedRateMeter`（预热不计、只数新帧、窗口固定）+ `EncodeBudgetProbe` 接缝 + `SharedPrefsEncodeEvidenceStore`。**缺：插件侧测量管线（没有任何平台实现 `EncodeBudgetProbe`）** |
| #4.1 声明帧率 | ✅ 已修复 | 声明帧率与请求帧率拆开：请求 60（泵不节流），声明在有证据时取实测、**无证据时取下限 5**（不再声明 60）。探针给不出这个数——它只测「接受」不测「持续」，已写进 ADR |
| #9 编码通道契约 | ⚠️ 2/3 | `EncodedPacket` 增加 `sourceSeq`/`sourcePts`/`sessionGeneration`/`isEos`；`EncodedStreamChannel.open()` 增加 `sessionGeneration`；`EncodedFrame` 增加 `sourceSeq`/`sourcePts`。`start`/`stop` 走 `SerialLock`，`open` 失败回滚，旧 run 的包按代次丢弃（`stalePackets`）。**缺：bitrate（协议无此字段）、`close()` 超时兜底** |
| #9/A2 生产者接线 | ✅ 已完成 | `measureDeliveredRate()`（`sustained_rate.dart`）把编码器交付流喂给 `SustainedRateMeter`，喂 `sourceSeq` 而非 `seq`。门禁用**真实 `NativeVideoEncoder`** + 重复源序号证明「重复不算交付」。**注意：生产侧暂无调用者** —— 它是各平台 `EncodeBudgetProbe` 的公共身体，而那些实现都还没有 |

**变异验证记录**（改坏实现 → 确认断言变红）：

| 变异 | 挂 |
| --- | --- |
| Annex B IDR 判定改坏 | 15 条 |
| 编码吞吐去掉「候选 ≤ 实测」 | 10 条 |
| Annex B 退回「一个 VCL = 一幅图」 | 7 条 |
| 协调器退回「可用性不按模式」 | 4 条 |
| 默认模式退回「取实测上限」 | 8 条（含 main/adoptInventory 打开 4K） |
| 持续帧率把重复帧当交付 | 7 条（`videorate` 凑数的陷阱） |
| 编码器不按代次丢弃旧 run 的包 | 4 条 |
| 一个包里的多张图共用同一个源序号 | 1 条 |
| `open` 失败后不回滚 `_running` | 1 条 |
| 不记录生产者声明的 EOS | 1 条 |
| 每个 run 不递增 session 代次 | 6 条 |
| `start`/`stop` 去掉串行锁 | 1 / 3 条 |
| 把 `cancel()` 挪到 `close()` 之前 | 10 条（尾包被丢，正是该次序要防的） |
| meter 喂 `seq` 而不是 `sourceSeq` | 3 条（重复帧被当成交付） |
| Annex B：关掉 pending 上限 | 6 条（缓冲无界增长） |
| Annex B：无条件丢弃 pending | 19 条（参数集不再随图像走） |
| Annex B：截断 pending 而非丢弃 | 1 条（残渣混进下一个单元） |
| Annex B：不计数溢出 | 2 条 |
| Annex B：把缺 slice 头当 continuation | 1 条（两个单元并成一个） |
| Annex B：把 HEVC 后缀 SEI 当图像数据 | 10 条 |

**明确没做的**：#7/#12–#13（Android vendor + 原生编码）、#16–#22（Windows/macOS/Linux 原生）、
#23（实测状态 UI）、#24/#25（发布收口）。这些需要用户跑构建/真机，助手侧无法验收。

---

## 三、明确没做的（汇总）

| 项 | 所属 | 性质 |
| --- | --- | --- |
| v0 全部技术选型 | `plan_v0.md` | 作废 |
| v1 协议层（信令集、`CommandCodec`、`DeviceIdService`、`VideoChunkRecorder`、`RecognitionHud`） | camera-edge-probe | 被后端现实推翻 |
| ffmpeg 编码通道（T9） | smartclass-integration | **有意不做**，接入点已留 |
| 人脸识别 HUD | camera-edge-probe | 设备协议里没有结果来源，移除 |
| 采集参数进设置界面 | runtime-settings | **有意不做**（注册时 announce） |
| 原生编码管线 / H.264 / H.265 / 无磁盘通路 | capability-probe | ~~Deferred~~ → **已开工，Linux 端暂停**（见第 8 节） |
| Windows / macOS / Android 三端原生编码流 | recording-correctness T7–T9 | ❌ 未开始（等 Linux 端编译通过再动） |
| iOS 构建 | 发布 | 需要付费 Apple Developer 证书 + provisioning profile |

---

## 四、验证到什么程度

| 层 | 状态 | 说明 |
| --- | --- | --- |
| `dart run tool/verify_pure.dart` | ✅ **以实跑输出为准**（HEAD `c84120a` 之上新增 Annex B 专项、编码吞吐专项、默认模式专项、持续帧率专项，以及编码通道契约/生产者接线、Annex B pending 上限与残缺 slice 头；最近一次 `passed: 1071, failed: 0`） | 本机**唯一能执行**的验证层。覆盖协议、注册、两个网关、采集管线、协调器状态机、串行锁、JPEG 裁剪、地址校验、能力算术、规范顺序、能力缓存、启动编排、构造顺序回归、能力报告、Annex B 切分（含 pending 上限与残缺/非法头）、可持续帧率模型、**原生编码器 Dart 侧契约与启停生命周期** |
| `dart format` 闸门 | ✅ 干净 | `dart format --output=none --set-exit-if-changed lib test tool` |
| 全量类型检查 | ⚠️ **换了一条路** | `dart analyze` / `flutter analyze` 因同一个管道问题失败（`CreateFile failed 231`）。替代：**Python 驱动 `frontend_server_aot.dart.snapshot` 单次编译**（`%TEMP%\wb_check.py`），只覆盖 Dart，不覆盖任何 C++ |
| `flutter test` | ✅ **用户跑的，全绿** | 助手跑不了（同上）。`+355 -2` 的两个失败（`a28d144` 前）已修并在 `a28d144` 之后重跑通过 |
| `flutter build` / `run` / Linux C++ 编译 | ❌ **本机完全跑不了** | 两条独立的限制：① 助手 shell 建不了子进程管道；② Linux 的 GStreamer / GTK / `flutter_linux` 头文件在本机不存在。这就是 Linux 端暂停的原因 |
| 真机 · Android 端到端 | ⚠️ 部分 | 基础链路跑通过一整轮（见计划 4）。**但能力探测这一轮（T8/T9）没在真机上验过**，`61504e9` 的 kiosk 修复也待重出包确认 |
| CI 四端出包 | ⚠️ 未确认 | `.github/workflows/release.yml` 已建，Android SDK 与 artifact 路径两个问题已修；远端已打 `v1.0.0`–`v1.0.3`，但运行结论本机看不到（GitHub API 限流、无 `gh`） |

### 变异测试（「断言有牙」的证据）

关键回归断言都做过**变异测试** —— 把代码改回 bug 版本，确认断言真的会红：

| 变异 | 结果 |
| --- | --- |
| `reconfigure` 复用旧 gateway 实例 | 挂 7 条 |
| `reconfigure` 不解绑 | 挂 2 条 |
| `pause()` 不解绑（恢复原来的不对称） | 挂 2 条（一个 id 两个 ack） |
| `resolveConnectionSettings` 改回「有地址才认凭据」 | 挂 1 条 |
| 参数变更后不重新注册 | 挂 2 条 |
| 跳过 `camera.reconfigure()` | 挂 2 条 |
| 跳过分辨率校验 | 挂 1 条 |
| 启动时不读能力缓存 | 挂 2 条 |
| 保留枚举顺序（不做规范排序） | 挂 5 条 |
| Annex B：把 IDR 判定改坏 | 挂 15 条（证明专项检查真的在跑，而非只写未运行） |
| 编码吞吐：去掉「候选 ≤ 实测上限」 | 挂 10 条 |
| Annex B：退回「一个 VCL = 一幅图」 | 挂 7 条 |
| 协调器：退回「codec 可用性不按模式判定」 | 挂 4 条 |
| 跳过探测失败的退化 | 挂 3 条 |
| `adoptInventory` 改回 `start()` | 挂 5 条 |
| `adoptInventory` 不先释放摄像头 | 挂 1 条 |
| gateway 改回构造时读摄像头清单 | 挂 2 条 |

---

## 五、已知缺口 / 下一步

1. **原生编码流的第一站改成 Android**（不是 Linux）。顺序 **Android → Windows →
   macOS → Linux**，依据是"用户能编能跑"。Android 需要先 vendor 第二个插件
   `camera_android_camerax`（CameraX 采集 + MediaCodec 编码），真机 V2405A 可测。
   整体方案见第 9 个计划 `docs/superpowers/plans/2026-10-10-dual-mode-capture.md`。
   Linux 排最后：本机没有 GStreamer/GTK/`flutter_linux` 头文件，**谁都编不了**；
   设计 + 代码已写但未编译，有 WSL2 可随时验证。
2. **`defaultFps` 已按要求改成 60（`b242541`），但当前帧泵交付不了 60。**
   帧泵每帧一张 `takePicture()`，单并发锁会把"上一次还没拍完就来的 tick"直接丢掉，
   1080p 实测约 5–10 fps。而服务端是**用 `fps` 估段时长**的，所以现在会**高估**每段
   持续了多久。这不是疏漏，是有意记录的偏离（常量注释里写明了）：
   抹平这个差距要靠原生编码管线，而那条路正暂停在第 1 条。
   → **恢复 Linux 之后这件事才算真正做完。**
3. **能力探测的真机验收未做。** 重点：插拔一个摄像头 → 点「重新检测」→ 摄像头顺序与
   声明列表应随之改变；以及 `switch_camera` 带 `resolution` / `fps` 时服务端
   `metadata` 快照应跟着更新（这需要重新注册，已实现但未验）。
4. **T8.3「401 恢复」未单独走一遍**（runtime-settings 计划）：令牌改错 → 保存 → 应出现
   「链路失败」且不再重试 → 改回正确令牌 → 保存 → 必须能重新连上。
5. **CI 四端出包的成功与否未确认**，且 Android 产物是否已随 artifact 路径修复正常进入
   Release 也未确认。
6. **Phase B 剩下的纯 Dart 部分可以先做**（不依赖 Linux）：Task 10 协调器换
   `EncoderFactory` + per-mode `supported_codec`。它独立于原生端，而且没有它，
   即使原生端通了，per-mode 的 codec 菜单也不会重算。
7. Windows / macOS / Android 三端原生编码流（T7–T9）等 Linux 端编译通过再动。
   用户已确认 **Android 这一轮要做**。

> 关于计划文件里的 `- [ ]` 复选框：这些计划是**一次性执行**的，复选框未逐个勾选，
> **执行状态以本文档为准**（逐个勾选会把「跑 `flutter test` 期望 PASS」这类
> 本机无法执行的步骤标成已完成，反而不准）。
