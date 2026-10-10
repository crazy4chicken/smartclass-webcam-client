# AI 交接文档 — 未完成的任务

> **面向接手本仓库的 AI 代理。** 先读这一份，再动手。  
> 最后更新：2026-10-10（第二批）。对应门禁 `passed: 1132, failed: 0`（**断言数以实跑输出为准**）。
>
> 这份文档只讲**还没做完的事**和**做之前必须知道的约束**。  
> 已完成的部分见 `docs/implementation-status.md`；不可动摇的约定见  
> `.workbuddy-ai/memory/MEMORY.md` 与 `.workbuddy-ai/memory/CONVENTIONS.md`。

---

## 0. 三十秒版本

**这是什么**：Flutter 跨平台摄像头**边缘探针**（Windows/macOS/Linux/Android/iOS），  
接入 `smartclass-webcam-server` 的设备协议。**设备是从属角色**——没收到 `start_recording`  
就什么都不推。

**现在的状态**：共享 Dart 层（协议、采集抽象、协调器、编码契约、**流诊断**）已完成并有门禁断言  
（断言数以实跑输出为准，最近一次 1132 条）；  
**所有原生编码实现都没做**（Android/Windows/macOS 一个都没有，Linux 写了但没编译过）。

**你要做的第一件事**：跑 `dart run tool/verify_pure.dart`，确认基线是 `failed: 0`。  
**在任何改动之前跑一次**，否则你分不清失败是你造成的还是本来就有的。

**最容易踩的三个坑**：

1. 助手 shell **跑不了** `flutter test` / `flutter build` / `flutter analyze`（见 §1）。
2. **别把「请求帧率」和「声明帧率」合并**（见 §6）。
3. **别拿探针的「接受率」当「实测率」填进证据缓存**（见 §5.1）。

---

## 1. 环境硬约束（先看，否则白干）

### 助手 shell 能跑什么

| 命令                                           | 能跑？         | 说明                                                                       |
| -------------------------------------------- | ----------- | ------------------------------------------------------------------------ |
| `dart run tool/verify_pure.dart`             | ✅           | **唯一可执行的门禁**。进程内执行                                                       |
| `dart format`                                | ✅           | 进程内执行                                                                    |
| `python tool/check_compile.py`               | ✅           | **整仓类型检查**（`lib/` + 全部 `test/`、`tool/`），约 5 分钟。**只编译不运行** —— 编译通过 ≠ 断言通过 |
| `flutter test` / `build` / `run` / `analyze` | ❌           | `ProcessException: All pipe instances are busy`（`errno = 231`）           |
| `dart analyze`                               | ❌           | 同上                                                                       |
| `flutter pub get`（**Windows 上**）             | ⚠️ **绝不要跑** | 见下                                                                       |

> ⚠️ **Windows 上绝不要用助手 shell 跑 `flutter pub get`。** 它会重建  
> `{windows,linux}/flutter/ephemeral/.plugin_symlinks/*`，但沙箱里 `Link.createSync`  
> **不报错却造出一个空目录**。Flutter 判 `link.existsSync()` 对普通目录返回 `false`，  
> 于是下一次真的 `flutter run` 撞 `ERROR_ALREADY_EXISTS(183)` 直接失败。  
> 修法：`rm -rf {windows,linux}/flutter/ephemeral/.plugin_symlinks`（纯生成物），  
> 然后由**用户自己的终端**重跑。**这条踩过一次。**

### 因此的验证策略

- **纯 Dart 部分**：你负责写断言并跑门禁。这是你的主战场。
- **Flutter/插件部分**：写 `test/` 下的用例，但**必须让用户跑**。不要声称跑过了。
- **原生部分**：只能交给用户。**没有编译证据的代码不许标完成。**

### 网络代理（白名单制）

- 打 **127.0.0.1 必须加 `--noproxy '*'`**，否则被代理拦截、报假的  
  `upstream connect failed`，看起来像服务没起。
- **公网反而要走代理**：`dl.min.io` 直连可达，`github.com` 加 `--noproxy` 就超时，  
  `registry-1.docker.io` 代理整个拒绝（Docker Hub 用不了）。

---

## 2. 文档地图（哪份在什么时候是权威）

| 文件                                                         | 什么时候读                           |
| ---------------------------------------------------------- | ------------------------------- |
| **`docs/adr/0001-dual-mode-capture-decisions.md`**         | **决策冲突时以它为准。** 双模式取画面的现行口径      |
| `docs/superpowers/plans/2026-10-10-dual-mode-task-list.md` | 26 项任务清单。**已勾选的是有证据的**，注释里写了缺什么 |
| `docs/implementation-status.md`                            | 每个计划实现了什么/偏离了什么/验证到什么程度         |
| `README.md`                                                | 架构、协议要点、本机环境的完整说明               |
| `.workbuddy-ai/memory/MEMORY.md`                           | **「改错了就会坏事」的不变量**（按需读，不要全文背）    |
| `.workbuddy-ai/memory/CONVENTIONS.md`                      | 协议细节、测试写法、本机环境的参考资料             |
| 后端仓库 `smartclass-webcam-server/docs/protocol/`             | **协议权威**。与本仓库冲突时以后端为准           |

**已被取代、不要照抄的文件**：`2026-10-09-recording-correctness-and-native-encoder.md`、  
`2026-10-09-linux-encoded-stream.md`、`New-two-features.md`、`docs/plan_v0.md`。  
取代关系写在 ADR 第一节。

---

## 3. 已完成 —— 不要重做

2026-10-10 落地，全部有门禁断言 + 变异验证：

| 内容                                    | 落点                                                                                            |
| ------------------------------------- | --------------------------------------------------------------------------------------------- |
| 门禁接线（两个专项检查此前**零调用**）                 | `tool/verify_pure.dart` + `verify_annexb.dart` / `verify_encode_budget.dart`                  |
| 多 slice 合并为一个 access unit             | `lib/src/capture/annexb.dart`                                                                 |
| 默认模式选择器（1080p 封顶、保形状、帧率只降不升）          | `lib/src/capture/default_mode.dart`                                                           |
| 编码证据模型 + 缓存 + 按模式 codec 校验            | `lib/src/capture/encode_budget.dart`、`lib/src/config/shared_prefs_encode_evidence_store.dart` |
| 持续帧率测量模型 + 平台接缝                       | `lib/src/capture/sustained_rate.dart`                                                         |
| 协调器编码工厂（拒绝即 `ack ok:false`，不偷换 codec） | `lib/src/agent/agent_coordinator.dart`                                                        |
| 决策收口（取代旧计划、纠正许可与断言数）                  | `docs/adr/0001-dual-mode-capture-decisions.md`                                                |

### 3.1 第二批（2026-10-10 晚）

| 内容（原 §4 的 A 类项）           | 落点                                                                                                                                        |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **A4 / #23 实测状态与可诊断失败信息** | `lib/src/agent/stream_diagnostics.dart`（新）、`agent_status.dart`、`agent_coordinator.dart`、`status_bar_overlay.dart`                         |
| **A6 / #2 文档与注释腐化**       | `lib/main.dart`、`camera_provider.dart`、`codec_probe.dart`、`packages/camera_desktop/VENDORED.md`、`docs/implementation-status.md`、旧计划顶部取代标记 |
| **A7 / #3 Linux 文档三层验证**  | `docs/linux-encoded-stream-status.md` 第〇节                                                                                                 |

**A4 的实际内容**（细节见任务清单 #23）：

- `AgentStatus` 的**单个 `fps` 已删除**，换成 `diagnostics`（`StreamDiagnostics`）：**目标 / 声明 /  
  实际采集 / 编码 / 发送**五个帧率 + `codec` + 硬件身份 + WxH + `droppedFrames` + `repeatedFrames`
  - 降级原因。状态条新增两行。
- **`BackendGateway.sendRecordingFrame` 由 `void` 改为 `bool`**（网关拒收时返回 `false`）。  
  这是「网络慢」能被区分出来的**前提** —— 此前链路断了也一律计为已发送。
- **采集帧率取自源序号前进量**，不是到达计数。否则「编码器丢了画面」与「相机没产出」  
  在数字上完全一样，`PipelineBottleneck.encoder` 永远不可达。
- `classifyBottleneck` 按**管线顺序**判：相机 → 编码 → 传输，**第一个不达标的赢**。
- **`队列` 有意未做**：`sendRecordingFrame` 是同步的，没有队列可报。不要为了凑字段加一个恒为 0 的。

> ⚠️ **A4 未验的部分**：状态条是 Flutter widget，`test/ui/status_bar_overlay_test.dart` 已按新  
> 字段重写，但**助手跑不了 `flutter test`** —— 那份用例由用户跑。助手侧只做了  
> `tool/check_compile.py` 类型检查（**编译 ≠ 断言**）。

---

## 4. 未完成的任务

### A 类：**助手可以做**（纯 Dart，不需要硬件）

> **2026-10-10 已完成 A1、A2、A4、A5、A6、A7**（A1/A2/A5 见本节末；A4/A6/A7 见 §3.1）。  
> **剩下 A3 与 A8。** 编号保持原样，避免与日志和任务清单里的引用对不上。

#### A3. #11 的收尾 —— `EncodeBudgetProbe` 的**非原生**部分

**现状**：模型、缓存、校验、接线全部完成。**缺**：

- 预热时长与窗口长度的**标定**（现在是 `SustainedRateMeter` 的默认值 1.5s / 3s，没有实测依据）。
- 「多窗口取最快样本是否代表持续能力」的审查（`EncodeSample` 的文档假设了「最快的一次是更好的证据」，  
  **这个假设没有被验证过**，尤其面对热降频）。
- PTS / 掉帧 / 硬件身份（encoder identity）的采集。

**这些都需要真机数据才能定**，但**判据与算法可以先写**。

---

#### A4. #23 实测状态与可诊断失败信息 —— **已完成（见 §3.1）**

`AgentStatus` 的单个 `fps` 已拆成五档，`sendRecordingFrame` 改为返回是否送达，  
`classifyBottleneck` 按管线顺序归因。**细节与未验项见 §3.1。**

---

#### A5. #10 的剩余部分 —— **已完成（见本节末）**

剩的只有一条，且是 B 类：**真实编码样本的解码证明** —— 需要原生编码器产出样本。  
`AnnexBSplitter` 的 pending 上限与残缺/非法 slice 头的系统用例都已补齐。

---

#### A6. #2 的剩余部分（文档与注释腐化）—— **已完成（见 §3.1）**

表中五条全部处理：`main.dart` 的 ffmpeg 注释、`VENDORED.md` 的 BSD-3 → **MIT**、  
`camera_provider.dart` / `codec_probe.dart` 的 ffmpeg 回退语义、旧计划顶部取代标记、  
`implementation-status.md` 的 Phase 划分与状态复核。

---

#### A7. #3 Linux 文档分层 —— **已完成（见 §3.1）**

`linux-encoded-stream-status.md` 新增第〇节「三层验证」，并改掉了第五节表里把 Task 5/6/7  
标成「纯 Dart」的过度声称。

---

#### A8. #25 的收尾

每完成一项，**同时**更新：README、`docs/implementation-status.md`、  
任务清单的勾选与注释。**不要等最后统一写。**

---

#### 已完成（2026-10-10）：A1 + A2 + A5

**A1（#9 的剩余部分）**：`EncodedPacket` 现在带 `sourceSeq` / `sourcePts` /  
`sessionGeneration` / `isEos`；`EncodedStreamChannel.open()` 多一个  
`required int sessionGeneration`；`EncodedFrame` 多 `sourceSeq` / `sourcePts`。

- `NativeVideoEncoder` 每个 run 递增代次，`_onPacket` **丢弃代次不符的包**  
  （`stalePackets`）—— 这就是「旧包不进入新流」从隐含变成可验证。
- 一个包里的多张图按 `sourceSeq + i` 编号（flush 的图在采集侧本来就是连续的）。
- `sawEos` 记录生产者有没有声明结尾；**没有**强制要求 EOS（那会废掉不发 EOS 的生产者）。
- `start`/`stop` 用 `SerialLock` 串行；`open` 失败回滚 `_running`。
- **次序语义定死**：`close()` 先于 `cancel()`；`close()` 被 await（尾包交付的保证点），  
  `cancel()` **不被 await**（单订阅流的 cancel 要到下一轮才完成，等它会让下一次 `start`  
  依赖一个已经不可能再交付的流的拆除）。
- **`EncodedFrame.seq` / `ts` 语义未变**：`seq` 仍是流内单调序号（服务端按它归档），  
  `ts` 仍是交付时刻。源 PTS 单独放 `sourcePts` —— 重复帧的 `ts` 必须前进，`sourcePts` 不该。

**A2（跨任务依赖）**：新增 `measureDeliveredRate({encoder, meter, clock})`  
（`lib/src/capture/sustained_rate.dart`）—— 把编码器的交付帧流喂给  
`SustainedRateMeter`，喂的是 `sourceSeq` 而不是 `seq`。门禁里有一条断言用**真实  
`NativeVideoEncoder`** + 一个重复源序号的 channel 证明「重复不算交付」。

**A5（#10 的剩余部分）**：`AnnexBSplitter` 的 pending 字节量现在有上限  
（`kMaxPendingBytes` = 1 MiB）。超限即**丢弃并计数**（`pendingOverflows` /  
`droppedPendingBytes`），随后按下一个起始码重新同步。丢是安全的，因为 pending 里  
按构造**不可能有图像** —— 图像一旦凑齐就立刻 emit，从不 hold。不加上限时，一个不发  
起始码、或只发 SEI 不发图像的产出者会把这块缓冲养到进程结束，而设备是要连续开机数周的。

顺带补齐了**残缺 / 非法 slice 头**的系统用例：只有 NAL 头没有 slice 头、单字节 HEVC NAL、  
未知 NAL 类型（0 / 12 / 31）、相邻两个起始码、孤立的 continuation 切片、HEVC 后缀 SEI  
（按前缀处理，有意且已文档化）。

> **写这类用例的坑（踩过一次）**：「缺 slice 头」只有在**图像已经打开**时才走得到  
> `_startsNewPicture` 的 `at >= end` 分支。单独喂一个无 slice 头的 NAL，会先撞上  
> 「起始码后面什么都没有」那条分支，用例照样绿 —— 但**它验证的不是它声称的那条规则**。  
> 正确的是 `[图像][无 slice 头的 NAL][切片]`，断言 3 个单元。变异验证：把那句改成  
> `return false`，只有这个形状的用例会红。

**未做的，别当成已做**：

- **没有任何平台填 `sourcePts`**（插件 API 大多不给 PTS）。字段有承载，采集没有。
- **`measureDeliveredRate` 目前只有门禁在调用**，生产侧没有调用者 —— 它是  
  `EncodeBudgetProbe` 各平台实现的公共身体，而**那些实现一个都还没有**（B 类）。  
  这与 `EncodeBudgetProbe` 自身的状态一致，不是新欠的债。
- `close()` **没有超时兜底**：插件不返回 `close()` 时 `stop()` 会一直挂着。

---

### B 类：**必须用户跑构建 / 真机**（你只能准备好代码与验收脚本）

| 任务          | 内容                                                                        | 为什么只能用户做                                            |
| ----------- | ------------------------------------------------------------------------- | --------------------------------------------------- |
| **#7**      | vendor `camera_android_camerax` 0.7.5+1，过构建闸                              | 需要 `flutter pub get` + APK 构建                       |
| **#12**     | Android 连续采集 + 编码方案验证（Camera2 帧率 range、高速 session 限制、MediaCodec 硬件 HEVC）  | 需要真机 API 行为                                         |
| **#13**     | Android native H.265/H.264 编码流                                            | 需要真机编译运行                                            |
| **#14**     | 跨平台 Dart 适配器与应用启动装配                                                       | 一半纯 Dart（可做），一半插件事件桥接（需 `flutter test`）             |
| **#15**     | Android 真机端到端与长稳验收                                                        | 真机                                                  |
| **#16–#18** | Windows Media Foundation 设计 / 实现 / 验收                                     | 本机可编译，但助手 shell 跑不了构建                               |
| **#19–#20** | macOS VideoToolbox                                                        | 需要 Mac                                              |
| **#21–#22** | Linux GStreamer                                                           | **暂停**。本机谁都编不了（缺 GStreamer/GTK/`flutter_linux` 头文件） |
| **#24**     | 许可 / 依赖 / CI 发布完整性（**三端**：Windows/macOS/Android；Linux 已于 2026-10-10 移出发布） | CI 在远端                                              |


**B 类里你能做的**：把接口、契约、fake 实现、验收脚本写好，  
让用户那边「接上就能跑」。**参考 `tool/e2e/` 里已有的做法**  
（`check_segment.py` 逐帧校验、`s3_stub.py` 最小 S3 替身）。

---

## 5. 已经定下的决策 —— 不要重开

全部记在 **`docs/adr/0001-dual-mode-capture-decisions.md`**。最容易误判的四条：

### 5.1 探针测不出帧率，别拿「接受率」当「实测率」

`plugin_capability_probe.dart` 的 `_acceptsFramerate` 是**接受性**测试：  
用 `fps: 60` 打开相机、`initialize()` 不抛就算过。它证明「插件没拒绝这个数字」，  
**不证明能以它产出**。五个平台的插件栈**都没有**报告真实帧率范围的 API。

> **不要**把 `CameraCapabilities.framerates` 填进 `EncodeEvidence`。  
> 那正是 `EncodeBudgetProbe` 这条接口存在的意义。

### 5.2 请求帧率 ≠ 声明帧率

|                                | 值            | 用途              |
| ------------------------------ | ------------ | --------------- |
| 请求 `AppConfig.defaultFps` = 60 | 泵的 tick 间隔   | **允许高于交付量，不节流** |
| 声明 `CameraMode.fps`            | 注册内容，服务端估段时长 | **不得高于已证实的交付量** |

无证据时声明 `kFpsWithoutEvidence = 5`。**用户明确要「高帧率」，  
不要把交付量压到声明值上。**

### 5.3 「无磁盘」是性能要求

用户口径：**利用内存的速度，实现高帧率、高画质、不本地存储**。

- 视频路径已闭环（native 内编码，原始帧不进 Dart）。
- **照片路径目前不满足**：`TakePictureFrameSource` 走 `takePicture()` → 临时**文件** →  
  `readAndDelete`。要真无磁盘必须改走 `ImageStreamFrameSource`  
  （`lib/src/capture/frame_source.dart` 里仍是 `UnimplementedError` 占位）。

### 5.4 段时长不用于计费

影响面是**检索/展示的时长准确性**。**误差方向与倍数从未查证**——  
不要引用旧文档里的「高估 6–10 倍」。

---

## 6. 不变量（改错了就会坏事）

完整清单在 `.workbuddy-ai/memory/MEMORY.md`。**最容易在不知情时违反的四条**：

1. **`lib/src/backend/`、非插件 `lib/src/capture/`、`lib/src/config/`、  
   `lib/src/app/capability_bootstrap.dart` 不得 import `package:flutter`。**  
   一旦引入，该模块就再也无法在本机验证（`verify_pure.dart` 跑不了）。
2. **`defaultResolutionFor` / `defaultModeFor` 是「摄像头以什么模式打开」的唯一选择器。**  
   调用点有**三处**：`lib/main.dart` 的 `openConfig`、协调器的 `_seedModes`、  
   协调器的 `adoptInventory`。**改一处漏一处就漂**，判据永远是：  
   **管线打开的几何 == 当前模式 == 公告**。
3. **门禁只有主入口 `tool/verify_pure.dart`。** 专项检查拆成独立文件后  
   **必须由主入口 import 并调用**（此前 `verify_annexb.dart` / `verify_encode_budget.dart`  
   就因为漏了这步而**零调用**）。**断言数以实跑输出为准**，文档不写静态数字。
4. **`AnnexBSplitter`：一个 chunk 必须含完整 picture。** 多 slice 合并靠 slice 头  
   **首字节最高位**（H.264 `first_mb_in_slice==0` / HEVC `first_slice_segment_in_pic_flag`），  
   **不是**靠「无 B 帧」推的。→ 测试 fixture 里 slice 的**首字节是语义位**  
   （≥0x80 = 开新图），HEVC NAL 头是 **2 字节**。
5. **采集帧率取自源序号的前进量，不是到达计数。** 一个「源序号跳了 5、只交出一个 AU」的产出者  
   是**编码器**丢了画面；数到达会让它和「相机没产出」变成同一个数字，`PipelineBottleneck.encoder`  
   就永远不可达。重复帧（前进量为 0）计 `repeatedFrames`，**不计采集**。
6. **`sendRecordingFrame` 返回是否送达；拒收必须计 `droppedFrames`。** 把它当 `void` 用  
   （或忽略返回值）会让链路断了也读成「一切正常」——「网络慢」就再也区分不出来。  
   同理：**诊断字段绝不进 `reportStatus()`**（那是服务端字段），也不含任何凭据。

---

## 7. 开工检查清单

改动之前：

- [ ] 跑 `dart run tool/verify_pure.dart`，记下基线 `passed/failed`。
- [ ] 读 `docs/adr/0001-dual-mode-capture-decisions.md`。
- [ ] 在 `MEMORY.md` 里搜你要碰的模块，看有没有相关不变量。

提交之前：

- [ ] 门禁 `failed: 0`，且**新增的 section 真的出现在输出里**。
- [ ] `dart format --output=none --set-exit-if-changed lib test tool` 干净。
- [ ] 动了 `lib/` 或 `test/` 的公开形状（接口、字段、构造参数）→ 跑  
  `python tool/check_compile.py`（约 5 分钟，**编译 ≠ 断言**），它才能发现坏掉的 `test/` 文件。
- [ ] 新写的断言做过**变异验证**（把实现改坏，确认它变红）——  
  没有变红过的断言等于没有断言。
- [ ] 新增独立检查文件时，**接线与变异验证同一次做完**。
- [ ] 需要 `flutter test` / 构建 / 真机的部分，**写进交接说明让用户跑**，  
  不要标成完成。
- [ ] 更新 `docs/implementation-status.md` 与任务清单的对应项。

**完成标记规则**：没有机器 / 没有证据 / 阻塞的项，**保持待办或进行中**。  
每个平台独立验收，任一平台达标都不替其他平台背书。
