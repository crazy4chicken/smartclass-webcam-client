# Linux encoded stream (Task 6, steps 2-5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Linux build a real encoder. Frames are captured and encoded inside the vendored `camera_desktop` plugin, and only compressed access units cross into Dart — so the device can actually deliver 1080p60 H.264/H.265 instead of the roughly 5-10 fps the still-picture path is capped at.

**Why this needs its own plan.** The parent plan (`2026-10-09-recording-correctness-and-native-encoder.md`) specifies Task 6 step 2 in one line:

> Add an encoded-stream branch to the GStreamer pipeline: capture (`v4l2src`, MJPEG caps at high resolution) → decode → `videoconvert` → encoder → `appsink` emitting encoded bytes.

That line is a sketch and, read literally, is not buildable: `v4l2src` on a device that the preview pipeline already holds cannot be opened a second time (EBUSY). The branch has to come off the existing tee. Everything else — what crosses into Dart, what `EncodedPacket.pictures` is, how the app reaches a plugin API it has no typed handle on — is also undecided. This plan decides those and then implements.

**Architecture:**

```
[source: v4l2src | pipewiresrc] ! videoconvert ! videoflip
  ! videoscale ! videorate ! video/x-raw,format=RGBA,WxH,framerate=F/1
  ! tee name=t
    t. ! queue ! appsink                       (preview, exists)
    t. ! [RecordHandler, exists]
    t. ! queue ! videoconvert ! encoder ! parse ! capsfilter ! appsink   (new)
```

One new class, `EncodedStreamHandler`, shaped exactly like the existing `RecordHandler` so the fork stays rebasable (see `packages/camera_desktop/VENDORED.md`). Access units are pushed to Dart over the plugin's existing method channel — the same channel Windows and macOS already use for `imageStreamFrame`, and the same one `Camera::SendError` uses on Linux.

**Tech Stack:** Flutter Linux desktop; GStreamer 1.0 (`gstreamer-1.0`, `gstreamer-app-1.0`, `gstreamer-video-1.0` already linked by `packages/camera_desktop/linux/CMakeLists.txt`); `flutter_linux` (`fl_method_channel_invoke_method`, `fl_value_new_uint8_list`); Dart 3.13.

**Spec:**
- `smartclass-webcam-server/docs/protocol/media.md` — one access unit per `recording.frame`, stored verbatim, no container
- `lib/src/capture/native_video_encoder.dart` — `EncodedStreamChannel`, `EncodedPacket`, the `pictures` cross-check
- `lib/src/capture/annexb.dart` — `AnnexBSplitter`, which is what makes a byte stream into units
- `packages/camera_desktop/VENDORED.md` — what this fork may and may not touch

## Decisions (these are the ones the parent plan left open)

1. **Tap the tee, never a second source.** The branch receives RGBA at the target width/height/fps, because `videorate` and the caps filter sit before the tee. That is what makes the declared rate honest: the encoder sees exactly the fps the registration announces.
   *Consequence, and the main performance risk of this plan:* everything downstream of the tee is raw RGBA — 497 MB/s at 1080p60. If measurement shows `videoconvert` + encoder cannot hold 60, the fix is to move the tap upstream of `videorate`, not to declare a lower rate. Record the measurement; do not guess.
2. **One access unit per buffer.** The branch ends in `capsfilter` with `video/x-h264,stream-format=byte-stream,alignment=au` (or `video/x-h265,…`). With `alignment=au`, one appsink buffer is one complete access unit, so native reports `pictures = 1` for every buffer it emits. That is an assumption about GStreamer, not a fact about the bytes — which is exactly what `EncodedPacket.pictures` exists to catch: if reality differs, Dart drops the packet and counts it in `droppedPackets` rather than emitting something undecodable.
3. **Parameter sets stay in band.** A consumer that tunes in mid-stream has nothing to sync on but a key frame, and the server stores bodies verbatim with no container. So the IDR must carry VPS/SPS/PPS with it. Set `config-interval=-1` on the parse element (insert parameter sets before every IDR) and a `key-int-max` on the encoder so key frames recur. **`config-interval=-1` is the single property in this plan I am least sure of** — verify it on the target box before trusting it, and if it does not do what is wanted, put the parameter sets in the encoder's own configuration instead.
4. **Push, marshal to the main thread, and shed rather than queue.** `new-sample` fires on a GStreamer streaming thread; `fl_method_channel_invoke_method` must be called from the main thread, so each buffer is handed over with `g_idle_add`. Buffers are bounded in flight: if Dart has not consumed the previous one, the new one is dropped. A late frame is a visible dropped frame; a queue is latency that looks like a broken camera.
5. **The app reaches the plugin through `CameraPlatform.instance`.** The app depends on `camera`, not on `camera_desktop`'s Dart API, and must not construct a second `CameraDesktopPlugin` — its `_ensureNativeCallHandler` would overwrite the live channel handler. `registerWith()` puts the one instance in `CameraPlatform.instance`, so the adapter casts to `CameraDesktopPlugin`. Wrapped in `try`/`is` so a platform without the branch falls back to mjpeg instead of throwing.
6. **What the device declares is measured, still.** This plan delivers the encoder and an availability answer (`h264` / `h265` / neither). Turning that into declared rates is Task 4's `sustainableRates`; feeding it real numbers needs a measured throughput probe, which is Task 8 here.

## Global Constraints

- **Verification is the human's.** This agent shell can run `dart run tool/verify_pure.dart` and `flutter pub get`, and nothing else — `flutter analyze` / `test` / `run` / `build` all fail with `CreateFile failed 231`. Every native task below therefore ends with "the human builds". Do not batch four platforms' worth of unverified C++ and hope.
- **Never run `flutter pub get` from the agent shell on Windows.** It writes broken plugin symlinks (`errno = 183` on the next build). The human runs it.
- **The fork stays rebasable.** New files are fine. Edits to existing upstream files are limited to: adding a member, adding a method, adding a dispatch entry, adding a source to `CMakeLists.txt`. Nothing upstream is rewritten.
- **Raw frames never enter Dart; nothing touches the disk.** Encoded bytes only.
- `camera_enum` is the announced index; the physical camera index never leaves the backend.
- Every command carrying an `id` is acked. Never apply-and-pretend.
- **An absent encoder is a correct answer, not a failure.** A box with no HEVC element announces H.264 only.

## Review Focus

1. **A second pipeline, not a tee branch.** Would fail with EBUSY at runtime, and `gst_parse_launch` would not catch it.
2. **The appsink callback touching the channel from the streaming thread.** Use-after-free on the `FlMethodChannel*`, not a race you can shrug off.
3. **Unbounded buffering.** An encoder that outruns Dart must shed frames, not accumulate them.
4. **A unit that cannot be decoded reaching the server.** The `pictures` cross-check is the only thing standing between a bad buffer and a corrupt recording.
5. **Declaring 60 because the pipeline accepted 60.** Only measurement declares a rate.

---

## Task 1: Which encoders exist (native)

**Files:** create `linux/encoded_stream_handler.h` / `.cc`; modify `linux/camera_desktop_plugin.cc`, `linux/CMakeLists.txt`

- [x] **Step 1** `EncodedStreamHandler::AvailableEncoders()` — a static list built with `gst_element_factory_find`, exactly the way `RecordHandler::DetectEncoder()` does it. H.264 candidates `vah264enc`, `vaapih264enc`, `nvv4l2h264enc`, `x264enc`, `openh264enc`, `avenc_h264`; H.265 candidates `vah265enc`, `vaapih265enc`, `nvv4l2h265enc`, `x265enc`, `avenc_hevc`. First present wins, per codec.
- [x] **Step 2** Add `availableEncoders` to the method dispatch. It needs no camera: answer from the class, not an instance. Returns a map of wire name → bool (`{"h264": true}`), not a list — *deviation from the original wording, deliberate*: `fl_value_append_take` could not be checked against the `flutter_linux` headers here (the Linux engine artifacts are not on this Windows box), whereas `fl_value_set_string_take` + `fl_value_new_bool` are already used by `handle_get_platform_capabilities` in the same file. Same reasoning as every other blind-compile decision in this plan: prefer the API that is provably in use.
- [x] **Step 3** Add the two new files to `PLUGIN_SOURCES` in `linux/CMakeLists.txt`.
- [ ] **Step 4** Human: `flutter build linux` (or `flutter run -d linux` on the Linux box). **Stop here if it does not compile** — everything below is worthless until the fork builds.

## Task 2: The branch

**Files:** `linux/encoded_stream_handler.{h,cc}`

- [ ] **Step 1** `Setup(GstElement* pipeline, GstElement* tee, GError** error)` — create `queue`, `videoconvert`, `encoder`, `parse`, `capsfilter`, `appsink`; add and link; `gst_element_sync_state_with_parent`. Mirror `RecordHandler::Setup` field for field.
- [ ] **Step 2** Queue bounds: `max-size-time=1s` plus a `leaky` setting that sheds frames rather than growing latency. Confirm the leak direction on the target box and write the measured choice into a comment.
- [ ] **Step 3** Encoder properties: `x264enc` → `tune=zerolatency`, `speed-preset=ultrafast`, `key-int-max`; `x265enc` equivalent. Set them by name only when the chosen element is the software one — a property a hardware element lacks is a hard error, not a warning.
- [ ] **Step 4** `parse` → `config-interval=-1` (see Decision 3).
- [ ] **Step 5** `capsfilter` → `video/x-h264,stream-format=byte-stream,alignment=au` (`x-h265` for HEVC), and assert the caps actually negotiated — a caps filter that silently failed is a stream of AVC-length-prefixed bytes that Dart will mangle.
- [ ] **Step 6** `appsink`: `sync=false`, `emit-signals=true`, `max-buffers=1`.
- [ ] **Step 7** `Start()` / `Stop()` that only move the branch: set the valve/queue state, do not touch the pipeline as a whole. `Stop()` sends EOS down the branch so the encoder flushes, and only then tears it down — that flush is the tail of the recording.

## Task 3: Handing bytes to Dart

**Files:** `linux/encoded_stream_handler.cc`, `linux/camera.h`

- [ ] **Step 1** `new-sample` callback: take the buffer, extract the bytes, and hand them to the main thread with `g_idle_add`. Nothing but the copy happens on the streaming thread.
- [ ] **Step 2** Main-thread callback: `fl_value_new_map` with `cameraId`, `pictures` (= 1, Decision 2) and `bytes` (`fl_value_new_uint8_list`); `fl_method_channel_invoke_method(channel, "encodedStreamPacket", …)`. Same shape as `Camera::SendError`.
- [ ] **Step 3** Bound in flight with an atomic counter, the way `image_stream_in_flight_` does. Over the bound: drop the buffer and count it.
- [ ] **Step 4** Threading comments on every field the streaming thread touches, matching the `C-2`…`C-5` convention already in `camera.h`.

## Task 4: Wire it into `Camera`

**Files:** `linux/camera.{h,cc}`, `linux/camera_desktop_plugin.cc`

- [ ] **Step 1** Add `std::unique_ptr<EncodedStreamHandler> encoded_stream_handler_` and call `Setup` from `BuildPipeline`, right after the existing `record_handler_->Setup(…)`.
- [ ] **Step 2** `StartEncodedStream(FlMethodCall*)` / `StopEncodedStream(FlMethodCall*)` on `Camera`, responding exactly like `StartVideoRecording` does (including the not-running error).
- [ ] **Step 3** Add both to the dispatch in `camera_desktop_plugin.cc`, alphabetically placed among the existing entries.
- [ ] **Step 4** `Dispose()` tears the branch down before the pipeline.

## Task 5: Dart side of the plugin

**Files:** `packages/camera_desktop/lib/src/camera_desktop_plugin.dart`

- [ ] **Step 1** An `EncodedStreamPacket` value type (`bytes`, `pictures`) — the plugin cannot import the app's type, so it declares its own and the app maps across.
- [ ] **Step 2** `startEncodedStream(cameraId, codec, width, height, fps, bitrate)`, `stopEncodedStream(cameraId)`, `availableEncoders()`.
- [ ] **Step 3** An `encodedStreamPacket` branch in `_handleNativeCall` feeding a per-camera `StreamController<EncodedStreamPacket>`, mirroring the `imageStreamFrame` branch.
- [ ] **Step 4** Nothing here may break `camera_platform_interface` conformance — no existing method changes signature.

## Task 6: The app's adapter

**Files:** create `lib/src/capture/plugin_encoded_stream.dart`; test in `tool/verify_pure.dart`

- [ ] **Step 1** Write the failing checks first: a fake plugin surface producing packets → `EncodedPacket`s 1:1; an absent plugin (wrong platform, cast fails) yields no channel and no throw; a camera with no native encoder yields no channel.
- [ ] **Step 2** `PluginEncodedStream implements EncodedStreamChannel`, obtaining the live plugin via `CameraPlatform.instance` and casting (Decision 5). **This file imports `package:flutter`** — it is the plugin-facing seam, and the pure-boundary rule exempts it. Keep it the only place that knows about the plugin.
- [ ] **Step 3** Run `dart run tool/verify_pure.dart` — expect PASS.
- [ ] **Step 4: Commit** → `feat(capture): reach the plugin's encoded stream from the device`

## Task 7: Availability becomes a codec probe

**Files:** `lib/src/capture/codec_probe.dart` (or a new plugin-backed probe), `lib/main.dart`, `tool/verify_pure.dart`

- [ ] **Step 1** A `CodecProbe` that reads `availableEncoders()` and unions with `BaselineCodecProbe`, via the existing `CompositeCodecProbe`. A platform with no native encoder still announces `mjpeg`.
- [ ] **Step 2** Wire it into `main.dart`'s probe composition.
- [ ] **Step 3** Run the harness. **Step 4: Commit.**

## Task 8: Measured rates (the part that makes the declaration honest)

**Files:** `tool/verify_pure.dart` first, then a real measurement path

- [ ] **Step 1** Pure checks for turning samples into `EncodeSample`s, reusing `sustainableRates` from Task 4 of the parent plan. No native code involved.
- [ ] **Step 2** On the Linux box: a short probe recording that reports the encoder's real sustained fps at the current geometry. Land the numbers — without them the device has no business announcing 60.
- [ ] **Step 3** Record the measurement for 1080p60 in `docs/implementation-status.md`, together with which encoder element was used. If 60 is not reachable in software on the target hardware, that is the finding, not a problem to paper over.

---

## Open items

1. **A Linux box.** Every native step above ends in the human building. Without one, Tasks 1-4 cannot be verified at all, and unverified C++ is how a fork becomes unmaintainable.
2. **Which encoder the target actually has.** VAAPI element names differ between `gstreamer1.0-vaapi` (`vaapih264enc`) and the newer `va` plugin (`vah264enc`); Intel VAAPI HEVC encode is unreliable across drivers. Expect "H.264 only" on many boxes and treat it as correct.
3. **Whether 1080p60 survives `videoconvert` from RGBA** (Decision 1). Measure before optimising.
