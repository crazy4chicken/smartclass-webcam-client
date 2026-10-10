# 发布（GitHub Actions）

两个工作流：

- **`.github/workflows/ci.yml`** —— 每次分支 push 和每个 PR，只跑 gate（见下）。
- **`.github/workflows/release.yml`** —— 推 tag 时跑同样的 gate，然后三端并行出包。

**iOS 与 Linux 不参与**（原因见「为什么没有 iOS」与「为什么没有 Linux」两节）。

> **2026-10-10 变更：Linux 已从 release 工作流移除**（用户要求）。Linux 原生采集一直处于暂停、
> **一行都没编译过**（`docs/linux-encoded-stream-status.md`），把一个 Linux 包发出去等于宣传一个
> 本项目并不声称交付的平台。`linux/` 源码留在仓库里，`flutter build linux` 仍是本地冒烟的方式，
> 只是不再随 tag 发布。

## 产出

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Windows x64 | `webcam_client-<版本>-windows-x64.zip` | `build/windows/x64/runner/Release/` 整个目录 |
| macOS（通用二进制） | `webcam_client-<版本>-macos.zip` | `webcam_client.app` + README |
| Android | `webcam_client-<版本>-android-<abi>.apk` | 按 ABI 拆分的三个 APK |

版本号来自 tag（`v1.0.0` → `1.0.0`），build number 用 `github.run_number`。

## 怎么发一版

```bash
git tag v1.0.0
git push origin v1.0.0
```

推 tag 会：跑测试 → 三个平台并行构建 → 建一个 GitHub Release 并附上全部产物。

**只想验证流水线**：Actions → Release → Run workflow。
手动触发**不会**建 Release，产物只留在那次运行的页面上（可下载），
所以随便跑不会污染 Releases 列表。

## 前置：一个 gate

`verify` job 按顺序跑四件事，全绿才开始构建。任何一项挂了，三个平台都不会出包 ——
这是有意的，但如果你确实要在测试红的情况下出包，把 `build.needs: verify` 删掉即可。

| 步骤 | 命令 | 为什么 |
| --- | --- | --- |
| Formatting | `dart format --output=none --set-exit-if-changed lib test tool` | 项目本来就要求每个提交都过；交给 CI 就不用人眼盯 |
| Analyze | `flutter analyze --no-fatal-infos --no-fatal-warnings` | **只卡 error**，见下 |
| Pure Dart harness | `dart run tool/verify_pure.dart` | 断言数以实跑输出为准 |
| Widget and unit tests | `flutter test` | `test/` 下全部 |

**`flutter analyze` 为什么带那两个 flag**：这台机器上从来没跑过 analyzer（助手 shell 跑不了），
所以 `flutter_lints` 报的 info / warning 里必然有大量早于任何一次改动的历史项。
让它们卡构建，等于让这条流水线从第一天起就是红的 —— 而没人看的红灯等于没有红灯。
**历史项清完之后把两个 flag 去掉**，它就变成完整的 analyzer 闸门。

只卡 error 也已经值回票价：`flutter test` 只编译测试能触及的文件，
一个没人 import 的坏文件只能在这里（或者晚得多的 `flutter build` 里）被发现。

`flutter test` 会自动带上 `test/` 下的新文件，所以新增测试**不需要动流水线**；
`tool/verify_pure.dart` 同理。流水线里写死的路径只有三处：`lib test tool`（format）、
`tool/verify_pure.dart`、以及 `flutter test` 的默认范围。

## 分支 / PR 也要跑同样的 gate

`.github/workflows/ci.yml` 在**每次分支 push 和每个 PR** 上跑与上面**完全相同**的四步
（触发器 `push: branches: ['**']` + `pull_request`；`concurrency` 取消同分支的旧运行）。

**为什么不能只靠 release 那个 gate**：发布是推 tag 触发的，而 tag 可以指向一个从未经过 PR 的
提交 —— 所以 release 侧不能假设 CI 已经过了，两边都得跑。

**为什么必须有它**：`dart run tool/verify_pure.dart` 只覆盖纯 Dart 那一半，**它看不见 `test/`**
（那些文件 import `package:flutter`，要引擎，要 runner）。`test/agent/agent_coordinator_test.dart`
里曾经有三条陈旧断言在本地门禁全绿的情况下活了下来，直到用户手动跑 `flutter test` 才炸出来。
这个 workflow 存在的意义就是让陈旧断言**在这里红**，而不是在某个人的终端上红。

两个 workflow 的 `verify` 步骤列表**故意逐字相同**，各自在注释里点名对方，
改一个就要改另一个。这是本文档里唯一一处刻意重复：GitHub Actions 里让 workflow 共享步骤需要
`workflow_call`，而它会引入跨文件调用语义（`env` 是否继承、`concurrency` / `permissions`
各自怎么算都要重新确认），代价大于 7 行重复。**`FLUTTER_VERSION` 同样有两份，必须同步**
（它对应 `.metadata` 里记录的 revision）。

## 可选：Android 正式签名

**不配也能跑**，产物会用 debug key 签名 —— 能装，但**不能上架 Play**。
要出可上架的 APK，在仓库 Settings → Secrets and variables → Actions 里加四个 secret：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 base64：`base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 口令 |
| `ANDROID_KEY_ALIAS` | key 别名 |
| `ANDROID_KEY_PASSWORD` | key 口令 |

工作流会把它还原成 `android/app/release.keystore` 并写 `android/key.properties`
（该文件已在 `.gitignore` 里）。`android/app/build.gradle.kts` 检测到它就切到正式签名，
否则回落到 debug —— **不会因为缺证书而构建失败**。

生成 keystore：

```bash
keytool -genkeypair -v -keystore release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias webcam
base64 -w0 release.jks    # 贴进 ANDROID_KEYSTORE_BASE64
```

## 运行环境要求

产物**不捆绑**系统库，目标机器上要有：

- **Windows / macOS**：无额外依赖，但见下面的签名说明。
- **Android**：无。`usesCleartextTraffic="true"` 已开，明文 `http://` 后端可直接用。

（**Linux** 曾需要 GStreamer：`sudo apt install libgstreamer1.0-0
libgstreamer-plugins-base1.0-0 gstreamer1.0-plugins-good`。Linux 不再随 tag 发布，
但本地 `flutter build linux` 跑起来时仍然需要这些。）

## 已知限制

- **macOS 产物未签名 / 未公证**：Gatekeeper 会拦第一次启动。
  右键 → 打开，或 `xattr -dr com.apple.quarantine webcam_client.app`。
  要真正分发得配 Apple Developer 证书 + `notarytool`，目前没做。
- **Windows 产物未签名**：SmartScreen 会提示。
- **Android 默认 debug 签名**：见上面「可选：Android 正式签名」。

## 为什么没有 iOS

**iOS 构建需要付费 Apple Developer 账号的签名证书和 provisioning profile**，
没有它们 `flutter build ios` 产出不了任何可安装的东西。
`ios/` 目录保留在仓库里（工程配置、`Info.plist` 的相机权限说明都在），
只是不在 CI 里构建。

真要做的话，需要：macOS runner + `apple-actions/import-codesign-certs` 导入
`.p12` + `xcodebuild` 用 profile 打包 + 导出 `ipa`，再加 `app-store-connect` 上传。
这一整套依赖账号和证书，不适合放在"推个 tag 就出包"的默认流水线里。

## 为什么没有 Linux

**2026-10-10 移除，用户要求。** 理由不是"编不出来"，而是**不能声称交付**：

- Linux 的原生编码分支一直处于**暂停**状态，`packages/camera_desktop/linux/**` 那批 C++
  **一行都没有编译过**（本机缺 GStreamer / GTK / `flutter_linux` 头文件）。
  详见 `docs/linux-encoded-stream-status.md`。
- 一个能下载、能安装的 Linux 包会被当成"这个平台支持"，而设备要交付的 1080p60 编码流
  在 Linux 上根本没有实现 —— 发出去就是**用产物替未验证的代码背书**。

**代码没删，构建方式也没变**：`linux/` 源码留在仓库里，本地 `flutter build linux`
仍是将来验它时的第一件事；只是**不再随 tag 发布**。

**要加回来**：`build.matrix` 加一条 Linux 条目 + 两个 Linux-only 步骤
（`Install Linux dependencies`、`Package (Linux)`）+ 把 `-linux-x64.tar.gz` 放回
release job 的完整性校验列表 + 更新本文件与 release notes。别只加矩阵条目 ——
少了安装依赖那步，构建会在缺 GTK/GStreamer 的 runner 上失败。

## 几个实现上的坑（改工作流前先读）

- **所有平台都必须把产物放进同一个 `release/` 目录，上传只用 `release/*` 这一个 pattern。**
  `actions/upload-artifact` 把 artifact 的根目录设成 **「所有 search path 的最小公共祖先」**
  —— 注意是**路径 pattern 的**公共祖先，**不是实际匹配到的文件的**。
  早先的写法同时写了 `webcam_client-*.zip`、`webcam_client-*.tar.gz`、`dist/*.apk`：
  在 Android 那个 job 里前两个什么都匹配不到，但它们照样把根目录拉到了工作区根，
  于是 APK 在 artifact 里被存成 `dist/….apk`；release job 拿到的是 `dist/dist/….apk`，
  而 `files: dist/*` 只匹配到那个**目录**（release action 会跳过目录且不报错）→
  **APK 从 release 里凭空消失，全程零报错。** 只有 Android 用了子目录，所以只有它中招。
- **release job 会校验三个平台都在**，缺任何一个直接 `::error::` 退出。
  发布一个"看起来正常但少了某个平台"的 release 是最糟的结果 —— 没人会立刻发现。
- **版本号是「盖」进 `pubspec.yaml` 的，不是用 `--build-name` 传的。**
  Windows 的 `flutter build` 没有 `--build-name`，而 Android 的
  `versionName`/`versionCode` 直接读 pubspec —— 只有改 pubspec 才能让所有平台
  对同一个版本号。文件只在 runner 里改，不提交。
- **macOS 打包必须用 `ditto` 而不是 `zip`。** `.app` 是带符号链接和扩展属性的 bundle，
  普通 zip 会把 loader 需要的链接拍平，产出一个打不开的 app。
- **Android 的 `setup-android` 必须显式传 `packages`**（默认值是已被删除的 `tools` 包），
  而且**包名按空格分隔**；NDK 是必需的（`ndkVersion = flutter.ndkVersion`）。
- **`fail-fast: false`**：Windows 挂了不该把 macOS / Android 的产物一起取消。
- **`pubspec.lock` 是提交进仓库的。** 这是应用不是库；不提交的话 CI 每次取
  "最新的兼容版本"，某天依赖发了新版就可能出一个和本地不一样的包。
