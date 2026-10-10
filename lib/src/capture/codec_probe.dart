import 'stream_settings.dart';

/// Reports which codecs this device can actually produce.
///
/// The server performs **no negotiation**: it stores the announced list
/// verbatim in `metadata.codecs` and never picks one. So the choice is entirely
/// the client's, and it must be made from measured capability rather than
/// assumed.
abstract interface class CodecProbe {
  /// Must never throw: an unusable probe source contributes nothing rather
  /// than failing the whole selection.
  Future<Set<CaptureCodec>> availableCodecs();
}

/// Always reports `{mjpeg}`.
///
/// This is the guaranteed floor, not a placeholder: `takePicture()` returns a
/// JPEG on every one of the five platforms, and one JPEG per
/// `recording.frame` is precisely the server's definition of `mjpeg`.
class BaselineCodecProbe implements CodecProbe {
  const BaselineCodecProbe();

  @override
  Future<Set<CaptureCodec>> availableCodecs() async => const <CaptureCodec>{
    CaptureCodec.mjpeg,
  };
}

/// Reports a fixed set. Useful for tests and for pinning a platform's
/// capability during development.
class StaticCodecProbe implements CodecProbe {
  const StaticCodecProbe(this.codecs);

  final Set<CaptureCodec> codecs;

  @override
  Future<Set<CaptureCodec>> availableCodecs() async => codecs;
}

/// Unions several probe sources.
///
/// A future native probe is added to the list and immediately participates in
/// selection — nothing else changes.
class CompositeCodecProbe implements CodecProbe {
  CompositeCodecProbe({required List<CodecProbe> probes})
    : _probes = List<CodecProbe>.unmodifiable(probes);

  final List<CodecProbe> _probes;

  @override
  Future<Set<CaptureCodec>> availableCodecs() async {
    final found = <CaptureCodec>{};
    for (final probe in _probes) {
      try {
        found.addAll(await probe.availableCodecs());
      } catch (_) {
        // A probe that cannot answer contributes nothing; it must not take
        // the others down with it.
      }
    }
    return found;
  }
}

/// Picks the best available codec from [CaptureCodec.preference].
class CodecSelector {
  CodecSelector({required CodecProbe probe}) : _probe = probe;

  final CodecProbe _probe;

  /// `h265 → h264 → mjpeg`, falling back to `mjpeg` if the probe is empty or
  /// fails, because a codec must always be announced: an empty
  /// `supported_codec` list is a `400` and would stop the device registering
  /// at all.
  Future<CaptureCodec> select() async {
    Set<CaptureCodec> available;
    try {
      available = await _probe.availableCodecs();
    } catch (_) {
      available = const <CaptureCodec>{};
    }

    for (final codec in CaptureCodec.preference) {
      if (available.contains(codec)) return codec;
    }
    return CaptureCodec.mjpeg;
  }
}
