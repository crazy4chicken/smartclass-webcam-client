# ADR 0002 — Android 编码流的接缝与通道协议

**状态：** 设计已定，**尚未被真机证实**。本 ADR 只在 **Task 4** 于目标真机上产出
**实测访问单元（AU）计数**后才算被证实（见第七节）。在此之前它是"待验证的接缝设计"，
不是"已落地的行为"。

**上游文件：** `docs/superpowers/plans/2026-10-10-android-encoded-stream.md` 的
**Task 2**（本 ADR 就是它的产出）。与本文冲突时，以本文件为准。

**核实的源码：** pub cache 里的 `camera_android_camerax-0.7.5+1`
（`C:\Users\Lhui\AppData\Local\Pub\Cache\hosted\pub.dev\camera_android_camerax-0.7.5+1`）。
下文所有 `文件:行号` 都相对这个目录。Task 1 把它 vendor 到 `packages/camera_android_camerax/`，
内容相同。

---

## 一、范围与问题

要交付 1920×1080 @ 60fps 的 H.265（其次 H.264）压缩 AU，替换今天 mjpeg 直通 5–10fps 的现状。
全局约束要求**采集与编码都在 native 内完成，原始帧不跨入 Dart，视频路径不落临时文件**
（ADR 0001 §一.5、本计划 Global Constraints）。所以编码必须发生在**持有相机帧的那个进程**里。

Android 的相机由 CameraX 1.6.2 持有（`android/build.gradle.kts:79`：
`val cameraxVersion = "1.6.2"`，`camera-core` / `camera-camera2` / `camera-lifecycle` /
`camera-video` 同版本）。本 ADR 要回答的是：**编码器以什么形态挂在 CameraX 上**，
以及**Dart 与 native 之间那条通道的契约**。

本任务只做"定缝"与"冻协议"，**不写生产代码**。

---

## 二、选中的路线：自定义 `VideoOutput` + `MediaCodec` 输入 surface（路线 A）

**做法：** 在 vendored 插件内实现一个 `androidx.camera.video.VideoOutput`，
在它的 `onSurfaceRequested(SurfaceRequest)` 里把 CameraX 交来的相机 surface 接到
`MediaCodec` 的 `createInputSurface()` 上；输出侧用异步 `MediaCodec.Callback`
把每个编码 buffer（一个 AU）交给 Flutter。这个自定义 `VideoOutput` 被包进一个
`VideoCapture`，**与既有的 `Preview` / `ImageCapture` 放进同一次 `bindToLifecycle` 调用**。

**为什么选它：** 它同时满足三条硬约束 —— 编码在持帧进程内、原始帧不进 Dart、不落盘；
而且它复用 CameraX 自己的 surface 协商（`SurfaceRequest.provideSurface`），
不需要把 1080p60 的 YUV 拷进 CPU。三条事实的源码证据见第三节；三条都成立，所以**不需要**
备选路线（第五节的 C / D 只是记录与判据，不是当前路线）。

---

## 三、三条事实的源码证据

### 事实 1：`androidx.camera.video.VideoOutput` 是公开接口，且 `VideoCapture(VideoOutput)` 在 1.6.2 可构造 —— **成立**

| 证据 | 位置 |
| --- | --- |
| 插件今天就 import 并用 `VideoOutput` 建 `VideoCapture` | `android/src/main/java/io/flutter/plugins/camerax/VideoCaptureProxyApi.java:15`（`import androidx.camera.video.VideoOutput;`）、`:32-34`（`withOutput(@NonNull VideoOutput videoOutput, …)` → `new VideoCapture.Builder<>(videoOutput)`）、`:43`（`builder.build()`） |
| Pigeon 把 `VideoCapture` 建成 `UseCase` 子类，构造入参就是 `VideoOutput` | `pigeons/camerax_library.dart:419-421`（`abstract class VideoCapture extends UseCase { VideoCapture.withOutput(VideoOutput videoOutput, …); }`） |
| `VideoOutput` 被建模为一个（空）抽象 Pigeon 类，映射到 CameraX 真类型 | `pigeons/camerax_library.dart:433-434`（`@ProxyApi(kotlinOptions: KotlinProxyApiOptions(fullClassName: 'androidx.camera.video.VideoOutput')) abstract class VideoOutput {}`） |
| 目前唯一的实现是 `Recorder` | `pigeons/camerax_library.dart:440-441`（`abstract class Recorder implements VideoOutput`） |
| 生成的 Kotlin 里 `withOutput` 的入参类型就是 CameraX 接口本身 | `android/src/main/java/io/flutter/plugins/camerax/CameraXLibrary.g.kt:3468-3471`（`videoOutput: androidx.camera.video.VideoOutput → androidx.camera.video.VideoCapture<*>`）、`:3609`（`open class PigeonApiVideoOutput`）、`:1001`（运行时判定 `value is androidx.camera.video.VideoOutput`） |
| CameraX 版本 | `android/build.gradle.kts:79`（`val cameraxVersion = "1.6.2"`） |

**若不成立会怎样：** 自定义 `VideoOutput` 根本挂不上去，路线 A 从第一步就不可行 —— 只能退到
路线 C（第五节的判据）。**事实成立**，所以不必退。

### 事实 2：自定义 `VideoOutput` 能与既有 `Preview` / `ImageCapture` **一起**绑定 —— **成立（源码层面）**

| 证据 | 位置 |
| --- | --- |
| `bindToLifecycle` 接受**一个 use case 列表**，整体绑定 | `android/src/main/java/io/flutter/plugins/camerax/ProcessCameraProviderProxyApi.java:64-76`（`bindToLifecycle(provider, cameraSelector, List<? extends UseCase> useCases)` → `pigeonInstance.bindToLifecycle(lifecycleOwner, cameraSelector, useCases.toArray(new UseCase[0]))`） |
| `VideoCapture` **是** `UseCase`，所以能进这个列表 | `pigeons/camerax_library.dart:419`（`abstract class VideoCapture extends UseCase`） |
| Dart 侧今天就 `VideoCapture + Preview + ImageCapture + ImageAnalysis` **一次绑定** | `lib/src/android_camera_camerax.dart:961-972`（`final useCases = <UseCase>[videoCapture!];` 逐个 `add(preview!)` / `add(imageCapture!)` / `add(imageAnalysis!)`，随后 `unbindAll()` + 单次 `bindToLifecycle(cameraSelector!, useCases)`）；注释 `:960` 明写 "Unbind all use cases and rebind" —— 这正是"整体替换"语义 |
| `VideoCapture` 由**哪个** `VideoOutput` 支撑，只取决于构造入参 | `lib/src/android_camera_camerax.dart:421-425`（`recorder = Recorder(…)`；`videoCapture = VideoCapture.withOutput(videoOutput: recorder!, …)`）—— 把 `recorder!` 换成自定义 `VideoOutput` 是同一个构造 |

**关键点（本条的 crux）—— ⚠️ 2026-10-10 更正，见 §九.3：** 本节原先断言
「CameraX 的 `bindToLifecycle` 是**整体替换**语义，所以必须与 `Preview` / `ImageCapture`
出现在同一次调用里」。**那句话是错的**，插件自身的代码就与之矛盾：
`_bindUseCaseToLifecycle` 一次只绑**一个** use case（`android_camera_camerax.dart:1292-1305`），
而 `startVideoCapturing` 在 preview 已绑的情况下**只绑 `videoCapture`**（`:1158`）——
若真是替换语义，一开录预览就会被顶掉。CameraX 对同一个 `LifecycleOwner` 是**增量追加**。

这条更正改变了 Task 4 的做法：我们的自定义 `VideoCapture` **可以单独再绑一次**，
不必去拿 `Preview` / `ImageCapture` 的引用。**以 §九 为准。**
（`:961-972` 那个 `unbindAll()` + 单次 `bindToLifecycle([...])` 是**切相机**时的重建路径，
不是唯一的绑定方式。）

**源码不能证明的部分：** 源码只能证明"类型系统允许、插件今天就是这么绑的"。
它**不能**证明 CameraX 在**真机运行时**愿意接受一个**第三方实现的 `VideoOutput`**
（而非它自带的 `Recorder`）与 `Preview` + `ImageCapture` 同绑 —— 那取决于 CameraX 内部
对 `VideoOutput` 实现的支持面与设备能力。**这是本 ADR 最需要在 Task 4 证伪的一点**
（Review Focus 3：录像中拍照不能打断视频）。

**若不成立会怎样：** 若真机拒绝三者并存（即 §九.3 的增量绑定在运行时也不成立），
路线 A 的"与 Preview/ImageCapture 并存"这一半破产，按第五节退到路线 C。
**运行时仍需 Task 4 用真机证明**：源码只能证明插件依赖增量绑定，不能证明 CameraX 1.6.2 的运行时行为。

### 事实 3：`c2.mtk.hevc.encoder` / `c2.mtk.avc.encoder` 接受 **surface 输入** —— **源码无法判定（仅有旁证）**

插件源码与 Pigeon 里**没有**任何关于设备编码器能力的声明 —— 这是**设备/编解码器属性**，
不是插件属性，所以从这份源码里查不出来。

- **旁证（不作为证据）：** 目标真机的实测表（计划 `2026-10-10-android-encoded-stream.md:40`）
  用 `cat /vendor/etc/media_codecs*.xml` 读出硬件编码器
  `c2.mtk.hevc.encoder`（alias `OMX.MTK.VIDEO.ENCODER.HEVC`）、`c2.mtk.avc.encoder`；
  Task 2 Step 1 事实 3（同计划 `:146`）记录 `/vendor/etc/media_codecs*.xml` 里**已声明 `surface`**。
  仓库内**没有**该 XML 的留档，所以这只是"平台声称"，**不是本机能复核的源码事实**。
- **判定：** **undetermined**。`surface` 声明是"必要不充分"——它说明该 codec 在 XML 里
  自报支持 surface 输入，但**是否真的能 `configure` + `createInputSurface()` 并持续出帧**，
  只能在设备上跑通才算数。这正是计划把它列为 **Task 4** 验收项的原因。

**若不成立会怎样（codec 只吃 ByteBuffer 输入）：** `MediaCodec.createInputSurface()` 会失败，
路线 A 的"surface 直通"破产 → 退到路线 C。

---

## 四、冻结的 Dart↔native 通道协议（逐字取自计划 Task 2 "Produces"）

> **以下名字与形状被后续任务逐字依赖，不得改写。**

- **通道名：**
  - `MethodChannel('smartclass/encoded_stream')`
  - `EventChannel('smartclass/encoded_stream/packets')`
- **`open`** 参数：
  `{cameraId: int, width: int, height: int, fps: int, quality: int, codec: String, sessionGeneration: int}`
  → 成功 resolve、失败 throw `PlatformException`
- **`close`** 参数：`{}` → resolve 表示**已冲刷完毕**
- **`encoders`** 参数：`{}` → `{encoders: [{codec: String, name: String, hardware: bool}]}`
- **事件载荷：** `{bytes: Uint8List, pictures: int, ptsUs: int?, generation: int, eos: bool}`

**契约要点（由计划其它任务钉住，本 ADR 只引用）：**

- `open` 的 `codec` 是 `String`（如 `"h265"` / `"h264"`）；native 侧把它解析成
  `MediaFormat.KEY_MIME`（`video/hevc` 或 `video/avc`），**不上报 bitrate**——
  `quality` 是唯一画质旋钮，`KEY_BIT_RATE` 是插件内部从 `quality` 折算的。
- `close` 的 resolve 语义是"尾包已交付"：native 先 `signalEndOfInputStream()`，
  等 `BUFFER_FLAG_END_OF_STREAM`（有界超时 5 秒）再回 resolve（计划 Task 4 Step 2）。
- 事件载荷里 `generation` 必须**回显** `open` 时给的 `sessionGeneration`；Dart 侧据此
  丢弃换 run 之后迟到的旧包（计划 Task 3 Step 3 规则 2）。
- `bytes` 必须是 `Uint8List`；Dart 侧 `Uint8List.fromList` **拷贝**，不把平台 buffer 直接交出去。
- `ptsUs` 可为 `null`；`pictures` / `eos` 缺字段时 Dart 按 `0` / `false` 处理，**不抛**。

---

## 五、被否决 / 备选的路线及判据

事实 1、2 均成立，所以**当前走路线 A**。下面两条是计划点名的备选，记录判据以备 Task 4
真机证伪时启用；**不现场发明第三条**。

### 路线 C（备选）：`ImageAnalysis`（YUV_420_888）→ `MediaCodec` ByteBuffer 输入

**判据（计划 Task 2 Step 1）：**
1. 编码器是否声明 `COLOR_FormatYUV420Flexible` 输入；
2. 1080p60 的 YUV 是约 **124 MB/s** 的 CPU 拷贝 —— **实测到不了 60 就否决**。

**为什么它是"备选"而不是"首选"：** 它把每一帧从相机 surface 拉到 CPU 再喂回编码器，
与"无磁盘/高帧率"的目的（ADR 0001 §4.2）直接冲突；只有在路线 A 的真机验证失败时才启用。

### 路线 D（已否决）：`Recorder` + `FileDescriptor` 管道再解析容器

**已否决，理由（计划 Task 2 Step 1）：** 它**仍然走容器**（`Recorder` 产出的是 mp4 之类的
封装流），从容器里解析不出"一个完整的编码 AU"这个后端契约要的粒度；而且管道/落盘违反
"视频路径不落临时文件"的全局约束。

**现状佐证：** 插件的 `RecorderProxyApi.java:63-73` 的 `prepareRecording` 只认 `String path`
并建 `FileOutputOptions`（`:66-67`），`validateOutputPath` 还强制 `.mp4`（`:86-89`）——
即上游 `VideoCapture<Recorder>` **只有文件出口，没有 AU 出口**，这正是本计划要 fork 的理由。

---

## 六、`sourceSeq` 的取法，以及为什么这条规则住在 Dart

**native 只上报原始事实：** 每个事件只带 `ptsUs`（`presentationTimeUs`，原样），
**不**在 native 侧算 `sourceSeq`。

**`sourceSeq` 由 Dart 适配器从 `ptsUs` 推导**（计划 Task 3 Step 3 规则 3）：适配器维护
`_lastPtsUs` 与 `_sourceSeq`：

| 条件 | 动作 |
| --- | --- |
| `ptsUs == null` | 每个包都算新帧（`_sourceSeq++`），并记一条诊断计数 |
| `ptsUs != _lastPtsUs` | `_sourceSeq++`（真的推进了） |
| `ptsUs == _lastPtsUs` | **`sourceSeq` 原地不动**（重复帧） |

**为什么规则住在 Dart：** 这是 `SustainedRateMeter` 唯一能识破"重复帧凑 60"的入口
（Review Focus 2）。而它必须住在**本机唯一能自动跑的那一层**——`MethodChannel` 薄壳
（Task 4 写）跑不了门禁，Dart 适配器（Task 3，全部 Flutter-free）能跑。所以协议解析与
去重规则放在 Dart，让 `tool/verify_pure.dart` 能用"重复 `ptsUs` 不推进 / 递增 `ptsUs` 推进"
的用例把它钉死（计划 Task 3 Step 5、handover §下一步任务.3）。

---

## 七、本 ADR 的证实条件（未证实）

**本 ADR 现在不算被证实。** 它只在 **Task 4** 于真机上跑出**实测 AU 计数**后才成立：
计划 Task 4 Step 6 的验收是 **10 秒内 AU 计数 ≥ 550（≥55fps）**、选中的 codec 名是
`c2.mtk.hevc.encoder`（**不是** `c2.android.hevc.encoder`）、同期 `ImageCapture` 拍照仍成功、
且事件里的 `ptsUs` 递增。Task 6 再把每个 codec 的**实测持续帧率**写回本 ADR。

**目标真机的实测事实（逐字取自计划 Global Constraints 表，不在此重新推导）：**

| 项 | 值 |
| --- | --- |
| 机型 / SoC | vivo **V2405A** / `mt6991`（Dimensity 9400 级），`arm64-v8a` |
| Android | **16**（API **36**） |
| 摄像头 | 7 个 Camera2 设备；0 号 = `BACK`，`activeArraySize` 4096×3072，`orientation` 90 |
| 目标帧率档 | `aeAvailableTargetFpsRanges` 含 **`[15,60]` 与 `[60,60]`** → 普通 session 就能请求 60fps，不必走高速 session |
| 1080p 流配置 | 1920×1080 在 `availableStreamConfigurations` 里有 OUTPUT 条目（format 33/34/35） |
| 硬件编码器 | `c2.mtk.hevc.encoder`（alias `OMX.MTK.VIDEO.ENCODER.HEVC`）、`c2.mtk.avc.encoder` |
| 编码器实测档 | AVC 1920×1080 → **30–66 fps**；HEVC 1280×720 → 53–117、3840×2160 → 13–29（**无 1080p 条目**） |
| 插件 | `camera_android_camerax` 0.7.5+1（Java），CameraX **1.6.2**，`minSdk 23` |

> 表里最关键的是 HEVC"**无 1080p 条目**"：1080p 的速率只能由 720p/4K 两档外推（约 52–116），
> **外推不是证据**。所以"1080p60 在这台机器上能否持续"只能由 Task 6 的 `EncodeBudgetProbe`
> 在真机上测出来。**本 ADR 不对任何帧率背书，只对"接缝可建"背书，且这份背书也要等 Task 4。**

---

## 八、什么会证伪本 ADR

只要发生下列任一条，本 ADR 的路线 A 即被证伪，应改走第五节记录的备选（并同步改计划）：

1. **Task 4 真机上自定义 `VideoOutput` 无法与 `Preview` + `ImageCapture` 同绑**
   （CameraX 运行时拒绝第三方 `VideoOutput`，或三者争抢 session 导致拍照/预览被打断）。
   → 退路线 C。**这是最可能出问题的一条。**
2. **`c2.mtk.hevc.encoder` / `c2.mtk.avc.encoder` 在真机上 `createInputSurface()` 失败**
   （XML 声明了 `surface` 但实际只吃 ByteBuffer 输入）。→ 退路线 C。
3. **Task 4 的 AU 计数达不到 ≥55fps（只有 30 上下）且查清是**接缝**（而非帧率协商）的问题。**
   → 先查 `aeTargetFpsRange` 与 CameraX 的帧率协商（计划 Task 4 Step 6 的"停在这里"条款）；
   若确为接缝所致，重估路线。
4. **通道协议被 Task 3/4 证明无法承载后端契约**（例如 `pictures` / `eos` / `generation`
   在某个事件上缺失且无法按默认值兜底，或 `close` 的尾包在有界超时内送不到）。
   → 回到本文件第四节重定协议；**协议一旦改动，Task 3/4/5 必须同批更新。**

**不会证伪本 ADR 的：** HEVC 实测只到 30fps。那是**速率**结论（属 Task 6 / ADR 0001 §4.1.1），
与"接缝能不能建"无关——接缝照样成立，只是声明值随之降到 30（计划 Task 6 Step 3 的模式级判据）。

---

## 九、补遗（2026-10-10）：自定义 `VideoOutput` 如何进入绑定 —— 机制选择

> 本节回应 Task 4 之前悬着的一个问题：**我们 Java 里实现的 `VideoOutput` 如何到达 Dart 侧的
> `VideoCapture.withOutput` 调用**，且要尽量守住 fork 的「只新增文件 + 两行注册」纪律。
> 结论同时**更正 §三.2 事实 2 里「CameraX `bindToLifecycle` 是整体替换」的说法** —— 那句话是错的，
> 而它正是先前把路线设计成「必须同一次调用绑定」的原因。

### 9.1 结论：选**机制 4（native 自持绑定）**

native 在 `open` 里自己造 `VideoCapture` 并自己 `bindToLifecycle`。**Dart 不需要拿到 `VideoOutput`，
也不需要调用 `VideoCapture.withOutput`** —— 因此机制 1/2/3 所解决的问题（如何把 native 的
`VideoOutput` 交给 Dart）在本路线里根本不存在。这条路线之所以成立，关键证据是**CameraX 对同一个
`LifecycleOwner` 的绑定是增量追加、不是整体替换**（见 9.3）。机制 3 仍然可行，记录为 9.4 的备选。

### 9.2 四个机制的调查结果

| 机制 | 可行性 | 关键证据 | 代价 |
| --- | --- | --- | --- |
| 1. 新增 Pigeon 类并重跑生成 | 可行但最大 | `pigeon` 确是 dev-dep（`pubspec.yaml:38`），生成配置在 `pigeons/camerax_library.dart:9-19` | 触碰 2 个上游生成文件 + 上游 `ProxyApiRegistrar.java`；需用户跑 `flutter pub get` 才能生成 |
| 2. 手写生成产物 | **否决** | 生成文件由 pigeon 版本决定字节 | 与 `pigeons/` 源不一致，下次生成即被覆盖，rebase 认不出 |
| 3. 复用既有 `VideoOutput` 类，native 注册、Dart 包装 | 可行，但**单独不够** | `PigeonApiVideoOutput.pigeon_newInstance` 是公开方法（`CameraXLibrary.g.kt:3612`） | 零生成改动；但要用它就得让 Dart 参与绑定，而绑定住在上游 Dart 文件里 |
| 4. native 自持绑定 | **选定** | 插件自身依赖增量绑定（`android_camera_camerax.dart:1292-1305, 1158`） | 只新增文件 + 两行注册；需自己算 `CameraSelector` |

**机制 1 的展开（为什么否决）：** `pigeon` 是 `pubspec.yaml:38` 的 dev-dependency，配置
`dartOut: lib/src/camerax_library.g.dart`、`kotlinOut: .../CameraXLibrary.g.kt`
（`pigeons/camerax_library.dart:9-19`）。重跑需要在 `packages/camera_android_camerax/` 里先
`flutter pub get`（**助手禁止**，会造假 symlink）再 `dart run pigeon --input pigeons/camerax_library.dart`。
它会**整体重写**两个大生成文件，还要新增 `EncodedStreamOutputProxyApi.java` 并在上游
`ProxyApiRegistrar.java:236-245`（既有 `getPigeonApiVideoCapture`/`getPigeonApiRecorder` 的样式）
加一个 `getPigeonApi…` 覆盖 —— **那是第二个上游 Java 文件**。生成文件与 pigeon 版本强绑定，
rebase 时几乎必冲突。代价最大，否决。

**机制 2 的展开：** 手写 `camerax_library.g.dart` / `CameraXLibrary.g.kt` 的增补，会让它们与
`pigeons/camerax_library.dart` 的源不一致；任何一次正规生成都会覆盖，rebase 也认不出来。
风险远大于收益，否决。

### 9.3 机制 4 的决定性证据：CameraX 是增量绑定

§三.2 断言「`bindToLifecycle` 是整体替换，所以必须同一次调用」。**插件自己的代码与这句话矛盾**：

| 证据 | 位置 |
| --- | --- |
| `_bindUseCaseToLifecycle` 对**单个** use case 调 `bindToLifecycle` | `android_camera_camerax.dart:1292-1305`（`:1302` `bindToLifecycle(cameraSelector!, <UseCase>[useCase])`） |
| `startVideoCapturing` 在 preview/imageCapture 已绑的前提下**只绑 `videoCapture`**，并单独 `unbind` imageAnalysis | `:1145-1158`（`:1155` unbind imageAnalysis，`:1158` 绑 videoCapture） |
| `resumePreview` / `pausePreview` 只绑/解绑 preview | `:984`（`_bindUseCaseToLifecycle(preview!, …)`）、`:937`（`_unbindUseCaseFromLifecycle(preview!)`） |
| `_unbindUseCaseFromLifecycle` 用 `unbind([useCase])` 逐个解绑 | `:1392-1399` |
| proxy 直通 CameraX，中间无「先 unbindAll」 | `ProcessCameraProviderProxyApi.java:62-76`（`bindToLifecycle(lifecycleOwner, selector, useCases)`） |

若 `bindToLifecycle` 真是替换语义，`:1158` 一执行预览就会被顶掉——插件不可能如此，故 CameraX
对同一 `LifecycleOwner` 是**追加**。于是 native 可以只绑我们的 `VideoCapture`，它会**追加**到既有的
Preview/ImageCapture 上，**无需拿到它们的引用**。所需的生命周期所有者与 context 都在 registrar：
`ProxyApiRegistrar.getLifecycleOwner()`（`ProxyApiRegistrar.java:108-117`）、`getContext()`（`:90-93`）；
provider 用 `ProcessCameraProvider.getInstance(context)`（`ProcessCameraProviderProxyApi.java:39-54`）。
`CameraSelector` 由 `open` 的 `cameraId` 经 `Camera2CameraInfo.getCameraId()` 在
`getAvailableCameraInfos()` 里定位后构造（`pigeons/camerax_library.dart:272-281` 显示它支持
`requireLensFacing` / `cameraInfoForFilter` / defaultBack/defaultFront）。

### 9.4 机制 3（备选）：Dart 拿到 `VideoOutput` 的确切调用

若 9.3 的增量假设被真机证伪（见 9.6.1），退机制 3。它**可行且零生成改动**，握手链路已现成：

- **native 侧**：`CameraXLibrary.g.kt:3609-3643` 的 `PigeonApiVideoOutput` 是 **open class**，其
  `pigeon_newInstance(pigeon_instanceArg: androidx.camera.video.VideoOutput, callback)`（`:3612`）
  是**公开方法**，入参类型就是 CameraX 接口本身 —— 我们 `implements VideoOutput` 的类可直接传入。
  它内部 `instanceManager.addHostCreatedInstance(...)`（`:3624`）后把 identifier 经
  `dev.flutter.pigeon.camera_android_camerax.VideoOutput.pigeon_newInstance` 发给 Dart（`:3627-3629`）。
  **唯一调用**：`proxyApiRegistrar.getPigeonApiVideoOutput().pigeon_newInstance(output, cb)`
  （`getPigeonApiVideoOutput` 见 `CameraXLibrary.g.kt:530-531`）。
- **Dart 侧**：处理器早已存在（`camerax_library.g.dart:3405-3447`，在 `:443` 注册），收到后
  `addHostCreatedInstance(VideoOutput.pigeon_detached(...), id)`（`:3428-3435`）；Dart 用
  `PigeonInstanceManager.instance.getInstanceWithWeakReference<VideoOutput>(id)`
  （`:557-573`）取回句柄；再传给 `VideoCapture.withOutput` 时由
  `_PigeonInternalProxyApiBaseCodec.writeValue`（`:689-696`）按 identifier 编码，Kotlin 侧再解码
  回我们的 native 对象。

**机制 3 单独不够用**：它只解决「Dart 拿到 `VideoOutput`」，不解决「谁把它绑上去」。要用它，
Dart 必须自己调 `VideoCapture.withOutput` 并参与绑定；而插件今天的绑定住在
`android_camera_camerax.dart:421-425`（构造）与 `:961-972`（绑定），那是**上游 Dart 文件**。
**没有更便宜的办法**能让插件既有的绑定路径用上我们的 `VideoOutput`，除非改这个文件（约 2–4 行，
把 `videoCapture` 的 `VideoOutput` 从 `recorder!` 换成我们的）——那会破坏「只新增文件」，须同步
改 `VENDORED.md`。所以 9.1 优先选机制 4。

### 9.5 触及的上游文件与 Pigeon 生成

**纪律不破（只新增文件 + 两行注册）：**

- 新增 `.../camerax/EncodedStreamVideoOutput.java`（本次已写）。
- 新增 `.../camerax/EncodedStreamPlugin.java`（Task 4 写）。
- 改 `CameraAndroidCameraxPlugin.java` 两行（`CameraAndroidCameraxPlugin.java:27-46`）：
  `onAttachedToEngine` 里 `EncodedStreamPlugin.register(proxyApiRegistrar);`，
  `onDetachedFromEngine` 里对应注销。注册需要的是 `ProxyApiRegistrar`（拿 `lifecycleOwner`/`context`），
  不只是 `BinaryMessenger`；仍是**一行**。若只传 messenger，native 拿不到 `lifecycleOwner`，机制 4 退回机制 3。

**Pigeon 不需要重跑。** 机制 4 与机制 3 都不新增 Pigeon 类，不触碰 `pigeons/`、
`lib/src/camerax_library.g.dart`、`CameraXLibrary.g.kt`。**任何人都不需要跑 `flutter pub get` 或 pigeon**
（同时满足「助手绝不跑 `flutter pub get`」）。只有机制 1 才需要，且由**用户**在其 shell 里跑。

### 9.6 什么会证伪本选择

1. **CameraX 1.6.2 对同一 `LifecycleOwner` 实为替换语义**（与 9.3 插件用法矛盾）→ 机制 4 会把
   Preview/ImageCapture 顶掉（**静默坏预览**，正是最该防的失效）。Task 4 必须先验证：绑完我们的
   use case 后，预览仍有画面、`ImageCapture` 仍能拍照。若证伪 → 退机制 3 + **最小上游 Dart 改动**
   （`android_camera_camerax.dart` 约 2–4 行），并同步 `VENDORED.md` 的「只新增文件」条款。
2. **`CameraSelector` 无法定位到已绑的同一相机** → `bindToLifecycle` 抛
   「Multiple LifecycleCameras…」或绑到第二台相机 → 退机制 3。
3. **插件后续 `unbindAll()`**（`android_camera_camerax.dart:404` 创建、`:519` dispose、`:971`
   切相机）会静默丢掉我们的 use case。若这在**正常流程**（而非切相机/释放）里发生，机制 4 的
   「native 自持」假设不成立 → 退机制 3。
4. **机制 4 无法在 `open` 时拿到可用的 `lifecycleOwner`**（例如 `onAttachedToActivity` 尚未发生）
   → 退机制 3。

**不会证伪本选择的：** HEVC 实测只到 30fps。那是速率结论（§八末），与「VideoOutput 怎么进绑定」无关。
