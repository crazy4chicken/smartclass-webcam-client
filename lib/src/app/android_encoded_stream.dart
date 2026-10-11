import 'dart:io' show Platform;

import '../agent/agent_coordinator.dart';
import '../capture/camera_plugin_encoded_transport.dart';
import '../capture/codec_probe.dart';
import '../capture/encoded_stream_transport.dart';
import '../capture/native_video_encoder.dart';
import '../capture/stream_settings.dart';
import '../capture/video_encoder.dart';
import 'capability_bootstrap.dart';

/// Assembles the Android encoded-stream chain, and only that chain.
///
/// One object because the three pieces have to agree: the plugin transport the
/// bytes arrive on, the channel that turns them into [EncodedPacket]s, and the
/// encoder that shapes them into access units. Building them apart is how a
/// channel ends up bound to one camera while the registration describes
/// another.
///
/// **Android-only, by construction.** [isSupported] is the gate, and every
/// entry point refuses off Android rather than degrading: there is no encoded
/// stream to fall back to, and the platform's floor — `mjpeg` from
/// `takePicture()` — is carried by the coordinator's own default factory, not
/// by this class. Wiring this in must not become the way mjpeg is served.
///
/// **Nothing here announces a rate.** It supplies encoders; what the device
/// declares comes from `planCapture` and the evidence behind it. A factory that
/// also picked a frame rate would be a second, unsourced opinion about a number
/// the server divides by.
///
/// This file lives in `lib/src/app/` — the Flutter layer — because
/// `CameraPluginEncodedTransport` imports `package:flutter/services.dart`. It
/// must therefore never be imported by `lib/src/backend/`, `lib/src/config/`,
/// `lib/src/agent/`, `lib/src/app/capability_bootstrap.dart` or a non-plugin
/// file under `lib/src/capture/`, or `tool/verify_pure.dart` stops being able
/// to run.
class AndroidEncodedStreamFactory {
  AndroidEncodedStreamFactory({
    EncodedStreamTransport? transport,
    CameraInventory? inventory,
    this.log,
  }) : _transport = transport ?? CameraPluginEncodedTransport() {
    if (inventory != null) this.inventory = inventory;
  }

  final EncodedStreamTransport _transport;

  final void Function(String message)? log;

  /// The cameras in canonical order, used to translate a `camera_enum` into a
  /// physical id.
  ///
  /// Mutable because a re-probe can renumber them: the physical camera behind
  /// `camera_enum 0` is whatever the newest inventory says it is, and an
  /// encoder built from a stale one would open a different sensor than the
  /// registration described. See `main.dart`'s `applyInventory`.
  CameraInventory? inventory;

  /// What the platform's hardware encoders claim to be, once known.
  ///
  /// Null until [prime] succeeds, and left null when it does not: an unknown
  /// encoder name is reported as empty rather than invented, which is the
  /// weaker but honest answer — see `VideoEncoder.identity`.
  List<EncoderClaim>? _claims;

  /// Whether this platform has the plugin the chain needs.
  ///
  /// Android is the only platform whose vendored camera plugin exposes
  /// `smartclass/encoded_stream` today. Refusing everywhere else is what keeps
  /// the other four platforms byte-for-byte on today's mjpeg path.
  bool get isSupported => Platform.isAndroid;

  /// Asks the platform once which encoders it has, so an encoder can carry a
  /// real name.
  ///
  /// [VideoEncoderFactory] is synchronous — it is consulted while a command is
  /// being answered — so the name has to be in hand before the first recording
  /// is requested. It matters because `identity` is one of the keys
  /// `EncodeEvidence` is cached under: a constant would keep a rate measured on
  /// one driver answering for another.
  ///
  /// Never throws, and does nothing off Android: start-up must not fail on a
  /// platform that has no encoder to ask.
  Future<void> prime() async {
    if (!isSupported) return;
    try {
      _claims = await _transport.encoders();
    } catch (error) {
      log?.call('[encoder] the platform encoder list is unavailable: $error');
      return;
    }
    for (final claim in _claims!) {
      if (claim.hardware) {
        log?.call(
          '[encoder] ${claim.codec.wireName} via ${claim.name} (hardware)',
        );
      }
    }
  }

  /// Reports the codecs the platform's **hardware** encoders claim.
  ///
  /// A claim, not a measurement: it says the device has an H.265 encoder, not
  /// that it holds 1080p60. What may be *announced* is still filtered by
  /// measured evidence in `planCapture`, so on a device with nothing measured
  /// this contributes to the claim set and to nothing else — the announced list
  /// stays at the mjpeg floor.
  CodecProbe codecProbe() =>
      PlatformCodecProbe(transport: _transport, log: log);

  /// The identity of the encoder *set* behind [codecs], for the evidence cache.
  ///
  /// `EncodeEvidence` is cached and validated under `encoderIdentity`, and the
  /// key has to name the encoders the numbers came from: a driver update that
  /// swaps `c2.mtk.hevc.encoder` for something slower must invalidate a cached
  /// rate, and it can only do that if the identity changed with it. One string
  /// because the evidence covers every measured codec at once, so it lists all
  /// of them — `h265=c2.mtk.hevc.encoder,h264=c2.mtk.avc.encoder`.
  ///
  /// Empty when [prime] has not run or failed, which is the same "the platform
  /// did not say" that [VideoEncoder.identity] documents; callers that need the
  /// mjpeg floor's identity use `kMjpegEncoderIdentity` instead of this.
  String evidenceIdentity(List<CaptureCodec> codecs) {
    if (_claims == null) return '';
    final parts = <String>[];
    for (final codec in codecs) {
      final name = _identityFor(codec);
      // `unknown` rather than an empty field: a codec the platform would not
      // name still has to occupy its slot, or two different devices would
      // produce the same key for different hardware.
      parts.add('${codec.wireName}=${name.isEmpty ? 'unknown' : name}');
    }
    return parts.join(',');
  }

  /// The coordinator's encoder factory, or null off Android.
  ///
  /// Null is deliberate and load-bearing: the coordinator only falls back to
  /// its own mjpeg factory when it is given nothing, so handing it a factory
  /// that refuses everything would silently remove the floor from every
  /// platform that has no native encoder.
  VideoEncoderFactory? get encoderFactory => isSupported ? encoderFor : null;

  /// Builds one encoder for one recording, or refuses.
  ///
  /// Null is a refusal with a meaning: the coordinator acks `ok:false` for the
  /// codec that was named instead of substituting one. It refuses when the
  /// codec has no Annex B form (only `h264` / `h265` do — `NativeVideoEncoder`
  /// would throw), and when the physical camera id behind [cameraEnum] cannot
  /// be resolved.
  VideoEncoder? encoderFor({
    required CaptureCodec codec,
    required int cameraEnum,
    required String streamId,
  }) {
    if (!isSupported) return null;
    if (codec != CaptureCodec.h264 && codec != CaptureCodec.h265) return null;

    final cameraId = cameraIdFor(cameraEnum);
    if (cameraId == null) {
      // Not guessing. The plugin matches `cameraId` against CameraX's own
      // camera ids, and an id invented here would either fail the open or —
      // worse — bind a different sensor than the one announced.
      log?.call(
        '[encoder] no physical camera id for camera_enum $cameraEnum; '
        'refusing ${codec.wireName}',
      );
      return null;
    }

    return NativeVideoEncoder(
      codec: codec,
      cameraEnum: cameraEnum,
      streamId: streamId,
      channel: AndroidEncodedStreamChannel(
        transport: _transport,
        cameraEnum: cameraEnum,
        cameraId: cameraId,
        codec: codec,
      ),
      identity: _identityFor(codec),
    );
  }

  /// The physical camera id behind [cameraEnum], or null when it is unknown.
  ///
  /// **The two numbers are different numbering schemes and are never
  /// interchangeable.** [cameraEnum] is the announced position in the canonical
  /// order — what the server sends back and what the registration publishes.
  /// The id returned here is the plugin's own camera id, which on
  /// `camera_android_camerax` is Camera2's `getCameraId()`
  /// (`packages/camera_android_camerax/lib/src/android_camera_camerax.dart:320`)
  /// and is exactly the string `EncodedStreamPlugin.resolveCameraSelector`
  /// compares against
  /// (`.../EncodedStreamPlugin.java:333-341`).
  ///
  /// The bridge is the inventory and nothing else: `descriptors[cameraEnum]` is
  /// the physical camera's descriptor, so its `name` is that camera's id. A
  /// name that is not a number is not a Camera2 id, and null — a refusal — is
  /// the answer rather than a parsed-with-defaults guess.
  int? cameraIdFor(int cameraEnum) {
    final descriptors = inventory?.descriptors;
    if (descriptors == null) return null;
    if (cameraEnum < 0 || cameraEnum >= descriptors.length) return null;
    return int.tryParse(descriptors[cameraEnum].name);
  }

  /// The platform's own name for the hardware encoder behind [codec].
  ///
  /// Empty when the platform did not say — [prime] not run, or it failed —
  /// which is the honest answer `VideoEncoder.identity` documents. Software
  /// encoders are skipped: naming one would claim a H.265 stream this device
  /// cannot hold at any useful rate.
  String _identityFor(CaptureCodec codec) {
    final claims = _claims;
    if (claims == null) return '';
    for (final claim in claims) {
      if (claim.codec == codec && claim.hardware) return claim.name;
    }
    return '';
  }
}
