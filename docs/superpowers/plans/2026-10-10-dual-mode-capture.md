# 双模式画面获取：照片 + 编码视频流

**目标：** 设备提供两种取画面方式 —— ① 照片；② 经 H.264/H.265 压缩的视频流推给后端。
默认 **1080p @ 60fps**，设备撑不住就往下退。

**这份文档记录的是已经拍定的决策**，不是待议项。每一条都经过逐条确认，
落定过程见 2026-10-10 的对话。改动若与之冲突，先回来改这份文档。

**执行清单：** [双模式取画面与真实 60fps：完整任务清单](2026-10-10-dual-mode-task-list.md)。
清单包含 25 项待办、依赖和验收证据；原文中的生命周期、能力测量及“已接受的偏差”等假设由清单 #26/#9/#10 先复核，不作为免验依据。

---

## 一、已定决策

| # | 决策 | 结论 |
| --- | --- | --- |
| 1 | 默认分辨率 | **`min(实测上限, 1080p)`**。设备上限低于 1080p 就用上限；4K 设备默认 1080p |
| 2 | 4K 要不要声明 | **要。** 声明列表保留到实测上限，默认只是不用它；服务端可用 `switch_camera` 点上去 |
| 3 | 默认帧率 | **60**，撑不住就降帧率 |
| 4 | 降级顺序 | **先降帧率，保分辨率**（1080p60 → 1080p30 → 1080p15 → …） |
| 5 | "撑不住"怎么判 | **开机探测定分辨率上限；编码器吞吐实测定帧率**，都缓存。探测失败退化成"只声明正在用的那一对"（兜底已实现） |
| 6 | 默认 codec | **硬件支持 H.265 就用 H.265，否则 H.264**。真正决定的是实测吞吐，不是偏好顺序 |
| 7 | 两种模式关系 | **并存。** 录制中可以拍照；照片走相机**当前**的几何 |
| 8 | 照片要不要独立几何 | **不要。** 中途 `reconfigure` 会让服务端已快照的录制 `metadata` 与实际不符，且**没有任何东西会报错** |
| 9 | 落地顺序 | **Android → Windows → macOS → Linux** |
| 10 | Linux 那份已写的 C++ | **留着**，状态标注为"未编译" |
| 11 | 声明 60 / 交付 5–10 的偏差 | **接受，记录在案**，直到原生编码器落地 |

---

## 二、为什么"换个 codec"救不了 60fps

顺序是这样的，**瓶颈在采集，不在编码**：

```
采集（帧源）  →  编码  →  过桥进 Dart  →  发后端
 ↑ 卡在这里        ↑ 换这里没用
```

- 今天唯一的帧源是 `takePicture()`：一次完整拍照 + JPEG 编码 + 落盘回读，
  1080p 单帧 100–200 ms → **5–10 fps**。把下游换成 H.264 只是把每秒那 5–10 张
  换成 H.264 格式，**换不掉"每秒能拿出几张画面"**。
- 反过来，若绕过 `takePicture()` 改用插件的 `startImageStream` 把原始帧喂进 Dart，
  1080p60 的 BGRA 是 **497 MB/s** —— Dart 侧直接被压垮。
  **所以"在原生层编码"不只是为了帧率，也是为了让过桥的字节量小到能过桥**
  （编码后约 5–10 Mbps，差两个数量级）。

结论：**要换的是帧源，换帧源 = 改插件原生管线。** 这也正是"原始帧不进 Dart、
不落盘"那条约束的由来。

---

## 三、默认模式怎么算

```
分辨率 = min(实测上限, 1080p)
帧率   = 该分辨率下实测能稳住的最高档，且 ≤ 60
```

**探测全空时的退化**：只声明"正在用的那一对"。`supported_resolutions: []` 是 `400`，
"连不上"比"少声明"糟糕得多 —— 这个兜底已实现。

**声明列表**（`declaredFor()`，注册与 `switch_camera` 校验**共用**，别分开算）：
常见阶梯 ∪ 探测值 ∪ {当前模式}，分辨率截到实测上限。

> ⚠️ **协议里 `supported_resolutions` 和 `supported_framerates` 是两个独立列表，
> 服务端不做任何配对限制。** 设备**表达不了**"1080p 只能 30"。
> 所以"1080p30 能跑"这个事实只能体现为**默认模式选 1080p30**，不能体现为约束；
> 运营侧仍可从菜单里点出 1080p60，那时设备回 `ack ok:false`。

### 现在要改的地方

| 位置 | 现状 | 要改成 |
| --- | --- | --- |
| `AgentCoordinator._seedResolutionFor` | 返回 `highestResolution`（无上限） | `min(highestResolution, 1080p)` |
| `AgentCoordinator._seedModes` 的 fps | 一律 `settings.fps`（常量 60） | 查该分辨率的可持续帧率表，取 ≤60 的最高档；无实测样本时退回常量 |
| `AppConfig.defaultFps` | 60（已改） | 保留为**目标值/无实测时的回退值** |
| 可持续帧率表 | `encode_budget.dart` 的 `sustainableRates` 已有 | 需要真实样本喂进去 —— 这是原生端的事（各端 Task 的最后一步） |

---

## 四、两种模式的关系

| | 照片 | 视频流 |
| --- | --- | --- |
| 触发 | `take_photo` | `start_recording` / `stop_recording` |
| 路径 | `takePicture()` | `VideoEncoder`（`MjpegEncoder` 或 `NativeVideoEncoder`） |
| 几何 | 相机**当前**的几何，不 reconfigure | 当前模式（服务端 `switch_camera` 可改） |
| 并发 | 与帧泵共用一个 `SerialLock`（已实现） | 同上 |

**照片为什么不能独立跑到最大分辨率**：设备是**从属**的，`take_photo` 可能落在录制中间。
服务端在 `recording/start` 时把当前模式快照进了 `metadata`，中途改几何会让快照与实际不符，
而且**没有任何东西会报错**。协议里也没有"设备主动改模式"的上报消息 ——
真要 4K 照片，得先在协议里加一条模式变更上报。

---

## 五、codec 选择

- per-mode `supported_codec` = `sustainableCodecs(rates)`（`encode_budget.dart` 已有）。
  **撑不住的就是不声明**，不靠偏好顺序猜。
- 两个都撑得住时：**硬件支持 H.265 → H.265，否则 H.264**。
  （倾向 H.264 的通用理由也存在：后端逐字存帧，消费者要能解，H.264 到处能解；
  但你的场景是画质 + 高帧率，所以让硬件能力说话。）
- **`mjpeg` 永远是地板**：`takePicture()` 五平台都通，一帧一张 JPEG 正是服务端对 `mjpeg`
  的定义。没有原生编码器的机器仍然能录，只是 codec 只有 mjpeg。

---

## 六、落地顺序：Android → Windows → macOS → Linux

**排序依据是"谁编得了、谁跑得了"**，不是字母顺序也不是常见度：

| 平台 | 谁能编 | 谁能跑 | 说明 |
| --- | --- | --- | --- |
| **Android** | 用户 | 用户（真机 V2405A） | 需要 **第二个 fork**：`camera_android_camerax`。CameraX 采集 + MediaCodec 编码 |
| **Windows** | 用户 | 用户（就是这台） | Media Foundation。**`windows/record_handler.cpp:114` 已经在进程内编 H.264**（`MFVideoFormat_H264`），只是写进文件；`windows/camera.cpp:1322` 已有逐帧回调（`imageStreamFrame`）。改造比 Linux 短：把回调里的原始帧先喂编码器 MFT，再推压缩字节 |
| **macOS** | 用户 | 用户（需 Mac） | VideoToolbox。`camera_desktop` 的 macOS 侧已有 `RecordHandler.swift` |
| **Linux** | **没人**（本机无 GStreamer/GTK/`flutter_linux` 头文件） | 没人 | GStreamer。设计 + 代码已写（`packages/camera_desktop/linux/encoded_stream_handler.{h,cc}`），**未编译**。有 WSL2，随时可装 Flutter + `libgtk-3-dev` + `libgstreamer1.0-dev` 验证 |

### 每一端的共同形状

```
采集 → 编码（同进程）→ 一个 AU 一帧 → Dart → recording.frame
```

Dart 侧契约 **已经写好并有断言覆盖**：`lib/src/capture/native_video_encoder.dart`
（`EncodedStreamChannel` / `EncodedPacket` / `NativeVideoEncoder`），
配合 `annexb.dart` 的 `AnnexBSplitter` 切分。各端只需实现那个通道。

已 vendor 的 fork 边界见 `packages/camera_desktop/VENDORED.md`；
Linux 端的暂停交接见 `docs/linux-encoded-stream-status.md`。

---

## 七、不依赖原生、现在就能做的

这三块是纯 Dart，在本机 `dart run tool/verify_pure.dart` 里能全量验证 ——
即使原生端还没影儿，它们也该先落地：

1. **默认模式算法**：`_seedResolutionFor` 封顶 1080p + 帧率按可持续表降级。
2. **Task 10（上游计划）**：协调器把 `FramePumpFactory` 换成
   `EncoderFactory = VideoEncoder Function(CaptureCodec)`，并按**当前模式**重算
   `supported_codec`。没有它，原生端就算通了，per-mode 的 codec 菜单也不会更新。
3. **两种模式并存的语义**补断言：录制中 `take_photo` 不打断录制、不改几何。

---

## 八、已知代价（读这段再上线）

**原生编码器落地前，设备会声明 60 但交付 5–10 fps。**
mjpeg 走每帧一次 `takePicture()`，单并发锁丢掉"上次没拍完就来的 tick"。
而**服务端用 `fps` 估段时长** → 每段时长会被**高估 6–10 倍**。

这是**有意、已记录的偏离**（`AppConfig.defaultFps` 的注释里写明了，
状态文档的「已知缺口」也有），不是疏漏。**如果段时长要用于计费或检索，这条必须先解决。**

收尾动作与原生端绑死：Android/Windows 任一端接通后，第一件事就是让这个数字变成真的。

---

## 九、依赖与未决

1. **Android 需要第二个 vendor** —— `camera_android_camerax`，与 `camera_desktop` 并列。
   要不要按同样的四条 fork 纪律管（只改采集/编码路径、其余逐字保持上游）？**待确认。**
2. **吞吐实测怎么落地**：需要一个短探测录制，把实测 fps 喂给 `sustainableRates`。
   各端 Task 的最后一步，规格待各端设计时定。
3. **`min(上限, 1080p)` 的 1080p 是常量还是配置**：目前当常量。若将来要按设备型号调，
   再提为 `AppConfig`。
4. **GPL**：x264/x265 一旦进包，发行版许可要改。Android 走 MediaCodec、Windows 走
   Media Foundation 都不需要，**但 Linux 的软件回退需要**（用户已确认接受 GPL）。
