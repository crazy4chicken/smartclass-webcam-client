# 发布（GitHub Actions）

工作流：`.github/workflows/release.yml`。**iOS 不参与**（原因见最后一节）。

## 产出

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Windows x64 | `webcam_client-<版本>-windows-x64.zip` | `build/windows/x64/runner/Release/` 整个目录 |
| macOS（通用二进制） | `webcam_client-<版本>-macos.zip` | `webcam_client.app` + README |
| Linux x64 | `webcam_client-<版本>-linux-x64.tar.gz` | `bundle/` 目录（含 `lib/`、`data/`） |
| Android | `webcam_client-<版本>-android-<abi>.apk` | 按 ABI 拆分的三个 APK |

版本号来自 tag（`v1.0.0` → `1.0.0`），build number 用 `github.run_number`。

## 怎么发一版

```bash
git tag v1.0.0
git push origin v1.0.0
```

推 tag 会：跑测试 → 四个平台并行构建 → 建一个 GitHub Release 并附上全部产物。

**只想验证流水线**：Actions → Release → Run workflow。
手动触发**不会**建 Release，产物只留在那次运行的页面上（可下载），
所以随便跑不会污染 Releases 列表。

## 前置：一个 gate

`verify` job 先跑 `dart run tool/verify_pure.dart`（586 项断言）和 `flutter test`，
全绿才开始构建。任何一项挂了，四个平台都不会出包 —— 这是有意的，
但如果你确实要在测试红的情况下出包，把 `build.needs: verify` 删掉即可。

`flutter test` 会自动带上 `test/` 下的新文件，所以新增测试**不需要动流水线**；
`tool/verify_pure.dart` 同理（它是纯 Dart，不需要 Flutter 引擎，但 job 里已经有 Flutter 了）。
流水线里唯一写死的路径就是这两个。

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

- **Linux**：GStreamer（`camera_desktop` 直接链接它做 V4L2 采集）
  ```bash
  sudo apt install libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 gstreamer1.0-plugins-good
  ```
- **Windows / macOS**：无额外依赖，但见下面的签名说明。
- **Android**：无。`usesCleartextTraffic="true"` 已开，明文 `http://` 后端可直接用。

## 已知限制

- **macOS 产物未签名 / 未公证**：Gatekeeper 会拦第一次启动。
  右键 → 打开，或 `xattr -dr com.apple.quarantine webcam_client.app`。
  要真正分发得配 Apple Developer 证书 + `notarytool`，目前没做。
- **Windows 产物未签名**：SmartScreen 会提示。
- **Android 默认 debug 签名**：见上面「可选：Android 正式签名」。
- **Linux 产物的 glibc 下限**取决于 runner 镜像。`ubuntu-latest` 目前是 24.04
  （glibc 2.39），在更老的发行版上跑不起来。要覆盖老系统就把它改成 `ubuntu-22.04`。

## 为什么没有 iOS

**iOS 构建需要付费 Apple Developer 账号的签名证书和 provisioning profile**，
没有它们 `flutter build ios` 产出不了任何可安装的东西。
`ios/` 目录保留在仓库里（工程配置、`Info.plist` 的相机权限说明都在），
只是不在 CI 里构建。

真要做的话，需要：macOS runner + `apple-actions/import-codesign-certs` 导入
`.p12` + `xcodebuild` 用 profile 打包 + 导出 `ipa`，再加 `app-store-connect` 上传。
这一整套依赖账号和证书，不适合放在"推个 tag 就出包"的默认流水线里。

## 几个实现上的坑（改工作流前先读）

- **所有平台都必须把产物放进同一个 `release/` 目录，上传只用 `release/*` 这一个 pattern。**
  `actions/upload-artifact` 把 artifact 的根目录设成 **「所有 search path 的最小公共祖先」**
  —— 注意是**路径 pattern 的**公共祖先，**不是实际匹配到的文件的**。
  早先的写法同时写了 `webcam_client-*.zip`、`webcam_client-*.tar.gz`、`dist/*.apk`：
  在 Android 那个 job 里前两个什么都匹配不到，但它们照样把根目录拉到了工作区根，
  于是 APK 在 artifact 里被存成 `dist/….apk`；release job 拿到的是 `dist/dist/….apk`，
  而 `files: dist/*` 只匹配到那个**目录**（release action 会跳过目录且不报错）→
  **APK 从 release 里凭空消失，全程零报错。** 只有 Android 用了子目录，所以只有它中招。
- **release job 会校验四个平台都在**，缺任何一个直接 `::error::` 退出。
  发布一个"看起来正常但少了某个平台"的 release 是最糟的结果 —— 没人会立刻发现。
- **版本号是「盖」进 `pubspec.yaml` 的，不是用 `--build-name` 传的。**
  Windows 和 Linux 的 `flutter build` 没有 `--build-name`，而 Android 的
  `versionName`/`versionCode` 直接读 pubspec —— 只有改 pubspec 才能让四个平台
  对同一个版本号。文件只在 runner 里改，不提交。
- **macOS 打包必须用 `ditto` 而不是 `zip`。** `.app` 是带符号链接和扩展属性的 bundle，
  普通 zip 会把 loader 需要的链接拍平，产出一个打不开的 app。
- **Android 的 `setup-android` 必须显式传 `packages`**（默认值是已被删除的 `tools` 包），
  而且**包名按空格分隔**；NDK 是必需的（`ndkVersion = flutter.ndkVersion`）。
- **`fail-fast: false`**：Windows 挂了不该把 Linux / Android 的产物一起取消。
- **`pubspec.lock` 是提交进仓库的。** 这是应用不是库；不提交的话 CI 每次取
  "最新的兼容版本"，某天依赖发了新版就可能出一个和本地不一样的包。
