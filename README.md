# webcam_client

前台 kiosk 式跨平台摄像头边缘探针客户端，接入 **`smartclass-webcam-server`** 的设备协议。

设备是**从属角色**：它不主动推流。运营侧在管理面 `POST /api/devices/{id}/recording/start`
之后，服务端才下发 `start_recording`，客户端此时才开始推帧；`stop_recording` 一到立刻停。

实现依据：`docs/superpowers/plans/2026-10-04-smartclass-backend-integration.md`（T1–T8）。
**协议权威文档**是后端仓库的 `smartclass-webcam-server/docs/protocol/`
（index / registration / transport / control / media），本客户端逐条对齐。

> **五个计划各自的实施状态**（实现了什么、有意偏离了什么、明确没做什么、验证到什么程度）
> 见 **`docs/implementation-status.md`**。作废的计划在其文件顶部有醒目标记。

> ### 服务端是**另一个仓库**，不是本仓库的一部分
>
> 本仓库**只包含客户端**。`smartclass-webcam-server/` 若出现在工作区里，那只是一份
> **本地测试用的检出**，并且**已被 `.gitignore` 忽略**（本仓库 0 个文件跟踪它）——
> 删掉它，`flutter pub get` / `flutter test` / `flutter build` / `dart run tool/verify_pure.dart`
> 全部照常工作。
>
> 客户端对服务端**没有任何路径依赖**，只有**网络依赖**：后端地址是唯一的耦合点，
> 它可以在编译期用 `--dart-define=BASE_URL=` 播种，也可以在设备上的**设置界面**里改
> （见「运行时可配置后端参数」）。代码里所有 `smartclass-webcam-server` 的出现都只是
> **注释里引用的文档出处**，不是路径。

## 平台

Windows / macOS / Linux / iOS / Android 单代码库覆盖。桌面三端由 `camera` + `camera_desktop`
提供（Media Foundation / AVFoundation / GStreamer+V4L2），移动端走 `camera_android_camerax`
与 `camera_avfoundation`。**不使用 `camera_windows`**。

`camera_desktop` 已 **vendor 进仓库**（`packages/camera_desktop/`，上游 2.0.0，BSD-3），
因为高帧率只能从插件自己的采集管线里出来，而改那条管线必须碰插件源码。
fork 的边界写在 `packages/camera_desktop/VENDORED.md`。

## 运行

```bash
flutter pub get

# 脱机自测：内置假后端，不需要服务端也不需要凭据
flutter run -d windows --dart-define=USE_MOCK_BACKEND=true

# 接真后端（BASE_URL 是注册与 WebSocket 的共同基址）
flutter run -d windows \
  --dart-define=BASE_URL=http://192.168.1.10:8080 \
  --dart-define=DEVICE_ID=01J8ZK9WQ7X3YV0M4N5P6Q7R8S \
  --dart-define=DEVICE_TOKEN=wdt_...
```

`DEVICE_ID` / `DEVICE_TOKEN` 由管理面 `POST /api/devices` 下发，**不是客户端生成的**
（`device_id` 是 26 字符 ULID，token 是 `wdt_` + 43 个 base64url 字符）：

```bash
curl -X POST http://127.0.0.1:8080/api/devices \
  -H 'Content-Type: application/json' --data '{"name":"教室A-前门"}'
# 201 -> {"device": {"id": "01M45TRK…"}, "token": "wdt_KTKM…"}
```

⚠️ **令牌只在创建时返回这一次**（服务端只存 SHA-256）；丢了就
`POST /api/devices/{id}/token` 轮换。**客户端里没有默认值**：凭据是服务端给这台设备的
身份，硬编默认值会让整批设备在服务端互相踢。详见 `docs/android-setup.md` §5。

用 `--dart-define` 传只是为了开发方便 —— 那是明文编译进二进制的；首次启动会把这三个值
（地址 + 凭据）一起**播种**进 `SharedPrefsSettingsStore`，之后**一律以设备上保存的为准**。
所以设备上那两个框空着是正常的，填上并保存即可。

### 运行时可配置后端参数（设置界面）

**换后端 / 换凭据不再需要重新打包。** 屏幕左下角常驻一个齿轮按钮，点开就是设置界面：

| 分区 | 字段 |
| --- | --- |
| 后端 | 后端地址（`http://192.168.1.20:8080`；不写 scheme 自动补 `http://`，`ws://` 按 `http://` 处理） |
| 设备凭据 | 设备 ID（26 位 ULID）、设备令牌（默认遮蔽，可点眼睛显示） |
| 操作 | 测试连接（`GET /healthz`，不消耗 ticket）· 重新检测（重测摄像头能力）· **查看支持的分辨率** · 保存并重连 · 恢复默认 · 清空凭据 |

保存即生效：**先落盘 → 停推 → 断链 → 用新参数重新注册**。三条要记住的行为：

- **未配置凭据时齿轮带红点**，一眼能看出这台设备连不上。
- **录制中保存会中断当前录制**，服务端会把该流标 `failed`（界面上有琥珀色横幅预告）。
- **保存时是换一个全新的 gateway 实例，不是改旧实例的 base**。因为 `401` 会让旧实例进入
  `_stopped = true` 的永久终态 —— 令牌填错一次之后，无论等多久都不会自己恢复。
  重建实例顺手把这个问题一起解决了（`tool/verify_pure.dart` 有专门的回归断言）。
- **播种只补不删**。地址与凭据是**两个独立的问题**：老版本只写过 `device_id`/`device_token`、
  没写过 `base_url`，如果把它们当一个值读出来，播种时算出的 settings 会不带凭据，
  而 `save()` 的语义是"替换" → **升级后第一次启动就会把好设备的身份删掉**。
  这个 bug 在真机上真的发生过，现在由 `loadBaseUrl()` / `loadCredentials()` 两个问题
  加一条回归断言钉住。

采集参数（fps / 分辨率 / 质量）**仍然不在设置界面里**：它们是注册时 announce 的，
运行期改它们要走 `switch_camera`（服务端下发），而且改了必须重新注册 ——
「重新检测」只重测**能力清单**，不动当前模式。

### 「查看支持的分辨率」页（只读）

点开是一台摄像头一张卡：名字、`camera_enum`、镜头方向、**当前模式**，
以及**声明给服务端的两份清单**（分辨率 / 帧率），当前生效的那一项高亮。

**它是只读的，这是设计而不是没做完。** 这些清单就是设备的注册内容：服务端按连接收到一次，
并用它校验 `switch_camera`。模式唯一能合法改变的地方是服务端下发的 `switch_camera` ——
设备端加一个控件会让设备和服务端对「摄像头现在是什么模式」各执一词，而协议里没有任何东西
会发现这件事。

它的用途是回答安装工真正会问的两个问题：**设备到底测出了什么**，以及**为什么我这个分辨率被拒**。
两个答案都在「服务端拿到的那份清单」里。

- 内容读自 `declaredFor()` —— 与注册、与 `switch_camera` 校验**同一个函数**，
  所以「页面上印出来的」和「设备会接受的」在构造上就是同一份东西。
  两处各算一次一定会漂，而漂的表现是：运营侧从设备自己印的清单里选一个值，收到 `ok:false`。
- 录制中也能打开（不像「重新检测」）—— 它只读已经测好的数据，不会碰摄像头。
- 报告是**点开时才读**的，不是建屏时的快照：重测可能就发生在这个界面开着的时候。

### 设备端能不能自己调分辨率？—— 设计结论：不做

协议**结构上**容得下：`switch_camera` 接受 `resolution` / `fps`，`start_recording` 不点名分辨率
（用当前模式），而且设备改完重新注册就能把服务端的 `metadata` 快照纠正过来 ——
这条路径 T7 已经实现并测试了。但要做成设备端功能，必须同时满足三条，缺一条就会静默不一致：

1. **走同一份校验**（`declaredCapabilities()`）。否则运营侧从设备自己印的清单里选一个值会被拒。
2. **必须重新注册**。`switch_camera` 在服务端不落任何状态，`metadata.resolution` 来自**注册**；
   只改本地不重注册 = 「设备在 720p，服务端记着 480p」，而且没有任何东西会报错。
3. **录制中必须拒绝**。服务端那条 stream 是 `active`，重建采集管线会丢帧，而服务端不会回滚。

**真正的顾虑不是这三条，而是控制面变成两个。** 现在模式只有一个写入口（服务端下发），
所以「服务端记的模式」和「设备实际的模式」不一致这件事在结构上不可能发生。
加上设备端可调之后，服务端在 `recording/start` 快照到的可能是**一个它没有要求过的模式**，
而协议里没有"设备主动改了模式"这条消息 —— 运营侧只能在下次注册时才知道。

所以结论是：**保持只读**，让设备当前模式走周期性 `status` 暴露（`reportStatus()` 已经带
`resolution` / `fps`），运营侧看得到、但只有一个写入口。真要做设备端可调，
前提是**协议先加一条设备主动上报模式变更的消息**；在那之前，「设备端静默改 + 不重注册」
是唯一真正危险的组合，而它恰好是最省事的实现方式。

测试与自检：

```bash
flutter test
dart run tool/verify_pure.dart    # 586 项断言的纯 Dart 自检，不需要 Flutter 引擎
```

端到端联调（真机 × 真服务端）见 `docs/superpowers/plans/2026-10-04-android-server-e2e-test.md`，
工具在 `tool/e2e/`：

```bash
# 拆开一个落盘 segment，逐帧校验（长度前缀拼接 + 每帧是否为完整 JPEG）
python tool/e2e/check_segment.py <segment.bin>
python tool/e2e/check_segment.py --url <presigned-url> --dump frame

# 没有可用对象存储时的最小 S3 替身（见下）
python tool/e2e/s3_stub.py --port 9000 --dir <object-dir>
```

## 架构

```
main.dart ── BootstrapRoot ── 先探测摄像头，再换 kiosk（runApp 只调一次）
        │         └── BootstrapScreen ── 进度/结果文案；onDone 保证恰好一次
        │
UI (agent_screen / status_bar_overlay / preview_toggle_button / camera_error_view
    / settings_button → settings_screen → capabilities_screen)
        │  AgentStatus
AgentCoordinator ── 命令驱动的状态机：每条命令都 ack，没收到 start_recording 就不推任何媒体
        │            （命令与 ack 结果走可注入的 log sink，控制台可见）
        │            reconfigure() ── 换设置时重建 gateway，而不是改它的 base
        │            adoptInventory() ── 「重新检测」后换 provider + 能力，再重建 gateway
        │            _modes[] ── 每个 camera_enum 当前的分辨率/帧率（服务端不存，只有这里有）
        │            capabilityReport() ── 「查看支持的分辨率」页读它（经 declaredFor，与校验同源）
        │
        ├── BackendGatewayFactory ── 每个 ConnectionSettings 建一个新实例
        │      BackendGateway ── SmartClassBackendGateway（注册 → 挂载 → 保活 → 退避重注册）
        │        protocol/envelope ── Message 信封 / WireCodec 闭集 / parseDeviceCommand
        │        protocol/binary_frame ── uint32 BE + JSON + 裸字节
        │        registration_client ── GET /ws/register（带 JSON body）
        │        health_probe ── GET /healthz（「测试连接」，无鉴权、不消耗 ticket）
        │      MockBackendGateway（离线用，下发真实协议词汇）
        └── CameraProvider ── CameraBackend ── CameraService ── FramePump ── VideoEncoder
               CameraPluginBackend (camera + camera_desktop, 5 平台)
                 ├── cameraOrder ── announced enum → 物理下标的置换，**只在这个文件里存在**
                 ├── serial_lock ── 串行化「相机重建」与「抓帧」两条互斥路径
                 └── jpeg ── 裁掉相机 HAL 偶尔追加在 EOI 之后的 0 字节；jpegSize 读真实像素

摄像头能力探测（纯 Dart 的部分能在 VM 上直接跑）
  app/capability_bootstrap ── ensureInventory：枚举 → 排序 → 探测 → 缓存
  capture/camera_capabilities ── CameraCapabilities / CameraMode / declaredCapabilities
  capture/camera_order ── canonicalCameraOrder（rear → external → front，组内按像素降序）
  capture/capability_probe ── CapabilityProbe 接口 + kProbeFramerates
  capture/plugin_camera_ranker ── 每个摄像头开一次拿上限
  capture/plugin_capability_probe ── 每档 preset 拍一张，从 JPEG 里读真实尺寸
  config/capabilities_store ── 按「摄像头集合」缓存（一份，含规范顺序），独立于 SettingsStore

config (纯 Dart，不依赖 Flutter)
  connection_settings ── ConnectionSettings / validateBaseUrl / resolveConnectionSettings
  settings_store ── SettingsStore 接口
  shared_prefs_settings_store ── shared_preferences 实现（唯一新增键：base_url）
```

### 协议要点（改之前请先读后端 `docs/protocol/`）

- **注册是 `GET /ws/register` 带 JSON body**，`Authorization: Bearer wdt_…`，返回一次性 ticket
  （64 位小写 hex）、`expires_at`（RFC3339**Nano**，60s TTL）、`websocket_path`。
- **挂载是 `GET {base}/ws/device/{ticket}`**。ticket 一次性、随连接死亡，**没有 session resume**，
  所以每次重连都要重新注册。
- 信封 `{channel,type,id?,payload?}`，`channel ∈ control/recording/photo`。
  **二进制帧 = `uint32 BE N` + N 字节 UTF-8 JSON + 裸媒体字节**，`N ∈ 1..65536`，整帧 ≤ 16 MiB。
- server→device 只有 5 种：`switch_camera` / `start_recording` / `stop_recording` / `take_photo` / `ping`。
- device→server：`ack` / `pong` / `status` / `error`（文本）+ `frame` / `photo`（二进制）。
- **每条带 `id` 的命令都必须 ack**，失败回 `ok:false` + `error`。服务端不等待、不重试，
  ack 是运营侧唯一的确认手段 —— 所以**绝不静默丢弃**。
- **codec 是闭集且精确小写**：`h264` / `h265` / `mjpeg` / `mpeg4` / `vp8` / `vp9` / `av1`。
  **`hevc` 只是别称，服务端拒收**，线上必须写 `h265`。
- `camera_enum` 必须等于注册数组下标；`fps` 必须是 **>0 的整数**（`29.97` 直接 400）。
- **协议 v0.3.0 起，注册必须带 `supported_resolutions` 与 `supported_framerates`**
  （`531c74f feat(webcam)!`）。二者**非空、去重、且必须包含该摄像头当前的
  `resolution` / `fps`**，任一条不满足就是 `400` —— 不是"少个功能"，是**设备根本连不上**。
  详见下面「摄像头能力声明」。
- **`switch_camera` 可以带 `resolution`（`"1280x720"`）和 `fps`**；不带就是"保持现状"
  （所以 v0.3.0 之前的服务端行为不变）。**服务端不为这条命令存任何状态**
  （文档写明 "Server state: None"）→ 改了参数必须**重新注册**，否则服务端 `metadata`
  里那份快照仍然是旧模式。
- **`start_recording` 可以带 `codec`**；不带 = 设备首选（= 声明列表的**第一项**）。
  做不到的 codec 必须 `ack ok:false`，绝不"照跑但假装成功"。
- **空闲时也要周期性发 `status`**，否则 60s 静默被服务端断开（默认 30s 一次）。
- **`stop_recording` 之后继续推的帧会被丢弃**，所以收到就立刻停泵。
- `1008` = ticket 已被别的连接挂载 → 重新注册；`1009` = 单帧超 16 MiB；`1006` 是**正常现象**
  （被新连接替换时服务端不握手直接关）。
- **服务端没有人脸识别结果回推**，AI 是另一个走管理面 REST 拉录制分片的服务，
  所以客户端不展示识别结果（`RecognitionHud` 已删除）。
- **服务端重启会把中断的流收尾为 `failed`**（后端 `b8b4d7e`，客户端无需配合）：
  流的缓冲帧只活在进程内存里，所以重启后任何还是 `active` 的行都是**孤儿**。
  服务端启动时在**接受设备连接之前**跑一次 sweep，把它们标 `failed` 并补 `ended_at`。
  设备断开（服务端活着）时同样标 `failed`，并做最后一次 flush。
  > 修复前的表现：孤儿流**永远停在 `active`**，并**阻塞该 camera 之后的所有录制**
  > （`409 camera_enum N is already streaming`），必须运营侧显式 `recording/stop` 才能清掉。
  > 客户端在这两种情况下的行为都是对的：链路一断就自己中止录制。

### 编码选择

偏好链 `h265 → h264 → mjpeg`，由 `CodecProbe` 实测决定，选择逻辑在 `CodecSelector`。
**当前实际落在 `mjpeg`**，这不是妥协：服务端对 `mjpeg` 的定义就是"每个 `recording.frame`
一张 JPEG"，而 `takePicture()` 产出的正好是 JPEG，天然满足"需要时序信息"。

`h265`/`h264` **正在做，方式是原生编码，不是 ffmpeg**：`takePicture()` 每帧都是一次完整
拍照 + JPEG 编码，1080p 上限约 5–10 fps —— 把编码器接在它下游只换编码、不换上限。
所以帧必须在插件自己的管线里编码完再进 Dart（原始帧不进 Dart、不落盘）。
Dart 侧契约 `lib/src/capture/native_video_encoder.dart` 已完成并有断言覆盖；
Linux 的 GStreamer 分支已写完但**尚未编译**，现暂停。
进度与交接见 `docs/linux-encoded-stream-status.md`。

### 存储格式决定了不能用 mp4

服务端把每个 `recording.frame` 的裸负载按 `[uint32 BE len][frame]…` **拼接**成 `.bin` 片段，
**无容器、无头信息**，期望的是"一个编码访问单元 / 一帧"。所以原来的
`CameraPluginVideoChunkRecorder`（产出带 `moov` 的完整 mp4）**已删除** —— 发过去只会得到
无法解码的垃圾片段。持续推帧走 `FramePump`。

### 代码分层

- `lib/src/backend`、`lib/src/capture`（非插件部分）、`lib/src/config` 与
  `lib/src/app/capability_bootstrap.dart` **不依赖 Flutter**，
  所以能在纯 Dart VM 上直接跑 `tool/verify_pure.dart`（**705 项断言**，覆盖协议、注册、
  两个网关、采集管线、协调器状态机、串行锁、JPEG 裁剪与尺寸读取、能力模型与声明、
  摄像头排序、能力缓存与 `ensureInventory` 编排、地址校验与设置解析、Annex B 切分、
  可持续帧率模型、原生编码器的 Dart 侧契约）。
  新增代码请保持这条边界：一旦引入 `package:flutter/*`，该模块就再也无法在本机验证。
  这条边界直接决定了三个接口放在哪里：`CameraRanker` 放在纯的 `camera_order.dart`、
  `CapabilityProbe` 放在纯的 `capability_probe.dart`、`CameraEnumerator` 放在纯的
  `camera_service.dart`，插件实现各自单独成文件（`plugin_*.dart`）——
  因为 `ensureInventory` 的编排逻辑（缓存命中、退化、排序失败回退）恰恰是最值得在
  本机跑起来验证的部分。
  设置层是照着这条边界拆的 —— `connection_settings.dart` / `settings_store.dart` /
  `capabilities_store.dart` 是纯 Dart，只有 `shared_prefs_*.dart` 碰 `shared_preferences`。
- `unrecognized_command_log.dart` 的默认 sink 是 `print` 而不是 `debugPrint`
  （`main.dart` 显式传 `debugPrint`），`AgentCoordinator` 的命令日志走可注入的
  `void Function(String)` sink —— 都是为了上面那条边界。
- 摄像头四层抽象（`CameraProvider → CameraBackend → CameraService → FramePump`）不泄漏插件类型；
  预览走窄接口 `CameraPreviewProvider.previewController`（`Object?`），UI 层再窄化为 `CameraController`。
- **不引入 `permission_handler`**（原因见下）。

### 界面硬约束（Android 真机踩出来的）

- **预览开关与设置齿轮都在底部**（`PreviewToggleButton` 右下、`SettingsButton` 左下），
  顶部状态条只放信息。Android 的系统状态栏占着右上角，放上面会被盖住、点不到。
- **设置齿轮在摄像头报错页上也渲染**：全新安装最可能看到的正是那一屏，入口不能只挂在预览分支里。
- **状态条与设置界面共用 `linkStateLabel()`**，避免两屏对同一个状态用不同的词
  （"链路失败" / "连接失败"）让人以为它们说的不是一回事。
- **预览必须保持原始宽高比**：`CameraPreview` 内部用 `AspectRatio`，而
  `Stack(fit: StackFit.expand)` 会传**紧约束**，`RenderAspectRatio` 遇到紧约束直接返回
  `constraints.smallest` —— 宽高比被无视，画面被拉伸变形。所以 `_PreviewArea` 外面套了一层
  `Center`（`Center` 会把约束放松），画面按 contain 居中、留黑边。
  手机竖屏下源是 9:16、屏约 9:20，用 contain 只留很窄的上下黑边；改成 cover 要横向裁掉
  约 75% 的画面，人脸会被裁没，所以这里必须用 contain。

### 设备与媒体层的坑（端到端联调发现，都已修）

三个都是**读代码看不出来**的，只有真机跑起来 + 看落盘字节才会暴露。改这块之前请先读。

**① `takePicture()` 不能并发 —— 录制中拍照会静默失败。**
`take_photo` 和帧泵都在同一个 `CameraController` 上抓帧。并发时输的那个抛异常，
`TakePictureFrameSource` 把它吞成 `null`，协调器回 `ack ok:false` 而**没有人在听** ——
运营侧只看到 `202`，然后照片永远不出现。修法是 `SerialLock`（`lib/src/capture/serial_lock.dart`）
把抓帧串行化，且**与相机重建锁分开**，避免互相阻塞。泵的单并发语义不受影响
（它本来就 shed 而不是 queue）。
> 规律：同一个底层资源有两条调用路径时，**串行化要放在资源那一层**，不能指望调用方自觉。

**② 注册必须声明"实际生效值"，不是"能力阶梯"。**
`buildAnnouncements` 曾拿到 `supportedResolutions`（`[640x480, 1280x720, …]`）并按 camera
下标取值，于是 camera 0 报了最低档 `640x480` —— 而服务端会把它快照进
`metadata.resolution`，与实际采集的 1280x720 不符。
> 规律：**「我在做什么」（`resolution`/`fps`）和「我能做什么」（`supported_*`）
> 是两个字段，不能互相代替。** 前者是快照来源，后者是运营侧的选择菜单。
> v0.3.0 之前只有前者，所以拿阶梯去填它是错的；现在两者都有，而且后者是**实测**的。

**③ 相机 HAL 会在 JPEG 的 EOI 之后追加 0 字节。**
实测约 **1/20** 的帧比图片本身长 6~8 字节（结构完好，SOI/EOI 都在）。只有**持续推帧**那条
路径会这样，而且是间歇性的；按需拍照（同一条 `takePicture` + 读 + 删）字节精确 ——
所以是高频调用放大了 HAL 的抖动。`trimJpegPadding`（`lib/src/capture/jpeg.dart`）
裁到最后一个 `FF D9`，**且只在后面是 ≤64 字节 0 时才裁**。
没有 SOI / 没有 EOI / 尾巴过长 / EOI 后有非零字节 —— **一律不动**，
否则一个真被截断的帧会被悄悄裁成"看起来合法"。
> 规律：清理逻辑要**窄到不会掩盖真正的损坏**。这个坑只有 `check_segment.py` 那种字节级校验能发现。

### 摄像头能力声明（协议 v0.3.0）

服务端自 `531c74f feat(webcam)!` 起**要求**注册带 `supported_resolutions` 与
`supported_framerates`。这不是可选的增强 —— 缺了它设备**根本连不上**（`400`）。

**怎么测的**：插件栈在五个平台上都**没有枚举 API**，`ResolutionPreset` 又只是相对档位
（文档明说不保证像素尺寸），`controller.value.previewSize` 描述的是预览面而不是静帧。
所以唯一的诚实来源是**真拍一张**，再从 JPEG 的 SOF 段里读真实宽高（`jpegSize`）。
两档 preset 解析到同一尺寸是常态，所以去重是硬规则而不是清理。

**三趟，从便宜到贵**：

| 趟 | 做什么 | 代价 |
| --- | --- | --- |
| 枚举 | 列摄像头，不开 | 0 次开合 |
| 排序 | 每个摄像头在 `max` 档开一次，读上限 | n 次开合 |
| 探测 | 每个摄像头走 6 档 preset 各拍一张，再在最高分辨率上试 3 个帧率 | 9n 次开合 |

结果按**摄像头集合**缓存，一份（`CapabilitiesStore`，与 `SettingsStore` **分开** ——
`save()` 的语义是替换，把能力塞进 `ConnectionSettings` 会在每次探测后删掉设备凭据）。

**缓存命中 = 一次开合都没有。** 键是**无序**的摄像头名集合（排序后指纹化），
而**规范顺序作为缓存内容的一部分**存下来 —— 命中时用它把「名字顺序」映射回当前枚举顺序，
重新算出置换。键不能依赖顺序，否则就成了循环：算键要先排序，而排序正是缓存要省掉的开销。
所以第二次启动：不排序、不探测，只有一次 `availableCameras()`。

> 这里踩过一个真 bug：早先的实现**按摄像头逐个 key 存**，而 `shared_preferences`
> 那边只留**一个** entry —— 于是后一个摄像头的 save 覆盖了前一个。
> 双摄设备上 **0 号摄像头每次启动都未命中、永远重新探测**，正是"每次都检测"的现象。
> 现在整个集合是一个值，这种表示法直接不存在了。

**命中还要过一道置换校验**：缓存里的顺序是按**名字**匹配当前枚举的，每个名字必须不多不少
对上一次。U 盘摄像头换个口枚举顺序就变了，复用旧**下标**会把 `camera_enum 0` 指到别的设备上。
校验不过就当作未命中，重探。

**排序规则**：`(group, -maxPixels, index)`，组顺序 = `CameraGroup` 的声明顺序
（rear → external → front）。末尾的 `index` 是保稳用的，正因如此
**Windows（全 `front`）和 Linux（全 `external`）会自然退化为纯分辨率排序**，
不需要特例分支 —— 这两端 `camera_desktop` 把 `lensDirection` 写死成 `0` / `2`，
只有 macOS 和 Android 报真实方向。**代码和注释都必须写明这一点**，
否则半年后会有人当"有后置摄像头"是断言。

**声明 = `实测 ∪ 常见阶梯`，再截到实测上限，最后并入当前模式**：
`declaredCapabilities()` 是注册和 `switch_camera` 校验**共用**的同一个函数 ——
设备接受的必须恰好等于它公布过的，否则运营侧从一个"设备自己印出来的菜单"里
选了一个值却收到 `ok:false`。当前模式**永远并入且最后并入**：服务端拒收
"没声明当前模式"的注册，而 `AppConfig.defaultFps` 是 5、探测只试 60/30/15，
所以当前帧率真的可能不在探测值里。

**探测失败不能变成空列表**：`supported_resolutions: []` 是 `400`，
"连不上"比"少声明"糟糕得多，所以探测为空时退化成"只声明我正在用的那一对"。

### `camera_enum` 的规范顺序与「当前模式」

**`camera_enum` 是位置量，所以"顺序"就是协议里"哪个摄像头"的词汇。** 以前 index `i`
就是平台列出来的第 `i` 个 —— 一台两摄手机和一台三摄笔记本含义完全不同，
插一个 USB 摄像头还会整体挪位。

- **顺序 = `(group, -maxPixels, index)`**，`CameraGroup` 的声明顺序即组顺序
  （rear → external → front），组内按实测像素降序。
- **物理下标只存在于 `CameraPluginBackend` 里。** 它以规范顺序构造
  `_descriptors`，`switchCamera(enum)` 在碰插件列表之前先过一遍置换。
  `CameraDescriptor.index` 因此**就是** announced enum，下游再也见不到第二套编号。
- 置换不是合法排列（长度不对、越界、有重复）时**退回恒等**，而不是"部分采纳" ——
  一个重复项会让两个 announced 摄像头指向同一台设备。

**「当前模式」只有设备自己记得。** 服务端对 `switch_camera` **不存任何状态**，
它对某个摄像头分辨率/帧率的认知全部来自注册。所以：

- 设备为每个 `camera_enum` 记一份 `CameraMode{resolution, fps}`；
- `switch_camera` 带的参数**先对着自己公布过的清单校验**，不在清单里就 `ack ok:false`
  并且**什么都不做**（绝不"照跑但假装成功"）；
- 参数**真的变了**就**重新注册** —— 否则服务端在 `recording/start` 时快照进
  `metadata` 的仍是旧模式。这条走 `reconfigure()`，不另开一条重连路径。
- 只切摄像头、或校验失败的切换**不重连**：白白掐断媒体没有任何好处。

**「重新检测」按钮**（设置界面）做的是**强制重测**（忽略缓存、测完再写回缓存），
然后 `adoptInventory()` 把**置换和能力一起换掉**再重连 —— 两者必须同时换，
否则服务端会去要一台后端没有的摄像头。它走 `reconfigure()` 而不是直接 `start()`，
因为**摄像头清单是在构造 gateway 时烘进去的**，在同一个实例上重新注册只会把旧清单再发一遍。

### 命令可观测性

服务端对多数命令**不记录任何状态**（`switch_camera` 的文档原话是
"the ack is the only confirmation an operator can get"），而客户端不把 ack 写日志的话，
**一个回 `ok:false` 的设备和一个干脆忽略命令的设备从外面看一模一样**。
所以 `AgentCoordinator` 接一个可注入的 `log` sink（`main.dart` 传 `debugPrint`），
每条命令和它的 ack 结果都打到控制台：

```
start_recording(camera=0, stream=01M4…) →
  ack ok
switch_camera(camera=1) →
  ack FAILED: cannot switch camera while stream 01M4… is active
```

**`switch_camera` 在 stream 活着时会被拒绝**（`ok:false` + 原因），这是有意为之：
协议允许 `ok:false` "when the device cannot switch"，而一台物理摄像头只能服务一条流，
切换会**静默杀死**正在跑的流。服务端没有任何"设备放弃了这条流"的信号 ——
它只会在**设备断开**或**自己重启**时收尾，所以那条流会一直挂着 `active`，
运营侧无从察觉。**明确拒绝比静默失败好。** 停流后切换正常（实测 64ms）。

## 端到端联调环境

> 这一节讲的都是**本地临时搭的东西**，不是本仓库的组成部分。
> 服务端仓库、PG 集群、S3 替身都放在工作区外（`smartclass-webcam-server/` 那一份检出已被
> gitignore），随时可以整个删掉，不影响客户端构建与自测。

完整步骤在 `docs/superpowers/plans/2026-10-04-android-server-e2e-test.md`，Android 侧细节在
`docs/android-setup.md`。这里只记**踩过的环境坑**，因为它们会让"跑不起来"看起来像代码问题。

### 对象存储：这台机器上一个真实 S3 都用不了

- MinIO **社区版已停发**：`dl.min.io/server/minio/release/…` 与所有 `/archive/` 旧版本
  一律返回 **410**；新路径 `dl.min.io/aistor/…` 能下，但启动即报
  `No valid license found … All S3 operations are denied`。
- **Docker Hub 被代理整个挡掉**（`registry-1.docker.io` 走代理返回 000，
  Docker Desktop 自身又没配 HTTPS proxy），所以 `minio/minio` 镜像也拉不到。
- GitHub release 走代理 502。

→ 用 `tool/e2e/s3_stub.py`。`minio-go` 只用五个操作
（`HEAD /{bucket}`、`PUT /{bucket}`、`PUT|GET|DELETE /{bucket}/{key}`），
且**签名可以忽略** —— 目的是验客户端字节，不是验 S3。对象落真实目录，
可以绕开 API 直接看字节。

⚠️ **它必须解 `aws-chunked`**：`minio-go` 上传用 SigV4 streaming，body 是
`<hex>;chunk-signature=…\r\n<data>\r\n…`，而 **`Content-Encoding: aws-chunked` 这个头不一定发** ——
要直接看 body 前 64 字节有没有 `;chunk-signature=`。第一版没解，存下来的段开头是
`10000;chunk-signature=…`，**看起来完全像客户端的 bug**。

> 没有对象存储时服务端会用 `NoopStorage` 丢字节，但 ⚠️ **segment 行照样写、`size_bytes` 照样有值**，
> 所以"有行有大小"绝不能代替字节校验。

### 本机后端栈（不用 Docker）

- **PostgreSQL**：系统那套在 5432，但 `postgres` 口令未知、pg_hba 全 `scram-sha-256`、无 `.pgpass`。
  **自建 trust 集群绕开**：`initdb -D <dir> -U postgres -A trust` 然后
  `postgres.exe -D <dir> -p 5433`。**PG18 跑后端内嵌迁移没问题**，不必退 PG16。
- **服务端**：`go build ./cmd/server`，环境变量见 `internal/config/config.go`。
  `WEBCAM_DEV=true` 关掉 teamusers 鉴权，但**设备令牌仍然校验** ——
  `GET /ws/register` 必须带 `Authorization: Bearer wdt_…`。

### ⚠️ 本机 shell 有 HTTP 代理（白名单制）

- 打 **127.0.0.1 必须加 `--noproxy '*'`**，否则被代理拦截、返回假的
  "upstream connect failed"，看起来像服务没起。
- **公网反而要走代理**：`dl.min.io` 直连可达，`github.com` 加 `--noproxy` 就超时。

## 发布

`.github/workflows/release.yml`：**Windows / macOS / Linux / Android** 四端并行出包，
iOS 不参与（需要 Apple Developer 证书，见 `docs/release.md`）。

```bash
git tag v1.0.0 && git push origin v1.0.0    # 跑测试 → 四端构建 → 建 Release 附产物
```

- 手动触发（Actions → Release → Run workflow）**只出产物、不建 Release**，用来验流水线。
- `verify` job 先跑 `dart run tool/verify_pure.dart` + `flutter test`，全绿才构建。
- Android 配了 `ANDROID_KEYSTORE_*` secrets 就用正式签名，没配回落 debug（不会因此构建失败）。
- **`pubspec.lock` 现在提交进仓库了**：这是应用不是库，发布必须解析到和本地一致的版本。

完整说明（产物清单、签名、各平台运行环境要求、已知限制、实现上的坑）见
**`docs/release.md`**。

## 构建环境

Windows 端需要 Visual Studio（Desktop development with C++ 工作负载）。
已在 VS 18 / MSVC 14.51 / Windows SDK 10.0.26100 上验证构建通过。

### 为什么没有 permission_handler

`permission_handler_windows` 0.2.2 强制 `/await` 并拉取 C++/WinRT 2.0.210806.1，其头文件包含
`<experimental/coroutine>`。MSVC 14.51 已把它变成硬错误：

```
error C2338: static assertion failed: 'error STL1011: The /await compiler option,
<experimental/coroutine>, <experimental/generator>, and <experimental/resumable>
are deprecated by Microsoft and will be REMOVED SOON.'
```

理论上可用 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` 压掉，但微软明确说这套 API
会被移除，而该依赖本身是**冗余**的：

- `camera_android_camerax` 自带 `CameraPermissionsManager`（`ActivityCompat.requestPermissions`），
  且在自己的 manifest 里声明了 `android.permission.CAMERA`；
- `camera_avfoundation` 自带 `CameraPermissionManager`（`AVCaptureDevice.requestAccess`）。

两者都在 `initialize()` 时申请权限，插件抛出的 `CameraException` 由
`cameraFailureFrom()` 映射成带类型的 `CameraFailure`。删掉后 Windows 端只剩 `camera_desktop`
一个原生插件（纯 Media Foundation C++，不碰 C++/WinRT）。

### Android

`AndroidManifest.xml` 里必须有 `android:usesCleartextTraffic="true"`：targetSdk 36 时
Android 9+ 默认禁止明文流量，而网关是 `ws://`，不开的话连接会被系统直接拒掉。
将来上 TLS 时要和 `ws://` 默认值一起撤掉。真机步骤见 `docs/android-setup.md`。

### 关于本机 Flutter CLI

`C:\Users\Lhui\AppData\Local\flutter` 在**用户自己的终端**里可正常使用。

在**助手工具的 shell** 里，任何会**开子进程管道**的命令都失败
（`ProcessException: All pipe instances are busy`，`errno = 231`）。所以：

| 命令 | 助手 shell |
| --- | --- |
| `flutter pub get` | ✅ **唯一能跑的 flutter 子命令**（只做网络 IO）—— 但见下面警告 |
| `flutter run` / `build` / `test` / `analyze`、`dart analyze` | ❌ 失败 |
| `dart run tool/verify_pure.dart`、`dart format` | ✅ 进程内执行 |

> ⚠️ **Windows 上绝不要用助手 shell 跑 `flutter pub get`。** 它会重建
> `{windows,linux}/flutter/ephemeral/.plugin_symlinks/*`，但在那个沙箱里 `Link.createSync`
> **不报错却造出一个空目录**。Flutter 判 `link.existsSync()` 对普通目录返回 **false**，
> 于是下一次真的 `flutter run` 走到 `createSync` 撞 ERROR_ALREADY_EXISTS(183) 直接失败。
> 修法：`rm -rf {windows,linux}/flutter/ephemeral/.plugin_symlinks`（纯生成物），
> 然后由用户自己的终端重跑。**这条踩过一次。**

助手侧的三条替代验证路径：

1. `dart run tool/verify_pure.dart` —— 进程内执行，**705 项断言**。
2. 用 Python 直接驱动 `frontend_server_aot` 做单次编译（等价于类型检查，只覆盖 Dart）。
3. **真机联调**：`flutter run` 起不来，但**已经装好的 debug APK 可以完全用 adb 驱动** ——
   详见 `docs/android-setup.md` 的「不用 flutter run 也能驱动真机」。

### Linux

**本机编不了 Linux。** 除了上面的管道问题，Linux 的 GStreamer / GTK / `flutter_linux`
头文件在这台 Windows 机器上根本不存在。所以 `packages/camera_desktop/linux/` 下的任何改动
都必须在一台 Linux 机器上 `flutter build linux` 验证。
这也是 Linux 原生编码分支暂停的原因 —— 进度见 `docs/linux-encoded-stream-status.md`。
