# AGENTS.md — 项目宪法

<!-- 本文件每次会话全额加载，每一行都在消耗注意力预算。
判断标准：删掉这一行，AI 会犯错吗？不会就删。 -->

## 项目是什么

一句话：Flutter 跨平台摄像头**边缘探针**（kiosk，常亮全屏不锁屏），接
`smartclass-webcam-server` 的设备协议。**设备是从属角色** —— 没收到
`start_recording` 之前什么都不推；每条带 `id` 的命令都必须 ack。
项目散文多中文，**代码注释一律英文**。

## 常用命令

- 跑门禁（**本机唯一可执行的验证层**）：`dart run tool/verify_pure.dart` → 必须
  `failed: 0`。**断言数会漂移，看实跑输出，不信任何文档里的数字。**
- 格式闸门：`dart format --output=none --set-exit-if-changed lib test tool`
- 整仓类型检查：`python tool/check_compile.py`（~5 min，覆盖 `lib/` + 全部
  `test/`、`tool/`）。**它只编译不运行** —— 能发现写坏的 `test/` 文件（门禁看不见），
  但不能替代 `flutter test`。
- ❌ **跑不了**（助手 shell 建不了子进程，`errno = 231`）：`flutter test` /
  `build` / `run` / `analyze`、`dart analyze`。写了 `test/` 就交给用户跑，
  **不要声称跑过**。
- ⚠️ **绝不要在助手 shell 里跑 `flutter pub get`（Windows）**：沙箱里
  `Link.createSync` 不报错却造出空目录假 symlink，会让用户下一次真
  `flutter run` 撞 `ERROR_ALREADY_EXISTS(183)`。

## 红线（违反即返工）

1. **`lib/src/backend`、非插件 `lib/src/capture`、`lib/src/config`、
   `lib/src/agent`、`lib/src/app/capability_bootstrap.dart` 不得 import
   `package:flutter`。** 一引入，本机门禁就再也跑不了。
2. **门禁只有主入口 `tool/verify_pure.dart`。** 专项文件（`verify_*.dart`）必须被
   主入口 **import 并调用**（曾因漏这步零覆盖 ~97 条断言）；每个 section 必须经
   **`guard()`**，不许裸调用 —— `check()` 只记 FAIL，但 `x!.y` 抛异常，裸调用会让
   整轮静默死掉、连 `passed/failed` 那行都不打印。
3. **请求帧率 ≠ 声明帧率。** 请求 = `AppConfig.defaultFps`(60)，泵的 tick 上限、
   **不节流**；声明 = `CameraMode.fps`，写进注册、服务端拿它估段时长，**不得高于
   已证实的交付量**，无证据时声明 `kFpsWithoutEvidence`(5)。这类断言在 **`tool/`
   与 `test/` 两处**，只扫一处会漂（**已踩两次**），且一律用具名常量、不写字面量。
4. **别拿探针的「接受率」当「实测率」。** `_acceptsFramerate` 只证明插件没拒绝
   这个数字；五端插件栈都没有报告真实帧率范围的 API。
   `CameraCapabilities.framerates` **绝不能**填进 `EncodeEvidence`。
5. **摄像头编号一律用「公告序号」，物理下标绝不出 `CameraPluginBackend`。**
   能力声明与校验必须共用 `declaredCapabilities()`，否则运营侧从设备自己印的
   菜单里选一个值、却收到 `ok:false`。
6. **`defaultResolutionFor` / `defaultModeFor` 是「摄像头以什么模式打开」的唯一
   选择器。** 判据永远是：管线打开的几何 == 当前模式 == 公告。调用点：
   `main.dart` 的 `openConfig`、`defaultModeFor` 内部（→`_seedModes`）、
   `adoptInventory`（**最容易被忘**）。
7. **拼设备面 URL 一律 `resolveDevicePath`，禁止 `base.replace(path:)`。** 服务端
   常挂在路由前缀下；读后端 router 得到的是子进程内部视图 ≠ 外部可见路径。
   另：**HTTP 404 也是一次应答**，不能用 `statusCode == 200` 当"可达"。
8. **`AnnexBSplitter`：一个 chunk 必须含完整 picture。** 多 slice 合并靠 slice 头
   **首字节最高位**，不是靠"无 B 帧"推；pending 有 1 MiB 上限，超限丢弃并计数。
9. **采集帧率取自源序号前进量，不是到达计数**（否则 `PipelineBottleneck.encoder`
   永远不可达）；`sendRecordingFrame` 返回是否送达，拒收必须计 `droppedFrames`。
   **诊断字段绝不进 `reportStatus()`**（那是服务端字段），也不含任何凭据。
10. **启停次序定死**：先认领 stream 再 `pump.start()`；`_stopRecording` 先清状态
    再 `await cancel()`；`close()` 先于 `cancel()`，且 `close()` 被 await、
    `cancel()` **不被 await**。同一底层资源有两条调用路径时，串行化放在资源那一层。
11. **没有机器 / 没有证据 / 阻塞的项，保持待办或进行中。** 每平台独立验收，
    任一平台达标都不替其他平台背书。**不许为了凑字段加恒为 0 的假数据。**

## 项目结构

- `lib/src/backend/` 协议与网关 —— 接口不得泄漏 `web_socket_channel` / `http` 类型。
- `lib/src/capture/` 采集抽象与编码器契约（**插件部分单独成文件**）。
- `lib/src/agent/` 协调器与状态机；`lib/src/app/` + `lib/src/ui/` 是 Flutter 层。
- `packages/camera_desktop/` vendor 的桌面插件（**MIT**）；`packages/camera_android_camerax/`
  vendor 的 Android 插件（BSD-3-Clause）。fork 纪律见各自的 `VENDORED.md`。
- `tool/` 门禁与检查脚本；`test/` Flutter 测试（助手跑不了）。
- 桌面三端统一 `camera` + `camera_desktop`，**不要 `camera_windows`**（无 image
  stream、不支持 pause/resume、release 崩溃 #161288）。iOS/Android 系统禁止后台
  用摄像头 → 切后台必须停推 + 释放 + 断连。

## 禁区

- **不擅自增删发布矩阵。** 当前是三端 **Windows / macOS / Android**：iOS 不构建
  （需 Apple 证书），Linux 已于 2026-10-10 按用户明确要求移出。
- **不自行决定 ADR §4.1.1 的 peak-vs-plateau** —— 那是唯一开着的决策。
- 不引入新依赖（确需先问）。
- 不绕过或删除现有断言。**新断言必须做过变异验证**（改坏实现、确认变红）；
  没变红过的断言等于没有断言。新增独立检查文件时，**接线与变异验证同一次做完**。
- **尺寸/几何类断言必须带竖屏 fixture。** 手机默认竖屏，`fitsWithin` 这类逐轴比较在
  竖屏下语义完全不同 —— 只测横屏等于没测「朝向」这个维度。2026-10-10 真机上因此把默认
  几何开成了 240x320，而门禁 104 个横屏 fixture 全绿。
- 不写"已完成"，除非有机器跑过的证据。

## 按需文档（点播层：只在任务涉及时读取，平时勿加载）

- **接手先看**：`docs/agents/handover.md` —— 当前状态 / 下一步 / 卡点（覆盖式更新）。
- **决策冲突以它为准**：`docs/adr/0001-dual-mode-capture-decisions.md`
- 每个计划实现了什么 / 偏离了什么 / 验证到什么程度：`docs/implementation-status.md`
- 不变量全集：`.workbuddy-ai/memory/MEMORY.md`（指针）与 `CONVENTIONS.md`（细节）
- 发布与两个 workflow：`docs/release.md`；Linux 暂停交接：`docs/linux-encoded-stream-status.md`
- 上一轮 A8 复核（带行号）：`docs/agents/review-2026-10-10-dart-side.md`
- 任务清单 26 项（**已勾选的是有证据的**）：
  `docs/superpowers/plans/2026-10-10-dual-mode-task-list.md`
- **Android 60fps 编码流实施计划**（7 个任务，Task 1–3 已落地）：
  `docs/superpowers/plans/2026-10-10-android-encoded-stream.md`
- **Android 编码流的接缝与通道协议**（冲突时以它为准）：`docs/adr/0002-android-encoded-stream-seam.md`
- 端到端工具：`tool/e2e/check_segment.py`、`s3_stub.py`
- Issues 用 GitHub Issues（`crazy4chicken/smartclass-webcam-client`）+ `gh` CLI，
  见 `docs/agents/issue-tracker.md`；triage 标签见 `docs/agents/triage-labels.md`
- 协议权威（**冲突时以后端为准**）：`smartclass-webcam-server/docs/protocol/`
- 根 `GLOSSARY.md` **尚不存在**，别去找。

## 工作流程约定

- **未提交的改动等于不存在。** 报告"完成"必须说清是否已提交 / 推送；只在
  工作区就明说"需要你提交 / 推送"。**这条真出过事故。**
- **两个 workflow 触发不同**：`ci.yml` 分支 push + PR；`release.yml` **只认 tag
  push `v*`**。"我 push 了"不等于你以为的那个 workflow 跑了。**重推没变过的 tag
  不触发任何东西**（要发新版必须推新 tag）。
- **核实，不要假设**：`git status`、`git log --oneline origin/<branch>..HEAD`、
  `git show <commit>:<file>`。`.workbuddy-ai/` 被 gitignore，不算"已提交"。
- 动 `lib/` 的公开形状（接口 / 字段 / 构造参数）→ 跑 `check_compile.py`；
  动 CI → 核对触发条件，并保持两个 workflow 的 `verify` 步骤**逐字相同**、
  `FLUTTER_VERSION` 同步。
- 每完成一个可验证单元提交一次，message 写清"做了什么 + 为什么"。
- **会话结束（任务完成或中断）：最后一步必须覆盖式更新 `docs/agents/handover.md`。**
- **外部编辑器会拿旧缓冲区回写文件，静默覆盖你的编辑**（本仓已发生两次，丢过一整段计划，
  还让一条提交说明成了假话）。改完文档**回读磁盘**确认内容在，提交后
  `git show HEAD:<file> | grep` 再核一次；**别用 `git add -A` 盲提**。
- **`camera_android_camerax` 必须挂在 `dependency_overrides`，不能放 `dependencies`**：
  `camera` 依赖的是 pub.dev 上的它，root 的 path 源替换不了已发布的传递依赖，pub 直接拒绝
  解析（`camera ^0.12.1 requires camera_android_camerax from hosted`）。
