# Android 客户端 × smartclass-webcam-server 端到端联调测试计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在本机起一个真实的 `smartclass-webcam-server`，让 Android 客户端注册、挂载并保持连接，再由服务端下发 `switch_camera` / `start_recording` / `stop_recording` / `take_photo` 四类命令去控制它，验证到**字节级**：客户端上传的帧确实落到了对象存储，且能被解出来。

**Architecture:** 服务端用 `WEBCAM_DEV=true` 免掉 teamusers 鉴权，PostgreSQL 与 MinIO 走 Docker，Android 端通过 `adb reverse` 把设备上的 `127.0.0.1:8080` 反向隧道到宿主机，因此客户端无需知道局域网 IP。观测三路：服务端 stdout、`flutter logs`、管理面 REST 查询。

**Scope 内**：注册/挂载/保活/四类命令/媒体字节校验/断线重连/ticket 一次性。
**Scope 外**：人脸识别（第三个仓库，不参与）、h265 编码（T9 未实现，本次应为 `mjpeg`）、性能压测、iOS/桌面端（同一套协议，Android 通过后按需补跑）。

---

## 环境盘点（已核实）

| 依赖 | 状态 | 位置 / 版本 |
|---|---|---|
| Go | ✅ | `go1.27.1 windows/amd64`（后端要求 ≥1.26） |
| PostgreSQL | ✅ | **18.6**，已作为 Windows 服务运行，监听 `0.0.0.0:5432`；客户端工具在 `C:\Program Files\PostgreSQL\18\bin`（`psql.exe` / `createdb.exe` / `pg_isready.exe`，默认不在 PATH） |
| Java | ✅ | `21.0.12` |
| Docker | ✅ 仅兜底 | `29.5.2` —— **本计划不依赖它**；仅当 PG18 建库失败时用于起一个 PG16 对照实例 |
| Android SDK | ✅ | `C:\Users\Lhui\AppData\Local\Android\Sdk`，有 `platforms/android-36`、`build-tools/36.0.0`、`platform-tools/adb.exe` |
| Android 模拟器 | ❌ | **无 `emulator`、无 `system-images`、无 AVD** |
| MinIO（对象存储） | ❌ | 未安装 —— 用单个 exe 本地起，见 Step 0.2 |
| Flutter | ✅ | `C:\Users\Lhui\AppData\Local\flutter`（注：本沙箱内 `flutter analyze` 起不来，报 `All pipe instances are busy`；`flutter run` / `flutter logs` 未验证过，若同样受阻换一个会话执行） |
| 明文 HTTP | ✅ | `android/app/src/main/AndroidManifest.xml` 已有 `android:usesCleartextTraffic="true"` |

**Android 目标二选一（推荐真机）**

- **真机（推荐）**：真摄像头、真网络栈、零下载。需要一台开 USB 调试的手机。
  关键技巧：`adb reverse tcp:8080 tcp:8080` 把**设备的** `127.0.0.1:8080` 映射到**宿主机的** 8080，于是客户端 `BASE_URL` 直接填 `http://127.0.0.1:8080`，绕开局域网 IP 与防火墙。
- **模拟器（备选）**：需先装约 1.5 GB。访宿主机用 `10.0.2.2:8080`（**不是** `127.0.0.1`）。Windows 上选 x86_64 镜像，arm64 镜像无指令翻译会极慢。

---

## 关键约束（实现前必读）

- `WEBCAM_DEV=true` 会**完全关闭鉴权**，每个请求按 `any` 作用域处理 —— 这是本测试不搭 teamusers 的原因。**仅限本地。**
- 注册是 **`GET` 带 JSON body**。本地无代理，无需额外配置。
- ticket 一次性、TTL 60 秒；**连接一断 ticket 就死**，重连必然重新注册。
- 服务端 **60 秒读超时**：客户端空闲时必须自己发 `status` / `pong`，否则被踢。
- 不配对象存储时服务端用 **no-op 后端，字节直接丢弃**（只留行数）。要校验字节内容**必须**起 MinIO。
- 客户端声明 `fps = 5`（`AppConfig.defaultFps`），服务端用它估算 `duration_ms`；实际送不到 5fps 会让时长被高估 —— 这也是要验的一项。

---

### Task 0: 起 PostgreSQL、MinIO 与服务端

**Files:** 无（不改代码）

- [ ] **Step 0.1: 用本机 PostgreSQL 18 建库**

已装的是 **18.6**，服务已在跑、5432 已在监听，不需要 Docker。后端要求 PostgreSQL ≥16，18 满足。

```sh
PGBIN="C:/Program Files/PostgreSQL/18/bin"
"$PGBIN/pg_isready.exe" -h 127.0.0.1 -p 5432        # 期望 accepting connections
"$PGBIN/createdb.exe" -U postgres -h 127.0.0.1 webcam
```
Expected: `createdb` 无输出即成功。若提示密码，填安装 PostgreSQL 时设的 `postgres` 口令。

**若 18 上建库/启动报 schema 错误**（后端内嵌迁移是针对 PG16 写的，大版本可能踩到移除的语法），退回 Docker 起一个 PG16 对照：
```sh
docker run -d --name webcam-pg16 -e POSTGRES_PASSWORD=webcam -e POSTGRES_DB=webcam -p 5433:5432 postgres:16
```
然后把 `WEBCAM_DB_URL` 的端口改成 `5433`。

- [ ] **Step 0.2: 起 MinIO（对象存储，字节校验必需）**

MinIO 未安装。**优先用单个 exe，不依赖 Docker**：
```sh
curl -Lo "$HOME/minio.exe" https://dl.min.io/server/minio/release/windows-amd64/minio.exe
set MINIO_ROOT_USER=webcam
set MINIO_ROOT_PASSWORD=webcam12345
"$HOME/minio.exe" server "%USERPROFILE%\minio-data" --console-address ":9001"
```
备选（若不想下 exe）：
```sh
docker run -d --name webcam-minio -e MINIO_ROOT_USER=webcam -e MINIO_ROOT_PASSWORD=webcam12345 \
  -p 9000:9000 -p 9001:9001 minio/minio server /data --console-address ":9001"
```
健康检查（两种都适用）：
```sh
curl -fsS http://127.0.0.1:9000/minio/health/live
```
Expected: HTTP 200

> 不配对象存储时服务端会用 **no-op 后端直接丢弃字节**，只留数据库行数 —— 那样做不了 Task 3.5 的字节级断言，所以这一步不能省。

- [ ] **Step 0.3: 起服务端**

```sh
cd smartclass-webcam-server
export WEBCAM_DEV=true
export WEBCAM_DB_URL='postgres://postgres:webcam@127.0.0.1:5432/webcam?sslmode=disable'
export WEBCAM_S3_ENDPOINT='127.0.0.1:9000'      # host:port，不带 scheme
export WEBCAM_S3_ACCESS_KEY=webcam
export WEBCAM_S3_SECRET_KEY=webcam12345
export WEBCAM_S3_BUCKET=webcam-streams
export WEBCAM_S3_USE_SSL=false
export WEBCAM_LISTEN_ADDR=':8080'
go run ./cmd/server
```
Expected: 启动日志出现监听地址，无 panic。Bucket 在启动时自动创建。

- [ ] **Step 0.4: 健康检查**

```sh
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS http://127.0.0.1:8080/readyz
```
Expected: 均 200

- [ ] **Step 0.5: 建设备，拿凭据**

```sh
curl -sS -X POST http://127.0.0.1:8080/api/devices \
  -H 'Content-Type: application/json' \
  --data '{"name":"Android E2E","location":"bench"}'
```
Expected: `200/201`，返回 `{"device":{"id":"<26字符ULID>",...},"token":"wdt_<43字符>"}`

**把 `device.id` 与 `token` 记下来**（`WEBCAM_DEV=true` 下无需 Bearer 头）。token 只出现这一次。

- [ ] **Step 0.6: 准备 Android 目标**

真机：
```sh
ADB="C:/Users/Lhui/AppData/Local/Android/Sdk/platform-tools/adb.exe"
"$ADB" devices                       # 应列出一台 device
"$ADB" reverse tcp:8080 tcp:8080     # 设备 127.0.0.1:8080 → 宿主机 8080
"$ADB" reverse --list                # 确认映射存在
```
模拟器（备选，需先装）：
```sh
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
  "emulator" "system-images;android-36;google_apis;x86_64"
"$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
  -n webcam-e2e -k 'system-images;android-36;google_apis;x86_64' -d pixel_7
"$ANDROID_HOME/emulator/emulator" -avd webcam-e2e -camera-back webcam0
```

- [ ] **Step 0.7: Commit（若产生了脚本）**

```bash
git add tool/e2e 2>/dev/null || true
git commit -m "chore: add e2e verification helpers"
```

---

### Task 1: 冷启动 —— 注册与挂载

**Files:** 无

- [ ] **Step 1.1: 启动客户端**

```sh
flutter run -d <deviceId> \
  --dart-define=BASE_URL=http://127.0.0.1:8080 \
  --dart-define=DEVICE_ID=<Step 0.5 的 ULID> \
  --dart-define=DEVICE_TOKEN=wdt_<Step 0.5 的 token>
```
模拟器则把 `BASE_URL` 换成 `http://10.0.2.2:8080`（且不需要 `adb reverse`）。

- [ ] **Step 1.2: 授权摄像头**

首次启动会弹 CAMERA 权限，手动允许。

- [ ] **Step 1.3: 校验注册内容**

```sh
curl -sS http://127.0.0.1:8080/api/devices/$DEVICE_ID/
```
Expected:
- `online: true`
- `cameras` 非空，长度 ≥1（手机通常 2：前后摄）
- 每个 `camera_enum` 等于数组下标
- 至少一个摄像头的 `supported_codec` 含 `"mjpeg"`，且**不含** `"hevc"` / `"H264"`
- `resolution` 形如 `"1280x720"`，`fps` 为 `5`

- [ ] **Step 1.4: 校验客户端侧日志**

```sh
flutter logs          # 或: adb logcat -s flutter
```
Expected 出现：`[register] announcing ...`、`[codec] available=mjpeg selected=mjpeg`，无 `device authentication failed`、无 `404`。

---

### Task 2: 保活 —— 静默 90 秒不能被踢

**Files:** 无

- [ ] **Step 2.1: 静置**

客户端停在预览页不动 90 秒（超过服务端 60 秒读超时）。

- [ ] **Step 2.2: 校验仍在线**

```sh
curl -sS http://127.0.0.1:8080/api/devices/$DEVICE_ID/ | grep -o '"online":[a-z]*'
```
Expected: `online:true`

- [ ] **Step 2.3: 校验客户端确实在发保活流量**

`flutter logs` 中应能看到周期性 `status` 上报与对 `ping` 的 `pong`。若服务端日志出现读超时关闭，说明空闲心跳没做 —— 这是缺陷，回到 T4 修。

---

### Task 3: `recording/start` —— 推帧并落到对象存储（核心项）

**Files:** Create: `tool/e2e/check_segment.py`

- [ ] **Step 3.1: 下发开始录制**

```sh
curl -sS -X POST http://127.0.0.1:8080/api/devices/$DEVICE_ID/recording/start \
  -H 'Content-Type: application/json' --data '{"camera_enum":0}'
```
Expected: `201`，返回 stream 资源，含 `id`（26 字符 ULID）、`status:"active"`、`metadata.fps=5`、`metadata.codecs` 含 `mjpeg`

- [ ] **Step 3.2: 客户端侧确认**

状态条应进入「采集中」并显示该 `stream_id`；`flutter logs` 中应有对 `start_recording` 的 `ack {ok:true}`。
Expected: 客户端**此前没有推过任何媒体** —— 未收到命令就推帧是协议违规。

- [ ] **Step 3.3: 等一个 flush 周期**

服务端每 5 秒或 150 帧刷一次。等待 **8 秒**。

- [ ] **Step 3.4: 查 segment 行**

```sh
curl -sS http://127.0.0.1:8080/api/streams/$STREAM_ID/
```
Expected: `segments` 非空，每条 `size_bytes > 0`，`segment_seq` 为整数。

- [ ] **Step 3.5: 字节级校验（本测试的关键断言）**

取第一条 segment 的 `download_url`（15 分钟有效），下载后按 `[uint32 BE len][frame]...` 拆分：

```python
# tool/e2e/check_segment.py
import struct, sys
raw = open(sys.argv[1], 'rb').read()
i, frames = 0, []
while i + 4 <= len(raw):
    n = struct.unpack('>I', raw[i:i+4])[0]
    i += 4
    frames.append(raw[i:i+n])
    i += n
print(f'frames={len(frames)} trailing={len(raw)-i}')
jpeg = [f for f in frames if f[:2] == b'\xff\xd8' and f[-2:] == b'\xff\xd9']
print(f'jpeg_ok={len(jpeg)}/{len(frames)}')
print('sizes:', sorted({len(f) for f in frames})[:5])
```
Expected: `frames > 0`、`jpeg_ok == frames`（每帧都是完整 JPEG）、`trailing == 0`（长度前缀拼接无残留）、帧大小在几十 KB 量级（720p JPEG）。

若 `jpeg_ok < frames`，说明帧被截断或客户端发了非 mjpeg 负载 —— 严重缺陷。

- [ ] **Step 3.6: 校验时长估算合理**

`duration_ms ≈ frames × 1000 / 5`。若实测帧数远低于 `duration_ms/200`，说明客户端声明的 5fps 实际送不到 —— 要么调 `AppConfig.defaultFps`，要么让后端别用它估时长。

---

### Task 4: `take_photo` —— 单张照片与 `request_id` 回传

- [ ] **Step 4.1: 下发拍照**

```sh
curl -sS -X POST http://127.0.0.1:8080/api/devices/$DEVICE_ID/photo \
  -H 'Content-Type: application/json' --data '{"camera_enum":0}'
```
Expected: `202`，返回 `command_id` 与 `request_id`

- [ ] **Step 4.2: 校验照片记录**

```sh
curl -sS "http://127.0.0.1:8080/api/devices/$DEVICE_ID/photos"
```
Expected: 出现一条 `request_id` 与上一步一致、`content_type == "image/jpeg"`、`size_bytes > 0`

- [ ] **Step 4.3: 字节校验**

下载其 `download_url`，确认开头 `FF D8`、结尾 `FF D9`（合法 JPEG）。

---

### Task 5: `recording/stop` —— 立刻停推

- [ ] **Step 5.1: 下发停止**

```sh
curl -sS -X POST http://127.0.0.1:8080/api/devices/$DEVICE_ID/recording/stop \
  -H 'Content-Type: application/json' --data '{"camera_enum":0}'
```
Expected: `200`，stream `status:"completed"`

- [ ] **Step 5.2: 校验客户端真的停了**

记下当前 segment 数，**等 15 秒**再查一次。
Expected: segment 数**不再增长**。若仍在增长，说明客户端收到 stop 后没停止帧泵 —— 严重缺陷（服务端在排队命令时就把 stream 标 completed，晚到的帧会被丢弃）。

- [ ] **Step 5.3: 校验 `stop_recording` 后重开**

再次 `recording/start` 同一 camera。
Expected: 新的 `stream_id`（ULID 不重复），能重新推帧。

---

### Task 6: `camera/switch` —— 切摄与越界拒绝

- [ ] **Step 6.1: 切到注册的另一路**

```sh
curl -sS -X POST http://127.0.0.1:8080/api/devices/$DEVICE_ID/camera/switch \
  -H 'Content-Type: application/json' --data '{"camera_enum":1}'
```
Expected: `202` + `command_id`；客户端日志出现 `switch_camera` 的 `ack {ok:true}`

- [ ] **Step 6.2: 越界值应被服务端拒绝**

```sh
curl -sS -X POST http://127.0.0.1:8080/api/devices/$DEVICE_ID/camera/switch \
  -H 'Content-Type: application/json' --data '{"camera_enum":99}'
```
Expected: `400`，problem+json 的 `detail` 含 `is not registered`（说明服务端在**下发前**就校验了注册范围，客户端不会收到非法 `camera_enum`）

- [ ] **Step 6.3: 切回 0**

Expected: `202`，客户端 ack。

---

### Task 7: 断线重连 —— 必须重新注册

- [ ] **Step 7.1: 杀掉服务端**

Ctrl-C 掉 `go run`。

- [ ] **Step 7.2: 观察客户端**

Expected: 状态条进入「重连」；`flutter logs` 出现退避重试。**不应**出现崩溃或紧循环。

- [ ] **Step 7.3: 重启服务端并等待**

重新执行 Step 0.3 的 `go run`。

- [ ] **Step 7.4: 校验恢复**

```sh
curl -sS http://127.0.0.1:8080/api/devices/$DEVICE_ID/
```
Expected: `online:true`

- [ ] **Step 7.5: 校验用的是新 ticket**

服务端日志中 `GET /ws/register` 的次数应 **+1**（ticket 随连接死亡，不存在 session resume）。若是复用旧 ticket，会看到 `404 device websocket not found`。

- [ ] **Step 7.6: 校验被中断的流**

`GET /api/devices/$DEVICE_ID/streams` 中，断线时仍 active 的流应变为 `failed`（不是 `completed`）。

---

### Task 8: ticket 一次性（可选，纯 curl，不需要客户端）

- [ ] **Step 8.1: 连注册两次**

```sh
T1=$(curl -sS -X GET http://127.0.0.1:8080/ws/register \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data "{\"device_id\":\"$DEVICE_ID\",\"cameras\":[{\"camera_enum\":0,\"resolution\":\"1280x720\",\"fps\":5,\"supported_codec\":[\"mjpeg\"]}]}" \
  | python -c 'import sys,json;print(json.load(sys.stdin)["device_websocket_id"])')
```
再注册一次得到 `T2`。

- [ ] **Step 8.2: 用第一个 ticket 发起升级**

```sh
curl -i -sS "http://127.0.0.1:8080/ws/device/$T1" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13"
```
Expected: `404` + `device websocket not found` —— 第二次注册**立刻作废**了前一个未使用的 ticket（协议规则 5）。

---

## 验收清单

| # | 场景 | 通过标准 | 在哪看 |
|---|---|---|---|
| 1 | 注册 | `online:true`，cameras 与客户端声明一致，codec 含 `mjpeg` 不含 `hevc` | `GET /api/devices/{id}/` |
| 2 | 保活 | 静默 90s 仍在线 | 同上 |
| 3 | 开始录制 | `201` + stream active，客户端 ack ok:true，未收命令前**零**媒体 | REST + `flutter logs` |
| 4 | 帧落盘 | segment `size_bytes>0`，拆分后**每帧都是完整 JPEG**，无残留字节 | `check_segment.py` |
| 5 | 拍照 | photo 记录 `request_id` 匹配、`content_type=image/jpeg`、字节是 JPEG | REST + 下载 |
| 6 | 停止 | stream `completed`，15s 内 segment 不再增长 | REST |
| 7 | 切摄 | `202` + ack；越界值服务端返回 `400` | REST |
| 8 | 重连 | 服务端恢复后 `online:true`，register 次数 +1，中断的流为 `failed` | 服务端日志 + REST |
| 9 | ticket 一次性（可选） | 重复注册后旧 ticket 附接返回 `404` | curl |

## 故障排查表

| 现象 | 最可能的原因 | 定位 |
|---|---|---|
| 客户端日志 `device authentication failed` | `DEVICE_ID` 或 `DEVICE_TOKEN` 传错 | 重新执行 Step 0.5 取凭据 |
| 注册 200 但挂载 `404` | ticket 过期（>60s）或已被新注册作废 | 看客户端是否在 60s 内挂载；查 register 次数 |
| `online` 一直 false | 客户端没连上，或连上后 60s 静默被踢 | `flutter logs` 看 gateway 状态机 |
| recording/start 返回 `409` | 设备离线，或该 camera 已有 active 流 | 先查 `online`，再查 streams |
| 有 segment 但 `size_bytes` 为 0 / 拆不出帧 | 客户端发的内容与声明 codec 不符 | `check_segment.py` 看帧头 |
| 客户端连不上 `127.0.0.1:8080` | 真机忘了 `adb reverse`；模拟器用了 `127.0.0.1` 而非 `10.0.2.2` | `adb reverse --list` |
| MinIO 报 bucket 不存在 | 服务端启动失败没走到建桶 | 看 `minio.exe` 窗口输出（`docker logs webcam-minio` 若走 Docker）+ 服务端 stdout |
| `createdb` 报认证失败 | 用了错口令 | 填安装 PostgreSQL 18 时为 `postgres` 设的口令；或改用 PG16 容器（Step 0.1 兜底） |
| `flutter run` 卡住 | 本沙箱管道问题 | 换会话执行，或直接用 `adb install` 装已构建的 apk |

## 清理

```sh
adb reverse --remove tcp:8080       2>/dev/null || true
# 本机 PostgreSQL 保留（库可留作后续复跑，或手工 dropdb webcam）
"$PGBIN/dropdb.exe" -U postgres -h 127.0.0.1 webcam    # 可选
docker rm -f webcam-pg16 webcam-minio 2>/dev/null || true   # 仅当用过 Docker
```

## Self-Review Checklist

1. **协议覆盖**：注册、挂载、保活、四类命令、媒体两种通道、重连、ticket 一次性 —— 均有对应 Task 与可观测断言。
2. **字节级验证存在**：Task 3.5 与 4.3 直接校验落盘内容，而不是只看 HTTP 状态码 —— 这是本计划区别于「冒烟测试」的地方。
3. **环境事实已核实**：Go / PostgreSQL 18.6 / Android SDK 均来自本机实测，能用本机的就不额外起容器；模拟器缺失已标注为前置下载项，未假装可用。**Docker 只在两处兜底**（PG18 不兼容时起 PG16、MinIO 不想下 exe），不是主路径。
4. **失败即缺陷的判定明确**：未收命令就推帧、stop 后继续推、帧非完整 JPEG、重连复用旧 ticket —— 四条都写成了显式失败条件。
5. **比例**：命令与断言逐条给出，不重复描述协议细节（那些在 `docs/protocol/` 与本仓库的接入计划里）。
