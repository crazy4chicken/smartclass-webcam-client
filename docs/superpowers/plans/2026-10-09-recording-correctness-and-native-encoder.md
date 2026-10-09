# Recording correctness & native H.264/H.265 encoder

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two recording-correctness bugs that Feature 1 turned from latent into live, then give the device a real encoder — capture and encode inside a forked native camera plugin so that 1080p60 H.264/H.265 is actually deliverable, with the declared capabilities measured rather than assumed.

**Architecture:** Phase A is two small coordinator fixes. Phase B replaces the frame path: each platform's camera plugin is forked to expose an *encoded* stream — capture and encode happen in-process, and only compressed access units cross into Dart — instead of the current `takePicture()` per frame, which cannot exceed roughly 5–10 fps at 1080p no matter what encoder is attached. One encoder implementation (libavcodec, GPL build with x264/x265) serves all platforms, using ffmpeg's hardware wrappers (`h264_vaapi`, `h264_videotoolbox`, `h264_mf`, `h264_mediacodec`) where the machine has them and software x264/x265 where it does not. What the device declares is what it measured: a throughput probe decides which rates and codecs are announced for the current mode.

**Tech Stack:** Dart 3.13 / Flutter; `camera` 0.12.1 + `camera_desktop` 2.0.0 + `camera_android_camerax` 0.7.5; forked native plugins in C/C++/Swift/Kotlin; libavcodec + libx264 + libx265 shipped as dynamic libraries.

**Spec:**
- `smartclass-webcam-server/docs/protocol/media.md` — one access unit per `recording.frame`, stored verbatim, no container
- `smartclass-webcam-server/docs/protocol/registration.md` — `supported_resolutions`, `supported_framerates`, `supported_codec`; **no pairwise restriction** between the lists
- `smartclass-webcam-server/docs/protocol/control.md` — `start_recording.codec`, `switch_camera` parameters, "a switch to another camera leaves that camera at the parameters it reported in its registration"

## Global Constraints

- **Verification gate.** `dart run tool/verify_pure.dart` is the only test that runs in an agent shell — put every new decision there. `flutter test` needs the human's terminal; mirror its most brittle assertions into the harness.
- **Pure boundary.** `lib/src/backend`, `lib/src/capture` (non-plugin files), `lib/src/config` and `lib/src/app/capability_bootstrap.dart` must stay free of `package:flutter`. New `package:camera` code goes in its own file.
- **Raw frames never enter Dart, and no frame touches the disk.** The encoder lives in the native plugin; Dart sees encoded access units only.
- **A declared rate is a measured rate.** Nothing announces 60 fps because a camera accepted a setting; the throughput probe decides.
- **The protocol has no pairwise restriction.** A device cannot express "H.265 only up to 1080p30". So the codec list is computed *for the current mode*, and a request the device cannot sustain is acked `ok:false` — the server's stream row stays `active` and never rolls back.
- **One access unit per `recording.frame`**, no container, in-band SPS/PPS (VPS for HEVC). `EncodedFrame.isKeyFrame` already models this.
- `camera_enum` is the announced index everywhere; the physical camera index never leaves the backend.
- Every command carrying an `id` is acked. Never apply-and-pretend.
- **Licensing is an action, not an opinion.** libx264/libx265 are GPLv2+. Shipping them makes the distributed binary GPLv2+: `LICENSE` must change and every release must offer the corresponding source. Do not start Task 11 without that acknowledged.

## Review Focus

1. **`start_recording` naming a camera that is not the open one.** Today it acks `ok:true` and records whatever is open. Frames are filed under another camera's id, and since Feature 1 each camera announces its own ceiling, under the wrong `metadata.resolution` too.
2. **A bare `switch_camera` between cameras with different ceilings.** The rebuild is skipped, so the new camera runs at the old camera's geometry while the registration announces its own.
3. **A rate the encoder cannot sustain.** Announcing 60 because `MediaSettings(fps: 60)` was accepted makes the server overstate `duration_ms` — `media.md` warns about exactly this.
4. **H.265 requested where only H.264 is sustainable.** Must ack `ok:false`; the stream stays `active`. Encoding H.264 and acking `ok` produces a recording that is not what was asked for.
5. **A truncated or unparsable access-unit stream from the encoder.** Drop the batch, never emit partial NALs — the server stores bytes verbatim and has no way to notice.

---

## Phase A — Recording correctness (land this first)

### Task 1: `start_recording` must activate the camera it names

**Files:**
- Modify: `lib/src/agent/agent_coordinator.dart`
- Test: `tool/verify_pure.dart` (add to the coordinator section)

- [ ] **Step 1: Write the failing checks**

```dart
// start_recording for camera 1 while camera 0 is open
check('it activates the named camera', h.camera.cameraIndex == 1);
check('and acks ok', h.gateway.acks.single.ok);
// ...and when the switch cannot be done
check('an unreachable camera is refused', h.gateway.acks.single.ok == false);
check('and no pump was started', h.pump.startCalls == 0);
```

- [ ] **Step 2: Run `dart run tool/verify_pure.dart`** — expect the new checks to fail.

- [ ] **Step 3: Extract the activation path**

Move the body of `_switchCamera` from `final previous = _modeFor(cameraEnum)` through `_setMode(cameraEnum, requested)` into:

```dart
/// Makes [cameraEnum] the active camera at [requested], or says why not.
/// Returns null on success.
Future<String?> _activateCamera(int cameraEnum, CameraMode requested) async
```

`_switchCamera` keeps its null-camera and recording guards, calls it, and acks with the returned reason. The re-registration condition is unchanged: `requested.differsFrom(previous)`.

- [ ] **Step 4: Call it from `_startRecording`**

After the codec check and before `_pumpFactory()`, activate `command.cameraEnum` at `_modeFor(command.cameraEnum)` when it differs from `_cameraEnum`; on failure ack `ok:false` with the reason and start nothing.

- [ ] **Step 5: Run the harness** — expect PASS.

- [ ] **Step 6: Commit** → `fix(agent): start_recording must activate the camera it names`

### Task 2: A bare switch must rebuild when the ceilings differ

**Files:**
- Modify: `lib/src/agent/agent_coordinator.dart`
- Test: `tool/verify_pure.dart`

**Why this is a bug:** `resolutionChanged` compares `requested.resolution` against `previous.resolution`, and `previous` is `_modeFor(cameraEnum)` — the *target* camera's own mode. For a switch with no parameters those are the same object, so the flag is always false and the rebuild never happens. Before Feature 1 every camera shared one ceiling and this was invisible; now they differ.

- [ ] **Step 1: Write the failing check**

Build a two-camera fixture whose ceilings differ (1080p and 720p). Assert that a bare `switch_camera(cameraEnum: 1)` leaves `camera.lastConfig` at 1280x720 and `activeMode.resolution` at 1280x720. The existing identical-ceiling case must still assert `reconfigureCalls == 0` — do not weaken it.

- [ ] **Step 2: Run the harness** — expect failure.

- [ ] **Step 3: Compare against the built geometry**

```dart
final resolutionChanged = requested.resolution != _config.resolution;
```

`_config` is what the pipeline is actually built at; the target camera's announced mode is what it *should* be at. Compare the two.

- [ ] **Step 4: Run the harness** — expect PASS, including the unchanged identical-ceiling case.

- [ ] **Step 5: Commit** → `fix(agent): rebuild the geometry when switching to a different ceiling`

---

## Phase B — Native encoder

### Task 3: Annex B access-unit splitter (pure)

**Files:**
- Create: `lib/src/capture/annexb.dart`
- Test: `tool/verify_pure.dart`

- [ ] **Step 1: Write the failing checks** — handcrafted byte vectors for both NAL families: 3-byte and 4-byte start codes, SPS/PPS/VPS/SEI attaching to the following AU, VCL NAL starting a new AU, IDR (H.264 type 5, HEVC ≥ 19 and < 32) marking a keyframe, empty input, and a trailing fragment with no start code.

- [ ] **Step 2: Implement**

```dart
class AccessUnit {
  const AccessUnit({required this.bytes, required this.isKeyFrame});
}

/// Splits an Annex B elementary stream into access units.
/// A trailing incomplete unit is dropped, never emitted partial.
List<AccessUnit> splitAnnexB(Uint8List bytes, {required CaptureCodec codec});
```

Document the single-slice-per-frame assumption (true for the encoder arguments used in Task 6 onward: no B-frames).

- [ ] **Step 3: Run the harness** — expect PASS. **Step 4: Commit.**

### Task 4: Sustainable-rate model (pure)

**Files:**
- Create: `lib/src/capture/encode_budget.dart`
- Test: `tool/verify_pure.dart`

- [ ] **Step 1: Write the failing checks** — measured samples → declared rates (round **down**, never up); a sample too slow for the lowest declared rate yields an empty list; codecs with no sustainable rate are omitted; the model is monotone.

- [ ] **Step 2: Implement**

```dart
class EncodeSample { final CaptureCodec codec; final CameraResolution resolution; final int measuredFps; }

/// Rates the device can actually hold, per codec, for one geometry.
/// Also the source of the per-mode `supported_codec` list.
Map<CaptureCodec, List<int>> sustainableRates(List<EncodeSample> samples, List<int> candidates);
```

- [ ] **Step 3: Run the harness** — expect PASS. **Step 4: Commit.**

### Task 5: Dart-side encoder contract

**Files:**
- Modify: `lib/src/capture/video_encoder.dart`
- Create: `lib/src/capture/native_video_encoder.dart` (the plugin-facing side; keep it Flutter-free, talk to the plugin through an injectable channel interface)
- Test: `tool/verify_pure.dart` with a fake channel

- [ ] **Step 1: Write the failing checks** — frames emitted 1:1 with the AU stream; `stop()` flushes; a count mismatch drops the whole batch; an unparsable stream emits nothing; `isKeyFrame` tracks IDR.

- [ ] **Step 2: Implement `NativeVideoEncoder implements VideoEncoder`** over an injected `EncodedStreamChannel { Stream<Uint8List> open(...); Future<void> close(); }`, splitting with Task 3 and emitting `EncodedFrame`.

- [ ] **Step 3: Run the harness** — expect PASS. **Step 4: Commit.**

### Task 6: Native encoded stream — Linux

**Files:**
- Fork `camera_desktop` into the repo (vendored), Linux side: `linux/camera.cc`, `linux/camera.h`, plugin registration
- Dart: `lib/src/capture/plugin_encoded_stream.dart`

- [ ] **Step 1** Vendor the plugin and prove the existing preview still builds and runs. **This is the gate for Tasks 7–9** — if the fork is not viable, stop and escalate rather than continuing.

- [ ] **Step 2** Add an encoded-stream branch to the GStreamer pipeline: capture (`v4l2src`, MJPEG caps at high resolution) → decode → `videoconvert` → encoder → `appsink` emitting encoded bytes.

- [ ] **Step 3** Link libavcodec (GPL build) and select the encoder at runtime, best first: `h264_vaapi` / `hevc_vaapi` → `nvv4l2h264enc` / `nvv4l2h265enc` → `x264enc`-equivalent software path (`libx264`, `speed-preset=ultrafast|veryfast`) → `libx265` for HEVC.

- [ ] **Step 4** Surface availability to Dart so Task 4's probe has real input.

- [ ] **Step 5: Commit** → `feat(plugin): encoded camera stream on Linux`

### Task 7: Native encoded stream — Windows

Same shape, Media Foundation. Encoder order `h264_mf` → `hevc_mf` → software `libx264` / `libx265`. Probe decides; a machine with no HEVC path announces H.264 only. Commit per platform.

### Task 8: Native encoded stream — macOS

Same shape, VideoToolbox (`h264_videotoolbox` / `hevc_videotoolbox`), reusing the vendored plugin's existing Swift FFI infrastructure. Commit per platform.

### Task 9: Native encoded stream — Android

Fork `camera_android_camerax` (**a second fork** — Android does not use `camera_desktop`), CameraX for capture and `h264_mediacodec` / `hevc_mediacodec`. Device-dependent: a phone with no HEVC encoder announces H.264 only. This is the most expensive task; it can be deferred without blocking 6–8.

### Task 10: Coordinator swap and per-mode codec list

**Files:**
- Modify: `lib/src/agent/agent_coordinator.dart`, `lib/main.dart`
- Test: `tool/verify_pure.dart`

- [ ] **Step 1: Write the failing checks** — a recording at 60 fps with a sustainable codec acks `ok`; an unsustainable codec acks `ok:false` and starts no pump; an absent codec uses the first entry of the *current mode's* list; a mode change re-registers with a recomputed codec list; `take_photo` still goes through the still path and stays JPEG.

- [ ] **Step 2** Replace `FramePumpFactory` with `EncoderFactory = VideoEncoder Function(CaptureCodec)`. `MjpegEncoder` still wraps the pump byte-for-byte and remains the fallback when no native stream is available.

- [ ] **Step 3** `_onCapturedFrame` consumes `EncodedFrame`. Keep the existing "claim the stream before starting the producer" ordering.

- [ ] **Step 4** Compute `supported_codec` **per mode** from Task 4's output and re-register when the mode changes — the existing re-registration path already fires on mode change, so this rides on it.

- [ ] **Step 5** `main.dart` composes the codec probe from `BaselineCodecProbe()` and the native probe; the README's "added here and nowhere else" rule for the backend chain still applies.

- [ ] **Step 6: Run the harness** — expect PASS. **Step 7: Commit.**

### Task 11: Licensing, packaging and documentation

- [ ] **Step 1** Change `LICENSE` to GPLv2+ and note the obligation to offer source with every release. Do this only after the human confirms — see Global Constraints.
- [ ] **Step 2** Ship the dynamic libraries next to the app on all four platforms; update the release workflow's staging steps (each platform's artifact grows).
- [ ] **Step 3** Update `README.md` (codec selection, no-disk guarantee, platform matrix) and `docs/implementation-status.md` (T9 from "deliberately not done" to implemented, with the GPL deviation recorded).
- [ ] **Step 4** Note in `docs/android-setup.md` that `minSdk` must be 24 if MediaCodec is required.
- [ ] **Step 5: Commit.**

---

## Open items (decide before starting, not during)

1. **Android in or out of this pass?** Task 9 is the second plugin fork and the largest single piece. Tasks 6–8 and 10 deliver a working 1080p60 device on the three desktop platforms without it.
2. **Confirm the GPL move.** Task 11 changes the project's licence. Everything before it is licence-neutral.
3. **Hardware encoder availability is machine-dependent**, especially HEVC on Linux (Intel VAAPI HEVC encode is unreliable across drivers). Expect Linux boxes to announce H.264 only; the plan treats that as correct, not as a failure.
