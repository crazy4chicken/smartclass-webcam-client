import 'dart:async';

import 'package:flutter/services.dart';

import 'encoded_stream_transport.dart';
import 'stream_settings.dart';

/// The [EncodedStreamTransport] backed by the Android plugin's two channels.
///
/// This is the only file in the capture layer that is allowed to know
/// `package:flutter`, and it is deliberately the thinnest one here: it moves
/// platform words in and out and interprets nothing. `AndroidEncodedStream
/// Channel` owns every rule — the `sourceSeq` derivation, the stale-generation
/// filter, the byte copy — and it is pure Dart so `tool/verify_pure.dart` can
/// pin those rules with a fake transport. Rules that lived here would be
/// unreachable from the gate, which is the one automated check this project
/// has; that is why "no parsing, no sequencing, no filtering" is a design
/// constraint on this class and not merely a style preference.
///
/// The channel names and argument shapes below are frozen verbatim by
/// `docs/adr/0002-android-encoded-stream-seam.md` §四 and are depended on by
/// the native side. Do not rename, retype or "normalise" any of them.
class CameraPluginEncodedTransport implements EncodedStreamTransport {
  /// [methodChannel] / [eventChannel] exist for injection: a caller that owns
  /// a `BinaryMessenger` (a test, or a different engine attachment) can supply
  /// its own channels, and [binaryMessenger] is the shorthand for "the same
  /// frozen names, but this messenger". Defaults are the real plugin channels
  /// with the engine's default messenger, which is what production uses.
  CameraPluginEncodedTransport({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    BinaryMessenger? binaryMessenger,
  }) : _method =
           methodChannel ??
           // The messenger is the *third* positional slot on both channels:
           // the second is the codec. Passing it as the second would type-check
           // against `MethodCodec` and fail only once something imported this
           // file, which nothing did until `lib/src/app` reached it.
           MethodChannel(
             'smartclass/encoded_stream',
             const StandardMethodCodec(),
             binaryMessenger,
           ),
       _packets =
           eventChannel ??
           EventChannel(
             'smartclass/encoded_stream/packets',
             const StandardMethodCodec(),
             binaryMessenger,
           );

  final MethodChannel _method;
  final EventChannel _packets;

  /// The platform's raw event maps, verbatim.
  ///
  /// Broadcast, and cached rather than built per call, for two reasons.
  /// `receiveBroadcastStream()` yields a single-subscription stream, so
  /// returning it raw would make the second subscriber throw; and building a
  /// fresh broadcast stream per getter access would give each caller its own
  /// native subscription, so one packet would be delivered once per caller.
  /// The adapter above subscribes before `open` (the first frame can arrive
  /// from inside it) and cancels when the consumer stops listening, which a
  /// cached broadcast stream absorbs: it drops the underlying subscription
  /// when its last listener leaves and re-subscribes on the next run.
  ///
  /// Nothing is read out of these maps here — not `bytes`, not `generation`.
  /// What they mean is the adapter's business.
  late final Stream<Object?> events = _packets
      .receiveBroadcastStream()
      .asBroadcastStream();

  /// Starts the pipeline; a `PlatformException` propagates untouched.
  ///
  /// Every key is passed exactly as the native side reads it and [codec] goes
  /// out as its wire name (`h265` / `h264` — never an alias such as `hevc`,
  /// which the server rejects). Nothing is translated or defaulted here: this
  /// call is the frozen contract, so a "tidier" argument shape would silently
  /// desynchronise it from `EncodedStreamPlugin.java`.
  ///
  /// The failure is not wrapped: `AndroidEncodedStreamChannel.open` rethrows it
  /// so the encoder above can roll its `_running` flag back and the device can
  /// ack `ok:false` instead of recording a pipeline it does not have.
  @override
  Future<void> open({
    required int cameraId,
    required int width,
    required int height,
    required int fps,
    required int quality,
    required CaptureCodec codec,
    required int sessionGeneration,
  }) {
    return _method.invokeMethod<void>('open', <String, Object?>{
      'cameraId': cameraId,
      'width': width,
      'height': height,
      'fps': fps,
      'quality': quality,
      'codec': codec.wireName,
      'sessionGeneration': sessionGeneration,
    });
  }

  /// Stops the pipeline; a `PlatformException` propagates untouched.
  ///
  /// Resolving means the native side has already flushed the tail — it waits
  /// for `BUFFER_FLAG_END_OF_STREAM` before answering — so nothing here waits
  /// for, or cancels, the event subscription. Cancel-later is what lets the
  /// adapter still receive the last packets.
  @override
  Future<void> close() {
    return _method.invokeMethod<void>('close', const <String, Object?>{});
  }

  /// The encoders the platform reports. Never throws.
  ///
  /// It cannot: this is what `PlatformCodecProbe` consults at start-up and on
  /// every re-detect, and a probe source that throws takes the whole codec
  /// selection down with it. An unusable reply must instead contribute
  /// nothing, which lets the composite probe fall back to the mjpeg floor.
  ///
  /// The codec string is parsed defensively rather than by `wireName` lookup
  /// with a `!`: a device is free to report a codec this client has no enum
  /// value for (`hevc`, a new mime, an empty string), and one unknown entry in
  /// a list of five must not discard the four that are known and usable.
  /// `CaptureCodec.tryParse` returns null for anything unrecognised and the
  /// entry is skipped.
  @override
  Future<List<EncoderClaim>> encoders() async {
    try {
      final reply = await _method.invokeMethod<Object?>(
        'encoders',
        const <String, Object?>{},
      );
      return _parseEncoders(reply);
    } catch (_) {
      return const <EncoderClaim>[];
    }
  }

  /// Turns the `encoders` reply into claims, dropping what cannot be read.
  ///
  /// A missing or non-`bool` `hardware` reads as software, which is the
  /// conservative direction: `PlatformCodecProbe` announces only
  /// `hardware == true` claims, so an ambiguous entry is skipped rather than
  /// promising a codec this device may not be able to serve. A missing `name`
  /// reads as empty rather than invented — the name travels into
  /// `EncodeEvidence` to invalidate a cached rate on a driver change, and a
  /// fabricated one would invalidate it for no reason.
  static List<EncoderClaim> _parseEncoders(Object? reply) {
    if (reply is! Map) return const <EncoderClaim>[];
    final rawEncoders = reply['encoders'];
    if (rawEncoders is! List) return const <EncoderClaim>[];

    final claims = <EncoderClaim>[];
    for (final raw in rawEncoders) {
      if (raw is! Map) continue;
      final codec = CaptureCodec.tryParse(raw['codec']);
      if (codec == null) continue;
      final name = raw['name'];
      claims.add(
        EncoderClaim(
          codec: codec,
          name: name is String ? name : '',
          hardware: raw['hardware'] == true,
        ),
      );
    }
    return claims;
  }
}
