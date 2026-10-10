# Vendored: `camera_android_camerax` 0.7.5+1

A copy of pub.dev [`camera_android_camerax`](https://pub.dev/packages/camera_android_camerax)
0.7.5+1, taken from the pub cache and committed here. Upstream licence
(**BSD-3-Clause**, `Copyright 2013 The Flutter Authors`) is in `LICENSE`;
nothing in this directory changes that. The copy was pinned by the sha256
recorded in `pubspec.lock` — `47645ffd20c597cb0edab4de20f3c89447b7eca90425ee13683b746275b18e2b`
— not by a version string alone. It is built against CameraX **1.6.2**
(`android/build.gradle.kts:79`) with `minSdk 23` (`android/build.gradle.kts:46`).

## Why it is here

The device has to deliver 1080p60 H.265/H.264, and the encoder has to sit
inside the process that owns the camera. `VideoCapture<Recorder>` only writes
to a file: it hands the camera surface to a `Recorder` and gives the caller no
access-unit outlet, so there is nowhere downstream of it to read compressed
frames. A `Recorder` on a `FileDescriptor` pipe would still go through a
container and still put bytes on disk.

Real frames therefore have to leave the plugin's own pipeline, encoded
in-process, with only compressed access units crossing into Dart. That means
changing files under `android/` — which is not reachable from outside the
package. `camera_desktop` carries the equivalent fork for Linux / macOS /
Windows; this directory is the Android half.

## Ground rules for this fork

1. **Change the capture/encode path, nothing else.** Every other file is
   upstream verbatim. A fork that drifts everywhere stops being rebasable,
   and upstream releases then become an incident instead of a merge.
2. **No frame touches the disk, and no raw frame enters Dart.** The whole
   point is that the bytes leaving the plugin are already compressed.
3. **What the device declares must be measured.** The plugin reports which
   encoders exist and what each sustained during a probe; Dart announces that,
   not a guess.
4. **A platform with no encoder for a codec says so.** Announcing H.264 only
   is a correct answer on a machine with no HEVC path.

## Scope of this fork

**New files only.** Everything upstream lands here unchanged, so the fork
stays rebasable. The single exception is a two-line registration change in
`android/src/main/java/io/flutter/plugins/camerax/CameraAndroidCameraxPlugin.java`
(`onAttachedToEngine` / `onDetachedFromEngine`), added by a later task. On any
rebase that touch has to be re-applied by hand — it will not survive a copy.

## How it is wired in

Through **`dependency_overrides`**, not `dependencies`:

```yaml
dependency_overrides:
  camera_android_camerax:
    path: packages/camera_android_camerax
```

That is not a stylistic choice. `camera` 0.12.1 declares
`camera_android_camerax: ^0.7.4` **from pub.dev**, and pub will not let a root
`dependencies` entry with a `path:` source replace a *published* transitive
dependency — the whole resolution fails with
`camera ^0.12.1 requires camera_android_camerax from hosted`. Redirecting a
transitive dependency at a local fork is what `dependency_overrides` is for.

`camera_desktop` can sit in `dependencies` only because nothing else depends on
it, so there is no source to conflict with.

## Upgrading

Diff this directory against the new upstream version before copying anything.
If upstream touched the capture path, the changes here have to be re-applied by
hand — do not overwrite the files this fork owns, and re-apply the two
`CameraAndroidCameraxPlugin.java` registration lines above.
