# webcam_client

前台 kiosk 式跨平台摄像头边缘探针客户端，接入 **`smartclass-webcam-server`** 的设备协议。

设备是**从属角色**：它不主动推流。运营侧在管理面 `POST /api/devices/{id}/recording/start`
之后，服务端才下发 `start_recording`，客户端此时才开始推帧；`stop_recording` 一到立刻停。

实现依据：`docs/superpowers/plans/2026-10-04-smartclass-backend-integration.md`（T1–T8）。
**协议权威文档**是后端仓库的 `smartclass-webcam-server/docs/protocol/`
（index / registration / transport / control / media），本客户端逐条对齐。

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
| 操作 | 测试连接（`GET /healthz`，不消耗 ticket）· 保存并重连 · 恢复默认 · 清空凭据 |

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

采集参数（fps / 分辨率 / 质量）**不在设置界面里**：它们不是"换个后端就要改"的东西，
而且 fps 与分辨率是注册时 announce 的，改动必须连带重建 announcements。

测试与自检：

```bash
flutter test
dart run tool/verify_pure.dart    # 393 项断言的纯 Dart 自检，不需要 Flutter 引擎
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
UI (agent_screen / status_bar_overlay / preview_toggle_button / camera_error_view
    / settings_button → settings_screen)
        │  AgentStatus
AgentCoordinator ── 命令驱动的状态机：每条命令都 ack，没收到 start_recording 就不推任何媒体
        │            （命令与 ack 结果走可注入的 log sink，控制台可见）
        │            reconfigure() ── 换设置时重建 gateway，而不是改它的 base
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
                 ├── serial_lock ── 串行化「相机重建」与「抓帧」两条互斥路径
                 └── jpeg ── 裁掉相机 HAL 偶尔追加在 EOI 之后的 0 字节

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
**v1 实际落在 `mjpeg`**，这不是妥协：服务端对 `mjpeg` 的定义就是"每个 `recording.frame`
一张 JPEG"，而 `takePicture()` 产出的正好是 JPEG，天然满足"需要时序信息"。
`h265`/`h264` 需要编码器（计划中的 T9，走 `ffmpeg_kit_flutter_new`），尚未实现。

### 存储格式决定了不能用 mp4

服务端把每个 `recording.frame` 的裸负载按 `[uint32 BE len][frame]…` **拼接**成 `.bin` 片段，
**无容器、无头信息**，期望的是"一个编码访问单元 / 一帧"。所以原来的
`CameraPluginVideoChunkRecorder`（产出带 `moov` 的完整 mp4）**已删除** —— 发过去只会得到
无法解码的垃圾片段。持续推帧走 `FramePump`。

### 代码分层

- `lib/src/backend`、`lib/src/capture`（非插件部分）与 `lib/src/config` **不依赖 Flutter**，
  所以能在纯 Dart VM 上直接跑 `tool/verify_pure.dart`（**393 项断言**，覆盖协议、注册、
  两个网关、采集管线、协调器状态机、串行锁、JPEG 裁剪、地址校验与设置解析）。
  新增代码请保持这条边界：一旦引入 `package:flutter/*`，该模块就再也无法在本机验证。
  设置层是照着这条边界拆的 —— `connection_settings.dart` / `settings_store.dart` 是纯 Dart，
  只有 `shared_prefs_settings_store.dart` 碰 `shared_preferences`。
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
`metadata.resolution`，与实际采集的 1280x720 不符。现在传 `camera.appliedResolution`。
> 规律：announce 出去的必须是**「我会交付什么」**，不是「我支持什么」。

**③ 相机 HAL 会在 JPEG 的 EOI 之后追加 0 字节。**
实测约 **1/20** 的帧比图片本身长 6~8 字节（结构完好，SOI/EOI 都在）。只有**持续推帧**那条
路径会这样，而且是间歇性的；按需拍照（同一条 `takePicture` + 读 + 删）字节精确 ——
所以是高频调用放大了 HAL 的抖动。`trimJpegPadding`（`lib/src/capture/jpeg.dart`）
裁到最后一个 `FF D9`，**且只在后面是 ≤64 字节 0 时才裁**。
没有 SOI / 没有 EOI / 尾巴过长 / EOI 后有非零字节 —— **一律不动**，
否则一个真被截断的帧会被悄悄裁成"看起来合法"。
> 规律：清理逻辑要**窄到不会掩盖真正的损坏**。这个坑只有 `check_segment.py` 那种字节级校验能发现。

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

`C:\Users\Lhui\AppData\Local\flutter` 可正常使用。另注：在**助手工具的 shell** 里 Dart VM 无法
创建子进程（`ProcessException: All pipe instances are busy`，`process_win.cc:744`），
所以 `flutter run/test/analyze` 在那个 shell 里会失败；用户自己的终端不受影响，与项目无关。
助手侧改用三条替代路径验证：

1. `dart run tool/verify_pure.dart` —— 进程内执行，393 项断言。
2. 用 Python 直接驱动 `frontend_server_aot` 做单次编译（等价于 `flutter test` 的类型检查）。
3. **真机联调**：`flutter run` 起不来，但**已经装好的 debug APK 可以完全用 adb 驱动** ——
   详见 `docs/android-setup.md` 的「不用 flutter run 也能驱动真机」。
