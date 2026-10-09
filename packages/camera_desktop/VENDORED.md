# Vendored: `camera_desktop` 2.0.0

A copy of [`camera_desktop`](https://github.com/hugocornellier/camera_desktop)
2.0.0, taken from the pub cache and committed here. Upstream licence (BSD-3) is
in `LICENSE`; nothing in this directory changes that.

## Why it is here

The device has to deliver 1080p60 H.264/H.265. It cannot, and no amount of
Dart can fix it: the frame source today is `takePicture()`, which is a full
still capture plus a JPEG encode per frame — about 5-10 fps at 1080p on any
platform. Attaching an encoder downstream of that changes the codec and not
the ceiling, because the ceiling is in the capture path.

Real frames have to come out of the plugin's own pipeline, encoded in-process,
with only compressed access units crossing into Dart. That means changing
`linux/camera.cc`, `windows/`, `macos/` and (for Android, a separate fork)
`camera_android_camerax` — none of which is reachable from outside the
package.

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

## Upgrading

Diff this directory against the new upstream version before copying anything.
If upstream touched the capture path, the changes here have to be re-applied by
hand — do not overwrite the files this fork owns.
