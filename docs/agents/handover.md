# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：`60d9c7c` 已推送**（#14 Dart 侧 + handover）；本轮新增的计划文件
  `docs/superpowers/plans/2026-10-10-android-encoded-stream.md`，已提交。
- 门禁 `passed: 1216, failed: 0`；`dart format` 干净（105 文件）；
  `check_compile.py` `compiled: 45, failed: 0`。**本轮只写文档，没动代码。**
- **#14 的 Dart 侧已完成**（启动装配：`planCapture` / `announcedCodecsFor` /
  `ensureEncodeEvidence`）。**#14 的插件事件桥接那一半，已并入下面这份计划。**
- **Android 真机已接上并读过特征**：vivo V2405A / mt6991 / Android 16（API 36）。
  完整实测表在计划文件的「目标真机的实测事实」一节 —— **别重复测**。
  关键两条：`aeAvailableTargetFpsRanges` 含 `[60,60]`（普通 session 就能请求 60fps）；
  硬件编码器是 `c2.mtk.hevc.encoder` / `c2.mtk.avc.encoder`。

## 下一步任务

**用户正在审查 `docs/superpowers/plans/2026-10-10-android-encoded-stream.md`。
审查通过后按该计划的 Task 1 起执行；Task 1 的第一步是用户跑 `flutter pub get`。**

计划的 7 个任务（每个都有独立可验的交付物）：

1. **Task 1**（#7）vendor `camera_android_camerax` 0.7.5+1 → root path 依赖 → 基线不回归。
   源码已在**本机 pub cache**（`camera_android_camerax-0.7.5+1`，171 文件，Java，CameraX 1.6.2），
   不用联网。
2. **Task 2**（#12 设计）读源码核实三条事实 + 写 ADR 0002 + **冻结 Dart↔native 通道协议**。
3. **Task 3** Dart 侧适配器（`EncodedStreamTransport` / `AndroidEncodedStreamChannel` /
   `PlatformCodecProbe`，全部 Flutter-free）**进门禁 + 变异验证**。`sourceSeq` 的
   distinct-PTS 去重规则在这一层，因为只有这层本机能自动跑。
4. **Task 4**（#13 主体）native `EncodedStreamVideoOutput` + `EncodedStreamPlugin` +
   Flutter 薄壳 → **真机上第一次看到 AU**（≥55fps 才算过，只有 30 就停下查）。
5. **Task 5**（#13 收口）`EncodedStreamSource` + `encoderFactory` 接进 app，
   物理下标留在 `CameraPluginBackend` 内。
6. **Task 6**（#14 收口）`AndroidEncodeBudgetProbe` + `main.dart` 的 `probe:` 由 `null` 换成真实探针。
7. **Task 7**（#15）真机端到端 + 长稳验收，三层计数分开统计。

之后才是 Windows（`windows/record_handler.cpp:114` 已有进程内 MF H.264）→ macOS。

## 卡点

- **一行原生编码代码都还没写**（本轮只产出计划）。计划里所有"期望值"都还是纸面的，
  **Task 4 Step 6 的 ≥55fps 是真机上第一次能证伪的地方**。
- **HEVC 在 1080p 的实测速率未知**：`media_codecs_performance.xml` 只给了 720p（53–117）与
  4K（13–29）两档，1080p 靠外推（约 52–116）。**外推不是证据**，要 Task 6 实测。
- **AVC 的 1080p 档是 30–66**，60 够得着但贴着上限 → 长稳掉到 30 是有可能的，Task 7 要量。
- **Task 2 的三条事实未经源码核实**（`VideoOutput` 能否与 Preview/ImageCapture 同时绑定是最大
  的不确定性）。若不成立，计划里给了备选路线 C 的判据，**不要现场发明第三条**。
- **peak-vs-plateau 未定**（ADR §4.1.1，唯一开着的决策）。当前 inert。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。

## 生效约束（仅本任务范围）

- 不引入新依赖（vendor 插件不算：它是既有 `camera` 依赖的本地实现）。
- **助手绝不在自己的 shell 里跑 `flutter pub get`**（假 symlink 会毁掉下一次 `flutter run`）；
  `flutter test` / 构建 / 真机一律用户跑。`main.dart` 助手跑不了，只能 `check_compile.py` 类型检查。
- 60fps 相关的任何承诺必须有真机实测数字；**不承诺所有真机必达 60**，只对 vivo V2405A 背书。
- 段时长的误差方向**从未查证**，别引用旧文档里的倍数；它**不用于计费**。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）。
- 新断言必须做过变异验证；新增独立检查文件时**接线与变异验证同一次做完**。
