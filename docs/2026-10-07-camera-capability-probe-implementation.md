# `2026-10-07-camera-capability-probe` 实施报告

> **计划原文**：`docs/superpowers/plans/2026-10-07-camera-capability-probe.md`
> **跨计划总览**：`docs/implementation-status.md`
> **记录时点**：2026-10-08，HEAD `61504e9`
> **验证基线**：`dart run tool/verify_pure.dart` → **598 项断言全绿**；
> `dart format` 干净；类型检查 36 个编译单元干净
> （`lib/main.dart` 为入口传递覆盖整个 `lib/`，外加 34 个 `test/` 文件与 `tool/verify_pure.dart`）。
>
> **后续修订**：偏离 #4（缓存命中跳不过排序）已由后续提交关闭，断言数随之到 **652**
> （37 个编译单元）。§四 的表格里标注了，§九 的验证表也已更新。其余数字仍对应上面那个 HEAD。

---

## 一、结论

**T1–T9 九个任务全部实现，没有未实现的任务。**

| 项 | 数量 |
| --- | --- |
| 计划任务 | 9（T1–T9） |
| 已实现 | **9** |
| 未实现 | **0** |
| 有意偏离计划 | **8 处**（§四） |
| 与计划**明确冲突** | **1 处**（§五，已在 commit message 标注） |
| 计划外的额外修复 | **3 项**（§七，其中 1 项是真机暴露的启动 bug） |
| 计划自己列为 separate plans 的 Deferred | **3 项，均未做**（§八） |

提交链：

```
23e7495  T1  feat(capture): add capability model, common ladder and JPEG size reader
9d2e58f  T2  feat(capture): order cameras rear-then-front by measured ceiling
99f53d0  T3  feat(capture): probe real camera resolutions and frame rates
f88214b  T4  feat(config): cache camera capabilities per camera set
d134bd4  T5  feat(backend): announce supported resolutions and frame rates
01f95c6  T6  feat(protocol): parse switch_camera parameters and start_recording codec
f016887  T7  feat(agent): honour switch_camera parameters and the requested codec
848e29f  T8  feat(app): probe and order camera capabilities on first launch
8be70c7  T9  feat(ui): re-probe camera capabilities from settings
8c2b709  —   docs: the capability probe, the canonical order and the current mode
dbd1135  —   fix(test): the two failures from the first `flutter test` run
61504e9  —   fix(app): the kiosk never started — the gateway factory read the coordinator too early
```

**目标达成情况**（计划 Goal 原文拆解）：

| 计划目标 | 达成 |
| --- | --- |
| 摄像头排成规范顺序（后置 → external → 前置，组内按总像素降序） | ✅ `camera_order.dart` + `CameraPluginBackend` 置换 |
| 测出每个摄像头真能做什么（分辨率 + 帧率） | ✅ `plugin_capability_probe.dart`（每摄像头 6 档 preset + 3 个帧率） |
| 按摄像头集合持久化 | ✅ `capabilities_store.dart`，键 = 有序名字指纹 + enum |
| 注册时声明（`GET /ws/register`） | ✅ `CameraDeclaration` / `buildAnnouncements` |
| 服务端通过 `switch_camera` 参数驱动模式 | ✅ `AgentCoordinator` 的模式状态 + 参数变更后重新注册 |
| 服务端通过 `start_recording.codec` 指定编码 | ✅ 解析 + 校验（今天只有 `mjpeg` 可用） |

---

## 二、逐任务对照

### T1 能力模型 / 常见阶梯 / JPEG 尺寸读取 — ✅

| 项 | 内容 |
| --- | --- |
| 新建 | `lib/src/capture/camera_capabilities.dart`（264 行） |
| 修改 | `lib/src/capture/jpeg.dart`（新增 `jpegSize()`） |
| 测试 | `test/capture/camera_capabilities_test.dart`（新）、`test/capture/jpeg_test.dart`（改） |

计划要求的 11 个能力模型用例 + 3 个 `jpegSize` 用例全部覆盖。`of()` 的去重与按像素降序、
`withCommonBaseline()` 的「以实测上限封顶」、`withCurrent()` 的「始终最后应用」、
`toJson`/`fromJson` 的往返与畸形输入容错均已实现并断言。

`jpegSize` 的实现与计划一致：从 SOI 走标记段、跳过无长度字段的独立标记、
从首个 SOF 读高宽、遇 `SOS` 停止（其后是熵编码数据，再出现帧头只能是内嵌缩略图）。

> **计划外的实现细节**：`C4` / `C8` / `CC` 被显式排除在 SOF 之外 —— 它们是 Huffman 表、
> 扩展段与算术条件段，不是帧头。计划只列了 `0xC0`–`0xCF` 的区间，未点名这三个。

### T2 规范摄像头顺序 — ✅

| 项 | 内容 |
| --- | --- |
| 新建 | `lib/src/capture/camera_order.dart`（115 行，纯）、`lib/src/capture/plugin_camera_ranker.dart`（111 行，插件） |
| 修改 | `lib/src/capture/camera_plugin_backend.dart`（`cameraOrder` 置换）、`camera_service.dart` |
| 测试 | `test/capture/camera_order_test.dart`（新）、`test/capture/plugin_camera_ranker_test.dart`（新） |

计划要求的 10 个排序用例 + 3 个 ranker 用例全部覆盖，另加「结果永远是输入下标的置换」
这一性质断言（计划 Step 1 里也有）。

签名与计划完全一致：

```dart
enum CameraGroup { back, external, front }
CameraGroup cameraGroupFor(String lensDirectionName);
class RankedCamera { final int index; final CameraGroup group; final int maxPixels; }
List<int> canonicalCameraOrder(List<RankedCamera> cameras);
abstract interface class CameraRanker { Future<List<RankedCamera>> rank(...); }
```

`CameraPluginBackend({... List<int>? cameraOrder})` 与计划一致（null = 恒等）。
Windows（全 `front`）/ Linux（全 `external`）退化为纯分辨率序这一点，
在 `CameraGroup` 的文档注释里写明，并有专门的断言与测试。

> **计划外的加固**：传进来的 `cameraOrder` 若不是真正的置换（长度不符 / 越界 / 有重复），
> **整体丢弃回落到恒等**，而不是部分采纳。部分采纳会让两个 announced enum 指向同一个物理
> 摄像头，且没有任何编译期或运行期信号。

### T3 能力探测 — ✅

| 项 | 内容 |
| --- | --- |
| 新建 | `lib/src/capture/capability_probe.dart`（53 行，纯契约）、`lib/src/capture/plugin_capability_probe.dart`（213 行，实现） |
| 修改 | `test/support/doubles.dart`（新增 `FakeCameraController` / `FakeFrameStore`） |
| 测试 | `test/capture/plugin_capability_probe_test.dart`（新） |

计划要求的 9 个用例全部覆盖。`kProbePresets`（6 档）、`kProbeFramerates = [60, 30, 15]`、
`CapabilityProbeResult`、`ProbeControllerFactory(description, preset, fps)`、
`CapabilityProbe.probe(int physicalCameraIndex)` 均与计划逐字一致。

「每个 preset 各自 try/catch」与「探测永不抛出」两条硬要求都有断言钉住。

> **计划外的实现细节**：`CameraController` 的构造函数**不碰任何 platform channel**
> （它 `extends ValueNotifier<CameraValue>`），所以测试替身只要 `override initialize()`
> 再写 `value` 即可，不需要 `CameraPlatform` 替身。但 `CameraValue` 的构造函数带私有参数
> `_isRecordingPaused`，外部构造不了 —— 用公开的 `copyWith`。这条写进了
> `test/support/doubles.dart` 的注释。

### T4 能力持久化 — ✅（2 处有意偏离）

| 项 | 内容 |
| --- | --- |
| 新建 | `lib/src/config/capabilities_store.dart`（54 行，纯）、`lib/src/config/shared_prefs_capabilities_store.dart`（75 行） |
| 测试 | `test/config/capabilities_store_test.dart`（新） |

`cameraFingerprint(List<String>)` 与 `CapabilitiesStore` 接口签名与计划一致。
计划要求的 8 个用例全部覆盖，其中「save 不碰已存的设备凭据」是**回归守卫**
（见 `95ca378`：设置播种曾把真机上的凭据删掉）。

两处偏离见 §四 #1、#2（单键 vs 双键；解析失败返回 null vs 空能力）。

### T5 声明 supported 列表 — ✅

| 项 | 内容 |
| --- | --- |
| 修改 | `lib/src/backend/registration_request.dart` |
| 测试 | `test/backend/registration_request_test.dart`（重写）、`test/support/doubles.dart` |

`CameraDeclaration` 与新的 `buildAnnouncements({cameras, codecs, attrs})` 与计划一致。
`CameraAnnouncement` 新增 `supportedResolutions` / `supportedFramerates`，
`toJson()` 输出 `supported_resolutions`（label 串）/ `supported_framerates`（int）。

计划要求的 7 个用例全部覆盖。`withCommonBaseline()` → `withCurrent()` 的**顺序**、
空列表退化为「当前这一对」、`minAnnounceableFps` 钳制、空 codec 回落 `mjpeg` 均保留。

> **计划外的实现细节**：`minAnnounceableFps` 现在定义为采集层的
> `kMinDeclaredFramerate`，不再是第二个字面量 —— 这个函数同时钳制 `fps` 字段**和**声明列表，
> 两者不一致正好就是它要避免的那个 `400`。

### T6 新命令参数 — ✅（1 处与计划冲突）

| 项 | 内容 |
| --- | --- |
| 修改 | `lib/src/backend/protocol/device_command.dart`、`lib/src/backend/protocol/envelope.dart` |
| 测试 | `test/backend/protocol/envelope_test.dart`（改） |

`SwitchCameraCommand.resolution/fps`、`StartRecordingCommand.codec` 与计划一致；
`CaptureCodec.tryParse` 直接复用（`hevc` 被拒，不别名）；`fps` 接受 JSON 分数并截断。

计划要求的 6 个用例全部覆盖。

> ⚠️ **这一任务与计划的 Global Constraint 明确冲突**，见 §五。

### T7 协调器模式状态 — ✅

| 项 | 内容 |
| --- | --- |
| 修改 | `lib/src/agent/agent_coordinator.dart`、`lib/src/capture/camera_capabilities.dart`（新增 `CameraMode`、`declaredCapabilities()`） |
| 测试 | `test/agent/agent_coordinator_test.dart`（改）、`test/support/doubles.dart` |

`CameraMode`（`{resolution, fps}`）与 `List<CameraMode> _modes` 按 **announced enum** 索引，
与计划一致。计划要求的 10 个用例全部覆盖。

- 校验走 `declaredCapabilities()` —— **注册与 `switch_camera` 校验共用同一个函数**，
  所以「设备接受的」在构造上就等于「它公布过的」。
- 改分辨率 → 真的 `camera.reconfigure()`；改帧率 → 更新声明帧率。
  「ack ok」与「真的那么采」是同一句话。
- 改参数 → 走 `reconfigure()` 重新注册（不另开一条重连路径）；只切摄像头 / 校验失败 → 不重连。
- codec 检查用 `CaptureCodec.isIntraOnly` 而非「在声明列表里」（偏离 #6）。
- `reportStatus()` 现在带上当前几何（`switch_camera` 服务端不落状态，
  周期 status 是运营侧唯一能看到当前模式的地方）。
- 保留「流活着时拒绝切摄像头」。

### T8 启动探测与装配 — ✅（1 处有意偏离 + 1 处签名调整）

| 项 | 内容 |
| --- | --- |
| 新建 | `lib/src/app/capability_bootstrap.dart`（213 行）、`lib/src/ui/screens/bootstrap_screen.dart`（156 行） |
| 修改 | `lib/main.dart`、`tool/verify_pure.dart` |
| 测试 | `test/app/capability_bootstrap_test.dart`（新）、`test/ui/bootstrap_screen_test.dart`（新） |

计划要求的 7 个编排用例 + 3 个屏幕用例全部覆盖，另加计划未列但必要的：
重复摄像头名、ranker 抛异常、ranker 返回非置换、缓存命中的写入行为。

`runApp` 只调一次，根组件先渲染 `BootstrapScreen`、`ensureInventory` 完成后换入 kiosk —— 与计划一致。

三处偏离/调整见 §四 #3、#4、#5、#8。

### T9 手动重新检测 — ✅

| 项 | 内容 |
| --- | --- |
| 修改 | `lib/src/ui/screens/settings_screen.dart`、`lib/src/ui/screens/agent_screen.dart`、`AgentCoordinator.adoptInventory()` |
| 测试 | `test/ui/settings_screen_test.dart`（改） |

「重新检测」按钮（key `settings-refresh-capabilities`）、录制中禁用、结果文字
（key `settings-refresh-result`）均按计划实现。计划要求的 5 个用例全部覆盖。

> **计划外，但写断言时抓到的一个真 bug**：`adoptInventory` 最初直接 `start()`，
> 而摄像头清单是在**构造 gateway 时烘进去的** —— 在同一个实例上重新注册只会把旧清单
> **再发一遍**，新测出的能力被缓存、却永远不会被公布。改成走 `reconfigure()`（重建实例）。
> 断言 `factory.built.length` 从 1 变 2 才抓住它。见 §七。

---

## 三、计划步骤中本机无法执行的部分

计划的每个任务都是 TDD 循环：**Step 1 写失败测试 → Step 2 跑 `flutter test` 期望失败 →
实现 → Step N 跑 `flutter test` 期望 PASS → commit**。

**Step 2 与 Step N 这两类共 18 步，在本机一次都没能执行。**
本机 shell 里 Dart VM 创建不了子进程（`All pipe instances are busy`），
`flutter test` / `flutter run` / `flutter analyze` 全部挂死。可用替代：

| 层 | 工具 | 结果 |
| --- | --- | --- |
| 纯 Dart 断言 | `dart run tool/verify_pure.dart` | ✅ 598 项全绿（**唯一能执行**的验证层） |
| 全量类型检查 | Python 驱动 `frontend_server_aot.dart.snapshot` 单次编译 | ✅ 36 个编译单元干净 |
| 语法/格式闸门 | `dart format --output=none --set-exit-if-changed lib test tool` | ✅ 干净 |
| `flutter test` | —— | ⚠️ 本机跑不了 |

因此**不是严格的 red-green TDD**：测试与实现是一起写的，靠类型检查 + harness 镜像
来发现错误，然后由用户在 CI/本机跑了一次 `flutter test`（结果 `+333 -2`，两个失败已修，见 §七）。

> **代价已经出现过一次**：那两个失败正是「跑不了的层」里的断言写错了 ——
> 一个是非法 JSON 字面量，一个是忘了 `withCommonBaseline()` 会并进常见阶梯。
> 教训已写进 `CONVENTIONS.md`：**跑不了的测试层，要把它最脆的断言镜像到跑得动的那一层。**

---

## 四、8 处有意偏离计划

| # | 计划写的 | 实际做的 | 为什么 |
| --- | --- | --- | --- |
| 1 | T4：**两个键** `camera_capabilities_fingerprint` + `camera_capabilities_json` | **一个键 `camera_capabilities`**，存一个 JSON 对象 | `SharedPreferences.setString` 是**整份重写**，两次调用就是两次写盘，中间掉电会留下「新指纹 + 旧能力」—— 正是双键布局要防的错配。合成一个对象才真的原子。 |
| 2 | T4：解析失败返回**空能力** | 返回 **null（= 重探）** | 空会让设备永远只声明「我正在用的那一对」并且**不再刷新**（命中一直在）。null 能自愈。 |
| 3 | T2：`CameraRanker` 接口放在 `plugin_camera_ranker.dart` | 接口放在纯的 `camera_order.dart` | `ensureInventory` 要编排排序，必须保持 Flutter-free 才能在 harness 里跑 —— 而编排逻辑（缓存命中、退化、排序失败回退）恰恰最值得跑。同样处理了 `CapabilityProbe` 与 `CameraEnumerator`。 |
| 4 | T8：缓存命中「skips **both** the ranking and the probe」 | ~~跳不过排序~~ → **已按计划实现**（见下方补充） | 首版实现里缓存键是**有序**摄像头集合，而顺序正是排序那趟的产出 —— 排序之前没有可用的键，所以只省了探测。**这条偏离已关闭**：改成对**无序**集合指纹化，并把规范顺序作为缓存内容的一部分存下来，命中时按名字映射回当前枚举顺序、重新算出置换。现在命中确实一次开合都没有。 |
| 5 | T8：指纹 = 有序摄像头名 | **有序名字 + enum**（`<setFingerprint>#<cameraEnum>`） | 两台同型号 USB 摄像头在 Windows 上**枚举出同一个名字**，只用名字会让 1 号拿到 0 号的能力。这不是假设，是教室里的常见配置。 |
| 6 | T7：codec 检查 = 是否在 `supported_codec` 里 | 用 `CaptureCodec.isIntraOnly` | 帧泵每帧都是一张自包含的图，需要帧间状态的 codec 根本编不出来。**声明是主张，错误的主张不能让设备 ack 一个它做不到的事。** |
| 7 | T6：绝不静默忽略被请求的 codec / 分辨率 | `resolution` / `fps` / `codec` 一律**宽松解析成 null** | 拒绝 payload 会让命令**消失** → 协调器看不到 → **永远不 ack**，而服务端不重试 —— 运营侧只看到一个毫无反应的命令。**能用但设备做不到**的值仍然 `ok:false` 拒绝，那才是协议真正要防的。见 §五。 |
| 8 | T8：`ensureInventory({required CameraLister listCameras, …})` | `required CameraEnumerator enumerate` | `CameraLister` 是 `Future<List<CameraDescription>> Function()`，而 `CameraDescription` 来自 `package:camera` —— 用它会让 `capability_bootstrap.dart` 不再是纯 Dart，与 T8 Step 6「新纯文件要被 `tool/verify_pure.dart` 覆盖」直接矛盾。改成返回领域模型 `CameraDescriptor` 的 `CameraEnumerator`，插件侧由 `pluginCameraEnumerator()` 适配。连带 `CameraInventory` 多了 `order` 字段（announced enum → physical index），因为 `descriptors` 刻意不暴露物理下标。 |

---

## 五、与计划明确冲突的 1 处（T6）

计划的 Global Constraints 写着：

> Every command carrying an `id` is acked. **Silently ignoring a requested codec or resolution
> is forbidden**: ack `ok:false` with `error`.

而 T6 Step 4 对 codec 的指示是：

> read `payload['codec']` through `CaptureCodec.tryParse`, so **an unrecognised name yields
> `null` instead of an exception**.

这两条在「无法识别的值」上是相反的。**实际选择：按 T6 Step 4 的明确指示做，
并把同一条规则应用到 `resolution` / `fps`。**

理由：拒绝整个 payload 会让 `parseDeviceCommand` 返回 null → **协调器根本看不到这条命令
→ 永远不会 ack**，而服务端不重试 —— 运营侧只看到一个毫无反应的 `switch_camera`，
这正是那条约束要排除的结果。对 codec 采取一条规则、对 `resolution` 采取相反规则，
比统一任何一边都糟。

**边界是清楚的**：解析不出字符串（版本不匹配 / 服务端 bug）→ 当作「没要求」，
命令本身仍然执行；**能解析但设备做不到**（未声明的分辨率 / 不可用的 codec）
→ 仍然 `ok:false` 拒绝，绝不影响「不许 apply-and-pretend」这条真正的红线。

这一处**写在 `01f95c6` 的 commit message 里**，没有偷偷选边。

---

## 六、计划文件里的 `- [ ]` 为什么一个都没勾

该计划共 **57 个 `- [ ]`**，勾选数 **0**。

这是有意的：计划是**一次性执行**的，而其中 18 步是「跑 `flutter test` 期望 PASS」
这类**本机无法执行**的步骤。逐个勾选会把它们标成「已完成」，反而不准。
**执行状态以本文档与 `docs/implementation-status.md` 为准。**

---

## 七、计划外的额外修复

这三项都不是计划要求的，是执行过程中暴露出来的真问题。

### 1. `dbd1135` — 首轮 `flutter test` 的两个失败（都是我的测试期望写错）

- **裸 TAB 让整个 JSON frame 非法。** 用例把 `'\t'` 直接插进 JSON 字符串。JSON 不允许
  字符串里有裸控制字符（RFC 8259 要求 U+0000–U+001F 转义），`jsonDecode` 严格执行 →
  **整个 frame 被拒** → `parseDeviceCommand` 返回 null → 测试里的 `!` 抛
  `Null check operator used on a null value`。它**根本没走到空白规则那一步**。
  → 症状读起来像「解析器把我的命令丢了」，其实是「我拼了非法 JSON」。
  现在 harness 里两个方向都钉住。
- **断言的帧率列表忘了阶梯。** 断言 `supportedFramerates == [30]`，实际是
  `[60, 50, 30, 25, 24, 20, 15, 10, 5]` —— `withCommonBaseline()` 会并进常见阶梯，
  那正是它的全部意义。该用例的名字是「重复项只报一次」，所以改成测**去重性质**。

`tool/verify_pure.dart` 586 → 589。

### 2. `61504e9` — 真机卡在 splash 页（**我引入的构造环**）

用户报告：Android 版停在「检测到两个摄像头」页面不动。不崩、不打日志。

根因：`AgentCoordinator` **在自己的构造函数里调用 gateway 工厂**，而工厂里
`_declarations(currentInventory, coordinator, …)` 是**急切求值**的 —— 读了一个还没赋值的
`late final coordinator` → `LateInitializationError`。它从 `_startKiosk` 抛出，
而 `BootstrapRoot._onInventory` 的 `await` **没有任何错误处理** → `setState` 永远不跑
→ splash 永远挂着。

> **为什么看起来像成功**：错抛在 await 链里，所以不崩、不打日志；而探针**已经成功跑完**，
> 所以最后一行是「检测到两个摄像头」。

三处修复：

1. **`SmartClassBackendGateway.cameras` 从 `List` 改成 `List<CameraAnnouncement> Function()`**，
   **注册时才读**。既符合语义（列表是注册那一刻才发布的），又直接解掉构造环。
2. **`BootstrapRoot` 不再吞掉启动失败** —— 捕获、打栈、渲染失败页 + 重试按钮。
   **真正的教训不是那个异常，而是「起不来的设备看起来像起来了」**，且没有任何可诊断信息。
3. 把 `_startKiosk` 里**每一处** `coordinator` 引用过了一遍：`statusReport` 与
   `pumpFactory` 本来就是闭包（安全），`LifecycleController(onPause: coordinator.pause)`
   在赋值**之后**（安全）。只有 `cameras:` 那一处是急切的。

### 3. T9 的 `adoptInventory` 改走 `reconfigure()`（见 §二 T9）

摄像头清单是在**构造 gateway 时**烘进去的，所以在同一个实例上重新注册只会把旧清单再发一遍。
最初写成 `start()`，断言 `factory.built.length` 从 1 变 2 才抓住它。

### 4. 用户报「每次启动都在检测分辨率」→ 能力缓存**只存了最后一个摄像头**

用户第二次报同一个问题时才挖到底：缓存**看起来**在工作（有 save、有 load），
但**双摄设备上 0 号摄像头每次启动都未命中**。

根因是两半各自都对、合起来错：`ensureInventory` **按摄像头逐个 `save()`**（key =
`<集合指纹>#<enum>`），而 `SharedPrefsCapabilitiesStore` **只维护一个 entry**。
于是第二个摄像头的 save 覆盖了第一个，下次启动 `load(key0)` 指纹不匹配 → 未命中 → 重探。

**修法**：整个摄像头集合变成**一个值**（`CachedCapabilities{order, byEnum}`），
一次 save 写完整套 —— 那种表示法从此不存在。同时把**规范顺序**也存进缓存，
命中时按名字映射回当前枚举、重算置换，于是**缓存命中真的零开合**（排序那趟也省掉了），
偏离 #4 随之关闭。

顺带修掉一个健壮性问题：`_fromCache` 的异常现在被当作**未命中**而不是向上抛 ——
启动路径上，一份坏缓存绝不能让设备起不来。

**这一条为什么会漏过去**：harness 和 widget test 用的都是 `Map` 替身，
天然支持多 entry；只有真的 `shared_preferences` 实现是单 entry。
**测试替身和真实现的语义差一点，bug 就整个藏进去了。**
补的回归断言跑在 `SharedPrefsCapabilitiesStore` 上，不是替身上。

---

## 八、没有实现的

### 计划自己列为 separate plans 的 Deferred —— **3 项，均未做**

| 项 | 内容 | 为什么这次不做 |
| --- | --- | --- |
| **原生编码管线** | fork/vend `camera_desktop`，在同进程的 GStreamer / Media Foundation 管线里编码，只有压缩字节跨进 Dart | 需要先有编码器（下一项）；这是一条独立的采集管线 |
| **H.264 / H.265** | 原生层接 ffmpeg（x264/x265 的 GPL 构建，或仅 H.264 的 `libopenh264`），硬件编码器作为同一 `NativeEncoder` 接口后的第二后端 | 计划 Global Constraint 明确写「out of scope here」；接入点已留 `VideoEncoder` / `CodecProbe` |
| **无磁盘帧通路** | 让原始帧不进 Dart，也不落盘 | 依赖上面两条；在此之前 `TakePictureFrameSource` 保持原位 |

### 计划内的「有意不做」

| 项 | 说明 |
| --- | --- |
| 采集参数（fps / 分辨率 / 质量）**进设置界面** | 不在计划范围内；它们是注册时 announce 的，改动必须连带重建 announcements。本次以另一种方式补齐了：服务端现在可以通过 `switch_camera` 参数驱动模式 |
| 探测时写临时 JPEG | 计划明确接受（`takePicture()`），只在 bootstrap 跑几次，不在帧通路上 |
| 声明 H.264 / H.265 | 今天编不出来就不许声明。`supported_codec` 仍是 `["mjpeg"]`，请求别的 codec 一律 `ok:false` |

---

## 九、验证到什么程度

| 层 | 状态 | 说明 |
| --- | --- | --- |
| `dart run tool/verify_pure.dart` | ✅ **598 项断言全绿**（后续修订后 **652**） | 本机**唯一能执行**的验证层 |
| `dart format` 闸门 | ✅ 干净 | `--output=none --set-exit-if-changed lib test tool` |
| 全量类型检查 | ✅ 干净 | 36 个编译单元：`lib/main.dart`（传递覆盖全部 `lib/`）+ 34 个 `test/` 文件 + `tool/verify_pure.dart` |
| `flutter test` | ⚠️ **本机跑不了** | 最后运行 `+333 -2`；两个失败已在 `dbd1135` 修掉并镜像进 harness，**修后未再跑** |
| 真机 · Android | ⚠️ 部分 | 基础链路跑通过一整轮（另一个计划）。**能力探测（T8/T9）未在真机验过**；`61504e9` 的 kiosk 修复待重出包确认 |

### 变异测试（「断言有牙」的证据）

关键回归断言都做过**变异测试** —— 把代码改回 bug 版本，确认断言真的会红：

| 变异 | 挂掉条数 |
| --- | --- |
| 参数变更后不重新注册 | 2 |
| 跳过 `camera.reconfigure()` | 2 |
| 跳过分辨率校验 | 1 |
| 启动时不读能力缓存 | 2 |
| 保留枚举顺序（不做规范排序） | 5 |
| 跳过探测失败的退化 | 3 |
| `adoptInventory` 改回 `start()` | 5 |
| `adoptInventory` 不先释放摄像头 | 1 |
| gateway 改回构造时读摄像头清单 | 2 |
| 缓存顺序按位置套用（不按名字匹配） | 7 |
| 指纹重新变成顺序敏感（去掉排序） | 7 |
| 缓存载荷的两半长度不一致仍被接受（同时弱化 `isEmpty`） | 1 |

> 有一条变异是**等价变异**，值得记下来：去掉 `_fromCache` 里「名字找不到就返回 null」
> 那道守卫，行为**不变** —— 因为 `removeAt(-1)` 会抛，而 `ensureInventory` 现在把
> `_fromCache` 的异常也当作未命中（见下）。两道防线都通向"重探"，所以没有可观察差异。
> 守卫仍然保留：让控制流走显式分支，而不是靠异常。

---

## 十、下一步 / 未验证

1. **`flutter test` 在 `dbd1135` 之后没有重跑。** 这是当前最该做的一步 ——
   它也是 CI 的 `verify` job 第一次真跑的入口。本机跑不了。
2. **能力探测的真机验收未做**（T8/T9）。重点两条：
   - 插拔一个摄像头 → 点「重新检测」→ 摄像头顺序与声明列表应随之改变；
   - `switch_camera` 带 `resolution` / `fps` 时，服务端 `metadata` 快照应跟着更新
     （这需要重新注册，已实现但未验）。
3. **`61504e9` 的 kiosk 修复需重新出 Android 包确认。** 若仍有问题，
   现在 splash 上会直接显示失败原因（不再是无声卡住）。
4. 三个 Deferred 项需要各自的计划。
