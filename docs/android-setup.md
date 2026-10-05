# Android 真机运行手册

面向本机现状写的可执行步骤（**2026-10-05 核实**）。

## 0. 现状：环境已就绪

真机端到端联调已经跑通过一整轮，下面是核实过的状态。

| 项           | 状态                                                                                                                                          |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Android SDK | ✅ `C:\Users\Lhui\AppData\Local\Android\Sdk`，有 `platforms/android-36`、`build-tools/36.0.0`、`platform-tools`、`ndk`、`cmdline-tools`、`licenses` |
| adb         | ✅ 37.0.0，`C:\Users\Lhui\AppData\Local\Android\Sdk\platform-tools\adb.exe`                                                                   |
| JDK         | ✅ JDK 21（PATH 上的 Oracle 21.0.12，另有 `C:\Program Files\Android\openjdk\jdk-21.0.8`）。AGP 9 要求 17+，够用                                           |
| 真机          | ✅ 已在 `V2405A`（Android 16）上跑通全流程                                                                                                             |
| 模拟器         | ❌ 没有 `emulator` / `system-images` / AVD —— 也不需要，用真机                                                                                         |
| Go          | ✅ 1.27.1（后端要求 ≥1.26），用于本地起服务端                                                                                                               |
| PostgreSQL  | ✅ 18.6（服务在 5432）；但 `postgres` 口令未知，联调时另起 trust 集群，见 README「端到端联调环境」                                                                         |
| Docker      | ⚠️ Desktop 已装但 **daemon 默认没起**，且 **Docker Hub 被本机代理挡掉**，拉不到镜像                                                                               |

项目侧版本：AGP 9.1.0 / Kotlin 2.4.0 / Gradle 9.3.1；  
Flutter 默认 `compileSdk=36`、`targetSdk=36`、`minSdk=24`、`ndkVersion=28.2.13676358`。  
`camera_android_camerax` 要求 `minSdk >= 23`，默认 24 满足，**不需要改 gradle**。

> 曾经踩过：`android/local.properties` 的 `sdk.dir` 一度指向  
> `C:\Users\Lhui\Desktop\tools` —— 那只是个放了 `adb.exe` 的普通文件夹。Flutter 看到里面有  
> `platform-tools/` 就把它当成 SDK，直到 Gradle 找不到 `platforms/android-36` 才暴露。  
> 现在指向真 SDK。

## 1. 换机器 / SDK 丢了才需要（当前机器不用做）

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

| 现象                                                                               | 处理                                                                                                      |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `SDK location not found` / `Failed to find target with hash string 'android-36'` | SDK 没装好，或 `local.properties` 还指向旧路径 → 回到第 1、2 步                                                         |
| `NDK not configured` / 提示缺 NDK                                                   | `sdkmanager "ndk;28.2.13676358"`（版本来自 Flutter 的 `ndkVersion`）                                           |
| `flutter devices` 看不到手机                                                          | 换数据线/换 USB 口（要数据线不是充电线）；`adb kill-server && adb devices`；手机上重新确认授权弹窗                                    |
| `flutter doctor` 报 license not accepted                                          | `sdkmanager --licenses` 手动同意                                                                            |
| 状态条显示「链路失败」+「未配置设备凭据」                                                            | 没传 `DEVICE_ID` / `DEVICE_TOKEN`，或存储里的旧值不是 ULID 已被忽略                                                     |
| 状态条显示「链路失败」+ 401                                                                 | 令牌被轮换或设备被删除。**重试没用**，需要运营侧重发凭据                                                                          |
| 状态条一直「重连中」                                                                       | 服务端没起、地址不对、或 `adb reverse` 掉了（拔插线后会失效）                                                                  |
| 状态条「已连接 / 空闲」，后端却收不到东西                                                           | 正常：设备是从属的，要等运营侧 `POST .../recording/start`                                                              |
| 装了新包但设备**根本不注册**，`online` 一直是 false                                              | 摄像头权限弹窗阻塞了 `initialize()`，而初始化排在注册之前。`adb shell pm grant <pkg> android.permission.CAMERA`               |
| 注册 401 `device authentication failed`                                            | 令牌被轮换 / 设备被删；**或**注册请求漏了 `Authorization: Bearer wdt_…`（`WEBCAM_DEV=true` 关的是 teamusers 鉴权，**设备令牌照样校验**） |
| `recording/start` 返回 `409 already streaming`，但明明没在录                              | 服务端**旧版本**会留下僵尸 `active` 流（重启不清理）。后端 `b8b4d7e` 起已在启动时自动收尾为 `failed`；仍出现说明跑的是旧构建                         |
| `take_photo` 返回 `202` 但照片列表一直空                                                   | 见 §11 权限那条；**录制中**拍照另有并发问题（已在客户端用 `SerialLock` 修掉，见 README「设备与媒体层的坑」）                                   |
| segment 有 `size_bytes` 但拆不出帧                                                     | 多半是**没配对象存储**，服务端用 `NoopStorage` 丢字节 —— 行和大小照样写，内容是空的                                                   |
| 拆出来有帧但不是完整 JPEG                                                                  | 相机 HAL 可能在 EOI 后追加 0 字节；客户端已用 `trimJpegPadding` 裁掉。若仍出现，用 `check_segment.py --dump` 导出看帧头帧尾             |
| 后端日志有 segment 但下游解不开                                                             | v1 用 `mjpeg`，一个 `recording.frame` 就是一张 JPEG；按 4 字节长度前缀切分即可                                              |

## 10. 真后端联调步骤

服务端默认监听 `:8080`。协议权威文档在**后端仓库**的 `smartclass-webcam-server/docs/protocol/`。

> **服务端是另一个仓库**，不属于本仓库。工作区里若有一份 `smartclass-webcam-server/`，  
> 那只是本地测试用的检出（已被 gitignore）。客户端对它是**网络依赖，不是路径依赖** ——  
> 唯一的耦合点是 `AppConfig.baseUrl`（默认 `http://127.0.0.1:8080`，可用  
> `--dart-define=BASE_URL=` 覆盖）。把那份检出删掉，客户端照样构建、照样跑  
> `flutter test` 和 `dart run tool/verify_pure.dart`。

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

## 11. 不用 `flutter run` 也能驱动真机

`flutter run` 起不来时（例如在助手 shell 里，Dart VM 建不了子进程），  
**已经装好的 debug APK 可以完全用 adb 驱动** —— 这条路径实测跑完过一整轮端到端联调。

前提：`flutter run` 或 `flutter build apk` 已经成功过一次，包已安装。

```sh
ADB="C:/Users/Lhui/AppData/Local/Android/Sdk/platform-tools/adb.exe"
PKG=com.example.webcam_client
DEVICE_ID=<管理面拿到的 ULID>
TOKEN=<wdt_…>

# 1. 让设备上的 127.0.0.1:8080 反向隧道到宿主机（APK 里 BASE_URL 是默认值时正好对应）
"$ADB" reverse tcp:8080 tcp:8080

# 2. 把凭据写进 shared_preferences（debug 包 run-as 可用）
cat > /tmp/prefs.xml <<EOF
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="flutter.device_id">$DEVICE_ID</string>
    <string name="flutter.device_token">$TOKEN</string>
</map>
EOF
"$ADB" shell am force-stop $PKG
"$ADB" shell "run-as $PKG sh -c 'echo $(base64 -w0 /tmp/prefs.xml) | base64 -d > shared_prefs/FlutterSharedPreferences.xml'"

# 3. 预授权摄像头（不预授权会卡住，见下）
"$ADB" shell pm grant $PKG android.permission.CAMERA

# 4. 启动
"$ADB" logcat -c
"$ADB" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1
sleep 12
"$ADB" logcat -d | grep 'flutter :' | tail
```

### 三个必须知道的点

- **键名前缀是 `flutter.`** —— `shared_preferences` 会自动加，所以  
  `device_id` 在文件里是 `flutter.device_id`。
- **必须 base64 中转**。直接 `cat | adb shell 'run-as … > file'` 会被换行和引号搞坏，  
  写出来的 XML 解析失败、表现为"凭据没生效"。
- ⚠️ **不预授权会卡住，而且现象极具误导性**。权限弹窗会阻塞 `initialize()`，  
  而初始化排在注册**之前** —— 所以设备根本不注册，`online` 一直是 `false`，  
  看起来像网络/凭据问题。真机上是 `pm grant` 一行的事。

### 两个会让 App「自己掉线」的坑（都不是 App 的问题）

- ⚠️ **`adb reverse` 隧道会随 adb daemon 一起死。** daemon 是启动它的 shell 的子进程；
  如果每条命令都跑在新 shell 里，上一条的 daemon 会被带走，**下一条 adb 命令会重启 daemon，
  而重启会清掉所有 reverse 映射**。现象：App 连上十几秒后掉线，
  `adb reverse --list` 是空的 —— 看起来像 App 主动断开。稳妥做法是让后台任务每几秒重设一次：

  ```sh
  while true; do "$ADB" reverse tcp:8080 tcp:8080 >/dev/null 2>&1; sleep 5; done
  ```

- ⚠️ **屏幕一灭，App 就按 kiosk 语义 pause → 断连。** 这是设计行为，不是 bug。
  长时间跑要先把屏幕按住：

  ```sh
  adb shell svc power stayon true
  adb shell input keyevent KEYCODE_WAKEUP
  ```

### 观测与归属验证

三路观测：`adb logcat -d | grep 'flutter :'`、服务端 stdout、管理面 REST。

**归属验证用受控实验，比看日志可靠**：

```sh
# 跑着 → online:true；force-stop → online:false；重启 → online:true
curl -sS "http://127.0.0.1:8080/api/devices/$DEVICE_ID/" | grep -oE '"online":(true|false)'
```

客户端现在会把**每条命令和它的 ack 结果**打到控制台（`flutter :` 前缀），  
所以 `switch_camera` / `take_photo` 这类"服务端不记录任何状态"的命令也能确认：

```
switch_camera(camera=1) →
  ack FAILED: cannot switch camera while stream 01M4… is active
```

## 12. 字节级校验（落盘内容）

HTTP 200 和 `size_bytes > 0` **说明不了任何事**，尤其是没有对象存储时  
服务端用 `NoopStorage` 丢字节、但 segment 行和 `size_bytes` 照样写。  
要验内容只能下载下来拆：

```sh
python tool/e2e/check_segment.py <segment.bin>          # 本地文件
python tool/e2e/check_segment.py --url <presigned-url>  # 直接拉
```

判读：

- `trailing` 必须是 `0` —— 非 0 说明长度前缀拼接对不齐；  
  `OVERRUN` 说明某个前缀承诺的字节数超过对象长度，框架完全对不上。
- `jpeg_ok` 必须等于 `frames` —— 少一个就说明有帧被截断，  
  或者 EOI 之后被追加了非图像数据。
- 帧大小应在几十~几百 KB（1280x720 JPEG）。

本地没有可用对象存储时用 `tool/e2e/s3_stub.py`，见 README 的「端到端联调环境」。
