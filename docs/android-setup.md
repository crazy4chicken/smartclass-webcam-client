# Android 真机运行手册

面向本机现状写的可执行步骤（2026-10-04 核实）。

## 0. 现状：本机还没有 Android SDK

| 项 | 状态 |
| --- | --- |
| Android SDK | **没有**（`platforms/`、`build-tools/`、`cmdline-tools/` 全缺） |
| `android/local.properties` 的 `sdk.dir` | 指向 `C:\Users\Lhui\Desktop\tools` —— **这是错的**，那只是个放了 `adb.exe` 的普通文件夹。Flutter 因为看到里面有 `platform-tools/` 就把它当成 SDK 了，Gradle 到那一步会找不到 `platforms/android-36` |
| JDK | 有，JDK 21（PATH 上的 Oracle 21.0.12，另有 `C:\Program Files\Android\openjdk\jdk-21.0.8`）。AGP 9 要求 17+，够用 |
| adb | 有，37.0.0，在 `C:\Users\Lhui\Desktop\tools\platform-tools\adb.exe` |
| 模拟器 | 没有，也不需要（真机） |

项目侧版本：AGP 9.1.0 / Kotlin 2.4.0 / Gradle 9.3.1；
Flutter 默认 `compileSdk=36`、`targetSdk=36`、`minSdk=24`、`ndkVersion=28.2.13676358`。
`camera_android_camerax` 要求 `minSdk >= 23`，默认 24 满足，**不需要改 gradle**。

## 1. 装 Android SDK（命令行，约 250 MB）

1. 到 <https://developer.android.com/studio#command-line-tools-only> 下载
   **Command line tools only** 的 Windows zip。
2. 解压后把里面的 `cmdline-tools/` 放到 SDK 目录下，并重命名为 `latest`，最终形如：

   ```
   C:\Users\Lhui\AppData\Local\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat
   ```

   （`latest` 这一层必须存在，否则 `sdkmanager` 认不出自己的根目录。）
3. 装组件（会提示接受 Google 的 SDK 许可，需要你自己同意）：

   ```powershell
   $sdk = "$env:LOCALAPPDATA\Android\Sdk"
   & "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root=$sdk --licenses
   & "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root=$sdk `
       "platform-tools" "platforms;android-36" "build-tools;36.0.0"
   ```

   真机运行**不需要** `emulator` 和 `system-images`。

## 2. 让 Flutter 指向这个 SDK

```powershell
flutter config --android-sdk "$env:LOCALAPPDATA\Android\Sdk"
flutter doctor -v
```

`flutter doctor` 的 Android toolchain 一栏要是 `√`。它会顺手把
`android/local.properties` 里的 `sdk.dir` 改对（该文件不进 git）。

## 3. 手机准备

1. 设置 → 关于手机 → 连点"版本号"7 次，打开开发者选项。
2. 开发者选项 → 打开 **USB 调试**。
3. 数据线连电脑，手机上弹出"允许 USB 调试吗？"→ 允许。
4. 确认能看到设备：

   ```powershell
   adb devices          # 应列出 <serial>  device
   flutter devices
   ```

## 4. 跑起来

```powershell
flutter run -d <device-id>
```

首次会下 Gradle 9.3.1 + AGP 9.1.0，比较慢。

## 5. 后端地址与设备凭据（关键，不然连不上）

`BASE_URL` 默认是 `http://127.0.0.1:8080`，**在手机上 `127.0.0.1` 指的是手机自己**，
所以要么做端口反向映射，要么指定电脑的局域网 IP。

注意客户端**不是自主推流的**：它注册成功、挂载 WebSocket 之后什么都不推，
要等运营侧 `POST /api/devices/{id}/recording/start` 下发 `start_recording` 才开始。
所以注册必须成功，否则后端根本不知道该设备在线。

**推荐：adb reverse（不用改地址）**

```powershell
adb reverse tcp:8080 tcp:8080
```

这样手机的 `localhost:8080` 会转发到电脑的 `8080`，默认 `BASE_URL` 直接可用。
（注意：`adb reverse` 在拔插线/重启 adb 后要重做。）

**或者：同一 Wi-Fi 下用局域网 IP**

```powershell
flutter run -d <device-id> `
  --dart-define=BASE_URL=http://192.168.x.x:8080 `
  --dart-define=DEVICE_ID=01J8ZK9WQ7X3YV0M4N5P6Q7R8S `
  --dart-define=DEVICE_TOKEN=wdt_...
```

`DEVICE_ID` / `DEVICE_TOKEN` 由管理面 `POST /api/devices` 下发（**不是客户端生成的**）。
首次启动后它们会写进 `shared_preferences`，之后不用再传。

**只想验证编译 / 摄像头 / 预览**：加 `--dart-define=USE_MOCK_BACKEND=true`，
用内置假后端跑，不需要服务端也不需要凭据。这种模式下客户端会走完整的命令周期
（`start_recording` → `take_photo` → `stop_recording` → `ping`）。

没有后端 / 凭据缺失时客户端**不会崩**：摄像头照常打开并预览，状态条显示
「链路失败」+ 具体原因。

## 6. 明文流量已放行

`android/app/src/main/AndroidManifest.xml` 的 `<application>` 上有
`android:usesCleartextTraffic="true"`。**这个是必需的**：targetSdk 36 默认禁明文，
而注册与网关都是 `http://` / `ws://`，不加的话连接会被系统直接拒掉、且现象很隐蔽。
将来如果上 TLS，把这个属性和 `AppConfig.baseUrl` 的 `http://` 默认值一起去掉。

## 7. 权限与运行时行为

- 权限弹窗由 **`camera_android_camerax` 自己发起**（`CameraPermissionsManager`），
  不再依赖 `permission_handler`。拒绝的话 `cameraFailureFrom()` 会映射成
  `permissionDenied`，界面显示"摄像头权限被拒绝…"并给出重试按钮。
- kiosk 行为：切后台 / 锁屏 → 暂停采集 + 释放摄像头 + 断连；回前台自动重建。
  Android 系统禁止后台使用摄像头，这是硬约束，不是可以绕过的选项。
- 屏幕常亮靠 `wakelock_plus`（已声明 `WAKE_LOCK`）。
- 已声明 `uses-feature android.hardware.camera required="true"`，无摄像头的设备装不上。

## 8. 打 release APK

```powershell
flutter build apk --release --split-per-abi
```

产物在 `build/app/outputs/flutter-apk/`。目前 release 用 debug 签名（Flutter 模板默认），
可以直接 `adb install -r <apk>`；正式分发前需要自己配 keystore。

## 9. 可能踩的坑

| 现象 | 处理 |
| --- | --- |
| `SDK location not found` / `Failed to find target with hash string 'android-36'` | SDK 没装好，或 `local.properties` 还指向旧路径 → 回到第 1、2 步 |
| `NDK not configured` / 提示缺 NDK | `sdkmanager "ndk;28.2.13676358"`（版本来自 Flutter 的 `ndkVersion`） |
| `flutter devices` 看不到手机 | 换数据线/换 USB 口（要数据线不是充电线）；`adb kill-server && adb devices`；手机上重新确认授权弹窗 |
| `flutter doctor` 报 license not accepted | `sdkmanager --licenses` 手动同意 |
| 状态条显示「链路失败」+「未配置设备凭据」 | 没传 `DEVICE_ID` / `DEVICE_TOKEN`，或存储里的旧值不是 ULID 已被忽略 |
| 状态条显示「链路失败」+ 401 | 令牌被轮换或设备被删除。**重试没用**，需要运营侧重发凭据 |
| 状态条一直「重连中」 | 服务端没起、地址不对、或 `adb reverse` 掉了（拔插线后会失效） |
| 状态条「已连接 / 空闲」，后端却收不到东西 | 正常：设备是从属的，要等运营侧 `POST .../recording/start` |
| 后端日志有 segment 但下游解不开 | v1 用 `mjpeg`，一个 `recording.frame` 就是一张 JPEG；按 4 字节长度前缀切分即可 |

## 10. 真后端联调步骤

服务端默认监听 `:8080`。协议权威文档在 `smartclass-webcam-server/docs/protocol/`。

1. 起服务端（见 `smartclass-webcam-server/docs/guide/getting-started`）。
2. 管理面 `POST /api/devices` 建设备，拿到 `device_id` 与 `wdt_` token。
3. `flutter run -d <device-id> --dart-define=BASE_URL=… --dart-define=DEVICE_ID=… --dart-define=DEVICE_TOKEN=…`
4. 状态条应显示「已连接 / 空闲」。
5. 运营侧 `POST /api/devices/{id}/recording/start` → 状态条变「采集中」并显示 `stream_id`；
   约 5 秒后服务端出现第一个 segment。
6. `POST /api/devices/{id}/photo` → 照片列表出现一条，`request_id` 与命令一致。
7. `POST /api/devices/{id}/recording/stop` → 客户端立刻停推，stream 变 `completed`。
8. 断网再恢复 → 状态条进「重连中」，恢复后**重新注册**（register 调用次数 +1）。

`1008`（ticket 已被挂载）会自动重新注册；`1006` 是被新连接替换时的正常关闭，不是故障。
