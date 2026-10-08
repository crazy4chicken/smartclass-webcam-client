# 计划实施状态

> 覆盖 `docs/plan_v0.md` 与 `docs/superpowers/plans/` 下的五个计划。
> 记录每个计划**实现了什么、有意偏离了什么、明确没做什么、验证到什么程度**。
>
> **最后更新：2026-10-08，HEAD `61504e9`。**
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

状态记号：✅ 按计划完成 · ⚠️ 完成但有待验证项 · ⛔ 作废 / 取代 · ❌ 未实现

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

---

## 三、明确没做的（汇总）

| 项 | 所属 | 性质 |
| --- | --- | --- |
| v0 全部技术选型 | `plan_v0.md` | 作废 |
| v1 协议层（信令集、`CommandCodec`、`DeviceIdService`、`VideoChunkRecorder`、`RecognitionHud`） | camera-edge-probe | 被后端现实推翻 |
| ffmpeg 编码通道（T9） | smartclass-integration | **有意不做**，接入点已留 |
| 人脸识别 HUD | camera-edge-probe | 设备协议里没有结果来源，移除 |
| 采集参数进设置界面 | runtime-settings | **有意不做**（注册时 announce） |
| 原生编码管线 / H.264 / H.265 / 无磁盘通路 | capability-probe | Deferred |
| iOS 构建 | 发布 | 需要付费 Apple Developer 证书 + provisioning profile |

---

## 四、验证到什么程度

| 层 | 状态 | 说明 |
| --- | --- | --- |
| `dart run tool/verify_pure.dart` | ✅ **652 项断言全绿** | 本机**唯一能执行**的验证层。覆盖协议、注册、两个网关、采集管线、协调器状态机、串行锁、JPEG 裁剪、地址校验、能力算术、规范顺序、能力缓存、启动编排、构造顺序回归、能力报告 |
| `dart format` 闸门 | ✅ 干净 | `dart format --output=none --set-exit-if-changed lib test tool` |
| 全量类型检查 | ✅ 干净 | 37 个编译单元，Python 驱动 `frontend_server_aot` 单次编译 |
| `flutter test` | ⚠️ **本机跑不了** | Dart VM 在助手 shell 里创建不了子进程。最后一次运行 `+333 -2`，两个失败已在 `dbd1135` 修掉并镜像进 harness，**修后未再跑** |
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
| 跳过探测失败的退化 | 挂 3 条 |
| `adoptInventory` 改回 `start()` | 挂 5 条 |
| `adoptInventory` 不先释放摄像头 | 挂 1 条 |
| gateway 改回构造时读摄像头清单 | 挂 2 条 |

---

## 五、已知缺口 / 下一步

1. **`flutter test` 未在 `dbd1135` 之后重跑。** 这是当前最该做的一步 —— 它也是 CI 的
   `verify` job 第一次真跑的入口。
2. **能力探测的真机验收未做。** 重点：插拔一个摄像头 → 点「重新检测」→ 摄像头顺序与
   声明列表应随之改变；以及 `switch_camera` 带 `resolution` / `fps` 时服务端
   `metadata` 快照应跟着更新（这需要重新注册，已实现但未验）。
3. **T8.3「401 恢复」未单独走一遍**（runtime-settings 计划）：令牌改错 → 保存 → 应出现
   「链路失败」且不再重试 → 改回正确令牌 → 保存 → 必须能重新连上。
4. **CI 四端出包的成功与否未确认**，且 Android 产物是否已随 artifact 路径修复正常进入
   Release 也未确认。
5. 三个 Deferred 项（原生编码管线 / H.264·H.265 / 无磁盘通路）需要各自的计划。

> 关于计划文件里的 `- [ ]` 复选框：这些计划是**一次性执行**的，复选框未逐个勾选，
> **执行状态以本文档为准**（逐个勾选会把「跑 `flutter test` 期望 PASS」这类
> 本机无法执行的步骤标成已完成，反而不准）。
