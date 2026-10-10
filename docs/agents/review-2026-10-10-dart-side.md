# A8 收尾复核（Dart 侧）— 2026-10-10

> **这是任务清单 #25 的一半。** A8 有两件事：①「随做随同步」（前三批都在做）；
> ②「最终 whole-branch 复核」，而它**要求分支本身完成** —— 原生端一个都没落地
> （Android / Windows / macOS 全部未开始，Linux 暂停且已移出发布），所以现在
> 只能复核到 **Dart 侧**。本文记录的就是这一层，以及**复核过程中发现并修掉的东西**。
>
> 复核基线：`passed: 1173, failed: 0`（复核后不变）。

---

## 一、复核了什么

| 项 | 命令 / 方法 | 结果 |
| --- | --- | --- |
| 门禁 | `dart run tool/verify_pure.dart` | `passed: 1173, failed: 0` |
| 格式闸门 | `dart format --output=none --set-exit-if-changed lib test tool` | 干净（103 文件） |
| 整仓类型检查 | `python tool/check_compile.py`（约 5 分钟） | `compiled: 44, failed: 0` |
| 不变量 | grep + 逐条读代码（下表） | 全部落实，见 §二 |
| 文档与代码的一致性 | 全仓 md 扫描，逐条对到行号 | 6 处腐化已修，见 §三 |

**没复核的（不能假装复核过）**：原生代码一行没看（没有编译证据，看了也标不了）；
`flutter test` 跑不了；远端 CI 结果看不到（无 `gh`，GitHub API 对当前 IP 限流）。

---

## 二、不变量逐条核对（都能指到行号）

| 不变量 | 核对结果 |
| --- | --- |
| `defaultModeFor` 只有一个调用点 | ✅ `lib/src/agent/agent_coordinator.dart:130`（`_seedModes`），其余 3 处是 `tool/verify_default_mode.dart` 的用例 |
| `defaultResolutionFor` 三处同源 | ✅ `lib/main.dart:201`（`openConfig`）、`lib/src/capture/default_mode.dart:200`（`defaultModeFor` 内部，即 `_seedModes` 那条路径）、`lib/src/agent/agent_coordinator.dart:731`（`adoptInventory`） |
| 拼设备面 URL 一律 `resolveDevicePath` | ✅ 唯一实现 `lib/src/backend/registration_client.dart:222`，调用点 `registration_client.dart:106`、`health_probe.dart:64`、`smartclass_backend_gateway.dart:278`。**唯一的 `base.replace(path:)` 就在 `resolveDevicePath` 体内（:227）**，另有 `health_probe.dart:52` 的注释记着这个坑。无违规 |
| `sendRecordingFrame` 返回是否送达，且不被忽略 | ✅ 接口 `backend_gateway.dart:82` 返回 `bool`；唯一生产调用点 `agent_coordinator.dart:1211` 取了返回值，`:1224` 起 `if (!delivered) { _droppedFrames++; return; }` |
| 诊断字段不进 `reportStatus()` | ✅ `agent_coordinator.dart:556-568`，只有 `active_camera` / `resolution` / `fps`（公告值）/ `recording` / `stream_id` / `frames_sent` / `link`，无诊断、无凭据 |
| fps 断言用具名常量，不写字面量 | ✅ `test/agent/agent_coordinator_test.dart:782/802/983` 与 `tool/verify_pure.dart` 五处全部引用 `kFpsWithoutEvidence`。`test/` 里剩下的 fps 字面量是**命令请求值 / 声明 fixture**（如 `fps: 30` 的 `switch_camera`），不是"默认声明值"，不属于这个陷阱 |
| `backend/` `config/` `agent/` `capability_bootstrap.dart` 不含 `package:flutter` | ✅ grep 唯一命中是 `lib/src/config/connection_settings.dart:17` **注释里的**「no `package:flutter`」字样（误报） |
| 专项 suite 全部被主入口调用 | ✅ `verify_pure.dart:64-69` import 六个，`main()` 里六个全部 `guard(...)` 调用 |
| `lib/` 无残留 ffmpeg / TODO / 未实现占位 | ✅ ffmpeg 零命中、TODO/FIXME 零命中；`UnimplementedError` 只有 `lib/src/capture/frame_source.dart:76/81/86`（`ImageStreamFrameSource`，有意且已在 MEMORY §5.3 记录：照片路径目前不满足「无磁盘」） |

---

## 三、发现并修掉的（本次改动）

### 3.1 门禁：一个 section 抛异常会杀死整轮 —— 已修

**问题**：`main()` 里所有 section 都是裸调用，没有 try/catch。而 `check()` / `eq()`
只记录失败、继续往下走，**但 `x!.y` 或 `.single` 抛的是异常，不是失败**。一旦抛出来：
`main` 死在原地、**不打印 `passed/failed` 那一行**、后面所有 section **静默跳过**。
一个空断言就能藏掉上百条失败，而门禁看起来像"从没跑过"。

这个坑已经在 2026-10-10 的 A3 里踩到过一次（用例在 `result.note!` 上抛异常，
整轮中止、只打了堆栈、没有 summary）。当时只修了那一处，没修机制。

**修法**：新增 `guard(name, body)`（`tool/verify_pure.dart`，`section()` 之后），
把抛出的异常**记成该 section 的一条 FAIL**（并打印一行文件路径:行号），然后继续跑。
`main()` 的 39 个 section 全部改走 `guard`。

**变异验证**（改坏实现 → 确认它真的会红）：在 `checkWireCodec()` 开头插
`throw StateError('MUTATION: ...')` → 输出

```
  FAIL: wire codec threw: Bad state: MUTATION: a section that throws
        at #0      checkWireCodec (file:///.../tool/verify_pure.dart:819:3)
...
passed: 1166, failed: 1        ← 有 summary，后面的 section 照跑
```

且 `exitCode == 1`（CI 会红）。变异已还原。

顺带把 `verify_sustained_rate.dart:58/130` 两处 `result!` 改成 `?.` + 兜底
（这是上一轮点名留下没动的两处）。其余 20 多处 `!` **没有批量改** —— 有了 `guard`，
它们最多让所在 section 提前结束，不再有"杀死整轮"的后果；批量替换是纯 churn。

### 3.2 `docs/implementation-status.md` 六处腐化 —— 已修

| 行 | 原内容 | 问题 / 改成 |
| --- | --- | --- |
| 279 | 「#4 默认模式 ✅ 2/3 … **未闭合：无证据时的 fps 仍是 60**」 | 与同表 #4.1 行（已修复）**自相矛盾**。改成 ✅ 已完成，并指出仍开着的只有 ADR §4.1.1 的 peak-vs-plateau |
| 330 | 「Windows/macOS/Android 三端原生编码流 … **等 Linux 端编译通过再动**」 | 与 ADR §五的落地顺序 **Android → Windows → macOS → Linux** 相反，且与"Linux 暂停"的事实矛盾。已改 |
| 339 | 门禁行：最近一次 `passed: 1071`；覆盖清单**漏了速率标定与流诊断两个专项** | 更新为 1173，补上两个专项，并写明「七个专项全部由主入口调用」+ `guard()` |
| 341 | 「替代：Python 驱动 `frontend_server_aot.dart.snapshot`（**`%TEMP%\wb_check.py`**）」 | 那个临时脚本早已固化成仓库内的 `tool/check_compile.py`。已改，并保留「只编译不运行，编译通过 ≠ 断言通过」 |
| 345 | 「远端已打 `v1.0.0`–`v1.0.3`」 | 实际已到 `v1.1.2`。已更新，并补一句：`ci.yml` 是 2026-10-10 新增的，此前分支 push 从不触发任何检查 |
| 288-311 | 变异表**只到 Annex B**，A3（速率标定 4 组）与 A4（诊断 4 组）的变异证据**一行都没进表** | 已补 8 行，含"采集改回数到达 → `PipelineBottleneck.encoder` 永不可达"这条理由 |
| 26-27 | 总览表第 10 行只列 #1/#4/#5/#10/#11 | 补上 #23、#9+A2、#4.1、#24 的三端收窄 |

---

## 四、发现但**需要用户定夺**的（我没有自行处理）

1. **`outputs/dual-mode-task-list.md` 是已提交的重复副本。** 当前与正文
   `docs/superpowers/plans/2026-10-10-dual-mode-task-list.md` **逐字节相同**（`diff` 确认，
   是在 `9160151` 里同步的），所以现在不"陈旧"。但它是**必须手工同步的第二份**，
   下次改正文就会再次漂移。**建议删掉**（正文在 `docs/superpowers/plans/`），
   删与不删由你定 —— 我没有擅自删 tracked 文件。
2. **ADR §4.1.1：注册写 peak 还是 plateau，仍然开着。** 现在的行为是 peak。
   工具（`readRateSeries()` 分开报 `peakFps` / `plateauFps`、`peakOverstatesSustained`）已就位，
   换策略是一行改动，但它是**行为变更**，不自行定。
3. **本地 `87d6eb2`（handover 刷新）仍未推送。** `origin/master` 停在 `9160151`。
   tag `v1.1.2` 已在远端且指向 `9160151`（含 Linux 移出发布那次修改）—— 之前
   「改了没提交 → 白推 tag」的事故已经闭环。这次的复核改动也**只在工作区**。
4. **`flutter test` 仍要你跑**：`test/ui/status_bar_overlay_test.dart`（按新诊断字段重写过）
   与 `test/agent/agent_coordinator_test.dart`。`check_compile.py` 只能证明它们**编得过**
   （`compiled: 44, failed: 0`），证明不了断言过。
5. **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 返回
   `API rate limit exceeded`。

---

## 五、核对过的"看起来像问题其实不是"的

- **`lib/src/backend/registration_client.dart:227` 用了 `base.replace(path:)`** ——
  它在 `resolveDevicePath` **体内**，是那个拼接唯一该出现的地方，不是违规。
- **`pubspec.yaml` 永远停在 `1.0.0+1`，而 tag 已到 `v1.1.2`** —— 有意的：
  版本号是在 runner 里"盖"进 pubspec 的（`release.yml:147-155`），文件不提交回来。
  `docs/release.md:165-168` 已写明。
- **`grep "package:flutter"` 命中 `connection_settings.dart`** —— 命中的是注释
  「Pure Dart on purpose — no `package:flutter`」，误报。
