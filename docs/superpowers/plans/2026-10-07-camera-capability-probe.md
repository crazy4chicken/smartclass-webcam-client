# Camera Capability Probe & Protocol v0.3.0 Adaptation

> **✅ 已执行完毕（2026-10-08）。** T1–T9 全部落地，提交 `23e7495`…`8be70c7`，
> 外加文档 `8c2b709`、测试修复 `dbd1135`、真机 bug 修复 `61504e9`。
>
> **本计划的逐任务实施报告（实现了什么、8 处有意偏离、与计划冲突的 1 处、
> 未验证项与 deferred 清单）见
> `docs/2026-10-07-camera-capability-probe-implementation.md`。**
> 跨五个计划的总览见 `docs/implementation-status.md`。
>
> 本文中的 `- [ ]` 复选框**未逐个勾选（0/57）** —— 该计划是一次性执行的，
> 其中 18 步是「跑 `flutter test` 期望 PASS」这类本机无法执行的步骤，
> 逐个勾选会把它们标成已完成，反而不准。执行状态以上面那份报告为准。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the device's cameras into a canonical order, measure what each can actually do (resolutions + frame rates), persist that per camera set, announce it on `GET /ws/register`, and let the server drive the device's mode through the new `switch_camera` parameters and `start_recording.codec`.

**Architecture:** Three passes over the camera list, cheapest first. A **ranking** pass opens each camera once at the top preset to learn its real ceiling; a pure ordering function then permutes the list into a canonical order — rear, then external, then front, highest resolution first within each group — and that order becomes `camera_enum` everywhere downstream, so no code ever holds two different indices. A **full probe** then walks the preset ladder on each camera, taking a real still and reading the JPEG's true pixel size, because the plugin stack exposes no enumeration API and "supported" can only mean "we asked and it produced". Frame rates are probed only at the top measured resolution. Results are cached under a fingerprint of the ordered camera list, so a changed camera set re-probes and an unchanged one does not.

**Tech Stack:** Flutter / Dart 3.13, `camera` 0.12.1 + `camera_desktop` 2.0.0, `shared_preferences`, existing pure-Dart capture layer.

**Spec:**
- `smartclass-webcam-server/docs/protocol/registration.md` (v0.3.0 — `supported_resolutions`, `supported_framerates`, `supported_codec`)
- `smartclass-webcam-server/docs/protocol/control.md` (v0.3.0 — `switch_camera` parameters, `start_recording.codec`)
- Upstream commits `531c74f feat(webcam)!: let cameras declare their supported parameters`, `53814b3 docs(webcam)`

## Global Constraints

- Resolutions are **absolute pixels** everywhere. Never assume `ResolutionPreset.medium == 720p`.
- **Camera order is canonical and declared once.** `camera_enum` is the announced index everywhere; the physical camera index never leaves the backend. Camera 0 is the highest-ranked rear camera, camera 1 the highest-ranked front camera; the rest follow rear → external → front, each group by total pixels descending.
- **Windows reports every camera as `front` and Linux as `external`** — both hardcoded in `camera_desktop` (`windows/camera_desktop_plugin.cpp:240` sends the literal `0`; `linux/device_enumerator.cc:129` and `pipewire_portal.cc:331` send `2`). Only macOS and Android report real directions. **On those two platforms the rear/front rule degenerates to "highest resolution first" and camera 0 is simply the strongest camera.** Code and comments must say this out loud.
- Declared lists are the **union of measured values and the common ladder, capped at the highest measured resolution.** Never declare a resolution above what was measured.
  - Common resolutions: `320x240, 640x480, 800x600, 1024x768, 1280x720, 1920x1080, 2560x1440, 3840x2160`.
  - Common frame rates: `5, 10, 15, 20, 24, 25, 30, 50, 60`.
- The server rejects a registration whose `supported_resolutions` or `supported_framerates` is empty, contains duplicates, or does not contain that camera's current `resolution` / `fps`. All three are `400`.
- `supported_codec` is non-empty, drawn from `h264, h265, mjpeg, mpeg4, vp8, vp9, av1`, exact lowercase, no duplicates, no aliases.
- A device captures from exactly one camera at exactly one resolution and frame rate at a time; only `switch_camera` changes them, and a recording never changes them.
- `start_recording.codec` must be one of the camera's `supported_codec`; absent means the device's preferred codec — **the first entry** of the announced list.
- Every command carrying an `id` is acked. Silently ignoring a requested codec or resolution is forbidden: ack `ok:false` with `error`.
- `lib/src/capture/` (non-plugin files), `lib/src/backend/` and `lib/src/config/` must stay Flutter-free — `tool/verify_pure.dart` imports them. Anything touching `package:camera` goes in its own file.
- Capabilities are **never** persisted through `ConnectionSettings` / `SettingsStore.save()`. `save()` means *replace*, and `credentials == null` deletes the stored pair. Capabilities get their own store and their own keys.
- **Today's codec support is `mjpeg` only.** The probe must not announce a codec the client cannot produce. H.264/H.265 belong to the separate native-encoder plan and are out of scope here.
- The probe writes temporary JPEGs (`takePicture()`). That is acceptable — it runs a handful of times at bootstrap, not in the frame path. The no-disk recording pipeline is a separate plan.

## Review Focus

1. **Duplicate resolutions.** Two presets regularly resolve to the same real size; the server answers `400 … must not contain duplicates`. Dedupe is a hard rule, not tidy-up.
2. **Current pair absent from the declared lists.** `AppConfig.defaultFps` is `5`; if only `[60,30,15]` are declared, `fps: 5` is a `400`. The declared list must always contain the mode the device is actually at.
3. **Probe yields nothing.** No camera, permission denied, or every open throws → both lists would be empty → `400`. There must be a fallback that still lets the kiosk register.
4. **A command naming something the device cannot do.** `switch_camera` with an unprobed resolution, or `start_recording` with `codec: h264`. Must ack `ok:false`, never apply-and-pretend.
5. **`switch_camera` changes a parameter but the server stores nothing.** Its `metadata.resolution` / `metadata.fps` snapshot comes from the registration, so a local-only switch desynchronises server-side metadata. The device must re-register after a parameter-changing switch.
6. **A platform whose lens direction is fabricated.** Windows (all `front`) and Linux (all `external`) give the ordering nothing to group by. The device must still register, camera 0 must still be its strongest camera, and no code path may assume a rear camera exists.

---

### Task 1: Capability model, common ladder and JPEG size reader

**Files:**
- Create: `lib/src/capture/camera_capabilities.dart`
- Modify: `lib/src/capture/jpeg.dart:64` (append after `trimJpegPadding`)
- Test: `test/capture/camera_capabilities_test.dart`, `test/capture/jpeg_test.dart`

**Interfaces:**
- Consumes: `CameraResolution` from `camera_resolution.dart`.
- Produces: `CameraCapabilities`, `jpegSize`, `kCommonResolutions`, `kCommonFramerates` — used by Tasks 2, 3, 4, 5, 7, 8, 9.

- [ ] **Step 1: Write the failing tests**

```dart
// test/capture/camera_capabilities_test.dart
test('of() drops duplicates and sorts by pixel count, descending');
test('withCurrent() adds a resolution the probe never produced');
test('withCurrent() adds an fps the probe never produced');
test('withCommonBaseline() adds common resolutions the probe did not produce');
test('withCommonBaseline() never adds a resolution above the measured maximum');
test('withCommonBaseline() adds the common frame rates');
test('withCommonBaseline() on empty capabilities stays empty');
test('withCommonBaseline() output is still deduped and sorted');
test('empty capabilities stay empty and report isEmpty');
test('toJson/fromJson round-trips');
test('fromJson ignores malformed input rather than throwing');

// test/capture/jpeg_test.dart
test('jpegSize reads the SOF0 dimensions');
test('jpegSize returns null for a buffer that is not a JPEG');
test('jpegSize returns null when no SOF marker is present');
```

- [ ] **Step 2: Run `flutter test test/capture/camera_capabilities_test.dart test/capture/jpeg_test.dart`** — expect compile failures (missing declarations).

- [ ] **Step 3: Implement `lib/src/capture/camera_capabilities.dart`**

```dart
/// Ladder of resolutions worth offering an operator even when the probe did
/// not surface them. Capped by the measured maximum before use, so a 480p
/// webcam is never advertised as 4K.
const List<CameraResolution> kCommonResolutions = <CameraResolution>[
  CameraResolution(width: 320, height: 240),
  CameraResolution(width: 640, height: 480),
  CameraResolution(width: 800, height: 600),
  CameraResolution(width: 1024, height: 768),
  CameraResolution(width: 1280, height: 720),
  CameraResolution(width: 1920, height: 1080),
  CameraResolution(width: 2560, height: 1440),
  CameraResolution(width: 3840, height: 2160),
];

const List<int> kCommonFramerates = <int>[5, 10, 15, 20, 24, 25, 30, 50, 60];

class CameraCapabilities {
  const CameraCapabilities({required this.resolutions, required this.framerates});
  final List<CameraResolution> resolutions;
  final List<int> framerates;

  static const CameraCapabilities empty = CameraCapabilities(resolutions: [], framerates: []);
  bool get isEmpty;

  /// Dedupes and sorts: resolutions by pixel count descending, framerates descending.
  factory CameraCapabilities.of({required Iterable<CameraResolution> resolutions, required Iterable<int> framerates});

  /// Union with the common ladder, dropping anything larger than the highest
  /// measured resolution. Empty in, empty out: with nothing measured there is
  /// no ceiling to cap against and nothing honest to add.
  CameraCapabilities withCommonBaseline();

  /// Declares the camera's current mode, adding [resolution]/[fps] when the probe
  /// did not surface them — the server rejects a current pair that is not declared.
  /// Always applied last.
  CameraCapabilities withCurrent({required CameraResolution resolution, required int fps});

  Map<String, Object?> toJson();
  static CameraCapabilities fromJson(Object? raw);
}
```

- [ ] **Step 4: Implement `jpegSize(Uint8List bytes) -> CameraResolution?` in `lib/src/capture/jpeg.dart`**

Walk markers from the SOI, skipping stand-alone markers, and read height/width from the first SOF (`0xC0`–`0xC3`, `0xC5`–`0xC7`, `0xC9`–`0xCB`, `0xCD`–`0xCF`). Return `null` when no SOF is found or the buffer is too short. Pure; no Flutter import.

- [ ] **Step 5: Run the tests** — expect PASS.

- [ ] **Step 6: Commit** `git add lib/src/capture/camera_capabilities.dart lib/src/capture/jpeg.dart test/capture/` → `feat(capture): add capability model, common ladder and JPEG size reader`

---

### Task 2: Canonical camera order

**Files:**
- Create: `lib/src/capture/camera_order.dart` (pure ordering)
- Create: `lib/src/capture/plugin_camera_ranker.dart` (the `package:camera` ranking pass)
- Modify: `lib/src/capture/camera_plugin_backend.dart`
- Test: `test/capture/camera_order_test.dart`, `test/capture/plugin_camera_ranker_test.dart`

**Interfaces:**
- Consumes: `CameraDescriptor` from `camera_service.dart`; `CameraResolution` (Task 1).
- Produces: `canonicalCameraOrder`, `CameraGroup`, `RankedCamera`, `CameraRanker` — used by Tasks 3 and 8.

- [ ] **Step 1: Write the failing tests**

```dart
// test/capture/camera_order_test.dart
test('back cameras come before external, external before front');
test('within a group, cameras are ordered by pixel count descending');
test('the strongest back camera lands at index 0');
test('the strongest front camera lands at index 1 when a back camera exists');
test('a device with no back camera puts its strongest remaining camera at 0');
test('all-front devices (Windows) fall back to pure resolution order');
test('all-external devices (Linux) fall back to pure resolution order');
test('a camera whose rank probe failed sorts last within its group');
test('the result is always a permutation of the input indices');
test('an unknown lens direction is treated as external');

// test/capture/plugin_camera_ranker_test.dart
test('ranks every camera with exactly one open each');
test('a camera that fails to open reports no ceiling instead of throwing');
test('rank never throws');
```

- [ ] **Step 2: Run `flutter test test/capture/camera_order_test.dart test/capture/plugin_camera_ranker_test.dart`** — expect failure.

- [ ] **Step 3: Implement `lib/src/capture/camera_order.dart`**

```dart
/// Sort key for the canonical order. **Declaration order is the group order**:
/// rear first, then external, then front.
enum CameraGroup { back, external, front }

/// Maps the plugin's `lensDirection.name` onto a group.
/// `back` → [CameraGroup.back]; `front` → [CameraGroup.front];
/// anything else — including `external` and `unknown` — → [CameraGroup.external].
CameraGroup cameraGroupFor(String lensDirectionName);

class RankedCamera {
  const RankedCamera({required this.index, required this.group, this.maxPixels = 0});
  final int index;      // physical camera index
  final CameraGroup group;
  final int maxPixels;  // 0 when the ranking probe could not measure it
}

/// Physical camera indices in canonical (announced) order.
/// Always a permutation of the input indices.
List<int> canonicalCameraOrder(List<RankedCamera> cameras);
```

Sort by `(group, -maxPixels, index)`. The trailing `index` keeps the result stable for ties, which is what lets an all-`front` Windows box or an all-`external` Linux box collapse to plain resolution order without a special case.

Add a comment recording *why* the groups exist and that two of the four platforms cannot fill them: `` hardcodes `lensDirection` to `0` on Windows and `2` on Linux, so on those targets every camera lands in one group and the order is resolution alone.

- [ ] **Step 4: Implement `lib/src/capture/plugin_camera_ranker.dart`**

```dart
abstract interface class CameraRanker {
  /// Never throws. A camera that cannot be opened reports `maxPixels: 0`.
  Future<List<RankedCamera>> rank(List<CameraDescriptor> devices);
}
```

Open each device **once** at `ResolutionPreset.max` with audio off, `initialize()`, read `controller.value.previewSize`, `dispose()`. One open per camera is the whole point: ranking runs before ordering, so it cannot know which cameras matter yet, and a full probe here would cost `n × 9` opens.

- [ ] **Step 5: Give `CameraPluginBackend` the permutation**

Add an optional `List<int>? cameraOrder` constructor argument mapping announced → physical index (null means identity, which keeps every existing test working). Build `_descriptors` in canonical order so `CameraDescriptor.index` **is** the announced enum, and resolve `switchCamera(enum)` through the permutation before touching `_cameras`. The physical index must not appear anywhere outside this file.

- [ ] **Step 6: Run the tests** — expect PASS.

- [ ] **Step 7: Commit** → `feat(capture): order cameras rear-then-front by measured ceiling`

---

### Task 3: Capability probe

**Files:**
- Create: `lib/src/capture/capability_probe.dart` (pure contract)
- Create: `lib/src/capture/plugin_capability_probe.dart` (the `package:camera` implementation)
- Modify: `test/support/doubles.dart` (add a fake controller)
- Test: `test/capture/plugin_capability_probe_test.dart`

**Interfaces:**
- Consumes: `CameraCapabilities`, `jpegSize` (Task 1); `CameraLister`, `FrameStore` from the capture layer.
- Produces: `CapabilityProbe` / `PluginCapabilityProbe` — used by Tasks 8 and 9.

- [ ] **Step 1: Write the failing tests**

```dart
test('probes every preset and returns the sizes the camera really produced');
test('drops a preset whose open throws, without failing the whole probe');
test('drops a preset whose picture cannot be read');
test('probes frame rates only at the highest measured resolution');
test('drops a frame rate whose open throws');
test('returns empty capabilities and a detail when no camera is present');
test('returns empty capabilities when every open throws');
test('probes the physical camera it was asked about');
test('never throws, whatever the camera does');
```

- [ ] **Step 2: Run `flutter test test/capture/plugin_capability_probe_test.dart`** — expect failure.

- [ ] **Step 3: Implement `lib/src/capture/capability_probe.dart`** (Flutter-free)

```dart
/// Probed highest-first: a device that cannot hold 60 must still be offered 30.
const List<int> kProbeFramerates = <int>[60, 30, 15];

class CapabilityProbeResult {
  const CapabilityProbeResult({required this.capabilities, this.detail});
  final CameraCapabilities capabilities;
  final String? detail;
}

abstract interface class CapabilityProbe {
  /// Probes one physical camera. Never throws: a failure shows up as empty
  /// [capabilities] plus [detail].
  Future<CapabilityProbeResult> probe(int physicalCameraIndex);
}
```

The probe takes a **physical** index because it runs against the plugin's own list; the announced index lives in Task 2's permutation and is applied by the caller.

- [ ] **Step 4: Implement `lib/src/capture/plugin_capability_probe.dart`**

`plugin_capability_probe.dart` also holds the preset ladder, because `ResolutionPreset` comes from `package:camera` and would break `tool/verify_pure.dart` if it leaked into the pure file:

```dart
const List<ResolutionPreset> kProbePresets = <ResolutionPreset>[
  ResolutionPreset.low, ResolutionPreset.medium, ResolutionPreset.high,
  ResolutionPreset.veryHigh, ResolutionPreset.ultraHigh, ResolutionPreset.max,
];

typedef ProbeControllerFactory = CameraController Function(
  CameraDescription description, ResolutionPreset preset, int? fps,
);

class PluginCapabilityProbe implements CapabilityProbe {
  PluginCapabilityProbe({CameraLister? listCameras, ProbeControllerFactory? controllerFactory, FrameStore frameStore = const IoFrameStore()});
}
```

Per camera, in this order:
1. List cameras; an out-of-range index → empty result with a detail.
2. For each preset in `kProbePresets`: build a controller with `enableAudio: false` and no fps, `initialize()`, `takePicture()`, read through `FrameStore`, `jpegSize()`, `dispose()`. Collect non-null sizes. **Wrap every preset in its own try/catch** — a preset that fails contributes nothing and must not abort the others.
3. Build `CameraCapabilities.of(...)`. Empty → return empty.
4. Let `top` be the largest measured resolution. For each fps in `kProbeFramerates`: build a controller at `_presetForHeight(top.height)` with `fps: value`, `initialize()`, `dispose()`. Success adds the value; a throw drops it. No picture needed.

Reuse the existing `_presetForHeight` helper from `camera_plugin_backend.dart` by exporting it. The default factory must pass `fps` through to `CameraController(..., fps: fps)` — `camera` 0.12.1 takes it as a named argument (`camera_controller.dart:251`).

- [ ] **Step 5: Run the tests** — expect PASS.

- [ ] **Step 6: Commit** → `feat(capture): probe real camera resolutions and frame rates`

---

### Task 4: Capability persistence

**Files:**
- Create: `lib/src/config/capabilities_store.dart` (pure interface + fingerprint)
- Create: `lib/src/config/shared_prefs_capabilities_store.dart`
- Test: `test/config/capabilities_store_test.dart`

**Interfaces:**
- Consumes: `CameraCapabilities` (Task 1).
- Produces: `CapabilitiesStore`, `cameraFingerprint` — used by Tasks 8 and 9.

- [ ] **Step 1: Write the failing tests**

```dart
test('fingerprint changes when a camera is added');
test('fingerprint changes when two cameras swap places');
test('fingerprint is stable for the same camera list');
test('load returns null when nothing was stored');
test('load returns null when the stored fingerprint differs');
test('save then load round-trips the capabilities');
test('save does not touch the stored device credentials');  // regression guard
test('load returns empty capabilities rather than throwing on corrupt JSON');
```

- [ ] **Step 2: Run `flutter test test/config/capabilities_store_test.dart`** — expect failure.

- [ ] **Step 3: Implement `lib/src/config/capabilities_store.dart`**

```dart
/// Identifies a camera set. Order-sensitive: `camera_enum` is positional, so
/// swapping two cameras changes what index 0 means.
String cameraFingerprint(List<String> cameraNames);

abstract interface class CapabilitiesStore {
  /// The cached capabilities for [fingerprint], or null when none are cached
  /// for that exact camera set — null is the trigger for re-probing.
  Future<CameraCapabilities?> load(String fingerprint);
  Future<void> save(String fingerprint, CameraCapabilities capabilities);
  Future<void> clear();
}
```

The fingerprint is taken over camera **names in canonical order**, so re-ordering the cameras invalidates the cache the same way swapping hardware does.

- [ ] **Step 4: Implement `lib/src/config/shared_prefs_capabilities_store.dart`**

Two keys, `camera_capabilities_fingerprint` and `camera_capabilities_json`, mirroring `shared_prefs_settings_store.dart`. Write the fingerprint and the JSON together so a partial write can never produce a hit for the wrong camera set. A read that fails to parse answers `null`, not an exception.

This store is deliberately separate from `SettingsStore`. Add a comment stating why: routing capabilities through `ConnectionSettings.save()` would replace the stored settings wholesale and delete a working device's credentials.

- [ ] **Step 5: Run the tests** — expect PASS.

- [ ] **Step 6: Commit** → `feat(config): cache camera capabilities per camera set`

---

### Task 5: Announce the supported lists

**Files:**
- Modify: `lib/src/backend/registration_request.dart`
- Test: `test/backend/registration_request_test.dart`

**Interfaces:**
- Consumes: `CameraCapabilities` (Task 1); `WireCodec` (`protocol/envelope.dart`).
- Produces: `CameraDeclaration`, the new `buildAnnouncements` — used by Tasks 7 and 8.

- [ ] **Step 1: Write the failing tests**

```dart
test('each camera emits supported_resolutions and supported_framerates');
test('a resolution produced by two presets is announced once');
test('the current resolution and fps are always among the declared values');
test('a camera with empty capabilities falls back to its current pair');
test('the codec list is emitted verbatim and stays non-empty');
test('camera_enum equals the element index, in canonical order');
test('attrs.label still carries the camera name');
```

- [ ] **Step 2: Run `flutter test test/backend/registration_request_test.dart`** — expect failure.

- [ ] **Step 3: Extend `CameraAnnouncement`**

Add `List<CameraResolution> supportedResolutions` (default `const []`) and `List<int> supportedFramerates` (default `const []`), and emit them in `toJson()` as `supported_resolutions` (labels) and `supported_framerates` (ints).

- [ ] **Step 4: Replace the parallel-array `buildAnnouncements` with a per-camera declaration**

```dart
class CameraDeclaration {
  const CameraDeclaration({
    required this.name,
    required this.resolution,   // the mode this camera is at now
    required this.fps,
    required this.capabilities, // what it accepts
  });
}

List<CameraAnnouncement> buildAnnouncements({
  required List<CameraDeclaration> cameras,
  required List<WireCodec> codecs,
  Map<String, Object?> attrs = const <String, Object?>{},
});
```

One object per camera replaces four positional lists; passing capabilities positionally is exactly how the old code handed camera 0 the lowest rung of the ladder. The list arrives already in canonical order and `camera_enum` is its index.

Inside, per camera: `capabilities.withCommonBaseline().withCurrent(resolution: …, fps: …)`. If that is still empty, substitute a one-element list holding the current resolution / fps. The server hard-rejects an empty list, and a kiosk that cannot register is worse than one that declares only what it is doing.

Keep `minAnnounceableFps` clamping and the empty-codec fallback to `mjpeg`.

- [ ] **Step 5: Update the existing call sites and their tests** to the new signature.

- [ ] **Step 6: Run the tests** — expect PASS.

- [ ] **Step 7: Commit** → `feat(backend): announce supported resolutions and frame rates`

---

### Task 6: New command parameters

**Files:**
- Modify: `lib/src/backend/protocol/device_command.dart`
- Modify: `lib/src/backend/protocol/envelope.dart:141-152`
- Test: `test/backend/protocol/envelope_test.dart`

**Interfaces:**
- Consumes: `CameraResolution` (`capture/camera_resolution.dart`), `CaptureCodec` (`capture/stream_settings.dart`).
- Produces: the extended commands — consumed by Task 7.

- [ ] **Step 1: Write the failing tests**

```dart
test('switch_camera carries resolution and fps when they are present');
test('switch_camera leaves them null when the payload omits them');
test('a whitespace-only resolution counts as absent');
test('start_recording carries the requested codec');
test('start_recording leaves the codec null when it is absent');
test('an unknown codec string decodes to null rather than throwing');
```

- [ ] **Step 2: Run `flutter test test/backend/protocol/envelope_test.dart`** — expect failure.

- [ ] **Step 3: Extend the commands**

```dart
class SwitchCameraCommand extends DeviceCommand {
  const SwitchCameraCommand({super.id, required this.cameraEnum, this.resolution, this.fps});
  final int cameraEnum;
  final CameraResolution? resolution;  // null keeps the resolution it is at
  final int? fps;                      // null keeps the frame rate it is at
}

class StartRecordingCommand extends DeviceCommand {
  const StartRecordingCommand({super.id, required this.cameraEnum, required this.streamId, this.codec});
  final int cameraEnum;
  final String streamId;
  final CaptureCodec? codec;           // null means the device's preferred codec
}
```

- [ ] **Step 4: Parse them in `envelope.dart`**

`switch_camera`: read `payload['resolution']` as a `"WIDTHxHEIGHT"` string, trim it, and treat a whitespace-only value as absent; read `payload['fps']` as an int. `start_recording`: read `payload['codec']` through `CaptureCodec.tryParse`, so an unrecognised name yields `null` instead of an exception.

- [ ] **Step 5: Run the tests** — expect PASS.

- [ ] **Step 6: Commit** → `feat(protocol): parse switch_camera parameters and start_recording codec`

---

### Task 7: Coordinator mode state

**Files:**
- Modify: `lib/src/agent/agent_coordinator.dart`
- Test: `test/agent/agent_coordinator_test.dart`

**Interfaces:**
- Consumes: the extended commands (Task 6), `CameraCapabilities` (Task 1), `buildAnnouncements` (Task 5).
- Produces: the per-camera mode the registration and the switch handler read.

- [ ] **Step 1: Write the failing tests**

```dart
test('switch_camera applies a declared resolution and fps and acks ok');
test('switch_camera acks ok:false for a resolution the camera never declared');
test('switch_camera acks ok:false for an fps the camera never declared');
test('switch_camera with no parameters only changes the active camera');
test('switch_camera resolves the announced enum to the right physical camera');
test('start_recording with codec mjpeg starts and acks ok');
test('start_recording with an unavailable codec acks ok:false and starts nothing');
test('start_recording with no codec uses the first announced codec');
test('a parameter-changing switch triggers a re-registration');
test('a switch that only changes the camera does not re-register');
```

- [ ] **Step 2: Run `flutter test test/agent/agent_coordinator_test.dart`** — expect failure.

- [ ] **Step 3: Add the mode model and wire it in**

Add `CameraMode` — `{CameraResolution resolution, int fps}` — to `lib/src/capture/camera_capabilities.dart` (pure), and give `AgentCoordinator` a `List<CameraMode> _modes` indexed by **announced** camera enum. Seed every entry from the capabilities the coordinator was constructed with, using the same default resolution and fps for all cameras.

`_switchCamera`: validate `command.resolution` / `command.fps` against that camera's declared capabilities before touching the camera. Anything undeclared is acked `ok:false` with an error naming the value and the camera, and the camera is left alone. On success apply through the existing `switchCamera` + `reconfigure` path — the backend resolves the announced enum to a physical camera, so the coordinator never sees a physical index — update `_modes[cameraEnum]`, ack `ok:true`, and **only when a parameter changed** rebuild the gateway so the server re-registers with the new mode. Without that rebuild the server keeps the registration's old `resolution` / `fps` and snapshots stale values into `metadata` at `recording/start` (`switch_camera` stores no server state).

`_startRecording`: resolve the codec as `command.codec ?? announcedCodecs.first`. When the resolved codec is not `mjpeg`, ack `ok:false` with an error saying only `mjpeg` is available today, and start nothing — the server's stream row stays `active`, so the device must be honest that it is not feeding it.

Keep the existing refusal to switch camera while a stream is active.

- [ ] **Step 4: Run the tests** — expect PASS.

- [ ] **Step 5: Commit** → `feat(agent): honour switch_camera parameters and the requested codec`

---

### Task 8: Bootstrap screen and startup wiring

**Files:**
- Create: `lib/src/app/capability_bootstrap.dart` (orchestration)
- Create: `lib/src/ui/screens/bootstrap_screen.dart`
- Modify: `lib/main.dart`
- Modify: `tool/verify_pure.dart`
- Test: `test/app/capability_bootstrap_test.dart`, `test/ui/bootstrap_screen_test.dart`

**Interfaces:**
- Consumes: `CameraRanker` + `canonicalCameraOrder` (Task 2), `CapabilityProbe` (Task 3), `CapabilitiesStore` + `cameraFingerprint` (Task 4), `CameraDeclaration` (Task 5).
- Produces: the root widget that shows the probe screen before the kiosk.

- [ ] **Step 1: Write the failing tests**

```dart
// capability_bootstrap_test.dart
test('ranks, orders and then probes, in that order');
test('a cached fingerprint skips both the ranking and the probe');
test('a different fingerprint re-ranks, re-orders and re-probes');
test('capabilities are stored per camera, keyed by the ordered camera names');
test('an empty probe result still yields a usable fallback for registration');
test('the fallback declares the current resolution and fps, never an empty list');
test('the announced camera list is in canonical order');

// bootstrap_screen_test.dart
test('shows progress while probing');
test('calls onDone with the inventory when the probe finishes');
test('shows a message and still completes when the probe finds nothing');
```

- [ ] **Step 2: Run `flutter test test/app/capability_bootstrap_test.dart test/ui/bootstrap_screen_test.dart`** — expect failure.

- [ ] **Step 3: Implement `lib/src/app/capability_bootstrap.dart`**

```dart
/// The ordered camera list plus what each camera can do.
class CameraInventory {
  const CameraInventory({required this.descriptors, required this.capabilities});
  final List<CameraDescriptor> descriptors;     // canonical order
  final List<CameraCapabilities> capabilities;  // indexed by camera_enum
}

Future<CameraInventory> ensureInventory({
  required CameraLister listCameras,
  required CameraRanker ranker,
  required CapabilityProbe probe,
  required CapabilitiesStore store,
  required CameraResolution fallbackResolution,
  required int fallbackFps,
  void Function(String message)? log,
});
```

1. List cameras (cheap, no open). Rank them — one open each — and compute `canonicalCameraOrder`. Reorder the descriptors.
2. Fingerprint the **ordered** names and load the cache. A hit returns immediately and opens nothing further.
3. Otherwise probe each camera in canonical order, applying `withCommonBaseline()` then `withCurrent(fallbackResolution, fallbackFps)`; when a probe comes back empty, degrade to `CameraCapabilities.empty.withCurrent(...)` — the server rejects empty lists outright, so a failed probe must become "only what I am doing", never nothing.
4. Save and return.

- [ ] **Step 4: Implement `lib/src/ui/screens/bootstrap_screen.dart`**

A `Scaffold` with centred progress and a line of text naming what is happening, consistent with the existing dark kiosk screens. Keys for tests: `bootstrap-progress`, `bootstrap-status`. Calls `onDone(CameraInventory)` exactly once.

- [ ] **Step 5: Wire `main.dart`**

`runApp` exactly once, with a small stateful root that renders `BootstrapScreen` while the inventory is unresolved and swaps to `AgentApp` when `ensureInventory` completes. Construct `CameraPluginBackend` with the `cameraOrder` permutation from the inventory so the backend and the announcements agree on what `camera_enum` means. Announcements are built from `CameraDeclaration` per camera, in canonical order.

Remove the documented "announcements are computed once and never rebuilt" limitation comment in favour of the re-registration behaviour added in Task 7.

- [ ] **Step 6: Update `tool/verify_pure.dart`** so the new pure files are covered by the Flutter-free check.

- [ ] **Step 7: Run `flutter test`** — expect everything PASS.

- [ ] **Step 8: Commit** → `feat(app): probe and order camera capabilities on first launch`

---

### Task 9: Manual re-probe from the settings screen

**Files:**
- Modify: `lib/src/ui/screens/settings_screen.dart`
- Modify: `lib/src/ui/screens/agent_screen.dart:114-135`
- Test: `test/ui/settings_screen_test.dart`

**Interfaces:**
- Consumes: `CameraRanker` (Task 2), `CapabilityProbe` (Task 3), `CapabilitiesStore` (Task 4).
- Produces: nothing further; this is the last task.

- [ ] **Step 1: Write the failing tests**

```dart
test('a refresh button is present and enabled when idle');
test('the refresh button is disabled while the device is recording');
test('tapping it runs the probe and reports the outcome');
test('a failed probe reports a message instead of failing silently');
test('a refreshed result is persisted for the next connection');
```

- [ ] **Step 2: Run `flutter test test/ui/settings_screen_test.dart`** — expect failure.

- [ ] **Step 3: Add the button to `settings_screen.dart`**

New optional `final Future<CameraInventory> Function()? onRefreshCapabilities` and an `OutlinedButton.icon` in the existing 操作 `Wrap`, keyed `settings-refresh-capabilities`, labelled 重新检测. Disable it while `widget.isRecording` — re-probing reopens the camera, which would kill a live stream, exactly the hazard the recording banner already warns about. Show the outcome in a `Text` keyed `settings-refresh-result`, styled like the existing probe result: camera count and measured resolution count on success, the failure reason otherwise.

- [ ] **Step 4: Thread it through `agent_screen.dart`**

Pass a closure that runs `ensureInventory` with a **forced** re-probe (ignore the cache), saves through the same `CapabilitiesStore`, and rebuilds the announcements so the next registration carries the new lists and the new order.

- [ ] **Step 5: Run `flutter test`** — expect everything PASS.

- [ ] **Step 6: Commit** → `feat(ui): re-probe camera capabilities from settings`

---

## Deferred (separate plans)

- **Native encoder pipeline.** ``'s image stream exists to deliver raw BGRA into Dart, so keeping raw frames out of Dart means owning the capture pipeline natively: fork/vend the plugin and tap the same GStreamer / Media Foundation pipeline in-process. Encoding happens there; only compressed bytes cross into Dart.
- **H.264 / H.265.** ffmpeg in the native layer (GPL build for x264/x265, or `libopenh264` for H.264 only), with hardware encoders as a second backend behind the same `NativeEncoder` interface. Until this lands, `supported_codec` stays `["mjpeg"]` and a request for any other codec is acked `ok:false`.
- **No-disk frame path.** Follows from the encoder work; `TakePictureFrameSource` stays in place until then.
