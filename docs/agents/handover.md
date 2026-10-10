# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：`87ae169` 等三个提交，⚠️ 尚未推送**（`deec697` vendor / `3c117dd` ADR 0002 /
  `87ae169` Dart 适配器）。远端一致点仍是 `60d9c7c`。工作区干净。
- 门禁 `passed: 1272, failed: 0`；`dart format` 干净（107 文件）。
  **`flutter test` 与 APK 构建本轮都没跑** —— 改了 `pubspec.yaml`，需要用户先 `flutter pub get`。
- **Android 编码流计划的前 3 个任务已落地**（
  `docs/superpowers/plans/2026-10-10-android-encoded-stream.md`）：
  - **Task 1**：`camera_android_camerax` 0.7.5+1 已 vendor 到 `packages/`（142 文件，从**本机
    pub cache** 取，未联网），`VENDORED.md` 写清 sha256 钉版 / BSD-3-Clause / CameraX 1.6.2 /
    "只加文件 + 上游两行注册"的 fork 范围；`pubspec.yaml` 加了 root path 依赖。
    **步骤 4/5/6（pub get、看 lock、编 APK 验基线）是用户的，未做。**
  - **Task 2**：`docs/adr/0002-android-encoded-stream-seam.md` —— 选路线 A（自定义
    `VideoOutput` + `MediaCodec` 输入 surface），三条事实带 `文件:行号` 证据，并**冻结了
    Dart↔native 通道协议**（通道名、`open`/`close`/`encoders`、事件载荷字段）。
  - **Task 3**：`lib/src/capture/encoded_stream_transport.dart`（Flutter-free）+
    `tool/verify_encoded_stream.dart`（已接进门禁）。`sourceSeq` 的 distinct-PTS 去重规则在这里，
    因为只有这层本机能自动跑。
- **真机仍在**（vivo V2405A / mt6991 / Android 16）。实测特征表在计划文件的
  「目标真机的实测事实」一节，**别重测**。

## 下一步任务

1. **用户跑 `flutter pub get`**（`pubspec.yaml` 变了）→ 确认 `pubspec.lock` 里
   `camera_android_camerax` 是 `source: path`。
2. **用户编 debug APK 并驱动真机**（`docs/android-setup.md` §11），确认三条基线不坏：
   预览出画面、拍照成功、注册成功。**这是 Task 1 的验收，没它就还没完成。**
3. 然后 **Task 4**：native `EncodedStreamVideoOutput` + `EncodedStreamPlugin` + Flutter 薄壳。
   **接缝点已经查清**：`android_camera_camerax.dart:961-972` 今天就是把
   `VideoCapture + Preview + ImageCapture` 一次性 `bindToLifecycle`，
   把构造 `VideoCapture` 的 `Recorder` 换成自定义 `VideoOutput` 即可（ADR §三.2）。
4. 再往后 Task 5（接进 app）→ Task 6（实测探针 + `main.dart` 的 `probe:`）→ Task 7（真机验收）。

## 卡点

- **一行原生编码代码都还没写。** Task 4 Step 6 的「10 秒内 AU ≥ 550」是真机上第一次能证伪的地方；
  只有 30 上下就**停下**查帧率协商，不许带着 30fps 往下做。
- **ADR 的三条事实里，事实 3 是 undetermined**：`/vendor/etc/media_codecs*.xml` 声称
  `c2.mtk.*` 接受 surface 输入，但**能否 `createInputSurface()` 并持续出帧只有真机能证**。
  事实 2 的"源码层面成立"也还没在运行时证明：CameraX 是否接受**第三方 `VideoOutput`**
  与 Preview/ImageCapture 同绑，是最大的不确定性（ADR §八.1）。
- **HEVC 在 1080p 的实测速率未知**：`media_codecs_performance.xml` 只有 720p（53–117）与
  4K（13–29）两档，1080p 靠外推。**外推不是证据**，Task 6 才测。
- **peak-vs-plateau 未定**（ADR 0001 §4.1.1，唯一开着的决策）。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。

## 生效约束（仅本任务范围）

- 不引入新依赖（vendor 插件不算：它是既有 `camera` 依赖的本地实现）。
- **助手绝不在自己的 shell 里跑 `flutter pub get`**（假 symlink 会毁掉下一次 `flutter run`）；
  `flutter test` / 构建 / 真机一律用户跑。`main.dart` 助手跑不了，只能 `check_compile.py` 类型检查。
- **fork 范围锁死**：`packages/camera_android_camerax/` 只加文件，上游文件唯一允许的改动是
  `CameraAndroidCameraxPlugin.java` 的两行注册（Task 4）。rebase 时手工重放。
- 60fps 相关的任何承诺必须有真机实测数字；**不承诺所有真机必达 60**，只对 vivo V2405A 背书。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）。
- 新断言必须做过变异验证；新增独立检查文件时**接线与变异验证同一次做完**。
- 提交消息里**别用反引号**（shell 会做命令替换把内容吃掉，已踩一次）。
