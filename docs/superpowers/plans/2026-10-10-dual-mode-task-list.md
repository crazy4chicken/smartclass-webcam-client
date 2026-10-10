# 双模式取画面与真实 60fps：完整任务清单

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提供可并存的 JPEG 照片和 H.265/H.264 连续视频流；默认目标 1080p60，不支持时选择设备较低的实际分辨率，先降帧率、保分辨率，以真实采集和后端解码证据验收。

**Architecture:** 用统一领域契约连接原生连续采集、原生编码、压缩访问单元传输、Dart 协调器和后端。共享模型先做，原生落地按 Android → Windows → macOS → Linux；Linux 当前仅保留设计及未验证代码，不恢复开发。

**Tech Stack:** 现有 Flutter/Dart 项目、camera、vendored camera_desktop 2.0.0；Android 候选 camera_android_camerax 0.7.5+1 + MediaCodec；Windows Media Foundation；macOS VideoToolbox；未来 Linux GStreamer。

**Spec:** `2026-10-10-dual-mode-capture.md`；旧计划 `2026-10-09-recording-correctness-and-native-encoder.md` 和 `2026-10-09-linux-encoded-stream.md`；状态入口 `../../implementation-status.md`。本清单负责拆任务，旧文档的冲突由 #26 统一，不能照抄旧假设。

**基线：** 当前代码快照 `c84120a`；已观察的门禁输出为 `passed: 708, failed: 0`。本次只建立清单，没有修复代码或重新验收原生能力。任务面板共 26 项：#8 是本次整理工作，另外 25 项是待开发/验证事项；不把创建任务当作完成实现。

## Global Constraints

- 默认目标 **1920×1080 @ 60fps**；更高分辨率可保留在能力声明中，但不默认使用。低于目标的设备选其可交付的最高合适尺寸；非 16:9 的选择规则由 #26 明确，禁止仅凭像素总数猜几何。
- **先降帧率，保分辨率**；不支持当前请求应 `ack ok:false`，不能偷偷换成另一 codec 或另一模式再报成功。
- **硬件 H.265 在当前模式可持续时优先，否则 H.264**。某 codec 在 30fps 可用不表示它在当前 60fps 可用。
- 视频采集和编码在 native 内完成，原始帧不跨入 Dart，视频路径不落临时文件。照片是否也要求完全无磁盘，由 #26 消除旧文档歧义。
- 照片使用当前几何，录像中不靠临时 reconfigure 拍照；每条带 id 的命令均需 ack。
- camera_enum 为公告序号，物理下标仅在插件后端内部；统一绑定 streamId 和 session 代次，禁止重启串流。
- 后端每个 recording.frame 接受一个完整编码访问单元，不是 MP4 文件；关键帧携带所需带内参数集。
- `lib/src/backend/`、`lib/src/config/`、非插件 `lib/src/capture/` 和 `capability_bootstrap.dart` 保持 Flutter-free。平台 bridge 和 Flutter messenger 测试独立于纯模型测试。
- 用户运行 `flutter pub get`、`flutter test`、平台构建及真机测试；助手不在当前 Windows shell 中重建插件链接。原生编译和运行尚无证据时，不标成完成。
- Linux 原生开发继续暂停；保留现有代码不等于支持已验收。不得擅自移除现有四端 CI 构建或绕过 verify。

## Review Focus

1. 配置/编码器输出计数达到 60，但源帧是重复帧：#11、#15、#18 分别测源新帧、编码 AU 和后端存储。
2. H.265 在低帧率可用，被错误公布为当前 1080p60 可用：#4、#5、#11 做模式级校验。
3. 订阅太晚丢第一包、停止太早丢尾包、重启收到上一流包：#9、#13 和平台验收钉住生命周期。
4. 无 B 帧被误当成无缓冲/单 slice、包计数相等被误当成可解码：#10 和各端真实解码验收覆盖。
5. 录像中拍照迫使相机换 session 或几何：#6、#12、#15 核查组合是否真正可行，不能只靠 Dart mock。

---

## 一、已存在的成果与仍缺的环节

| 内容 | 真实状态 |
| --- | --- |
| 默认 fps 常量改为 60 | 已提交 `b242541` / `ab8e210`，不代表实际采集达到 60 |
| 摄像头编号、声明、重配、JPEG 帧泵、照片路径 | 已有，仍需验证新视频路径下不回归 |
| Annex B、encode_budget、NativeVideoEncoder | 已有代码；独立 Annex B/吞吐检查未接进主门禁，且契约仍需审查 |
| camera_desktop vendor | 已有；`packages/camera_desktop/LICENSE` 实际是 **MIT**，旧文档误写 BSD-3 |
| Linux 编码分支 | 已写、未编译/未实测、继续暂停；不阻挡 Android/Windows/macOS |
| Android/Windows/macOS 裸编码流 | 尚未交付；现有文件录制能力不能当作裸流已接通 |

**两个计数更正：** 前文“97 条死断言”是源码约 97 处断言调用的静态计数，循环/分支会改变实际执行数，接线后必须实跑，不能预报 805；NativeVideoEncoder 已间接使用 splitter，缺的是独立专项检查，不能称它完全零覆盖。

## 二、任务分组与依赖

所有下列开发任务当前为 **待办**；[] 只在有相应证据后勾选。

### A. 清理阻塞与设计冲突

### #26 消除旧方案冲突并固定验收口径
**依赖：** 无。**文件：** 双模式方案、旧 New-two-features、Linux 方案、implementation-status、README。
- [ ] 明确实际尺寸选择、帧率档位/取整/容差、探测窗口、长稳时长、GOP/码率建议；把已确认的业务要求与技术待验证假设分开。
- [ ] 核对“H.265 仅 30、H.264 可 60”时选择顺序，以及照片无磁盘范围；需要用户决策时提出具体选项，不自行扩大要求。
- [ ] 纠正“用户已接受长期声明 60/交付 5–10”的过度表述：这是当前未修复状态，不是最终验收豁免。核对后端段时长公式，未查证不重复高估倍数。
- [ ] 标明旧 ffmpeg 批处理、默认无限取最高分辨率及 Linux 优先方案已被取代。验收：执行者能只按一个现行决策入口工作。

### #1 把 Annex B 与吞吐模型检查接进门禁
**依赖：** 无。**文件：** `tool/verify_pure.dart`、`verify_annexb.dart`、`verify_encode_budget.dart`。
- [x] 主入口导入并调用现有 `runAnnexBChecks()` / `runEncodeBudgetChecks()`；必要时抽公共断言助手解除循环导入，不复制检查。
- [x] 实跑主门禁，输出必须出现新增 section；记录真实 passed/failed，新增失败逐条诊断，不禁用用例。
- [x] 通过入口撤除/故意变异等方式确认检查确实被调用；CI 继续使用同一主入口。验收：不再有只写未运行的专项检查。
  > **2026-10-10 完成。** 708 → 940（含后续任务新增）；Annex B 专项 15 条、编码吞吐 10 条变异命中，
  > 门禁确实在跑这两个 suite。新增 `verify_default_mode.dart` 同样由主入口调用。

### #2 清理审计发现的文档与注释腐化
**依赖：** #1。**文件：** `lib/main.dart`、README、release、implementation-status、VENDORED。
- [ ] 旧 ffmpeg 接缝注释改为实际 native 契约/装配入口；修正 Phase A=T1–T2、Phase B 从 T3 开始等错位。
- [ ] 断言数量用实跑记录或“以运行输出为准”，删除混杂的 586/705 等过期承诺；覆盖表分清直接专项测试和间接调用。
- [ ] 修正 camera_desktop 的 MIT 来源描述，保留 LICENSE 原文；补旧计划取代链接。验收：实现、验证证据和状态说明一致。

### #3 Linux 文档区分共享 Dart 任务与原生暂停
**依赖：** 无。**文件：** `docs/linux-encoded-stream-status.md`、Linux 计划、implementation-status。
- [ ] 把纯领域模型、插件 Flutter bridge、Linux C++ 分为三个验证层，不能声称所有插件 Dart 都可由纯 VM 测。
- [ ] 写明契约会先在 Android 验证；Linux 未编译不是三端全部停工的理由，继续保留既有代码但不宣称交付。
- [ ] 明确暂停范围和恢复条件。验收：读者知道现在能做什么、未来必须在哪台机器验什么。

### B. 共享采集基础（不等待 Linux）

### #9 统一编码通道契约并修复启停生命周期
**依赖：** #1、#26。**文件：** `native_video_encoder.dart`、`video_encoder.dart`、纯门禁、对应测试。
- [ ] 合同覆盖 codec、绝对 WxH/fps/bitrate、cameraEnum/插件 cameraId、源 seq/PTS、AU/分片边界、session 代次和成功/失败/EOS。
- [ ] 保证生产前接收端就绪；open 失败释放资源；start/stop 串行、停止等待尾包/drain/stream done、有界超时、旧包不进入新流。
- [ ] fake channel 验证首包、异步尾包、错误、重复 stop、restart 及并发；错误可见，不能只计数吞掉。验收：close 完成与取消订阅次序有唯一明确语义。

### #10 修复 AU 切分与关键帧参数集保证
**依赖：** #1。**文件：** `annexb.dart`、NativeVideoEncoder、专项检查与真实编码样本。
- [ ] 核查多 slice、首 slice 标志、前/后缀 SEI、三/四字节起始码、残缺/非法头、碎片边界及 pending 内存上限。
  > **2026-10-10 部分完成。** 多 slice 合并 + 首 slice 标志（H.264 `first_mb_in_slice==0` /
  > HEVC `first_slice_segment_in_pic_flag`，均取 slice 头首字节最高位）已实现；
  > 前/后缀 SEI、三/四字节起始码、碎片边界、空/无码输入均有用例。**缺：pending 字节量的上限**
  > （`AnnexBSplitter` 目前无界持有）与残缺 slice 头的系统用例。变异验证：退回「一个 VCL = 一幅图」，7 条变红。
- [ ] 统一「原生明确 AU」与「Dart 拼分片」的边界职责；不能以无 B 帧推导单 slice，也不能以 pictures 数相等推导可解码。
  > 边界已写死并文档化：**chunk 必须含完整 picture**（边界即收口），`NativeVideoEncoder` 的
  > units==pictures 交叉校验因此保持成立；「无 B 帧 → 单 slice」的推导已从注释里删掉。
  > **pictures 相等 ≠ 可解码**仍只靠交叉校验兜底，真正确认要等真实样本。
- [ ] 多 slice 一幅图仍只发一帧，关键帧带所需参数集，丢包后恢复到可解码关键帧；真实样本解码证明。验收：不向后端发送拆错的单元。
  > 前两项有用例；**真实编码样本解码证明未做**（没有 native 编码器可产样本）。

### #11 实现吞吐测量、缓存与模式 codec 选择
**依赖：** #9、#10、#26。**文件：** `encode_budget.dart`、能力/缓存模型、插件测量接缝、门禁。
- [ ] 记录按相机/几何/codec 的实际源新帧、AU、交付计数、PTS、掉帧和硬件身份；预热/多窗口测量，审查当前取最快样本是否能代表持续能力。
- [x] 缓存带版本、摄像头指纹和编码器身份；命中省探测，重检/版本变化失效，损坏自愈，独立于凭据设置。
  > **2026-10-10 完成（模型与存储）。** `EncodeEvidence`（版本 + 摄像头指纹 + 编码器身份 + 样本），
  > 损坏一律 `invalid` → 未命中（自愈）；「实测为零」是**有效**结果、可与损坏区分并可缓存。
  > `EncodeEvidenceStore` 接口 + `InMemory`（门禁用）+ `SharedPrefsEncodeEvidenceStore`（独立键
  > `encode_evidence`，不碰凭据）。注意：**尚无任何平台真正写入它** —— 测量管线是上一条，未做。
- [x] 校验所选当前 fps 在该 codec 可持续列表内；测试 HEVC30/AVC60、热降频、空/负样本、重检。验收：静态支持列表不冒充实测。
  > **2026-10-10 完成。** `canServeMode` / `sustainableCodecsAt` 按模式判定；协调器
  > `codecsForMode()` 与 `defaultFpsFor` 都走它。HEVC30/AVC60、热降频（慢跑不清除快跑）、
  > 空/负样本、几何不串用均有用例。**边界**：完全无证据时不收窄（返回公告原样），由工厂兜底拒绝
  > —— 已有专门用例（「有实测但无编码器 → ack ok:false」）。

### #4 默认模式算法：1080p 封顶与同分辨率降帧率
**依赖：** #1、#11。**文件：** 默认模式领域选择器、agent_coordinator、main、harness/test。
- [x] 同源算法服务初始打开、seedModes、adoptInventory：4K 默认 1080p，低档用真实最高合适尺寸；声明仍保留更高已测能力。
- [ ] 同分辨率选可持续最高档≤60；无证据回退与实测失败严格区分，不把失败当作空样本强推60。
  > **算法已实现并有断言**（`defaultFpsFor` 的 `unmeasuredFps` 是必填参数，「实测为零/负也算无证据」有专门用例）。
  > **未闭合的是接线**：调用方仍传 `StreamSettings.fps`（=60），即无证据时仍声明 60 —— 这是 #26 的开放决策，
  > 见 `docs/adr/0001-dual-mode-capture-decisions.md` 第四节。改这一行就能翻转，但会改变每台设备的声明。
- [x] 回归 4K/720p/非16:9/30fps/空证据及缓存重检；管线实际几何=当前模式=公告。验收：不再只改 coordinator 留 main 打开4K。
  > **2026-10-10 完成。** `default_mode.dart` 是唯一选择器；`main.dart` 的 `openConfig` 与
  > `adoptInventory` 的重开几何都走它。变异验证：把选择器改回「取实测上限」，8 条断言变红
  > （含 main 打开 4K、adoptInventory 重开 4K 两条）。

### #5 协调器换 EncoderFactory 与 per-mode supported_codec
**依赖：** #9、#11。**文件：** agent_coordinator、video_encoder、Mjpeg/native 实现、门禁/test。
- [x] 创建请求保留 codec、cameraEnum、streamId，消费 EncodedFrame；无 native 时保留 MJPEG。
- [x] 先认领/订阅再启动，失败回滚；模式声明与可用性校验同源，mode 变更重注册；点名 codec 不偷换。
  > **2026-10-10 完成（协调器侧）。** `VideoEncoderFactory` 进协调器，`codecsForMode()` 按模式过滤
  > （证据 + 公告同源）；工厂拒绝 → `ack ok:false`，点名做不到的 codec 不偷换（有专门用例：
  > 「只实测到 30 的 codec 在 60 被拒，错误信息带模式」）。`isIntraOnly` 不再作为可用性判据。
- [ ] fake encoder 回归可持续60成功、不可持续拒绝、不点名默认、重配/后台资源互斥及每 id ack。验收：不再用 isIntraOnly 把真实 native codec 一律排除。
  > 前四项（可持续60成功 / 不可持续拒绝 / 不点名默认 / 每 id ack）已有 fake-encoder 用例；
  > **重配/后台互斥在 encoder 路径下的专项用例未写**（现有 pause/resume、reconfigure 回归走的是
  > 默认 mjpeg 工厂，仍然全绿）。native 侧实现仍缺（见 #12/#13/#16）。

### #6 录像中拍照不打断视频、不改几何
**依赖：** #5。**文件：** coordinator、still 相机资源层、harness/test。
- [ ] 原生视频录制中 take_photo 仍发 JPEG，使用当前几何，不停 encoder、不触发 reconfigure。
- [ ] 照片并发/失败准确 ack，不能污染 video 状态；still 锁放资源层，平台组合可行性另由原生验收证明。
- [ ] 纯测试与原生真机测试分别留证。验收：不能用 mock 通过代替三 use-case 同时运行。

### #23 增加实测状态与可诊断失败信息
**依赖：** #5、#11。**文件：** agent_status、协调器、状态 UI、native 统计/错误桥接。
- [ ] 分别显示目标/选中/实际采集/编码/发送 fps，codec、硬件身份、WxH、掉帧、队列及降级原因。
- [ ] 原生错误传到协调器/UI；不新增未定义的服务端字段、不泄漏凭据；不可达/相机失效仍有可恢复状态。
- [ ] 验慢链路/启动失败/重启诊断。验收：能区分“相机慢、编码慢、网络慢”。

### C. Android：首个完整交付平台

### #7 Vendor camera_android_camerax 并过构建闸
**依赖：** 无。**文件：** `packages/camera_android_camerax/`、pubspec、lock、VENDORED。
- [ ] 核对 0.7.5+1 来源/许可，保留版权，仅变更采集编码相关路径；Pigeon 源与生成物同步。
- [ ] root 依赖确保 camera 真正使用本地实现；用户运行 pub get，不在助手 shell 造假链接。
- [ ] 用户 APK 构建并在真机确认预览/照片基线不坏。验收：第二个 fork 有可重现的构建证据。

### #12 设计并验证 Android 连续采集与编码方案
**依赖：** #7、#9、#26。**文件：** vendor CameraX 原生接口/Pigeon、Android 子计划/最小原型。
- [ ] 从源码验证 Preview+ImageCapture+编码 Surface/原生队列接法；不能假设 Recorder 可无文件直接给 AU。
- [ ] 核查 Camera2 帧率 range、高速 session 的分辨率/use-case 限制、目标真机组合、MediaCodec 硬件 HEVC 及 size/rate。
- [ ] 拍定线程/资源所有权、桥接、码率/GOP与测量窗口；用户构建原型并验证，再进入正式实现。验收：有源代码/API与设备证据，不承诺所有真机必达60。

### #13 实现 Android native H.265/H.264 编码流
**依赖：** #10、#12。**文件：** vendor Android 编码实现、native 测试、插件接口。
- [ ] 连续采集→native MediaCodec→完整压缩 AU；带源 PTS/seq、参数集/IDR，不走逐帧拍照或原始帧 Dart 通道。
- [ ] 实现启动/drain/EOS/关闭、切相机/后台/异常释放；队列有界，预测帧丢失后重同步，不伪造 codec 成功。
- [ ] native/contract 测试及用户 APK 构建分阶段通过。验收：视频路径无临时文件，持续新帧可观测。

### #14 跨平台 Dart 适配器与应用启动装配
**依赖：** #4、#5、#7、#9、#10、#11。**文件：** plugin-facing adapter、纯接口、main、Flutter messenger 测试。
- [ ] Android 与 desktop 插件事件各自接统一通道，不重复注册 method handler；fake 接口与 Flutter bridge 分层测。
- [ ] 先 inventory/实测证据、再默认模式/打开管线、再同源注册；native probe 存在不等于 mode 可用。
- [ ] 重检/切模式失效证据并重算后注册；不支持平台仍能预览/照片/MJPEG。验收：Android 实际接通后才能称当前端到端链路完成，其他平台待对应实现。

### #15 Android 真机端到端与长稳验收
**依赖：** #6、#13、#14、#23。**操作者：** 用户跑构建/安装/flutter test，指挥者整理回放步骤与证据。
- [ ] 服务端命令驱动测试默认1080p60、低档设备、HEVC/AVC fallback、同分辨率降fps、录像中照片、switch 后重注册、重启/重检缓存。
- [ ] 分别统计源新帧、AU、后端收到/保存的帧；验证 codec/几何、关键帧起播、首/尾帧和 JPEG，不能重复帧凑60。
- [ ] 预热后长稳、发热/过载、慢链路、后台、重复 stop/restart、资源释放。验收阈值采用 #26/#12 已确认口径，保存实测与可复现失败。

### D. Windows：第二个平台

### #16 设计并验证 Windows native 编码接入
**依赖：** #15。**文件：** `packages/camera_desktop/windows/{camera,record_handler}.{cpp,h}`、Windows 子计划。
- [ ] 验证 CaptureEngine 压缩 sample callback/MFT 路径与预览、照片并存；既有文件录制 H264不算裸流已完成。
- [ ] 定 D3D/CPU 转换、硬件 MFT/fallback、AnnexB/长度前缀、参数集、PTS/seq、COM线程与关闭流程。
- [ ] 用户编译最小原型再确认正式设计。验收：不是“已有回调所以简单替换”式猜测。

### #17 实现 Windows H.265/H.264 编码流
**依赖：** #16。**文件：** Windows native handler/桥接、desktop Dart adapter、测试。
- [ ] 同进程采集→MF/MFT→压缩AU；动态硬件HEVC当前模式优先，拒绝请求不偷换。
- [ ] async MFT drain/EOS、首/周期关键帧、参数集、长度前缀转换、有界主线程桥接、设备拔出/重启/后台清理。
- [ ] 用户 Windows 构建与共用契约测试通过。验收：无视频落盘、原始帧不过 Dart。

### #18 Windows 摄像头及后端存储验收
**依赖：** #17、#23。
- [ ] 默认模式/实际fps、codec fallback、拍照并存、多摄编号、USB拔插、切模式、前后台与缓存分别验证。
- [ ] 源新帧/AU/后端帧及实际几何独立计数；存储字节解码验首尾、关键帧、过载恢复与长稳。
- [ ] 报告本平台独立数据，Android结果不能代替。验收：用户本机能复现完整流程。

### E. macOS：第三个平台

### #19 设计 macOS VideoToolbox 与构建方案
**依赖：** #18。**文件：** vendor macOS CameraSession/RecordHandler、macOS 子计划。
- [ ] 验证 CVPixelBuffer→VTCompressionSession、硬件HEVC、当前WxH/fps、低延迟配置与 flush、CMFormatDescription参数集和AnnexB转换。
- [ ] 明确 Swift/channel所有权、预览/照片组合和队列生命周期；用户Mac给构建/运行反馈。
- [ ] 无Mac时设计和实现/验收状态分开。验收：不把纸面设计标成可用。

### #20 实现并验收 macOS native 编码流
**依赖：** #19。
- [ ] 实现 VT 编码完整AU/源PTS/参数集与drain，接共用适配器、吞吐缓存、mode factory；硬件HEVC可持续才优先。
- [ ] 用户Mac验照片并存、重复启停、后台、长稳及后端解码；x64/arm64发布架构均核查。
- [ ] 缺机器/数据不能勾选完成。验收：本平台独立端到端证据。

### F. Linux：设计保留，实现延期

### #21 审查保留 Linux 代码并修正可行设计
**依赖：** #9、#10。**仅设计/审查，不恢复 Linux native 实现。**
- [ ] 核查关闭 valve 的 preroll、NULL分支影响tee、部分失败清理/request pad、回调handler/channel/session存活和旧在途包。
- [ ] 修正“videorate后输出60就是新帧采集60”“无B帧没有尾包”“factory存在就是硬件支持”等不成立的推导。
- [ ] 设计显式EOS/drain、真实源PTS、协商caps、带内参数集和预测帧重同步，按共用合同交接；代码继续标未编译/未验。

### #22 未来恢复 Linux：实现与实测验收
**依赖：** #20、#21；**额外门禁：用户明确恢复开发 + Linux环境可用。当前延期。**
- [ ] 修复保留分支的资源/preroll/错误/flush与硬件fallback，接共享 Dart 层和测量证据。
- [ ] Linux/WSL编译只能证明构建；摄像头权限、新帧60/codec/照片并存要在实际环境独立验。
- [ ] 解码后端字节、验长稳与过载，补运行依赖及CI。验收前不得称Linux native视频已交付。

### G. 发布与交接

### #24 许可、依赖与四端 CI 发布完整性
**依赖：** #15、#18、#20；许可预审随各vendor/平台设计同步，最终发行审查在此收口。
- [ ] MIT来源/版权与Android许可据真实文件核验；系统编码API和实际分发GPL组件分别审查，不机械塞ffmpeg或改许可。
- [ ] Android ABI/minSdk/Gradle、Mac架构、Windows DLL、Linux运行依赖/lock/version核查；用户已同意GPL但义务按实际分发判定。
- [ ] 保留 verify及原生编译门禁、现有四端构建矩阵；产物同 `release/` 且只上传 `release/*`，四端完整性明确核对。
- [ ] Linux native功能暂停不自动取消Linux构建；任何阻塞如实记录，不绕过门禁。验收：对应源码、依赖与发布包可追溯。

### #25 同步方案、状态、验证证据与恢复交接
**依赖：** #2、#3、#24；进度记录不是等最后才写，每个实现任务同时更新自己的状态。
- [ ] 每项附代码/commit/实际通过的测试与机器/未验证原因；README、implementation-status、release、Android setup和Linux交接一致。
- [ ] 删未经核实的FPS/时长/许可证承诺，原生落地后更新“配置60与实际交付”差距，只给实测平台背书。
- [ ] 最终whole-branch复核代码、真实样本、打包与剩余限制。验收：后来接手的人不用猜哪些只是计划。

---

## 三、验证与执行方式

**每个实现任务的共同循环：** 先写贴近真实入口的失败回归 → 观察失败 → 最小修改 → 本任务测试及主门禁通过 → 指挥者复核实际diff/结果 → 只记录已验证完成项。先解决漏接检查，再要求相关用例有“会红”的证据，不能仅靠增加 passed 数量。

- **纯模型：** `dart run tool/verify_pure.dart`；format用 `dart format --output=none --set-exit-if-changed lib test tool`。读取返回状态，不能用管道最后一个命令的0代替Dart成功。
- **Flutter/插件：** 用户 `flutter test`，包括 messenger契约及对应插件单测；纯VM不能验证Flutter bridge。
- **native：** 用户运行对应APK/Windows/macOS/Linux构建和真实设备；文件录制或factory查询通过不算裸流成功。
- **最终60fps：** 用事先确认的持续窗口与容差，核对不重复的源PTS、新AU与后端存储/解码；任何一层瓶颈单列，不用常量或生成重复帧凑数。
- **协作：** 沿用用户指定的指挥者+子代理执行代码方式；指挥者负责范围/合同/复核，用户负责本机Flutter/native构建与真机反馈。本轮只完成清单编排，不启动上述开发任务。

**可立即并行的入口：** #26（冲突收口）、#1（门禁接线）、#3（暂停归类）、#7（Android vendor）。后续按依赖解锁；Android实测过后再Windows、再macOS；Linux只先完善设计，恢复实现等待额外授权。

**完成标记规则：** #8 完成表示清单已整理，不表示其余25项完成。阻塞/失败/无机器/无证据保持待办或进行中。每个平台独立验收，任何一个平台达标都不替其他平台背书。
