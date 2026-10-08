# 运行时可配置后端参数（设置界面）Implementation Plan

> **✅ 已实现（T1–T8）。** 提交 `81a0d1f`（主体）、`c8262de`（首轮 `flutter test` 的两个失败）、
> `95ca378`（播种删凭据的真机 bug）。
>
> 两处**有意偏离计划**，都是 bug 修复而非取舍：`SettingsStore.load()` 拆成
> `loadBaseUrl()` / `loadCredentials()`；`pause`/`resume` 改成对称的 unbind/bind。
> 采集参数**有意不进设置界面**。
> T8 真机验收**部分完成**（T8.3「401 恢复」未单独走）。
> 详见 `docs/implementation-status.md`。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让运营/实施人员在客户端界面上直接填写并切换后端参数，不再需要为每台设备重新编一个带 `--dart-define` 的包。范围覆盖**后端地址 + 设备凭据**（`device_id` / `device_token`），保存后立即写盘并强制重连。采集参数（fps / 分辨率 / 质量）**不在本次范围内**。

**前置状态：** 端到端连通测试已通过（T0–T8 of `2026-10-04-android-server-e2e-test.md`）。当前 `AppConfig` 全部是编译期常量，凭据只在首次启动时从 `--dart-define` promote 进 `shared_preferences`，之后再无写入路径 —— 换后端必须重新打包。

**已确认的三个决策：**

| 决策点 | 选择 |
|---|---|
| 设置界面包含哪些参数 | 后端地址 + 设备 ID + 设备令牌 |
| kiosk 入口是否加锁 | 不加锁，屏幕左下角常驻齿轮按钮 |
| 保存后何时生效 | 立即生效：写盘 → 停推 → 断链 → 用新参数重新注册 |

---

## 🐞 变更记录 B（2026-10-07 —— 已修复：「测试连接」404 而链路正常）

**症状：** 设备已连上后端（预览上状态条显示"已连接"），点「测试连接」却报 `HTTP 404`。

**根因：** `HttpHealthProbe` 用 `base.replace(path: '/healthz')` 拼地址 —— **把 base path 丢掉了**。
而注册走的是 `resolveDevicePath(base, '/ws/register')`，**保留** base path。

于是两者在「服务部署在路由前缀下」时必然分道扬镳。部署文档 `docs/guide/deploy.md` 给的正是这种部署：

```yaml
route:
  prefix: /webcam
  strip: true   # /webcam/api/devices 到达子进程时是 /api/devices
```

前缀之下，**每个端点对外可见的地址都在前缀里，`/healthz` 也不例外**：

| 请求 | 外部路径 | 到达子进程 | 结果 |
|---|---|---|---|
| 注册 | `/webcam/ws/register` | `/ws/register` | ✅ 200 |
| 探测（修复前） | `/healthz` | —— | ❌ 404，前缀不匹配，ingress 根本不路由 |

**我原先的判断是错的，而且错得有迹可循**：计划里写「healthz 注册在根路径，所以要用 `replace(path:)`」，
这句是基于**直接读 chi 的 router**（`r.Get("/healthz", …)` 确实在根）—— 那是子进程内部的视图。
我漏了部署层：**服务被挂在前缀下时，外部可见路径整体平移**。`replace(path:)` 丢掉的正好是那一段。
已核对：v0.1.0 与 v0.2.0 的 router 里 `/healthz` 都存在，所以"服务端没有这个路由"可以排除。

**修法：** 探测改用 `resolveDevicePath(base, '/healthz')` —— 和注册用同一个拼法。
无 base path 时结果与旧表达式逐字节相同，简单场景零回归。

**顺带修的第二处：** `reachable` 原为 `statusCode == 200`。但 **404 也是一次应答**，
它恰恰证明地址是通的；把它报成"失败"正是这次让人以为设备坏了的原因。现改为：

| 情况 | 判定 | 界面 |
|---|---|---|
| 200 | `healthy` | 绿：可达（HTTP 200） |
| 有应答但非 200 | `reachable && !healthy` | 琥珀：地址可达，但探测路由返回 HTTP xxx（**不影响连接**） |
| 无应答（超时/拒绝） | `!reachable` | 红：不可达 + 原因 |

这样"地址错"和"地址对但探测路由不对"不会再混成一件事。

**改动：** `lib/src/backend/health_probe.dart`（新增纯函数 `healthProbeUri`）、
`lib/src/ui/screens/settings_screen.dart`（三态配色）、
新增 `test/backend/health_probe_test.dart`、`tool/verify_pure.dart` 加断言（406/406 通过）。

---

## 📌 变更记录 A（2026-10-05 追加 —— 原计划已在执行中，就地修订）

> **本文件是唯一计划。变更不另开文件，下文 T5 / T7 已就地改写，与本块一致。**

**来源：** 这份功能的第一批使用者是**同事 A —— 他机器上没有 Flutter、也没有 adb，只会拿到一个 APK**；而经理的服务端**尚未部署**，地址待定。

这个场景推翻了原计划的两个前提：

1. A 装完 APK 之后，**手里没有任何工具能把后端地址弄进去**（dart-define 需要编译、凭据注入需要 adb）。
   现在 APK 里的默认地址是 `http://127.0.0.1:8080`，**而在手机上 127.0.0.1 就是手机自己**
   —— A 一打开就是"链路失败"，且无从下手。所以"能在界面上填地址"不是锦上添花，
   **是这个 APK 能不能用的唯一前提**。
2. 同理，**只给地址字段不给凭据字段，APK 依然是死的**：凭据现在要么 dart-define、
   要么 adb `run-as` 注入，两条路 A 都走不了。经理说的"配置地址"隐含了凭据，只是没说全。

**由此上调两项定级：**

| 项 | 原定级 | 新定级 | 理由 |
|---|---|---|---|
| **T5.4 首次启动自动打开设置**（预填、可改） | 可选 | **必须** | 默认地址在手机上必错，A 需要一个"落地页"，而不是一个莫名其妙的失败状态 |
| **T7「测试连接」按钮**（`GET /healthz`） | 可选、可砍 | **必须** | A 没有 adb、没有 logcat。手敲 IP 敲错是概率最高的失败，而"链路失败"三个字分不清是**地址不通**、**防火墙挡了**还是**令牌错了** —— 没有这个按钮他只能来问我 |

**交付方式（不是代码，但决定 T5.4 的默认值填什么）：**

- 编这个测试 APK 时**用 `--dart-define` 把设备凭据一起编进去**（`DEVICE_ID` / `DEVICE_TOKEN`）。
  这是一台测试机、一个测试包，把凭据编进去完全可接受 —— **好处是 A 只需要改地址，
  不用在手机键盘上手敲 43 字符的令牌**。手敲令牌打错一个字符 = 401 = 永久终态，
  是这个流程里最容易踩且最难自查的坑。
- 后端地址**等经理的服务端部署好、IP 定了之后**再用 `--dart-define=BASE_URL=http://<IP>:8080`
  编进默认值；A 打开设置看到的就是对的，只在换机器时才需要改。
- 发 **debug APK**（`flutter build apk --debug`）：免签名、能装，反正只是测试。

---

## 一、现状与约束（改之前必读）

| 文件 | 现状 | 对本次的影响 |
|---|---|---|
| `lib/src/config/app_config.dart` | `BASE_URL` / `DEVICE_ID` / `DEVICE_TOKEN` / `USE_MOCK_BACKEND` 全是 `String.fromEnvironment` | 退化为**种子值**：仅在 store 为空时生效。保留，不删 |
| `lib/src/backend/credential_store.dart` | `SharedPrefsCredentialStore`，键 `device_id` / `device_token` | **复用**，不新增凭据键 → 老版本升级零迁移 |
| `lib/src/backend/smartclass_backend_gateway.dart` | `required Uri base`，`final`，构造时固定；`_registerAndAttach()` 每次重连都读它 | **本文件不改**。换后端 = 换一个 gateway 实例 |
| `lib/src/agent/agent_coordinator.dart` | `final BackendGateway _gateway`、`final DeviceCredentials? _credentials`；`start()` 里凭据为 null 就置 `failed` 并**再也不重试** | 必须新增重配入口，否则填完凭据也连不上 |
| `lib/main.dart` | 启动时一次性解析配置、建 gateway、建 coordinator | 改成从 store 读 + 提供 gateway 工厂 |
| `lib/src/ui/screens/agent_screen.dart` | 只有预览 + 状态条 + 右下角预览开关 | 左下角加齿轮入口 |

### 三条不能破的红线

1. **`lib/src/backend/` 与 `lib/src/capture/` 的非插件部分不得依赖 Flutter。** 所以 `ConnectionSettings` 模型、URL 校验、优先级解析必须是纯 Dart（放 `lib/src/config/`），只有 `shared_preferences` 实现单独一个文件。否则 `tool/verify_pure.dart` 再也跑不了。
2. **`SmartClassBackendGateway` 不改。** 它已经能正确表达"一次连接"；换后端本质就是换一次连接。改它要在 6 处测试调用点改签名，收益为零。
3. **不要在两处渲染同一个状态**（踩过：状态条详情行和右侧 chip 都写采集状态 → `find.textContaining` 命中 2 个 widget，测试挂）。设置界面里出现的文案必须带独立 `Key`。

### 一个必须绕开的坑：401 是终态

`SmartClassBackendGateway._fail()` 对 401 的处理是 `_stopped = true` —— **永久停止重试**，因为令牌被吊销/设备被删除只能由运营侧修。

这意味着：凭据填错一次之后，**无论等多久都不会自己恢复**，唯一出路是换一个新的 gateway 实例。本计划采用"重建 gateway"而不是"给旧 gateway 换个 base"的设计，正是因为它顺手把这个问题一起解决了。实现时务必验证这条路径（见 T8 验收第 2 项）。

---

## 二、架构决策：重建 gateway，而不是改 gateway 的 base

```
保存设置
  └─> SettingsStore.save(next)                     // 先落盘，宕机也不丢
      └─> coordinator.reconfigure(next)
            ├─ await _stopRecording()              // 服务端会把该 stream 标 failed
            ├─ await _unbindGateway()              // 取消三条订阅
            ├─ await _gateway.stop()
            ├─ _connection = next
            ├─ _gateway = _gatewayFactory(next)    // ← 新实例：新 base、新退避、新 ticket
            ├─ _started = false; _framesSent = 0; _lastError = null
            └─ await start()                       // 重新订阅 + 注册（凭据为空则 failed + 提示）
```

`BackendGatewayFactory` 定义为 **`BackendGateway Function(ConnectionSettings)`** —— 把新设置作为参数传进去，而不是让工厂闭包捕获一个可变变量。**这一点是刻意的**：用可变变量的话，"先更新变量再 apply" 和 "先 apply 再更新变量" 只有一句之差，写反了就能造出"用旧地址重连"的幽灵 bug。传参让顺序不可出错。

**工厂必须复用同一个 `UnrecognizedCommandLog` 实例**（`unrecognized`），否则重建一次就丢一次本地留痕。

---

## 三、文件结构

```
lib/src/config/
  connection_settings.dart        新增  纯 Dart：模型 + URL 校验 + 优先级解析
  settings_store.dart             新增  纯 Dart：SettingsStore 接口
  shared_prefs_settings_store.dart 新增  Flutter 依赖：shared_preferences 实现
lib/src/agent/
  agent_coordinator.dart          修改  gatewayFactory + reconfigure() + 订阅收拆
lib/
  main.dart                       修改  从 store 读配置、装配工厂、接线保存回调
                                        + 未配置时首帧后自动打开设置（T5.4）
lib/src/ui/screens/
  settings_screen.dart            新增  设置界面（字段预填、可改）
  agent_screen.dart               修改  左下角齿轮入口 + 路由
lib/src/ui/widgets/
  settings_button.dart            新增  齿轮按钮（未配置时带红点）
lib/src/config/
  app_config.dart                 修改  BASE_URL 默认值改为引用 defaultBaseUrl（单一来源）
lib/src/backend/
  health_probe.dart               新增  GET /healthz 连通性探测（T7，必须）
tool/verify_pure.dart             修改  新增三组纯 Dart 断言
test/config/settings_store_test.dart    新增
test/ui/settings_screen_test.dart      新增
test/ui/agent_screen_test.dart         新增
test/agent/agent_coordinator_test.dart 修改  新增 reconfigure 用例
test/backend/health_probe_test.dart    新增
```

---

## 四、任务

### T1 — 纯 Dart 配置层 `lib/src/config/connection_settings.dart`

- [ ] **T1.1** 定义 `ConnectionSettings`：

```dart
/// 运营人员可以在运行时改动的全部后端参数。
///
/// 刻意与 `StreamSettings`（采集参数）分开：这一半影响「连到哪、以谁的身份」，
/// 改了必须重新注册；那一半只影响本地采集。
class ConnectionSettings {
  const ConnectionSettings({required this.baseUrl, this.credentials});

  /// 后端 origin。注册 `{base}/ws/register` 与 WS 挂载地址都由它推导，
  /// 所以允许带子路径（`resolveDevicePath` 会保留 base path）。
  final Uri baseUrl;

  /// 未配置时为 null。
  final DeviceCredentials? credentials;

  bool get isProvisioned => credentials?.isConfigured ?? false;

  /// 形状检查。服务端对「形状错」和「值错」都回 401，本地先查形状能把
  /// 一句含糊的 device authentication failed 变成明确的「像是打错了」。
  bool get looksValid => credentials?.looksValid ?? false;

  ConnectionSettings copyWith({
    Uri? baseUrl,
    DeviceCredentials? credentials,
    bool clearCredentials = false,
  });

  /// 归一化后比较，用于判断「这次改动是否真的需要重连」。
  bool hasSameEndpoint(ConnectionSettings other);

  @override
  String toString();   // 复用 DeviceCredentials._redact，绝不打印令牌
}
```

- [ ] **T1.2** URL 校验与归一化：

```dart
enum BaseUrlProblem {
  empty, notAbsolute, badScheme, noHost, hasUserInfo, hasQuery, hasFragment;
}

class BaseUrlValidation {
  final Uri? uri;                 // 归一化后的值，仅 isOk 时非 null
  final BaseUrlProblem? problem;
  bool get isOk => problem == null && uri != null;
  String get message;             // 面向实施人员的中文提示
}

BaseUrlValidation validateBaseUrl(String raw);
```

规则（逐条实现）：

1. `raw.trim()`；空 → `empty`。
2. **没有 scheme 就按 `http://` 补全** —— 人只会敲 `192.168.1.20:8080`。（Dart 的 `Uri.parse` 对以数字开头的串不会认出 scheme，所以判 `!uri.hasScheme` 是安全的。）
3. `scheme` 映射 `ws→http`、`wss→https`；`http`/`https` 原样；其余 → `badScheme`。
   理由：`toWebSocketUri()` 只接受 http/https 作为输入，用户手敲 `ws://` 会让注册请求直接打到一个 ws 地址上。
4. `host` 为空 → `noHost`（能挡住 `https:/example.com` 这种漏敲一个斜杠的情况）。
5. `userInfo` 非空 → `hasUserInfo`（URL 里带口令，不该存进明文 preferences）。
6. `hasQuery` / `hasFragment` → 对应问题码（origin 上带这两者没有意义，且会污染 `resolveDevicePath` 的拼接）。
7. 归一化：**scheme 与 host 转小写**（否则 `HTTPS://Host` 和 `https://host` 会被判成"改过了"、白白触发一次重连）；path 去掉结尾 `/`，`/` 归一成 `''`；保留子路径与端口。

- [ ] **T1.3** 优先级解析（纯函数，可单测）：

```dart
/// store 里的值赢；没有 store 时用编译期 dart-define 播种；编译期默认值是地板。
ConnectionSettings resolveConnectionSettings({
  ConnectionSettings? stored,
  required String buildBaseUrl,
  required String buildDeviceId,
  required String buildDeviceToken,
});
```

- [ ] **T1.4** 导出 `const String defaultBaseUrl = 'http://127.0.0.1:8080';`，并让 `AppConfig.baseUrl` 的 `defaultValue` 引用它（单一来源，避免两处漂移）。

### T2 — 持久化 `lib/src/config/settings_store.dart` + `shared_prefs_settings_store.dart`

- [ ] **T2.1** 接口（纯 Dart，单独文件，好让 verify_pure 能 import）：

```dart
abstract interface class SettingsStore {
  /// 从未写入过 base url 时返回 null。
  Future<ConnectionSettings?> load();
  Future<void> save(ConnectionSettings settings);
  Future<void> clear();
}
```

**`load()` 返回 null 的判定是「`base_url` 键不存在」，不是「什么都没存」。** 这一条是刻意的：老版本只写了 `device_id`/`device_token`，如果它照样返回一个带默认地址的 settings，那么 bootstrap 会认为"已存过"从而不播种，`base_url` 永远写不进去，日后改 `BASE_URL` 的 dart-define 就再也不生效了。返回 null 能让老安装自动完成一次播种。

- [ ] **T2.2** `SharedPrefsSettingsStore implements SettingsStore`：
  - 组合已有的 `SharedPrefsCredentialStore` 处理凭据那一半（`SharedPrefsSettingsStore({CredentialStore? credentials, SharedPreferences? preferences})`）。**不新增凭据键、不改动 `CredentialStore` 的任何测试。**
  - 新增键 `base_url`（只此一个）。
  - `load()`：读到空或 `validateBaseUrl` 不过 → 返回 null（坏值等同于没存，宁可回退到播种也不要拿一个不能用的地址去连）。
  - `save()`：写 `baseUrl.toString()`；凭据非 null 就 `credentials.save()`，null 就 `credentials.clear()`。
  - `clear()`：删 `base_url` + 清凭据。

### T3 — `AgentCoordinator` 支持重配

- [ ] **T3.1** 新增 `typedef BackendGatewayFactory = BackendGateway Function(ConnectionSettings connection);`
- [ ] **T3.2** 构造函数改动：

```dart
AgentCoordinator({
  required BackendGatewayFactory gatewayFactory,   // 取代 required BackendGateway gateway
  required CameraProvider cameraProvider,
  required FramePumpFactory pumpFactory,
  required ConnectionSettings connection,          // 取代 DeviceCredentials? credentials
  CameraService? initialCamera,
  String? initialBackendId,
  CaptureConfig? config,
  StreamSettings? settings,
  void Function(String message)? log,
}) : _gatewayFactory = gatewayFactory,
     _connection = connection,
     _gateway = gatewayFactory(connection),
     ...
```

`_gateway` 与 `_connection` 改为非 `final`。加 `ConnectionSettings get connection`。

- [ ] **T3.3** 抽出订阅的绑定/解绑，避免重配时重复监听：

```dart
void _bindGateway() {
  _commandSub = _gateway.commands.listen((c) => unawaited(handleCommand(c)));
  _linkSub = _gateway.states.listen(_onLinkState);
  _errorSub = _gateway.errors.listen(_onGatewayError);
}

Future<void> _unbindGateway() async {
  await _commandSub?.cancel();
  await _linkSub?.cancel();
  await _errorSub?.cancel();
  _commandSub = null; _linkSub = null; _errorSub = null;
}
```

`start()` 改用 `_bindGateway()`；`stop()` 改用 `_unbindGateway()`。

- [ ] **T3.4** 新增重配入口：

```dart
/// 换后端 / 换凭据。调用方必须先落盘，再调这里。
///
/// 换的是**一整个 gateway 实例**而不是改旧实例的 base：旧实例可能已经因为
/// 401 进入 `_stopped = true` 的终态，那个状态下它永远不会再重试。
Future<void> reconfigure(ConnectionSettings next) async {
  _report('reconfigure → ${next.baseUrl}');

  // 先停媒体：断开后服务端会把这条 stream 标 failed，继续推只是浪费。
  await _stopRecording();
  await _unbindGateway();
  await _gateway.stop();

  _connection = next;
  _gateway = _gatewayFactory(next);
  _framesSent = 0;
  _lastError = null;
  _started = false;

  // 走 start() 而不是自己连线：凭据为空时它给出的 failed + 提示是同一条路径。
  await start();
}
```

- [ ] **T3.5** `start()` 里的凭据读取从 `_credentials` 改为 `_connection.credentials`，并把"未配置"文案从 `请用 --dart-define=… 启动` 改成 **`请打开设置填写后端地址与设备凭据`** —— 现在有 UI 了，再让人去编包是自相矛盾的。

### T4 — `lib/main.dart` 装配

- [ ] **T4.1** 替换 `_resolveCredentials`：

```dart
final settingsStore = SharedPrefsSettingsStore();
final stored = await settingsStore.load();

final connection = resolveConnectionSettings(
  stored: stored,
  buildBaseUrl: AppConfig.baseUrl,
  buildDeviceId: AppConfig.deviceId,
  buildDeviceToken: AppConfig.deviceToken,
);

// 首次启动（或老版本升级）把编译期值播种进 store，之后一律以 store 为准。
if (stored != connection) await settingsStore.save(connection);
```

保留原来"dart-define 的凭据形状不对就记一条 `UnrecognizedCommandLog`"的行为 —— 形状问题只在播种那一次有机会说清楚。

- [ ] **T4.2** 装配 gateway 工厂（`announcements` / `unrecognized` 照旧）：

```dart
BackendGateway buildGateway(ConnectionSettings c) {
  if (AppConfig.useMockBackend) {
    return MockBackendGateway(unrecognizedLog: unrecognized);
  }
  return SmartClassBackendGateway(
    base: c.baseUrl,
    registration: HttpRegistrationClient(),
    channelFactory: (uri) => WebSocketBackendChannel(WebSocketChannel.connect(uri)),
    cameras: announcements,
    statusReport: () => coordinator.reportStatus(),
    unrecognizedLog: unrecognized,      // ← 同一个实例，跨重建保留留痕
  );
}
```

- [ ] **T4.3** `AgentApp` 增加 `settingsStore` 与 `onConnectionChanged`，把"落盘 + 重连"绑在一起：

```dart
onConnectionChanged: (next) async {
  await settingsStore.save(next);       // 先落盘：保存后立刻断电也不丢
  await coordinator.reconfigure(next);
},
```

- [ ] **T4.4** 已知限制，写进 `buildGateway` 的注释：**`cameras`（announcements）是启动时算好的，重配不重算。** 本次范围内相机不变，所以一致；将来若把 fps/分辨率也放进设置界面，announcements 必须在工厂里按当前相机重建 —— 否则注册时 announce 的会是旧值（这正是 `45364b2` / `d81992b` 修过的那一类问题）。

### T5 — UI

- [ ] **T5.1** `lib/src/ui/widgets/settings_button.dart`：`IconButton(icon: Icon(Icons.settings))`，`Key('settings-button')`，`tooltip: '设置'`。`isProvisioned == false` 时右上角叠一个红点（未配置的设备连不上，要让实施人员一眼看见）。**不用 `Badge` 以免引入额外的 widget 类型断言**，就是一个小 `Stack`。

- [ ] **T5.2** `lib/src/ui/screens/agent_screen.dart`：
  - 新增可选参数 `SettingsStore? settingsStore` 与 `Future<void> Function(ConnectionSettings)? onConnectionChanged`。两者任一为 null → 不渲染齿轮（保持现有测试的构建方式不变）。
  - 入口放**左下角**（`Alignment.bottomLeft` + `SafeArea(top: false)`）。右下角已经是预览开关；**右上角不能用** —— Android 系统状态条吞掉过那片区域的点击（原注释有记）。
  - 点击 `Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(...)))`。不引路由包。
  - `AgentApp` 透传 `settingsStore` / `onConnectionChanged`。

- [ ] **T5.3** `lib/src/ui/screens/settings_screen.dart`（`StatefulWidget`）：

分区与字段：

| 分区 | 内容 |
|---|---|
| 后端 | 后端地址（`TextInputAction.next`，自动补全 http:// 由校验层负责） |
| 设备凭据 | 设备 ID（26 字符 ULID）、设备令牌（`obscureText`，右侧眼睛图标切换） |
| 操作 | 「测试连接」(**T7，必须**) · 「保存并重连」(filled) · 「恢复默认」· 「清空凭据」(红) |

要点：

- `initState` 用 `widget.initial` 播种三个 `TextEditingController` —— **预填当前生效值，不是空白**。使用者要改的通常只是 IP 那一段，凭据则是编包时带进去的（见变更记录 A）。
- 每次 `onChanged` 都跑一遍校验，把错误文案渲染在对应字段下方（`Text` + 独立 `Key`）。**保存按钮在校验不过时 disabled**，而不是点了才报错。
- **地址输入框必须 `keyboardType: TextInputType.url` + `autocorrect: false` + `enableSuggestions: false`。**
  这不是排版偏好：手机输入法会把 `http://192.168.1.20:8080` 首字母大写、加空格或"纠正"成别的，
  而地址一旦被改过就必然连不上 —— 且失败原因看起来跟防火墙、令牌错一模一样。
- 三个字段都允许长按粘贴（令牌 43 字符，靠手敲必错，而错一个字符就是 401 永久终态）。
- 令牌默认遮蔽 —— 它在界面上是可见的凭据，且会被明文写进 preferences。
- `widget.isRecording == true` 时顶部显示琥珀色横幅：**「保存会中断当前录制，服务端会把该流标记为 failed。」**（这是真的：断开即 `failed`，不能含糊。）
- 「保存并重连」：`Navigator.pop` → `widget.onSaved(validated)`。
- 「恢复默认」：把地址填回 `AppConfig.baseUrl`（不动凭据）。
- 界面底部显示当前链路状态（复用 `LinkState`），让实施人员当场确认新地址连上了。文案带独立 `Key`。

- [ ] **T5.4** ⭐ **首次启动自动打开设置（预填、可改、可关闭）** —— 变更记录 A 上调为必须：

**触发条件：`settingsStore.load() == null`（= 从未写过 `base_url`）。** 一旦保存过一次就不再自动打开 —— kiosk 不能因为连不上就每次启动都弹窗烦人。没保存就退出 → 下次启动仍然打开，这是期望行为。

```dart
// main.dart，runApp 之后
if (stored == null) {
  WidgetsBinding.instance.addPostFrameCallback((_) => _openSettings(context));
}
```

`addPostFrameCallback` 是必须的：不能在 `runApp` 同一帧里 `push`，此时 Navigator 还没有 material route。

要点：

- **预填 `connection`（已解析、含 dart-define 播种的凭据），不是空白表单。** 使用者的动作是"改 IP"，不是"从零填三个字段"。
- 字段全部可改 —— 自动打开不等于强制，直接返回也能用（只是连不上，状态条会说清楚原因）。
- 自动打开时**不阻断摄像头预览**：设置页是 push 上去的一层，相机照常打开。
  ⚠️ 与之交互的一个风险：相机权限弹窗是 `initialize()` 触发的系统对话框，
  可能与自动打开的设置页叠在一起。实现后要在真机上看一眼两者先后顺序是否别扭。
- 自动打开**只在未配置时发生一次性质**的实现，不要写成"每次启动都检查 `isProvisioned`" ——
  那只会在凭据被清空后把 kiosk 变成每次都弹窗。

### T6 — 测试

- [ ] **T6.1** `tool/verify_pure.dart` 新增三组（目标 287 → ~330）：
  - `checkBaseUrlValidation()`：空串 / 空白 / `http://127.0.0.1:8080` / 带尾斜杠 / `192.168.1.20:8080` 补 scheme / `localhost:8080` / `https://cameras.test` / `ws://`→`http://` / `wss://`→`https://` / `ftp://` 拒绝 / `http://` 无 host / 带 query / 带 fragment / 带 userInfo / 大小写归一 / 子路径保留。
  - `checkConnectionSettings()`：`copyWith` / `clearCredentials` / `hasSameEndpoint` / `isProvisioned` / `toString` 不泄露令牌。
  - `checkResolveConnectionSettings()`：store 优先 / store 为空时用编译期播种 / store 里是坏地址时回退到播种 / 都没有时落到 `defaultBaseUrl`。

- [ ] **T6.2** `test/config/settings_store_test.dart`（`SharedPreferences.setMockInitialValues`）：
  - 存取往返；`base_url` 缺失但凭据存在（=老版本升级）→ `load()` 返回 **null**；`clear()` 后返回 null；存进去一个坏地址 → `load()` 返回 null；`save()` 后凭据键仍是 `device_id` / `device_token`（钉住"零迁移"这件事）。

- [ ] **T6.3** `test/ui/settings_screen_test.dart`：
  - 三个字段被预填（不是空的）；地址非法 → 出现错误文案且保存按钮 disabled；改合法 → enabled；令牌默认遮蔽、点眼睛后明文可见；点保存 → `onSaved` 收到一次、且值是 trim / 归一化过的；`isRecording` 时横幅出现。

- [ ] **T6.4** `test/ui/agent_screen_test.dart`：齿轮按钮存在；点击后 `Navigator` 推入 `SettingsScreen`；`settingsStore == null` 时不渲染齿轮。

- [ ] **T6.4b** ⭐ 自动打开（T5.4）的测试：
  - `load()` 返回 null → 首帧后 `SettingsScreen` 出现在路由栈上，且三个字段**已预填**；
  - `load()` 返回非 null → **不**自动打开（这条比上一条重要：kiosk 每次弹窗不可接受）；
  - 自动打开后直接返回 → 应用不崩、预览仍在。

- [ ] **T6.5** `test/agent/agent_coordinator_test.dart` 增补（工厂返回可计数的假 gateway）：
  - `reconfigure` 后：**旧 gateway 被 `stop()`**、**新 gateway 是用新地址构造的**、**新 gateway 被 `start()`**；
  - 录制中重配 → 帧泵被 stop、`captureState` 回到 `idle`；
  - `framesSent` 归零；
  - 新凭据为 null → `linkState == failed` 且 `lastError` 指向设置界面；
  - **401 终态恢复**：让旧 gateway 停在 `failed`，`reconfigure` 后 `linkState` 不再是 `failed`（这条专门守住"换实例能救回 401"这个设计意图）。

- [x] **T6.6** `test/backend/health_probe_test.dart`：探测 URL **保留 base path**（`http://h/webcam` → `/webcam/healthz`，回归测试，见变更记录 B）；200 → healthy；404 → `reachable && !healthy` 且 summary 提到 404；超时 / 传输异常 → 不可达且**不抛**。

### T7 ⭐（**必须** —— 变更记录 A 由「可选、可砍」上调）— 「测试连接」按钮

**为什么从可砍变成必须：** 使用者是没有 adb、没有 logcat 的人，只会在手机键盘上手敲 IP。敲错是概率最高的失败，而"链路失败"三个字**分不清是地址不通、防火墙挡了、还是令牌错了** —— 没有这个按钮他唯一的办法就是来问我。

- [x] **T7.1** `lib/src/backend/health_probe.dart`：`GET {base}/healthz`，5s 超时。
  **地址必须用 `resolveDevicePath` 拼（即 `healthProbeUri`），和注册同一个拼法** ——
  不要写 `base.replace(path: '/healthz')`，那会丢掉 base path，在服务挂在前缀下时必然 404
  （真机踩过，见变更记录 B）。
  该路由**无鉴权、不消耗 ticket**，所以它可以随便点 —— 这是选它而不是调 `/ws/register` 做探测的原因（注册会真的发掉一张一次性 ticket，还会把相机列表写进服务端）。

  结果要分四类，**且每一类的措辞要指向不同的下一步**：

  | 结果 | 文案要点 | 指向的下一步 |
  |---|---|---|
  | 200 | 服务端可达 | 去保存 |
  | 非 200 / 连不上 / 超时 | **地址不通或服务未启动**，并提示检查服务端是否在跑、防火墙是否放行 | 改地址，或找部署的人 |
  | 地址本身不合法 | 由 T1 的校验层拦下，不发起请求 | 改格式 |

  ⚠️ 它**只能证明"地址通、服务在跑"**，证明不了令牌对不对 —— 令牌错是 401，只有真正保存后才会暴露。文案里不要暗示"测试通过 = 能连上"，否则会把人引到错误的结论上。

- [ ] **T7.2** 设置界面加一个「测试连接」按钮，结果显示在按钮旁。**它不阻断保存** —— 也只是个即时反馈，不能变成"不测通就不让保存"（服务端还没部署时测必然不通，那会直接把人锁死）。

### T8 — 真机验收（需人工执行，`flutter run` 在助手 shell 会挂）

- [ ] **T8.0** ⭐ **交付前预检（服务端还没部署也能做，建议最先做）：真机上摄像头权限是不是 App 自己弹出来的。**
  清单里 `<uses-permission CAMERA>` 有，但 `camera_android_camerax` 是在 `initialize()` 里触发申请的。
  **之前所有真机验证都是先 `adb pm grant` 预授权的 —— 等于绕过了这条路径，从没真正验证过弹窗。**
  如果它不弹，使用者就卡在黑屏，而那看起来跟"连不上后端"一模一样。
  做法：`pm revoke` 掉权限 → 冷启动 → 看有没有系统权限对话框。
- [ ] **T8.1** 起后端栈（照 `2026-10-04-android-server-e2e-test.md` 的 Step 0）。
  **服务端由经理部署，地址待定** —— 拿到之后把它作为 `--dart-define=BASE_URL=…` 的默认值编进 APK。
  部署那台机器上要确认三件事：`WEBCAM_LISTEN_ADDR` 默认 `:8080`（监听所有网卡 ✅）、
  **Windows 防火墙放行入站 8080**（最典型的一次性卡点）、手机与它在同一网段。
- [ ] **T8.2** 客户端默认连上 → 设置里把地址改成一个不存在的端口 → 保存 → 状态条应变成 **重连中/链路失败** 并给出原因 → 改回正确地址 → 保存 → 回到 **已连接**，管理面 `GET /api/devices/{id}` 显示 `online: true`。
- [ ] **T8.3** **401 恢复（关键）**：设置里把令牌改错 → 保存 → 出现「设备令牌被拒绝（401）」且**不再重试** → 改回正确令牌 → 保存 → 必须能重新连上。这条不通就说明 T3 的"换实例"没落实。
- [ ] **T8.4** 录制中保存 → 管理面查该 stream 状态应为 `failed`（这是预期行为，不是 bug；界面上有横幅预告过）。
- [ ] **T8.5** Android 明文：填 `http://` 的**局域网 IP**（不是 127.0.0.1，绕开 `adb reverse`）验证。`usesCleartextTraffic="true"` 已开；若后续填 `https://` 需服务端有 TLS，否则会直接连不上 —— 属于部署事项，不是客户端缺陷。
- [ ] **T8.6** 杀进程重启 → 新地址与凭据应仍然生效（验证真的落盘了）。
- [ ] **T8.7** ⭐ **完整走一遍使用者的路径（这才是本次交付的验收标准）**：
  1. `pm revoke` 权限 + 清掉 `shared_prefs`（模拟全新安装）；
  2. 冷启动 → **设置页自动打开**；
  3. 凭据**已经预填**（dart-define 编进去的），**只改 IP 那一栏**；
  4. 点「测试连接」→ 通 → 保存；
  5. 状态条回到 **已连接**；管理面 `GET /api/devices/{id}` 显示 `online: true`；
  6. 杀进程重启 → **不再自动弹设置**，直接连上。

  第 3 步和第 6 步是这次新增的两条：前者验证"预填、可改"，后者验证"只弹一次"。

---

## 五、自检

1. **`load()` 返回 null 的条件**为什么不是"什么都没存"？—— 因为老版本只存了凭据。若那种情况返回非 null，bootstrap 就认为已播种过，`base_url` 永远写不进去，日后改 `BASE_URL` 的编译期默认值会失效。见 T2.1。
2. **为什么重建 gateway 而不是给它加个 setter？** —— 401 会让旧实例进入 `_stopped = true` 的永久终态，加 setter 救不回来；重建顺手解决了。代价是 `BackendGatewayFactory` 要在 5 处构造点（`main.dart` ×1、`test/agent` ×2、`verify_pure` ×3）改签名 —— 比在 6 处 gateway 调用点改签名便宜，而且 `SmartClassBackendGateway` 一行不动。
3. **为什么工厂接收 `ConnectionSettings` 参数而不是捕获外部变量？** —— 捕获写法下"先更新变量 / 先 apply"只有一句之差，写反就造出"用旧地址重连"的幽灵 bug，且不会有任何编译期信号。传参让顺序不可出错。
4. **`_unbindGateway` 为什么必须存在？** —— `reconfigure` 里把 `_started` 置 false 再走 `start()`，`start()` 会重新 `listen` 三条流；不先取消旧的就会重复监听，同一条命令被处理两遍 → ack 发两次。
5. **为什么 `reconfigure` 里走 `start()` 而不是自己连线？** —— 凭据为空时 `start()` 已有"置 failed + 提示"的完整路径。自己写一遍就会出现两条行为不同的分支。
6. **T7 的 healthz 该用哪个拼法？** —— **用 `resolveDevicePath`，和注册同一个拼法**（见变更记录 B）。
   我原先写的是 `base.replace(path: '/healthz')`，理由是"chi 的 router 里 healthz 在根" —— 那是**子进程内部**的视图。
   服务一旦挂在路由前缀下（`deploy.md` 的 `route: prefix: /webcam, strip: true`），
   **外部可见路径整体平移**，`/healthz` 的对外地址变成 `/webcam/healthz`，
   丢掉 base path 就会打到前缀之外 → 404。真机就是这个症状。
7. **为什么自动打开的触发条件是 `load() == null`，不是 `!isProvisioned`？** —— 后者会在凭据被清空后每次启动都弹窗，kiosk 不能这样。前者是"从未配置过"的一次性语义，且保存过一次就永不触发。
8. **为什么地址输入框要关掉 autocorrect？** —— 手机输入法会大写首字母、加空格或"纠正" `http://192.168.1.20:8080`；改过的地址必然连不上，而失败现象跟防火墙挡、令牌错完全一样，无法自查。
9. **为什么「测试连接」不阻断保存？** —— 经理的服务端还没部署，测必然不通。做成硬门槛会在无法改变的事实面前把人锁死。它只是反馈，不是闸门。
10. **为什么建议把凭据也编进这个测试 APK？** —— 手敲 43 字符令牌错一个字符就是 401，而 401 是**永久终态**，界面上不重新保存就永远不重试。编进去让使用者只需改 IP，是消除这一整类失败最省事的办法。
11. **没做的事**：采集参数（fps / 分辨率 / 质量）不进设置界面。它们不是"换个后端就要改"的东西，而且 fps 与分辨率是注册时 announce 的，改动必须连带重建 announcements（T4.4 已标注接入点）。
