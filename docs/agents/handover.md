# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：本地领先 `origin/master` 若干提交**（Android 编码流的修复与接线，加上本文件自己的几次
  更新）。**这里故意不写数字也不写基线 sha** —— 每次改完这份文件、每次有人 push，它就会过期一次。
  **接手第一件事：`git log --oneline origin/master..HEAD` 看清楚，然后 `git push`。**
  工作区**不干净**：另有一份未提交的 Task 6 草稿（见下面 ⚠️ 那条）。
  注意：**这个仓可能有别人在同时动**（本次交接期间就有人 push 过）。
- **Android 编码流（H.265/H.264）已全链路接通，真机编译过，但一次都没跑起来过。**
  - Task 1–5 全部落地：vendor → ADR 0002 定缝 → Dart 解析层 → native 插件 → app 接线。
  - 用户跑 `flutter run -d 10AF5R29MC004Y6` **通过** —— 插件第一次真正进 APK 并装上真机。
  - 验证：javac 干净（0 error）、门禁 `passed: 1290, failed: 0`、`dart format` 干净、
    `check_compile.py` `compiled: 46, failed: 0`。
- **代码就位情况（以文件系统为准）**：`EncodedStreamVideoOutput.java`、`EncodedStreamPlugin.java`、
  `lib/src/capture/camera_plugin_encoded_transport.dart`、`lib/src/app/android_encoded_stream.dart`、
  `lib/src/capture/encoded_stream_transport.dart` 全在。**没写**：`main.dart` 的临时冒烟入口
  （Task 4 step 3）。
- **⚠️ 工作区另有一份未提交、且非本次会话所写的 Task 6 草稿**：`lib/src/app/android_encode_probe.dart`
  （新文件，12:40 写入）+ `main.dart` / `android_encoded_stream.dart` 的接线。
  **未验证、未提交、归属不明** —— 接手第一件事是确认它是不是别人正在做的一半，**别当它不存在，
  也别替它背书**（没跑过门禁、没跑过 `check_compile.py`、更没上过真机）。
  本文件其余各处「Task 6 未做」的表述，指的是 **HEAD 里的状态**。
- **真机仍在**（vivo V2405A / mt6991 / Android 16 / arm64-v8a）。实测特征表在 ADR 0002 §七，
  **别重测**。
- **两条已经论证完、不要再重新论证的结论**：
  1. **4K60 在这台机器上不存在** —— HEVC 3840×2160 实测只有 13–29fps，是 SoC 硬件编码器的档位墙，
     换采集方式救不了；现实目标是 **1080p60**（4K 最多 30 以下）。
  2. **装上 App 也看不到 h265，是设计不是故障** —— 见「卡点」第一条那道闸门。

## 下一步任务

按依赖顺序，只剩「把它跑起来证明」：

1. **`main.dart` 的临时冒烟入口**（`--dart-define=ENCODED_STREAM_SMOKE=true`）：绕过协调器，
   直接 `AndroidEncodedStreamFactory.encoderFor(codec: h265, ...)` 开 1080p60，10 秒数 AU。
   **它存在的意义就是被删掉** —— 证据拿到后移除。
2. **Task 6 的 `AndroidEncodeBudgetProbe`**：用真管线测持续帧率并写进 `EncodeEvidence`。
   **这是唯一能合法抬升「声明帧率」、并把 h265/h264 送进公告的路** —— 没有它，编码流接得再好
   也永远不会被服务器点名。（工作区可能已有一份未提交草稿，见「当前状态」那条 ⚠️。）
3. **Task 7**：真机端到端 + 长稳。

**验收（Task 4 Step 6）**：10 秒内 AU ≥ 550（≥55fps）、选中的是 `c2.mtk.hevc.encoder`、
同期拍照仍成功。**只有 30 上下就停下查帧率协商，不许带着 30fps 往下做。**

之后才是 Windows（`packages/camera_desktop/windows/record_handler.cpp:114` 已有进程内 MF H.264）
→ macOS。

## 卡点

- **一道闸门卡住全部**：公告 = 平台声称 ∩ 实测证据（`announcedCodecsFor`）。平台声称已经有了
  （Android 硬件编码器探针），**证据恒空** —— 没有任何平台实现 `EncodeBudgetProbe`，
  `main.dart` 至今传 `probe: null` → `EncodeEvidence.empty`（**刻意不写缓存**：没测 ≠ 测出是 0）
  → 声明帧率回退 `kFpsWithoutEvidence`=5 → `canServeMode` 对一切 codec 答否 → 公告兜底 `[mjpeg]`。
  **设备是从属角色，服务端只从公告里点名**，所以编码器永远不会被构造。
  **故意不能靠"编码器存在"来公告**（任务清单 Review Focus 2）。
- **运行时从未证明**：CameraX 1.6.2 是否接受一个第三方 `VideoOutput` 与 Preview + ImageCapture
  并存（ADR §八.1，最大的不确定性）；`getMediaCapabilities()` 报「只 SDR、不报 quality」是推断
  出来的安全选择（ADR §10.3），**真机绑不上先看它**。
- **画面朝向未定**：`EncodedStreamPlugin` 没设 `setTargetRotation`，也没把 `TransformationInfo`
  的旋转上报给 Dart。竖屏真机上画面很可能是横的。**上真机第一眼就要看这个。**
- **分辨率只能有一个来源**：调用方在 `VideoCapture.Builder` 上的 `ResolutionSelector`
  （编码器按 `MediaFormat` 的几何 configure，CameraX 若另给尺寸画面就是坏的）。
  `getStreamInfo()` **不能覆写** —— `StreamInfo` 在 1.6.2 是封闭的（ADR §10.1）。
- **码率是旋钮不是预算**：`bpp = 0.04 + 0.08*quality/100`，未经实测。
- **HEVC 在 1080p 的实测速率未知**（只有 720p 与 4K 两档，1080p 靠外推，**外推不是证据**）。
- **照片路仍卡在 `takePicture()`**（临时文件 → 读 → 删），违反「无磁盘」这条**性能**要求
  （ADR 0001 §4.2）。要真无磁盘得换 `ImageStreamFrameSource`（现为 `UnimplementedError` 占位）。
  **视频路已经不经过它了。**
- **peak-vs-plateau 未定**（ADR 0001 §4.1.1，唯一开着的决策）。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。

## 生效约束（仅本任务范围）

- **改 `packages/*/android/**/*.java` 前先跑本机 `javac`**（ADR 0002 §10.6 有命令与 jar 清单；
  现成的 classpath 在 `C:/Users/Lhui/AppData/Local/Temp/cx/cp2.txt`，失效了按 §10.6 重建）。
  `ProxyApiRegistrar` 的真类继承 pigeon 生成的 Kotlin，单独 javac 解不出 —— **要写桩**。
- **`MethodChannel(name, binaryMessenger)` 是错的**：第二个位置参数是 `codec`，messenger 在
  **第三个**。要写 `MethodChannel(name, const StandardMethodCodec(), binaryMessenger)`。
  这个坑只在文件被 import 之后才炸 —— `check_compile.py` 之前一直看不见。
- **Flutter 边界**：`lib/src/backend`、`lib/src/config`、`lib/src/agent`、
  `lib/src/app/capability_bootstrap.dart`、**非插件**的 `lib/src/capture/*` 不得 import
  `package:flutter`。插件桥与接线放插件文件或 `lib/src/app/`，否则 `verify_pure.dart` 跑不起来。
- **⚠️ 本仓有外部编辑器在异步回写文件**（markdown 格式化器），会拿旧缓冲区静默覆盖你的编辑。
  改完**回读磁盘**确认，提交后 `git show HEAD:<file> | grep` 再核一次；**别用 `git add -A` 盲提**。
- **`camera_android_camerax` 必须挂 `dependency_overrides`**，不能放 `dependencies`。
- 不引入新依赖。**fork 范围锁死**：只加文件，上游文件唯一允许的改动是
  `CameraAndroidCameraxPlugin.java` 的两行注册，rebase 时手工重放。
- **助手绝不在自己的 shell 里跑 `flutter pub get`**（假 symlink 会毁掉下一次 `flutter run`）；
  `flutter test` / 构建 / 真机一律用户跑。
- 60fps 相关的任何承诺必须有真机实测数字；**只对 vivo V2405A 背书**。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）；
  改默认几何还要记住 `defaultResolutionFor` 的三个调用点（`main.dart` 的 `openConfig`、
  `defaultModeFor` 内部、`adoptInventory`）—— 只改一处就是 240x320 那个回归复现。
- 新断言必须做过变异验证；新增独立检查文件时**接线与变异验证同一次做完**。
- 提交消息**别用反引号**（bash 会做命令替换吃掉内容），改用 `git commit -F <文件>`。
- 派子代理时**明确禁止它们跑 `git`**：并行子代理并发 add/commit 会撞索引；统一由指挥者提交。
