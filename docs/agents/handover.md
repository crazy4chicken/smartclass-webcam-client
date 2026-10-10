# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：`793a418`（`feat(capture): assemble the start-up path from evidence, not from claims`），
  ⚠️ 尚未推送 —— 需要用户 `git push`。** 上一个远端一致点是 `2117dcc`。
- 门禁 `passed: 1216, failed: 0`（上一轮 1173，本轮 +43）；`dart format` 干净（105 文件）；
  `check_compile.py` `compiled: 45, failed: 0`。
- **`flutter test` 本轮还没跑**（改了 `lib/` 的公开形状：协调器构造参数、`adoptInventory`
  参数、`main.dart` 装配）→ **请用户跑一次**。助手跑不了，只做到「类型检查通过」。
- **#14 的 Dart 侧做完了**（启动装配，见下）；**#14 的插件事件桥接那一半仍待办**，要等原生侧。
- A 类（纯 Dart）此前已全部完成；B 类（要真机/构建）仍全在用户那一步。

## 本轮做了什么（#14 Dart 侧）

新增 `lib/src/app/capture_bootstrap.dart`（Flutter-free，门禁直接跑）：

- `ensureEncodeEvidence()` —— 命中缓存就不测；**没有探针就不测、也不写缓存**（"没问过"≠"测过为零"）；
  探针抛错、或答的是别的摄像头/编码器 → 空证据，**不把别人的速率当成自己的**。
- `announcedCodecsFor()` —— **公告 = 平台声称 ∩ 实测**，且实测**按模式**判定
  （`canServeMode`），所以「H.265 在 30 可用」永远不会变成「1080p60 可用」。永不返回空列表。
- `planCapture()` —— **几何（来自 inventory）→ 在该几何上实测 → 声明帧率（来自实测）→ 公告
  codec（两者都要）**，一条顺序。
- `claimedCodecs()` —— 「声称集合」的唯一定义，探针问什么、播种模式用什么、能发什么，三处同源。

`main.dart`：按这条顺序装配（plan → 开管线 → 同源注册）；「重新检测」强制重测后重 plan 再
`adoptInventory`；gateway 的 codec 列表改成**每次注册时**按 `coordinator.activeMode` 重算
（`switch_camera` 走 `_reregister` → 「切模式 → 重算 → 注册」自然成立）。协调器新增
`codecCandidates`，`adoptInventory` 新增 `encodeSamples`/`announcedCodecs`。

**今天行为逐字不变**：没有任何平台实现 `EncodeBudgetProbe`，`main.dart` 传 `probe: null`
→ 计划恒为 `mjpeg` @ `kFpsWithoutEvidence`。不支持原生编码的平台照旧预览 / 照片 / mjpeg 流。

门禁新增 `tool/verify_capture_bootstrap.dart`（+43 条）；**8 个变异全部变红**
（详见 `docs/implementation-status.md` 的变异表）。

## 下一步任务

**全部是 B 类：需要用户跑构建 / 真机。助手侧的实质工作仍然没有。**

1. **#7** vendor `camera_android_camerax` 0.7.5+1 —— 用户 `flutter pub get` + 编 APK。
2. **#12** Android 采集/编码能力验证（Camera2 帧率 range、高速 session、MediaCodec HEVC）。
3. **#13** Android native H.265/H.264 编码流（最大一块）。
4. **#14 剩下的那一半**：插件事件统一通道（不重复注册 method handler）+ fake 接口与
   Flutter bridge 分层测 —— **要等 #13 才有东西可接**。
5. **第一个 `EncodeBudgetProbe` 实现**：`main.dart` 里 `probe: null` 是**唯一**的插入点；
   接上它，声明帧率、公告 codec 与默认模式会一起动（这是设计目标，不是巧合）。
6. 之后 Windows（`windows/record_handler.cpp:114` 已有进程内 MF H.264）→ macOS → Linux（暂停）。

## 卡点

- **原生编码实现一个都没有**（Android / Windows / macOS 未开始；Linux 写了但一行都没编译过，
  且已移出发布矩阵）。
- **没有任何平台实现 `EncodeBudgetProbe`** → `samples` 恒空 → 所有设备声明
  `kFpsWithoutEvidence`(5)、只公告 `mjpeg`。承载字段与装配都齐了，只差平台去填。
  没有任何平台填 `sourcePts`；`close()` 无超时兜底。
- **peak-vs-plateau 未定**（ADR §4.1.1，唯一开着的决策）。当前 inert。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。

## 生效约束（仅本任务范围）

- 不引入新依赖。
- **`main.dart` 与插件层助手跑不了**：改完只能靠 `check_compile.py`（只编译不运行）+
  用户 `flutter test`。别声称跑过。
- 60fps 相关的任何承诺必须有真机实测数字；**不承诺所有真机必达 60**。
- 段时长的误差方向**从未查证**，别引用旧文档里的倍数；它**不用于计费**。
- 改「声明帧率 / 默认模式 / 公告 codec」必须同时扫 `tool/` 与 `test/`（**已踩两次**）。
- 原生端落地后，A8 剩下的「最终 whole-branch 复核」才做得了。
