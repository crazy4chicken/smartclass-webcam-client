# Handover — 覆盖式更新，勿追加

<!-- 本文件只描述当前状态；历史交给 git log。
先读 `AGENTS.md`（宪法，每次会话全额加载），本文件只讲"现在在哪、下一步、卡在哪"。 -->

## 当前状态

- **git：`a964449`，已推送，与 `origin/master` 一致。最新 tag `v1.1.2` → `9160151`。**
- 门禁 `passed: 1173, failed: 0`；`dart format` 干净（103 文件）；
  `check_compile.py` `compiled: 44, failed: 0`；**`flutter test` 用户跑过，全过**。
- **A 类（纯 Dart）已全部做完**：A1 / A2 / A3 / A4 / A5 / A6 / A7 + A8 的 Dart 侧复核。
  共享 Dart 层（协议、采集抽象、协调器、编码契约、流诊断、速率标定）完成且有断言。
- 关键文件：`lib/src/agent/agent_coordinator.dart`、
  `lib/src/capture/{default_mode,sustained_rate,rate_calibration,encode_budget,annexb,native_video_encoder}.dart`、
  `lib/src/agent/stream_diagnostics.dart`、`tool/verify_pure.dart`。

## 下一步任务

**全部是 B 类：需要用户跑构建 / 真机。助手侧的实质工作已经没了。**

1. **#7** vendor `camera_android_camerax` 0.7.5+1 —— 用户跑 `flutter pub get` + 编 APK
   （十几分钟）。这是临界路径上**用户那一步**。
2. **#12** Android 采集/编码能力验证：Camera2 帧率 range、高速 session 的分辨率与
   use-case 限制、MediaCodec 硬件 HEVC。**只有真机能回答"60fps 在这台设备上可不可能"。**
3. **#13** Android 原生 H.265/H.264 编码流（最大一块，必须真机迭代）。
4. **#14** 跨平台 Dart 适配器与应用启动装配 —— **一半是纯 Dart，助手现在就能做**：
   契约 fake + 验收脚本，照 `tool/e2e/` 的做法。这是"接上就能跑"的那一层。
5. 之后 **Windows**（最短一站：`windows/record_handler.cpp:114` 已有进程内
   Media Foundation H.264，`camera.cpp:1322` 已有逐帧回调）→ **macOS** → **Linux（暂停）**。

助手在 B 类里能做的：把接口、契约、fake 实现、验收脚本写好，让用户接上就能跑。
**没有编译证据的代码不许标完成。**

## 卡点

- **原生编码实现一个都没有**（Android / Windows / macOS 未开始；Linux 写了但
  **一行都没编译过**，且已于 2026-10-10 移出发布矩阵）。
- **没有任何平台实现 `EncodeBudgetProbe`、没有任何平台写 `EncodeEvidence`、
  没有任何平台填 `sourcePts`** → 生产侧 `samples` 恒空，所有设备都声明
  `kFpsWithoutEvidence`(5)。承载字段都已存在，只差平台去填。
  `measureDeliveredRate()` 目前只有门禁在调用；`close()` 无超时兜底。
- **peak-vs-plateau 未定**（ADR §4.1.1，唯一开着的决策）。当前 inert —— 第一个平台
  探针落地才变活。推荐 plateau，理由与代价写在 ADR §4.1.1 补充段与
  `docs/agents/review-2026-10-10-dart-side.md` §4.1。
- **远端 CI 绿不绿看不到**：无 `gh`，`api.github.com` 对当前出口 IP 限流。
- 「声明 60、交付 5–10」是**当前缺口，不是验收豁免**；抹平它只能靠原生编码管线。

## 生效约束（仅本任务范围）

- 不引入新依赖。
- 60fps 相关的任何承诺必须有真机实测数字；**不承诺所有真机必达 60**。
- 段时长的误差方向**从未查证**，别引用旧文档里的倍数；它**不用于计费**，
  影响面是检索 / 展示的时长准确性。
- 改「声明帧率 / 默认模式」必须同时扫 `tool/verify_pure.dart` 与 `test/`（**已踩两次**）。
- 原生端落地后，A8 剩下的「最终 whole-branch 复核」才做得了（要真实样本与打包产物）。
