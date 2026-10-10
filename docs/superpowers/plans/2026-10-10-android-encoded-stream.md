# Android 60fps H.265/H.264 编码流实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Android 设备真正交付 **1920×1080 @ 60fps 的 H.265（其次 H.264）压缩访问单元**，替换今天 mjpeg 直通 5–10fps 的现状。

**Architecture:** 编码必须发生在**持有相机帧的那个进程**里 —— 帧不能跨进 Dart，路径不能落盘。Android 的相机由 vendored 的 `camera_android_camerax`（CameraX 1.6.2）持有，所以编码器作为**该插件内的一个自定义 `VideoOutput`** 落地：CameraX 把相机 surface 交给我们，我们把它接到 `MediaCodec` 的 input surface，输出的每个 buffer 就是一个访问单元。Dart 侧只看到已压缩的 AU，走**既有的** `EncodedStreamChannel` 契约（已冻结、已有门禁断言），因此本计划不新增任何 Dart 领域模型。

**Tech Stack:** Flutter / Dart 3.13；`camera_android_camerax` **0.7.5+1**（fork，Java，CameraX **1.6.2**）；Android `MediaCodec`（`c2.mtk.hevc.encoder` / `c2.mtk.avc.encoder`）；目标真机 **vivo V2405A**（mt6991，Android 16 / API 36，arm64-v8a）。

**Spec:** `docs/superpowers/plans/2026-10-10-dual-mode-task-list.md` 的 **#7 / #12 / #13 / #14 / #15**；决策入口 `docs/adr/0001-dual-mode-capture-decisions.md`；现状 `docs/implementation-status.md`；真机操作手册 `docs/android-setup.md`。

## Global Constraints

（逐字取自 spec 的全局约束；每个任务的要求都隐含包含本节）

- 默认目标 **1920×1080 @ 60fps**；**先降帧率，保分辨率**；做不到要 `ack ok:false`，**不能偷换 codec 或模式再报成功**。
- **硬件 H.265 在当前模式可持续时优先，否则 H.264。** 某 codec 在 30fps 可用**不表示**它在当前 60fps 可用。
- **采集与编码在 native 内完成，原始帧不跨入 Dart，视频路径不落临时文件。**
- **请求帧率 ≠ 声明帧率**：请求 = 60（泵的 tick 上限，**不节流**）；声明 = `CameraMode.fps`，**不得高于已证实交付量**，无证据时 `kFpsWithoutEvidence = 5`。
- **公告 = 平台声称 ∩ 实测**（`announcedCodecsFor`）。声称不是证据：平台**有**编码器 ≠ 它在当前模式可用。
- 照片使用当前几何，录像中不 reconfigure；每条带 `id` 的命令均需 ack。
- `camera_enum` 是**公告序号**，**物理下标绝不出 `CameraPluginBackend`**。
- 后端每个 `recording.frame` 接受**一个完整编码访问单元**；关键帧必须携带带内参数集。
- `lib/src/backend/`、`lib/src/config/`、**非插件**的 `lib/src/capture/`、`lib/src/app/capability_bootstrap.dart` 保持 Flutter-free。
- **不引入新依赖。** vendor 插件不算新增：它是既有 `camera` 依赖的本地实现。
- **用户**运行 `flutter pub get`、`flutter test`、构建与真机；**助手绝不在自己的 shell 里跑 `flutter pub get`**（会造出空目录假 symlink，毁掉下一次 `flutter run`）。
- 没有编译 / 真机证据，不许标完成。

### 目标真机的实测事实（2026-10-10 用 `adb` 读，写在这里避免重复测）

| 项 | 值 | 来源命令 |
| --- | --- | --- |
| 机型 / SoC | vivo V2405A / `mt6991`（Dimensity 9400 级），`arm64-v8a` | `getprop ro.product.model` `ro.board.platform` `ro.product.cpu.abi` |
| Android | **16**（API **36**） | `getprop ro.build.version.sdk` |
| 摄像头 | 7 个 Camera2 设备；0 号 = `BACK`，`activeArraySize` 4096×3072，`orientation` 90 | `dumpsys media.camera` |
| **目标帧率档** | `aeAvailableTargetFpsRanges` 含 **`[15,60]` 与 `[60,60]`** → **普通 session 就能请求 60fps，不必走高速 session** | 同上 |
| 高速 session | 支持：`CONSTRAINED_HIGH_SPEED_VIDEO` 在 `availableCapabilities` 里；`availableHighSpeedVideoConfigurations` 含 3840×2160 30–120 | 同上 |
| 1080p 流配置 | 1920×1080 在 `availableStreamConfigurations` 里有 OUTPUT 条目（format 33/34/35） | 同上 |
| 硬件编码器 | `c2.mtk.hevc.encoder`（alias `OMX.MTK.VIDEO.ENCODER.HEVC`）、`c2.mtk.avc.encoder` | `cat /vendor/etc/media_codecs*.xml` |
| 编码器实测档 | AVC 1920×1080 → **30–66 fps**；HEVC 1280×720 → 53–117、3840×2160 → 13–29（**无 1080p 条目**） | `cat /vendor/etc/media_codecs_performance.xml` |
| 插件 | `camera_android_camerax` 0.7.5+1 是 **Java**（171 文件）+ `build.gradle.kts`，CameraX **1.6.2**（`android/build.gradle.kts:79`），`minSdk 23` | pub cache |

> **这张表里最重要的一行是"无 1080p 条目"。** AVC 的 30–66 说明 1080p60 够得着但**贴着上限**；HEVC 只有 720p 和 4K 两档，按像素率外推 1080p 约 52–116 —— **这是外推，不是证据**。所以「1080p60 能不能持续」只能由 `EncodeBudgetProbe` 在真机上测出来，这也正是「不承诺所有真机必达 60」的具体含义。

## Review Focus

以下五条是 spec 隐含、但没有哪个任务会顺手覆盖的失效模式。每条都由指定任务的用例钉住。

1. **60fps 请求被静默降级**：`aeTargetFpsRange` 设了 `[60,60]`，但 CameraX 实际只跑 30，用户以为在录 60fps。→ Task 4 的 logcat 计数 + Task 7 的源序号计数。
2. **编码器把重复帧当新帧**：surface 上游跟不上时重复上一帧，AU 计数照样到 60。→ Task 3 的 `sourceSeq` 去重用例 + Task 7。
3. **录像中拍照打断视频**：`ImageCapture` 与编码 surface 抢 session。→ Task 4 必须证明三者能同时绑定，Task 7 在真机上验。
4. **切相机/切后台后旧包进新流**：插件是进程级单例，回调可能在换 run 之后才到。→ Task 3 的代次过滤 + Task 4 的 `sessionGeneration` 回显。
5. **H.265 在 30 可用被公布成 60 可用**：`capabilities` 只回答"有没有编码器"，速率由实测决定。→ Task 5 的 `canServeMode` 路径 + Task 6。

---

## Task 1: Vendor `camera_android_camerax` 0.7.5+1，让 app 解析到本地实现（#7）

**Files:**
- Create: `packages/camera_android_camerax/**`（从 pub cache 复制）
- Create: `packages/camera_android_camerax/VENDORED.md`
- Modify: `pubspec.yaml`（root `dependencies:` 段，约 :22）
- Modify（用户执行后产生）: `pubspec.lock`
- Modify: `docs/implementation-status.md`（#7 行）

**Interfaces:**
- Consumes: 无
- Produces: `package:camera_android_camerax` 可被 app 直接 import（Task 4 的 Flutter 薄壳要用）；`camera` 的 Android 实现从此是这份 fork。

- [ ] **Step 1: 复制上游，保留范围对齐 `packages/camera_desktop/`**

```bash
SRC="$LOCALAPPDATA/Pub/Cache/hosted/pub.dev/camera_android_camerax-0.7.5+1"
mkdir -p packages/camera_android_camerax
cp -r "$SRC/." packages/camera_android_camerax/
rm -rf packages/camera_android_camerax/example \
       packages/camera_android_camerax/skills \
       packages/camera_android_camerax/.dart_tool
```

保留：`lib/ android/ pigeons/ test/ LICENSE AUTHORS CHANGELOG.md README.md analysis_options.yaml pubspec.yaml`。

- [ ] **Step 2: 写 `packages/camera_android_camerax/VENDORED.md`**

照 `packages/camera_desktop/VENDORED.md` 的四节写（来源与许可 / 为什么在这里 / 本 fork 的地面规则 / 如何升级）。必须写进去的确切值：

- 上游：pub.dev `camera_android_camerax` **0.7.5+1**；sha256 见 `pubspec.lock`
- 许可：**BSD-3-Clause**（`Copyright 2013 The Flutter Authors`），以 `LICENSE` 原文为准
- CameraX：**1.6.2**，`minSdk 23`
- 为什么 fork：编码必须在持有相机的进程内；`VideoCapture<Recorder>` 只有文件出口，没有 AU 出口
- **改动范围：只新增文件。** 上游文件唯一一处改动是 `CameraAndroidCameraxPlugin.java` 里的两行注册（Task 4），rebase 时手工重放
- 地面规则沿用 `camera_desktop/VENDORED.md` 的四条（只改采集/编码路径；帧不落盘、原始帧不进 Dart；声明必须是实测的；没有编码器就直说）

- [ ] **Step 3: `pubspec.yaml` 加 root path 依赖**

```yaml
  # Root dependency, not merely transitive: a path dependency here is what makes
  # `camera` resolve its Android implementation to this fork. Only
  # `camera_android_camerax` is forked — see packages/camera_android_camerax/VENDORED.md.
  camera_android_camerax:
    path: packages/camera_android_camerax
```

- [ ] **Step 4: 用户在自己的 PowerShell 里跑 `flutter pub get`**（助手不要跑）

- [ ] **Step 5: 验证解析到了本地实现**

Run: `grep -A4 "camera_android_camerax:" pubspec.lock`
Expected: `source: path` 且 `description: path: "packages/camera_android_camerax"`（不再是 `source: hosted`）。

- [ ] **Step 6: 用户编 debug APK，按 `docs/android-setup.md` §11 驱动真机**

三条基线都不能坏：预览出画面、拍照成功、注册成功（`adb logcat -d | grep 'flutter :'` 里能看到 `[capture] plan:` 那行）。

- [ ] **Step 7: Commit**

```bash
git add packages/camera_android_camerax pubspec.yaml pubspec.lock docs/implementation-status.md
git commit -m "chore(android): vendor camera_android_camerax 0.7.5+1 so the encoder can live in the capture process"
```

---

## Task 2: 定缝并冻结通道协议（#12 的设计那一半）

**Files:**
- Create: `docs/adr/0002-android-encoded-stream-seam.md`
- Read（不改）: `packages/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/{VideoCaptureProxyApi,RecorderProxyApi,ImageCaptureProxyApi,ImageAnalysisProxyApi,CameraProxyApi,ProxyApiRegistrar,CameraAndroidCameraxPlugin}.java`、`pigeons/camerax_library.dart`

**Interfaces:**
- Consumes: Task 1 的 fork
- Produces（**本任务最重要的产出，Task 3/4 逐字依赖**）：
  - 通道名：`MethodChannel('smartclass/encoded_stream')`、`EventChannel('smartclass/encoded_stream/packets')`
  - `open` 参数：`{cameraId: int, width: int, height: int, fps: int, quality: int, codec: String, sessionGeneration: int}` → 成功 resolve、失败 throw `PlatformException`
  - `close` 参数：`{}` → resolve 表示**已冲刷完毕**
  - `encoders` 参数：`{}` → `{encoders: [{codec: String, name: String, hardware: bool}]}`
  - 事件载荷：`{bytes: Uint8List, pictures: int, ptsUs: int?, generation: int, eos: bool}`

- [ ] **Step 1: 从源码核实三条事实**

逐条读，**任一条不成立就停下来写 ADR，不要即兴改路线**：

1. `androidx.camera.video.VideoOutput` 是公开接口，且 `VideoCapture(VideoOutput)` 构造在 1.6.2 可用。读 `VideoCaptureProxyApi.java` 看它现在怎么建 `VideoCapture`。
2. 自定义 `VideoOutput` 能与既有的 `Preview` / `ImageCapture` **一起**绑定（CameraX 的 `bindToLifecycle` 是整体替换语义）。读 `ProxyApiRegistrar.java`、`CameraProxyApi.java`，以及 `CameraXLibrary.g.kt` 里 use case 的建模方式。
3. `c2.mtk.hevc.encoder` / `c2.mtk.avc.encoder` 接受 **surface 输入**。`/vendor/etc/media_codecs*.xml` 里已声明 `surface`，仍要在 Task 4 里跑通才算数。

若事实 1 或 2 不成立，按下面的备选路线写 ADR，**不要现场发明第三条**：
- **路线 C**：`ImageAnalysis`（YUV_420_888）→ `MediaCodec` ByteBuffer 输入。判据：编码器是否声明 `COLOR_FormatYUV420Flexible` 输入；且 1080p60 YUV 是约 124 MB/s 的 CPU 拷贝，实测到不了 60 就否决。
- **路线 D**：`Recorder` + `FileDescriptor` 管道再解析容器 —— **已否决**：仍走容器，拿不到 AU，且违反"不落盘"。

- [ ] **Step 2: 写 `docs/adr/0002-android-encoded-stream-seam.md`**

必须包含：选中的路线与理由；上表三条事实各自的源码证据（**文件:行号**）；被否决路线及判据；`sourceSeq` 的取法（见 Task 3 Step 3）；以及"本 ADR 只在 Task 4 拿到真机 AU 计数后才算被证实"。

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0002-android-encoded-stream-seam.md
git commit -m "docs(adr): choose the Android encoded-stream seam and freeze the channel protocol"
```

---

## Task 3: Dart 侧适配器 —— 传输接口 + 适配器 + codec 声称探针（全部 Flutter-free，进门禁）

**Files:**
- Create: `lib/src/capture/encoded_stream_transport.dart`
- Create: `tool/verify_encoded_stream.dart`
- Modify: `tool/verify_pure.dart`（import + `guard('encoded stream', runEncodedStreamChecks)`）

**Interfaces:**
- Consumes: `EncodedPacket` / `EncodedStreamChannel`（`lib/src/capture/native_video_encoder.dart`，已存在）、`CodecProbe`（`codec_probe.dart`，已存在）
- Produces:
  - `abstract interface class EncodedStreamTransport` —— 见 Step 2 的方法签名
  - `class AndroidEncodedStreamChannel implements EncodedStreamChannel`
  - `class PlatformCodecProbe implements CodecProbe`
  - `class EncoderClaim`（`{CaptureCodec codec, String name, bool hardware}`）

**为什么这样切**：`MethodChannel` 那层是薄壳（Task 4 写），**协议解析与 `sourceSeq` 去重规则放在这里**，于是本项目唯一能自动跑的门禁就能钉住它们 —— 这正是「fake 接口与 Flutter bridge 分层测」。

- [ ] **Step 1: 写失败用例 `tool/verify_encoded_stream.dart` 的骨架**

`Future<void> runEncodedStreamChecks() async`，用 `section(...)` + `check/eq`。先只写第一个用例，确认它红。

- [ ] **Step 2: 写 `EncodedStreamTransport` 接口**

```dart
abstract interface class EncodedStreamTransport {
  Future<void> open({
    required int cameraId,
    required int width,
    required int height,
    required int fps,
    required int quality,
    required CaptureCodec codec,
    required int sessionGeneration,
  });
  Future<void> close();
  Future<List<EncoderClaim>> encoders();
  Stream<Object?> get events;
}
```

- [ ] **Step 3: 写 `AndroidEncodedStreamChannel implements EncodedStreamChannel`**

`open(...)` 先订阅 `transport.events` **再** `await transport.open(...)`（先认领再启动，`NativeVideoEncoder` 也依赖这个次序）；`close()` 只 `await transport.close()`，**不 cancel 订阅**（尾包靠它送达）。

事件 → `EncodedPacket` 的转换规则，**每条都要有用例**：

1. `bytes` 必须是 `Uint8List`（`Uint8List.fromList` 拷贝，别把平台 buffer 直接交出去），否则丢弃并计数。
2. `generation != sessionGeneration` 的包**丢弃**（插件是进程级单例，换 run 后的旧包会到）。
3. **`sourceSeq` 由本层从 `ptsUs` 推导**：维护 `_lastPtsUs` 与 `_sourceSeq`；`ptsUs == null` → 每个包都算新帧（并记一条诊断计数）；`ptsUs != _lastPtsUs` → `_sourceSeq++`；`ptsUs == _lastPtsUs` → **`sourceSeq` 原地不动**（重复帧）。这条是 `SustainedRateMeter` 唯一能识破"重复帧凑 60"的入口。
4. `pictures` 与 `eos` **原样透传**（`NativeVideoEncoder` 靠 `pictures` 做 units==pictures 交叉校验、靠 `eos` 判断冲刷是否宣告）；缺字段按 `pictures: 0` / `eos: false` 处理，不抛。

- [ ] **Step 4: 写 `PlatformCodecProbe implements CodecProbe`**

`availableCodecs()` 把 `transport.encoders()` 映射成 `Set<CaptureCodec>`，**只收 `hardware == true` 的**，并把它跳过的软件编码器（`c2.android.*`）记一条诊断。理由：软件编码器在 1080p60 上必然不达标，把它放进声称集合等于把一个不可用的 codec 放进服务端当承诺的列表；一台只有软件编码器的设备就诚实地公告 mjpeg 下限。

**必须不抛**（接口契约）：任何异常 → 空集合（`CompositeCodecProbe` 会兜底成 `BaselineCodecProbe` 的 `{mjpeg}`）。

- [ ] **Step 5: 补齐用例**（每个都先红后绿）

- 首包与尾包：`open` 之后、`close` 之前到达的事件都能转成 `EncodedPacket`（尾包不丢）。
- 代次不符的包被丢弃，且不进 `frames`。
- 重复 `ptsUs` 不推进 `sourceSeq`；递增 `ptsUs` 推进。
- `ptsUs == null` 时每个包都推进（并计入诊断）。
- `pictures` / `eos` 原样透传；事件里缺这两个字段时按 `0` / `false` 处理，不抛。
- 非 `Uint8List` 的 `bytes` 被丢弃并计数，不抛。
- 软件编码器（`hardware == false`）不进 `availableCodecs()`。
- `encoders()` 抛异常 → `availableCodecs()` 返回空集合。
- `open` 抛异常 → `AndroidEncodedStreamChannel.open` 把它透出去（让 `NativeVideoEncoder` 回滚 `_running`），且**不留订阅**。

- [ ] **Step 6: 接线进门禁**

`tool/verify_pure.dart` 加 `import 'verify_encoded_stream.dart';` 与 `await guard('encoded stream', runEncodedStreamChecks);`。

- [ ] **Step 7: 跑门禁并做变异验证**

Run: `dart run tool/verify_pure.dart` → `failed: 0`。
然后逐个改坏实现、确认**指名**的用例变红并记下条数：`sourceSeq` 改成每个包都推进 / 去掉代次过滤 / `open` 失败后留下订阅 / `encoders()` 的异常透出 / `close()` 顺手 cancel 订阅。

- [ ] **Step 8: Commit**

```bash
git add lib/src/capture/encoded_stream_transport.dart tool/verify_encoded_stream.dart tool/verify_pure.dart
git commit -m "feat(capture): shape the Android encoded-stream transport in pure Dart"
```

---

## Task 4: native 编码器 + Flutter 薄壳 —— 第一次在真机上看到 AU（#12 的原型验证 / #13 主体）

**Files:**
- Create: `packages/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/EncodedStreamVideoOutput.java`
- Create: `packages/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/EncodedStreamPlugin.java`
- Modify: `packages/camera_android_camerax/android/src/main/java/io/flutter/plugins/camerax/CameraAndroidCameraxPlugin.java:27-46`（`onAttachedToEngine` / `onDetachedFromEngine` 各一行）
- Create: `lib/src/capture/camera_plugin_encoded_transport.dart`（Flutter 薄壳）
- Modify: `lib/main.dart`（**临时**调试入口，Task 5 会替换掉）

**Interfaces:**
- Consumes: Task 2 冻结的通道协议；Task 3 的 `EncodedStreamTransport`
- Produces: `MethodChannelEncodedStreamTransport implements EncodedStreamTransport`（Task 5 用）；`EncodedStreamVideoOutput` / `EncodedStreamPlugin` 这两个类名（Task 5 不改名）

- [ ] **Step 1: 写 `EncodedStreamVideoOutput implements VideoOutput`**

- `onSurfaceRequested(SurfaceRequest request)`：按构造时给定的 `MediaFormat`（`KEY_MIME` = `video/hevc` 或 `video/avc`，`KEY_WIDTH/HEIGHT`，`KEY_FRAME_RATE`，`KEY_I_FRAME_INTERVAL` = 1，`KEY_BIT_RATE`）建 `MediaCodec.createEncoderByType(...)`，`configure(format, null, null, CONFIGURE_FLAG_ENCODE)`，`createInputSurface()`，然后 `request.provideSurface(surface, executor, result -> ...)`。
- `getStreamInfo()`：返回 `StreamInfo.of(StreamInfo.STREAM_ID_ANY)`。
- 输出侧用 **异步 `MediaCodec.Callback`**（不是轮询 `dequeueOutputBuffer`）：`onOutputBufferAvailable` 里读 `BufferInfo`，`presentationTimeUs` 原样上报为 `ptsUs`，`getOutputBuffer()` 用完必须 `releaseOutputBuffer`。
- `pictures` 按本次 buffer 里**完整的图像**数上报：`BUFFER_FLAG_CODEC_CONFIG`（VPS/SPS/PPS）**本身不算一幅图**，上报 `pictures: 0`，由 `AnnexBSplitter` 把它挂到下一幅图前面 —— 这正是"关键帧必须携带带内参数集"的实现方式，已有门禁断言钉着，**不要在这里另做合并**。
- `eos: true` 只在收到 `BUFFER_FLAG_END_OF_STREAM` 的那个包上上报（`close` 触发的冲刷收尾）。
- **codec 名优先用 `MediaCodecList` 里的硬件实现**：HEVC 取 `c2.mtk.hevc.encoder`，AVC 取 `c2.mtk.avc.encoder`；找不到就返回失败，**不要退回 `c2.android.*` 软件编码器**（它会静默达不到 60，而这正是本计划要消灭的失效模式）。
- 编码器身份（`identity`）上报实际选中的 codec 名。

- [ ] **Step 2: 写 `EncodedStreamPlugin`**

注册两个通道；持有当前 `EncodedStreamVideoOutput` 与一个 `AtomicInteger generation`。
- `open`：把参数解析成 `MediaFormat`，建 `EncodedStreamVideoOutput`，**把它作为一个 use case 与既有 Preview / ImageCapture 一起 bind**（Task 2 核实的路线）；成功后才回 `generation`，失败 throw `PlatformException(code: 'open_failed')` 并释放已建资源。
- `close`：先 `signalEndOfInputStream()`，等 `onOutputBufferAvailable` 收到 `BUFFER_FLAG_END_OF_STREAM`（**有界超时，5 秒**）再回 resolve；随后 `stop()`/`release()`。`close` resolve 即代表尾包已交付。
- 每个事件载荷里回显 `generation`。
- 静态 `register(BinaryMessenger)` / `unregister()`，由 `CameraAndroidCameraxPlugin` 调用。

- [ ] **Step 3: 改 `CameraAndroidCameraxPlugin` 两行**

`onAttachedToEngine` 里 `EncodedStreamPlugin.register(binding.getBinaryMessenger());`；`onDetachedFromEngine` 里对应注销。**这是本 fork 对上游文件的唯一改动。**

- [ ] **Step 4: 写 `MethodChannelEncodedStreamTransport implements EncodedStreamTransport`**

薄壳：`MethodChannel.invokeMethod` / `EventChannel.receiveBroadcastStream()`；把 `PlatformException` 原样透出（Task 3 已钉住"open 失败要透出去"）。**不做任何解析逻辑** —— 解析在 Task 3 那层。

- [ ] **Step 5: 在 `main.dart` 里加一个临时调试入口**

`--dart-define=ENCODED_STREAM_SMOKE=true` 时，`_startKiosk` 里打开相机后立即 `open` 一次 1080p60 h265 流，10 秒后 `close`，把每秒的 AU 数打到 `debugPrint`。**标注为临时，Task 5 删除。**

- [ ] **Step 6: 用户编 APK 并在真机上跑冒烟**

```bash
adb shell am force-stop com.example.webcam_client
adb shell monkey -p com.example.webcam_client -c android.intent.category.LAUNCHER 1
adb logcat -c && sleep 12 && adb logcat -d | grep -E "EncodedStream|flutter :"
```

**期望（这是本任务的验收）**：
- 出现选中的 codec 名，且是 `c2.mtk.hevc.encoder`（**不是** `c2.android.hevc.encoder`）
- 10 秒内 AU 计数 ≥ 550（即 ≥55fps，留一点余量），**不是 30 上下**
- 同期 `ImageCapture` 拍照仍成功（Review Focus 3）
- 事件里的 `ptsUs` 递增；重复 `ptsUs` 的比例记下来（Review Focus 2 的现场证据）

若 fps 只有 30 上下 → **停在这里**，把 `aeTargetFpsRange` 的设法与 CameraX 的 `Preview`/`VideoCapture` 帧率协商查清楚再往下走；不要带着 30fps 继续做后面的任务。

- [ ] **Step 7: Commit**

```bash
git add packages/camera_android_camerax lib/src/capture/camera_plugin_encoded_transport.dart lib/main.dart
git commit -m "feat(android): encode in the capture process and hand access units to Dart"
```

---

## Task 5: 把编码器接进 app —— `EncodedStreamSource` + 工厂，第一次跑通 H.265 流（#13 收口）

**Files:**
- Modify: `lib/src/capture/camera_backend.dart`（新增 `EncodedStreamSource` 接口）
- Modify: `lib/src/capture/camera_plugin_backend.dart`（实现它；物理下标只在这里出现）
- Modify: `lib/main.dart`（删掉 Task 4 的临时入口；装配工厂与声称集合）

**Interfaces:**
- Consumes: Task 3 的 `AndroidEncodedStreamChannel` / `PlatformCodecProbe`；Task 4 的 `MethodChannelEncodedStreamTransport`；既有的 `VideoEncoderFactory` / `NativeVideoEncoder`
- Produces:
  - `abstract interface class EncodedStreamSource { EncodedStreamChannel? encodedStreamFor(int cameraEnum); }`
  - `CameraPluginBackend implements EncodedStreamSource`
  - `main.dart` 里把 `available` 从 `{mjpeg}` 换成 `CompositeCodecProbe([BaselineCodecProbe(), PlatformCodecProbe(...)])`

- [ ] **Step 1: 加 `EncodedStreamSource` 接口**

**不要**把它挂到 `CameraBackend` 上：那会迫使每个测试假件都实现一个它们根本不支持的方法。单独一个接口，"能产出编码流的后端才实现它"。

- [ ] **Step 2: `CameraPluginBackend` 实现 `encodedStreamFor(int cameraEnum)`**

用**它自己持有的** `_cameraOrder` 把公告序号翻成物理下标，再翻成插件相机 id，返回一个绑好该相机的 `AndroidEncodedStreamChannel`。`Platform.isAndroid` 之外返回 `null`（其它平台还没接）。**物理下标到此为止**。

- [ ] **Step 3: 删掉 Task 4 的临时调试入口**

- [ ] **Step 4: `main.dart` 装配**

- `available` 改为 `CompositeCodecProbe(probes: [BaselineCodecProbe(), PlatformCodecProbe(transport)])`
- 保留 `buildBackendChain(...)` 返回的列表引用，用 `whereType<EncodedStreamSource>().firstOrNull` 取源
- 给协调器传一个 `encoderFactory`：`codec` 是 `h264`/`h265` 时返回 `NativeVideoEncoder(codec: ..., cameraEnum: ..., streamId: ..., channel: source.encodedStreamFor(cameraEnum)!, identity: <该 codec 在 encoders() 里的 name>)`；取不到 channel 时返回 `null`（工厂拒绝 → `ack ok:false`，**不偷换 codec**）。`identity` 必须是平台真名（`c2.mtk.hevc.encoder`），它同时是 `EncodeEvidence` 的缓存键之一，写成常量会让换驱动后仍命中旧证据。
- `probe:` 仍然传 `null`（Task 6 才接）

- [ ] **Step 5: 用户跑 `flutter test` 与真机冒烟**

真机上发一条 `start_recording(codec=h265)`（走 `docs/android-setup.md` §10 的真后端联调），确认：`ack ok:true`、状态条上 `codec = h265`、`编码` 那一档帧率不是 0。**这一步是"端到端第一次出 H.265 流"**。

- [ ] **Step 6: Commit**

```bash
git add lib/src/capture/camera_backend.dart lib/src/capture/camera_plugin_backend.dart lib/main.dart
git commit -m "feat(android): serve h264/h265 through the native encoder, keeping the physical index inside the backend"
```

---

## Task 6: 实测接上 —— `AndroidEncodeBudgetProbe` + `main.dart` 的 `probe:`（#14 收口）

**Files:**
- Create: `lib/src/capture/android_encode_probe.dart`
- Modify: `lib/main.dart`（`probe:` 由 `null` 换成真实探针）
- Modify: `lib/src/capture/encode_budget.dart`（**只在需要时**：`kEncodeEvidenceVersion` +1 若样本含义变了）

**Interfaces:**
- Consumes: Task 5 的 `EncodedStreamSource`；既有的 `SustainedRateMeter` / `measureDeliveredRate` / `evidenceFromMeasurements` / `EncodeBudgetProbe` / `planCapture`
- Produces: `class AndroidEncodeBudgetProbe implements EncodeBudgetProbe`

- [ ] **Step 1: 写 `AndroidEncodeBudgetProbe.measure(...)`**

对 `codecs` 里的每个 codec：用 `EncodedStreamSource` 开一个 `AndroidEncodedStreamChannel`，包一层 `NativeVideoEncoder`，用 `measureDeliveredRate` 把 `SustainedRateMeter`（预热 1.5s + 窗口 3s）喂起来，等窗口关闭（**有界超时**）后 `stop()`，把 `FrameRateMeasurement` 收进 `Map<CaptureCodec, FrameRateMeasurement>`，最后 `evidenceFromMeasurements(...)`。

**必须遵守**：任何异常都返回 `EncodeEvidence.empty`（接口契约是"绝不抛"）；`close()` 挂住也要能收口（零是测量结果，不是"没测"）；**不得**把 `CameraCapabilities.framerates` 或插件声称的速率填进去。

- [ ] **Step 2: 在 `main.dart` 把 `probe:` 接上**

`Platform.isAndroid` 时传 `AndroidEncodeBudgetProbe(...)`，其它平台继续 `null`。`encoderIdentity` 从探针测出来的真实 codec 名传入（它是 `EncodeEvidence` 的缓存键之一）。

- [ ] **Step 3: 用户跑一次冷启动 + 一次热启动**

冷启动：logcat 里出现 `[evidence] measured: ...`，且 `[capture] plan:` 的声明帧率**不是 5**。
热启动：出现 `[evidence] cached: ...`，且**没有再测**（这是缓存键正确、启动变快的证据）。

**模式级判据（Review Focus 5）**：如果 HEVC 实测只到 30，那么计划里必须出现 `1080p @ 30` + 公告 `h265`；此时运营侧点名 `1080p60 h265` 必须收到 `ack ok:false`，而**不是**被偷换成 30fps 或另一个 codec 跑起来。这一条要在真机上发一次命令确认，不能只看代码。

- [ ] **Step 4: 记录实测数字**

把冷启动测出的每个 codec 的实测帧率写进 `docs/adr/0002-android-encoded-stream-seam.md` 与 `docs/implementation-status.md`。**这些数字就是"60fps 在这台设备上可不可能"的最终答案**，外推到此为止。

- [ ] **Step 5: Commit**

```bash
git add lib/src/capture/android_encode_probe.dart lib/main.dart docs/
git commit -m "feat(android): measure what the encoder sustains and declare that, not the claim"
```

---

## Task 7: 真机端到端与长稳验收（#15）

**Files:**
- Modify: `docs/android-setup.md`（补一节"编码流验收"）
- Modify: `docs/implementation-status.md`、`docs/superpowers/plans/2026-10-10-dual-mode-task-list.md`、`docs/agents/handover.md`

**Interfaces:**
- Consumes: Task 1–6 的全部
- Produces: 一份可复现的验收记录（命令 + 期望 + 实测）

- [ ] **Step 1: 三层计数分开统计，**不许用其中一层代替另一层

- 源新帧：`adb logcat` 里 `AndroidEncodedStreamChannel` 报的 distinct-PTS 计数
- 编码 AU：插件 `EncodedStream` 标签报的 AU 计数
- 后端收到/保存：`tool/e2e/check_segment.py` 对着 `s3_stub.py`（**必须解 `aws-chunked`**）数

**判据**：三层数字接近且**源新帧不是靠重复帧凑出来的**（重复比例要单独报）。

- [ ] **Step 2: 逐条走 spec #15 的清单**

默认 1080p60、低档设备回退、HEVC/AVC fallback、同分辨率降 fps、录像中拍照、`switch_camera` 后重注册、重启与重检缓存。每条记"命令 / 期望 / 实测 / 结论"。

- [ ] **Step 3: 长稳与资源**

预热后连续录制 ≥10 分钟：报发热后的帧率、有无掉到 30、`droppedFrames`/`repeatedFrames`；然后重复 `stop`/`start`、切后台再回前台，确认摄像头被释放且没有残留 AU 流进来。

- [ ] **Step 4: 用真机数据反过来校准声明**

如果长稳达不到 60，就把 `docs/adr/0001` 的默认模式按"先降帧率、保分辨率"重定（1080p60 → 1080p30），并说明依据。**不承诺所有真机必达 60**，只对这台背书。

- [ ] **Step 5: 更新文档并 commit**

```bash
git add docs/
git commit -m "docs(android): record the measured end-to-end acceptance for the encoded stream"
```

---

## 已知风险与不做的部分

- **本计划只做 Android。** Windows（`windows/record_handler.cpp:114` 已有进程内 MF H.264）与 macOS（VideoToolbox）各有独立计划，`camera_desktop` 的 fork 已经就位。
- **iOS 不构建**（需 Apple 证书），Linux 已移出发布矩阵 —— 都不在范围内。
- **照片路径仍然落盘**（`takePicture()` → 临时文件），本计划不碰它；「无磁盘」的照片那一半是 #6。
- **bitrate 不进契约**：协议里没有码率字段，`quality` 是唯一画质旋钮。Task 4 的 `KEY_BIT_RATE` 是插件内部从 `quality` 折算的，不上报、不声明。
- **peak-vs-plateau（ADR §4.1.1）仍未决**。Task 6 的探针只产出样本，聚合策略保持现状（`max`），**本计划不擅自改**。
- Task 4 Step 6 的 fps 门槛（≥55）是**这台设备**的判据，不是对其它机器的承诺。
