# Linux 原生编码分支 —— 暂停交接

> **状态：⏸ 已暂停（2026-10-10）。** 代码已落地到 HEAD `83df291`，**一行都没有编译过**。
>
> 目的：让这台设备真能交付 1080p60 H.264/H.265。帧率上限卡在 `takePicture()`
> （1080p 约 5–10 fps，全平台如此），把编码器接在它下游只换编码、不换上限 ——
> 帧必须在插件自己的管线里编码完再进 Dart。
>
> 计划：`docs/superpowers/plans/2026-10-09-linux-encoded-stream.md`
> 上游计划：`docs/superpowers/plans/2026-10-09-recording-correctness-and-native-encoder.md`（Task 6，
> **其 ffmpeg 架构已作废**，见该文件顶部取代标记）
> 总览：`docs/implementation-status.md`

---

## 〇、三层验证 —— 先分清哪一层能在哪台机器上验

这条链路上有三层，**可验证性完全不同**。混在一起说会得出「所有插件 Dart 都能由纯 VM 测」
这种错误结论 —— **Flutter bridge 那层就不能**：

| 层 | 例子 | 本机（Windows 助手 shell）能拿到什么证据 | 需要什么 |
| --- | --- | --- | --- |
| **① 纯领域模型**（不 import `package:flutter`） | `annexb.dart`、`encode_budget.dart`、`sustained_rate.dart`、`native_video_encoder.dart`、`lib/src/agent/**` | ✅ **跑过**：`dart run tool/verify_pure.dart`（含断言 + 变异验证） | 无 |
| **② 插件 Dart bridge**（`package:flutter` + MethodChannel / FFI） | 插件 Dart 侧（Task 5）、app 侧适配器（Task 6）、`CameraPlatform.instance` 强转 | ⚠️ 只有**类型检查**：`python tool/check_compile.py`。**编译 ≠ 断言** | **用户跑 `flutter test`** |
| **③ Linux C++** | `packages/camera_desktop/linux/**`、GStreamer 管线 | ❌ 连编译都不行（缺 GStreamer / GTK / `flutter_linux` 头文件） | **一台 Linux 机器** |

→ **本机唯一能给出「跑过」证据的是第 ① 层。** 第 ② 层最强只能到「编译通过」，
第 ③ 层什么都没有。**恢复时不要拿 ① 的绿灯去替 ② / ③ 背书**，也不要因为第 ② 层
「是 Dart」就以为它能进纯 VM 门禁 —— 它要 Flutter 引擎和 test runner。

---

## 一、为什么停在这里

不是做不下去，是**下一步必须有 Linux 机器**。

这一批全是 `packages/camera_desktop/linux/` 下的 C++，而本机（Windows）**编译不了**：

- `flutter analyze` / `build` / `test` / `run` 在助手 shell 里**全部失败**
  （`CreateFile failed 231`，沙箱建不了子进程管道）；
- Linux 的 GStreamer、GTK、`flutter_linux` 头文件在本机也**不存在**；
- 本机唯一能跑的只有 `dart run tool/verify_pure.dart` 和 `flutter pub get`。

继续往下写 Windows / macOS / Android 三端，等于攒一批**没人编译过**的原生代码再一起祈祷
—— 这正是上游计划里 T6 Step 1 那个闸要防的事。所以停。

### 暂停的范围（哪些停、哪些不停）

- **停**：`packages/camera_desktop/linux/**` 的原生编码实现 —— 不再往下写，**不宣称交付**。
- **不停**：共享 Dart 层（第 ① 层）继续演进，因为它**不需要任何原生实现**就能验。
  契约按 **Android → Windows → macOS → Linux** 的顺序，先在**能编能跑**的平台上验 ——
  所以「Linux 编不了」**不是**三端全部停工的理由，Linux 只是**排在最后**。
- **恢复条件（缺一不可）**：① 用户明确恢复 Linux 开发；② 一台装了 GStreamer + GTK +
  `flutter_linux` 头文件的 Linux 机器。恢复步骤见第六节。

---

## 二、已落地

| 提交 | 内容 |
| --- | --- |
| `441df72` | **vendor `camera_desktop` 2.0.0** 进 `packages/camera_desktop/`（75 文件，剔掉 `example/`）；root `pubspec.yaml` 改 `path:`。新增 `VENDORED.md` 写清来路与四条 fork 纪律 |
| `f10f86c` | **Task 1** 编码器可用性探测：`EncodedStreamHandler::DetectEncoder()` / `AvailableEncoders()`，方法 `availableEncoders`，CMake 加源文件 |
| `83df291` | **Task 2–4** 编码分支本体、字节交给 Dart、接进 `Camera` 与方法分发表（617 行） |

前置（同一条链路上的纯 Dart 部分，已完成且经过验证）：

| 提交 | 内容 |
| --- | --- |
| `604316d` / `6ca637c` | 录制正确性两处修复（`start_recording` 激活它点名的摄像头；不同上限的裸切要重建几何） |
| `36f55a8` / `a438a74` / `d910ea0` | Annex B 切分（改成有状态的 `AnnexBSplitter`）、可持续帧率模型 |
| `f2341e5` | **Task 5** Dart 侧契约 `native_video_encoder.dart`：`EncodedPacket` / `EncodedStreamChannel` / `NativeVideoEncoder`。**harness 673 → 705，全绿** —— 这是目前唯一真正被验证过的部分 |

### 分支拓扑

```
[src: v4l2src | pipewiresrc] ! videoconvert ! videoflip
  ! videoscale ! videorate ! video/x-raw,format=RGBA,WxH,framerate=F/1
  ! tee name=t
    t. ! queue ! appsink                                              (预览，原有)
    t. ! [RecordHandler]                                              (录文件，原有)
    t. ! queue ! valve ! videoconvert ! encoder ! parse ! capsfilter ! appsink
                                                                       (新增，每 codec 一条)
```

**从 tee 分出去，不是另开一条管线。** 上游计划那句「`v4l2src` → decode → …」照字面实现
会 EBUSY —— 预览管线已经占着设备，而且 `gst_parse_launch` 不会报错，要等到 PLAYING 才炸。

tee 之后拿到的已经是**目标分辨率 + 目标帧率的 RGBA**（`videorate` 在 tee 之前），
这正好让声明的帧率天然诚实。代价：1080p60 有约 497 MB/s 原始流量，是这条路最大的性能风险。

### 字节怎么过到 Dart

`new-sample` 在 **GStreamer 流线程**上 → 只做拷贝，然后 `g_idle_add` 回主线程 →
`fl_method_channel_invoke_method(channel, "encodedStreamPacket", {cameraId, pictures, bytes})`。

走的是插件**已有的 MethodChannel**：Windows / macOS 早就在用它推 `imageStreamFrame`，
Linux 的 `Camera::SendError` 也在用同一个函数。没有新开 EventChannel，也没有新开 FFI
（`image_stream_ffi` 是共享缓冲 + Dart 轮询，不适合变长突发的编码数据）。

`pictures` 一律报 1 —— 因为 `capsfilter` 钉了 `alignment=au`，一个 buffer 就是一个完整 AU。
这是**对 GStreamer 的假设，不是对字节的事实**，正好由 `EncodedPacket.pictures` 那条交叉
校验兜住：Dart 切出来的单元数对不上就整包丢弃并计数，而不是把解不出来的东西发出去。

> ⚠️ **2026-10-10：契约已扩，实现 `EncodedStreamChannel` 前先看现行定义**
> （`lib/src/capture/native_video_encoder.dart`）。`EncodedPacket` 多了
> `sourceSeq` / `sourcePts` / `sessionGeneration` / `isEos`，`open()` 多了
> `required int sessionGeneration`。两条实现义务：
> ① **`sourceSeq` 必须是采集侧的源序号**，不能自己重新编号 —— 重新编号永远不重复，
> 帧率测量就永远偏乐观（这正是 `videorate` 陷阱要防的）；
> ② 每个包原样回传 `open()` 给的那个代次，否则换 run 之后仍在途的回调会被当成当前流的包。

---

## 三、与计划的偏离（3 处，都写回计划文档了）

1. **不是一条分支，是每个 codec 一条。** `Start` 时才改配置意味着要往 PLAYING 的管线里加
   元素 —— 合法，但失败模式难看，而最多只有两条。两条都建，各自藏在关闭的 valve 后面，零 CPU。
2. **`Stop()` 不发 EOS，改成把分支 `set_state(NULL)`。** 分支配的是零延迟、无 B 帧，
   编码器**不留尾巴**，没有东西要 flush；而 park 到 NULL 让**下一次录制从新编码器开始** ——
   新编码器第一帧必然是带参数集的 IDR。不这么做，第二次录制会以一个 P 帧开头，
   **开头几秒直接不可解码，而服务端逐字存字节、完全不会报错**。
   （哪天真加了 B 帧，这两条同时不成立 —— 代码注释里写了。）
3. **`Dispose()` 里 handler 在管线 NULL + unref *之后* 才 reset**（计划原写"之前"）。
   appsink 回调带着 `this`，先拆 handler 会留一个流线程访问已释放内存的窗口。

---

## 四、未验证项 —— 恢复时第一件事

按"最可能让你白跑一趟"排序：

| # | 项 | 为什么可疑 | 错了的症状 |
| --- | --- | --- | --- |
| 1 | `h264parse config-interval=-1` | 全计划里最没把握的一处。想要的是「每个 IDR 前都插参数集」，`-1` 是不是这个语义没查证 | 中途接入的消费者拿不到 SPS/PPS，录像是能存不能解 |
| 2 | `queue leaky=2` 的丢帧方向 | `GST_QUEUE_LEAK_DOWNSTREAM` 是否真的是「丢最旧、留最新」，我有五成把握 | 反了的话延迟慢慢爬，不是崩溃，不盯着看不出来 |
| 3 | `fl_value_new_uint8_list` 的签名 | Linux 引擎头文件在本机不存在，没核对过 | **编不过**，直接挡在门口 |
| 4 | caps 是否真的协商上了 | Task 2 Step 5 的「断言 caps 协商成功」**没做** | capsfilter 静默失败 → Dart 收到 AVC 长度前缀字节 → 被 splitter 切碎 |

> 第 3 条是唯一会直接挡住编译的。前两条和第四条都是**编过了、跑起来也像对的、其实不对**
> —— 这类才是真正要去机器上验的。

---

## 五、还没做的

上游计划的 Task 5–8，加上另外三端。**「能验到哪一层」见第〇节** —— 这里最容易误判：

| Task | 内容 | 验证层 / 备注 |
| --- | --- | --- |
| 5 | 插件的 Dart 侧：`EncodedStreamPacket` 类型、`startEncodedStream` / `stopEncodedStream` / `availableEncoders()`、`_handleNativeCall` 里加 `encodedStreamPacket` 分支 | **第 ② 层**（MethodChannel）。本机只能 `dart format` 语法校验，**验证要用户 `flutter test`** |
| 6 | app 侧适配器 `lib/src/capture/plugin_encoded_stream.dart`，实现 `EncodedStreamChannel`。**通过 `CameraPlatform.instance` 强转拿到插件实例** —— 不能自己 new 一个，它的 `_ensureNativeCallHandler` 会覆盖掉活的 channel handler | **第 ② 层**。`CameraPlatform.instance` 与 channel handler 都要 Flutter 引擎，**不是纯 VM** |
| 7 | 把 `availableEncoders()` 接成 `CodecProbe`（与 `BaselineCodecProbe` 用 `CompositeCodecProbe` 并起来） | `CodecProbe` **接口**是第 ① 层；**实现**是第 ② 层（它要问插件） |
| 8 | **实测吞吐**，把数字喂给 Task 4 的 `sustainableRates` | 第 ② / ③ 层 + 真机。**没有实测就没有资格声明 60** |
| T7/T8/T9 | Windows（Media Foundation）/ macOS（VideoToolbox）/ Android（CameraX + MediaCodec） | 各平台独立验收；**Android 这一轮要做**，且顺序在最前 |
| T11 | 打包动态库、更新文档 | ⚠️ **前提已变**：原写「LICENSE 改 GPLv2+（x264/x265 一旦进包）」，但 **ffmpeg / x264 / x265 已否定**（见 ADR §5）→ 编码走各平台系统 API，**GPL 义务不再自动成立**。实际许可义务按**真正分发的东西**判定（#24），不要机械沿用 GPL 结论 |

---

## 六、恢复步骤

**先记住顺序**：契约先在 **Android** 上验（有真机、能编能跑），再 Windows、macOS，
**Linux 排最后**。所以「恢复 Linux」不等于「恢复原生编码」—— 前三端不需要这台 Linux 机器。

要恢复 **Linux 这一端**时：

1. 一台 Linux 机器，`flutter build linux`。
   **编不过就把报错贴回来改** —— 预计第一道坎是第四节表第 3 条（`fl_value_new_uint8_list`）。
2. 编过之后，按第四节那张表逐条验（第 1、2、4 条都要在真机上量，不是看代码能定的）。
3. 然后是 Task 5 → 6 → 7，把链路打通 —— 注意这三项是**第 ② 层**，需要用户的 `flutter test`。
4. Task 8 的实测数据出来之前，**不要声明任何高于 mjpeg 能稳住帧率的速率**。

> **恢复之前**：① 用户明确恢复；② Linux 机器可用（见第一节「恢复条件」）。

---

## 七、两条环境铁律（恢复时别忘了）

- **Windows 上绝不要用助手 shell 跑 `flutter pub get`**：它会把
  `{windows,linux}/flutter/ephemeral/.plugin_symlinks/*` 写成**空目录**（`Link.createSync`
  不报错但造出来的是普通目录），而下一次真的 `flutter run` 会撞 `errno = 183` 直接失败。
  `pub get` 只能由用户自己的终端跑。
- **`flutter test` 由用户跑**，助手跑不了。改完只能做 `dart format` 语法校验 + harness。
