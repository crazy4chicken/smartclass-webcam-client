# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：`90eb8be` 之后还有两个提交（lock + 计划更正），⚠️ 全部未推送。**
  远端一致点仍是 `60d9c7c`。工作区干净。
- 门禁 `passed: 1272, failed: 0`；`dart format` 干净（107 文件）。
- **`flutter pub get` 已通过**（用户跑的）：`pubspec.lock` 里 `camera_android_camerax` 是
  `dependency: "direct overridden"` / `source: path` / `version: 0.7.5+1`；
  `.flutter-plugins-dependencies` 的 `android` 数组里有它、path 指向本仓 `packages/`
  —— **override 只改了源，插件仍在构建里**（当时最担心的一点，已排除）。
- **Android 计划的前 3 个任务已落地**，Task 1 只剩最后一步（用户的 APK 基线）：
  - **Task 1**：vendor 完成（`deec697`），**依赖用 `dependency_overrides` 挂**（见"生效约束"）。
  - **Task 2**：`docs/adr/0002-android-encoded-stream-seam.md`，Dart↔native 通道协议已冻结。
  - **Task 3**：`lib/src/capture/encoded_stream_transport.dart` + 门禁用例（已接进主入口）。
- **真机仍在**（vivo V2405A / mt6991 / Android 16）。实测特征表在计划文件的
  「目标真机的实测事实」一节，**别重测**。

## 下一步任务

1. **用户编 debug APK 并驱动真机**（`docs/android-setup.md` §11），确认三条基线不坏：
   预览出画面、拍照成功、注册成功（logcat 里能看到 `[capture] plan:`）。
   **这是 Task 1 的验收，也是 Task 4 的前置**：先证明 fork 本身没破坏既有功能，再把编码器
   加上去；否则一旦出问题就分不清是 fork 还是编码器。
2. 然后 **Task 4**：native `EncodedStreamVideoOutput` + `EncodedStreamPlugin` + Flutter 薄壳。
   **接缝点已查清**：`android_camera_camerax.dart:961-972` 今天就是把
   `VideoCapture + Preview + ImageCapture` 一次性 `bindToLifecycle`，
   把构造 `VideoCapture` 的 `Recorder` 换成自定义 `VideoOutput` 即可（ADR §三.2）。
3. 再往后 Task 5（接进 app）→ Task 6（实测探针 + `main.dart` 的 `probe:`）→ Task 7（真机验收）。

## 卡点

- **🔴 默认模式是 240x320 —— 真机日志暴露的回归，必须先修，它挡着 Task 4/6。**
  真机日志：`[capture] plan: CapturePlan(240x320 @ 5fps, mjpeg, ...)`。
  从能力缓存反推出**摄像头真实测到的分辨率全是竖屏**：
  `3072x4096 / 2160x3840 / 1080x1920 / 720x1280 / 480x720 / 240x320`
  （缓存里另外 8 条是 `kCommonResolutions` 阶梯加进来的横屏项）。于是：
  1. `fitsWithin(c, 1920x1080)` 是**逐轴比较**的，竖屏 `1080x1920` 因为 `height 1920 > 1080`
     被判为"装不下"；
  2. `defaultResolutionFor` 的"与 native 同形状"过滤，native = `3072x4096`（竖屏 3:4），
     在能装下的候选里**只剩 `240x320`** 一条同形状。
  ⇒ 默认几何 = **240x320（0.077 MP）**。任何不显式 `switch_camera` 的录制都会是这个。
  **为什么门禁没抓到**：`tool/` + `test/` 里的 fixture 有 104 个横屏、只有 1 个竖屏 ——
  #4 那轮用横屏几何验证的，真机是竖屏。
  **建议的修法**（纯 Dart，可进门禁）：① `fitsWithin` 改成**方向无关**（两边都按长短边排序再比）——
  目标是"尺寸"不是"朝向"；② 形状过滤改成"**与实测到的任一形状相同**"，而不是"与最大的那一条同形状"，
  这需要让实测集合穿过 `withCommonBaseline` 保留下来（现在和阶梯合并后区分不出来了）。
  两条都做，这台设备的默认会变成 **1080x1920**（实测里能装下的最大项）。
  另外：形状过滤在它**设计针对**的场景（5:4 传感器）里其实是失效的 —— 阶梯里没有 5:4 项，
  过滤结果为空、回落到整个候选集。所以它现在既没用又在这里有害，得一并重做。
- **4K@60 被接受，服务端段时长估算差约 20 倍（已实测）**：日志
  `switch_camera(camera=0, 3072x4096 @ 60fps) → ack ok`，随后重注册声明
  `CameraMode(3072x4096 @ 60fps)`。协议把 `supported_resolutions` 与 `supported_framerate`
  当**两个独立列表**、不做配对限制，所以设备**表达不了**"3072x4096 只能跑 2fps" → 只能 ack ok。
  实测 21 帧 / 约 7.7 秒窗口 ≈ 2.7 fps（12.6 MP），而服务端按声明 60 折算 ≈ 0.35 秒。
  **这是 ADR 0001 里那条"已知缺口"的第一次真实测量**，不是新问题。
- **一行原生编码代码都还没写。** Task 4 Step 6 的「10 秒内 AU ≥ 550」是真机上第一次能证伪的地方；
  只有 30 上下就**停下**查帧率协商，不许带着 30fps 往下做。
- **ADR 的事实 3 是 undetermined**：`/vendor/etc/media_codecs*.xml` 声称 `c2.mtk.*` 接受 surface
  输入，但能否 `createInputSurface()` 并持续出帧只有真机能证。事实 2 的"源码层面成立"也还没在
  运行时证明：CameraX 是否接受**第三方 `VideoOutput`** 与 Preview/ImageCapture 同绑，
  是最大的不确定性（ADR §八.1）。
- **HEVC 在 1080p 的实测速率未知**：`media_codecs_performance.xml` 只有 720p（53–117）与
  4K（13–29）两档，1080p 靠外推。**外推不是证据**，Task 6 才测。
- **peak-vs-plateau 未定**（ADR 0001 §4.1.1，唯一开着的决策）。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。

## 生效约束（仅本任务范围）

- **依赖解析**：`camera_android_camerax` 必须走 `dependency_overrides`，**不能**放 `dependencies`
  —— `camera` 依赖的是 pub.dev 上的它，root 的 path 源替换不了已发布的传递依赖（pub 直接拒绝解析）。
  `camera_desktop` 能放 `dependencies`，只因为没别的包依赖它。三处文档都写了，别"顺手整理回去"。
- 不引入新依赖。**fork 范围锁死**：`packages/camera_android_camerax/` 只加文件，上游文件唯一
  允许的改动是 `CameraAndroidCameraxPlugin.java` 的两行注册（Task 4），rebase 时手工重放。
- **助手绝不在自己的 shell 里跑 `flutter pub get`**（假 symlink 会毁掉下一次 `flutter run`）；
  `flutter test` / 构建 / 真机一律用户跑。`main.dart` 助手跑不了，只能 `check_compile.py` 类型检查。
- 60fps 相关的任何承诺必须有真机实测数字；**不承诺所有真机必达 60**，只对 vivo V2405A 背书。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）。
- 新断言必须做过变异验证；新增独立检查文件时**接线与变异验证同一次做完**。
- **编辑文档后必须回读磁盘再提交**：本会话踩过一次 —— 外部 markdown 格式化器拿着旧缓冲区回写，
  把 `docs/` 的编辑覆盖掉，提交进去的是旧内容，而**提交说明还宣称改了**（说明成了假话）。
  现在做法：改完 `grep` 一遍磁盘，提交后 `git show HEAD:<file> | grep` 再核一次。
- **提交消息里别用反引号**（bash 双引号会做命令替换把内容吃掉，已踩一次），改用 `git commit -F`。
- 派子代理时**明确禁止它们跑 `git`**：并行子代理并发 add/commit 会撞索引；统一由指挥者提交。
