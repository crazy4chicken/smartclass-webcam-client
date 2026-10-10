# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：`eee49d3`（本提交）与 `53a2e8e` 两个提交未推送；`origin/master` 在 `295ad4a`**
  （竖屏回归修复已在远端）。**接手第一件事建议：`git push`。**
- 门禁 `passed: 1290, failed: 0`；`dart format` 干净；`check_compile.py` `compiled: 46, failed: 0`。
  **`flutter test` 本轮没跑过**（改了 3 个 `test/` 文件），需要用户跑。
- **Android 编码流计划（`docs/superpowers/plans/2026-10-10-android-encoded-stream.md`，7 个任务）
  的 Task 1–3 已落地，Task 4 进行中。**
  - **Task 1（#7）✅ 全部**：`camera_android_camerax` 0.7.5+1 已 vendor 到 `packages/`；
    依赖**必须**挂 `dependency_overrides`；`pub get` 通过、APK 真机跑通、预览与注册正常
    （**照片尚未单独验**）。
  - **Task 2（#12 设计）✅**：`docs/adr/0002-android-encoded-stream-seam.md`，通道协议已冻结。
  - **Task 3 ✅**：`lib/src/capture/encoded_stream_transport.dart` + `tool/verify_encoded_stream.dart`
    （已接进主入口，有变异验证）。
  - **Task 4 ⏳ 接缝已定、第一块代码已落地**：`EncodedStreamVideoOutput.java` 写完（含评审修掉的
    两个并发缺陷）；**未编译** —— 本机编不了 Java，用户的 Gradle 是第一次检查。
- **真机仍在**（vivo V2405A / mt6991 / Android 16 / arm64-v8a）。实测特征表在计划文件的
  「目标真机的实测事实」一节，**别重测**。
- **2026-10-10 顺带修掉一个已上线的回归**：默认几何曾是 **240x320**（见 `AGENTS.md` 禁区与
  `docs/implementation-status.md` 的 #4.2）。设备实测修复后为 `1080x1920 @ 5fps`。

## 下一步任务

**Task 4 剩下的三块**（顺序即依赖）：

1. `EncodedStreamPlugin.java`：注册 `MethodChannel('smartclass/encoded_stream')` +
   `EventChannel('smartclass/encoded_stream/packets')`；`open` 里由 `cameraId` 推出 `CameraSelector`、
   建 `EncodedStreamVideoOutput`、自建 `VideoCapture` 并**单独 `bindToLifecycle` 一次**
   （ADR §九：增量追加，不必拿 Preview/ImageCapture 的引用）；`close` 走 EOS 冲刷；
   生命周期所有者从 `ProxyApiRegistrar.getLifecycleOwner()` 取。**上游只改
   `CameraAndroidCameraxPlugin.java` 的两行注册。**
2. `lib/src/capture/camera_plugin_encoded_transport.dart`（Flutter 薄壳，实现
   `EncodedStreamTransport`；**不做任何解析** —— 解析在 Task 3 那层）。
3. `main.dart` 的**临时**冒烟入口（`--dart-define=ENCODED_STREAM_SMOKE=true`），Task 5 删掉。

**然后**：Task 5（`EncodedStreamSource` + 工厂接进 app）→ Task 6（`AndroidEncodeBudgetProbe`
+ `main.dart` 的 `probe:` 由 `null` 换成真探针）→ Task 7（真机端到端 + 长稳）。

**Task 4 Step 6 的验收**：10 秒内 AU ≥ 550（≥55fps）、选中的是 `c2.mtk.hevc.encoder`（不是
`c2.android.*`）、同期拍照仍成功。**只有 30 上下就停下查帧率协商，不许带着 30fps 往下做。**

之后才是 Windows（`windows/record_handler.cpp:114` 已有进程内 MF H.264）→ macOS。

## 卡点

- **`EncodedStreamVideoOutput.java` 从未编译过。** Java 在本机编不了，第一次真话来自用户的
  Gradle 构建；预计会有 import / API 签名层面的小错要修。
- **ADR §九 的增量绑定只有源码证据。** 插件自己逐个绑 use case（`android_camera_camerax.dart:1292-1305,
  1158`），所以 CameraX 1.6.2 对同一 `LifecycleOwner` 应是追加 —— 但**运行时仍未被真机证明**。
  若真机拒绝三者并存，退路线 C（ADR §五），**不要现场发明第四条**。
- **HEVC 在 1080p 的实测速率未知**：`media_codecs_performance.xml` 只有 720p（53–117）与 4K（13–29）
  两档，1080p 靠外推。**外推不是证据**，Task 6 才测。
- **4K@60 会被接受**（协议把分辨率与帧率当两个独立列表、不做配对限制），服务端段时长因此差约 20 倍
  —— 已实测（21 帧 / 7.7 秒窗口，声明 60 → 折算 0.35 秒）。这是 ADR 0001 那条已知缺口，**不是新 bug**。
- **peak-vs-plateau 未定**（ADR 0001 §4.1.1，唯一开着的决策）。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。

## 生效约束（仅本任务范围）

- **⚠️ 本仓有外部编辑器在异步回写文件（markdown 格式化器），会拿旧缓冲区静默覆盖你的编辑。**
  已发生两次：一次让提交说明成了假话，一次**删掉了计划文件 150 行**（已从 `28de2b5` 恢复）。
  规则：改完**回读磁盘**确认，提交后 `git show HEAD:<file> | grep` 再核一次；
  **别用 `git add -A` 盲提**（那次就是这样把被覆盖的版本一起提交了）。
- **`camera_android_camerax` 必须挂 `dependency_overrides`，不能放 `dependencies`**：`camera` 依赖的是
  pub.dev 上的它，root 的 path 源替换不了已发布的传递依赖，pub 直接拒绝解析。三处文档都写了。
- **尺寸/几何类断言必须带竖屏 fixture**（手机默认竖屏；`fitsWithin` 这类逐轴比较在竖屏下语义不同）。
- 不引入新依赖。**fork 范围锁死**：`packages/camera_android_camerax/` 只加文件，上游文件唯一允许的改动是
  `CameraAndroidCameraxPlugin.java` 的两行注册，rebase 时手工重放。
- **助手绝不在自己的 shell 里跑 `flutter pub get`**（假 symlink 会毁掉下一次 `flutter run`）；
  `flutter test` / 构建 / 真机一律用户跑。`main.dart` 助手跑不了，只能 `check_compile.py` 类型检查。
- 60fps 相关的任何承诺必须有真机实测数字；**不承诺所有真机必达 60**，只对 vivo V2405A 背书。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）。
- 新断言必须做过变异验证；新增独立检查文件时**接线与变异验证同一次做完**。
- 提交消息**别用反引号**（bash 会做命令替换吃掉内容），改用 `git commit -F <文件>`。
- 派子代理时**明确禁止它们跑 `git`**：并行子代理并发 add/commit 会撞索引；统一由指挥者提交。
