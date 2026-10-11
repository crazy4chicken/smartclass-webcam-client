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
- **Task 6 的实现已经有了**（`AndroidEncodeBudgetProbe`）：`lib/src/app/android_encode_probe.dart`
  + `main.dart` 把 `probe:` 从 `null` 换成它、`android_encoded_stream.dart` 新增
  `evidenceIdentity()` 作缓存键。
  - **这份代码不是本会话写的**（12:40 由他人写入），本会话只补了一个**缺 import 的编译错误**：
    它用了 `EncodedFrame` 却没有 `import '../capture/video_encoder.dart'` —— `sustained_rate.dart`
    在 `measureDeliveredRate` 的签名里**用到**这个类型但**不 re-export** 定义它的文件，所以名字
    不在作用域里。修好后：`check_compile.py` `compiled: 46, failed: 0`、门禁 `passed: 1290,
    failed: 0`、`dart format` 干净。
  - **仍然没有任何真机证据**：探针从未在设备上跑过，所以**不能**说它测得出数字、更不能说
    1080p60 可达。`planCapture` 会拿它返回的东西去决定声明帧率与公告 codec —— 第一次真机运行
    就是第一次验证。
- **真机仍在**（vivo V2405A / mt6991 / Android 16 / arm64-v8a）。实测特征表在 ADR 0002 §七，
  **别重测**。
- **真机第一次跑的结果（2026-10-11，从设备 SharedPreferences 里读出来的，不是猜的）**：
  `flutter.encode_evidence = {…,"encoder":"h265=c2.mtk.hevc.encoder,h264=c2.mtk.avc.encoder,
  mjpeg=unknown","samples":[]}`。
  - ✅ **通道通了**：`encoders` 枚举成功，两个目标硬件编码器都找到且被判为硬件。
  - ❌ **探针跑了但一条样本都没有**（`samples: []`）：h265/h264 各开了一次相机，两次都没拿到交付。
    **失败点还没定** —— 需要 `[probe] …` 那一行（`run failed: <异常>` vs `nothing was delivered`）。
  - ⚠️ **设备现在被卡住了**：这份"空结果"被当成有效答案缓存，每次启动都命中、**永不重测**。
    重测前必须清掉 `flutter.encode_evidence` 这一个键（**别 `pm clear`** —— 会连 device_token /
    base_url 一起清掉）。见「卡点」。
- **两条已经论证完、不要再重新论证的结论**：
  1. **4K60 在这台机器上不存在** —— HEVC 3840×2160 实测只有 13–29fps，是 SoC 硬件编码器的档位墙，
     换采集方式救不了；现实目标是 **1080p60**（4K 最多 30 以下）。
  2. **装上 App 也看不到 h265，是设计不是故障** —— 见「卡点」第一条那道闸门。

## 下一步任务

**代码已经全部写完了**（Task 4 / 5 / 6 的实现都在仓里）。剩下的**只有一件事：上真机把它跑起来**。

1. **`main.dart` 的临时冒烟入口**（`--dart-define=ENCODED_STREAM_SMOKE=true`）：绕过协调器，
   直接 `AndroidEncodedStreamFactory.encoderFor(codec: h265, ...)` 开 1080p60，10 秒数 AU。
   **它存在的意义就是被删掉** —— 证据拿到后移除。这是唯一还没写的代码。
2. **真机跑一次**（用户跑 `flutter run` / 构建安装）：走一遍 `planCapture` → `AndroidEncodeBudgetProbe`
   → `EncodeEvidence` → 公告。**这是 Task 6 的第一次验证**，它至今没在任何设备上跑过。
3. **Task 7**：真机端到端 + 长稳。

**验收（Task 4 Step 6）**：10 秒内 AU ≥ 550（≥55fps）、选中的是 `c2.mtk.hevc.encoder`、
同期拍照仍成功。**只有 30 上下就停下查帧率协商，不许带着 30fps 往下做。**

之后才是 Windows（`packages/camera_desktop/windows/record_handler.cpp:114` 已有进程内 MF H.264）
→ macOS。

## 卡点

- **⚠️ 探针的失败被当成答案缓存了**：`EncodeEvidence.isInvalid` 只看 `version < 0`，所以
  「`samples: []`」（一次都没测到）与「测出来是 0」在缓存层**无法区分** —— 于是第一次失败的
  结果被永久缓存，设备再也不会重测，h265 永远进不了公告。探针自己明明区分了这两件事
  （没测到 → 不产生样本；测出 0 → 产生 fps 0 的样本），**是缓存那一层把它们混为一谈了**。
  修的方向：一条样本都没有的探针结果不写缓存 / 不命中缓存。**改之前先问，这是 Task 6 的设计决定。**
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
- **助手的 shell 里 `flutter logs` 也跑不了**（`CreateFile failed 231`，与 test/build 同因），
  而 **`debugPrint` 的输出不落 logcat**（真机 logcat 里查不到本 App 任何一行）。
  所以要看运行日志，只能让用户 `flutter run … 2>&1 | tee run.log` 再把文件给助手。
  **替代诊断手段（adb 可用）**：`dumpsys media.camera`（CONNECT/DISCONNECT 时间线 + 设备状态）、
  `dumpsys SurfaceFlinger --list`（预览层在不在）、`cat /proc/<pid>/task/*/comm`（线程名 ——
  `EncodedStreamPl` 说明插件收到了方法调用，`CodecLooper` 说明动过 MediaCodec）、
  以及在本机 `build/app/outputs/flutter-apk/app-debug.apk` 的 dex 里 grep 插件字符串。
- 60fps 相关的任何承诺必须有真机实测数字；**只对 vivo V2405A 背书**。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）；
  改默认几何还要记住 `defaultResolutionFor` 的三个调用点（`main.dart` 的 `openConfig`、
  `defaultModeFor` 内部、`adoptInventory`）—— 只改一处就是 240x320 那个回归复现。
- 新断言必须做过变异验证；新增独立检查文件时**接线与变异验证同一次做完**。
- 提交消息**别用反引号**（bash 会做命令替换吃掉内容），改用 `git commit -F <文件>`。
- 派子代理时**明确禁止它们跑 `git`**：并行子代理并发 add/commit 会撞索引；统一由指挥者提交。
