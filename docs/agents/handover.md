# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：`HEAD = 09d1d52`，`origin/master = 01453f7` → 有 1 个提交未推送**（`fix(android): a
  custom VideoOutput cannot build a StreamInfo on CameraX 1.6.2`）。工作区干净。**接手第一件事
  建议：`git push`。**
- **Android 编码流 Task 4 的第一块代码已经过真机 Gradle 编译**：先是 4 个 javac error，
  修完后**用户跑 `flutter run -d 10AF5R29MC004Y6` 通过**（这是它第一次被真正编译 + 装到真机）。
  修的过程里**本机用 `javac` 先复现那 4 个 error、再确认修到 0 error**（命令见 ADR 0002 §10.6）。
- **Task 4 的文件现状（以文件系统为准）**：已有 `EncodedStreamVideoOutput.java`、
  `lib/src/capture/encoded_stream_transport.dart`；**待写** `EncodedStreamPlugin.java` 与
  `lib/src/capture/camera_plugin_encoded_transport.dart`。另：本文早先写的
  `windows/record_handler.cpp` 是**错路径**，实际是
  `packages/camera_desktop/windows/record_handler.cpp`。
- 门禁 `passed: 1290, failed: 0`（本轮实跑）。`dart format` / `check_compile.py` 本轮未跑
  （本次没动 Dart）。
- `docs/superpowers/plans/2026-10-10-android-encoded-stream.md` 的 7 个任务：
  Task 1–3 已落地，**Task 4 第一块（本文件）已过编译，Task 4 剩余两块 + 冒烟入口未写**。
- **真机仍在**（vivo V2405A / mt6991 / Android 16 / arm64-v8a）。实测特征表在 ADR 0002 §七，
  **别重测**。

## 下一步任务

（编译这一步已完成，直接往下做。）

**Task 4 剩下的三块**（顺序即依赖）：

1. `EncodedStreamPlugin.java`：注册 `MethodChannel('smartclass/encoded_stream')` +
   `EventChannel('smartclass/encoded_stream/packets')`；`open` 里由 `cameraId` 推出 `CameraSelector`、
   建 `EncodedStreamVideoOutput`、自建 `VideoCapture` 并**单独 `bindToLifecycle` 一次**
   （ADR §九：增量追加，不必拿 Preview/ImageCapture 的引用）；`close` 走 EOS 冲刷；
   生命周期所有者从 `ProxyApiRegistrar.getLifecycleOwner()` 取。
   **建 `VideoCapture` 时必须遵守 ADR §10.5 的三条硬约束**（尤其 `setResolutionSelector`）。
2. `lib/src/capture/camera_plugin_encoded_transport.dart`（Flutter 薄壳，实现
   `EncodedStreamTransport`；**不做任何解析** —— 解析在 Task 3 那层）。
3. `main.dart` 的**临时**冒烟入口（`--dart-define=ENCODED_STREAM_SMOKE=true`），Task 5 删掉。

**再然后**：Task 5 → Task 6（`AndroidEncodeBudgetProbe`）→ Task 7（真机端到端 + 长稳）。
**Task 4 Step 6 验收**：10 秒内 AU ≥ 550（≥55fps）、选中的是 `c2.mtk.hevc.encoder`、
同期拍照仍成功。**只有 30 上下就停下查帧率协商，不许带着 30fps 往下做。**

之后才是 Windows（`packages/camera_desktop/windows/record_handler.cpp:114` 已有进程内 MF H.264）
→ macOS。

## 卡点

- **运行时仍未证明。** 编译过 ≠ 能绑上。ADR §八第 1 条仍是最大的不确定性：CameraX 1.6.2 是否
  接受一个第三方 `VideoOutput` 与 Preview + ImageCapture 并存（增量绑定只有源码证据）。
- **`getMediaCapabilities()` 报「只 SDR、不报 quality」是一个推断出来的安全选择，未上机验证。**
  依据是 `VideoOutput` 的默认 `VideoCapabilities.EMPTY` 会给出**空的**动态范围集合，而
  `VideoCapture` 要拿它去和别的 use case 求交。若真机绑不上，先看这里（ADR §10.3）。
- **分辨率必须只有一个来源**：调用方在 `VideoCapture.Builder` 上设的 `ResolutionSelector`。
  编码器是按 `MediaFormat` 的宽高 `configure` 的，CameraX 若另给一个尺寸，画面就是坏的。
- `getStreamInfo()` **不能覆写** —— `StreamInfo` 在 1.6.2 是封闭的（ADR §10.1）。别"补"回去。
- **HEVC 在 1080p 的实测速率未知**（只有 720p 与 4K 两档，1080p 靠外推，**外推不是证据**）。
- **peak-vs-plateau 未定**（ADR 0001 §4.1.1，唯一开着的决策）。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。

## 生效约束（仅本任务范围）

- **改 `packages/*/android/**/*.java` 前先跑本机 `javac`**（ADR 0002 §10.6 有完整命令与 jar 清单）。
  这是本次新确认的能力 —— 不要再拿用户的一次 Gradle 构建当第一次检查。
- **⚠️ 本仓有外部编辑器在异步回写文件**（markdown 格式化器），会拿旧缓冲区静默覆盖你的编辑。
  改完**回读磁盘**确认，提交后 `git show HEAD:<file> | grep` 再核一次；
  **别用 `git add -A` 盲提**。
- **`camera_android_camerax` 必须挂 `dependency_overrides`**，不能放 `dependencies`。
- 不引入新依赖。**fork 范围锁死**：只加文件，上游文件唯一允许的改动是
  `CameraAndroidCameraxPlugin.java` 的两行注册，rebase 时手工重放。
- **助手绝不在自己的 shell 里跑 `flutter pub get`**（假 symlink 会毁掉下一次 `flutter run`）；
  `flutter test` / 构建 / 真机一律用户跑。
- 60fps 相关的任何承诺必须有真机实测数字；**只对 vivo V2405A 背书**。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）。
- 新断言必须做过变异验证；新增独立检查文件时**接线与变异验证同一次做完**。
- 提交消息**别用反引号**（bash 会做命令替换吃掉内容），改用 `git commit -F <文件>`。
- 派子代理时**明确禁止它们跑 `git`**：并行子代理并发 add/commit 会撞索引；统一由指挥者提交。
