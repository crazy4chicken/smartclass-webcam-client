import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/codec_probe.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

class _ThrowingProbe implements CodecProbe {
  @override
  Future<Set<CaptureCodec>> availableCodecs() async =>
      throw StateError('probe unavailable');
}

void main() {
  group('CodecSelector', () {
    test('selects h265 when the device offers it', () async {
      final selector = CodecSelector(
        probe: StaticCodecProbe({
          CaptureCodec.h265,
          CaptureCodec.h264,
          CaptureCodec.mjpeg,
        }),
      );
      expect(await selector.select(), CaptureCodec.h265);
    });

    test('falls back to h264 when h265 is unavailable', () async {
      final selector = CodecSelector(
        probe: StaticCodecProbe({CaptureCodec.h264, CaptureCodec.mjpeg}),
      );
      expect(await selector.select(), CaptureCodec.h264);
    });

    test('falls back to mjpeg when no video encoder exists', () async {
      final selector = CodecSelector(
        probe: StaticCodecProbe({CaptureCodec.mjpeg}),
      );
      expect(await selector.select(), CaptureCodec.mjpeg);
    });

    test('a codec is always announced, even when the probe fails', () async {
      // An empty `supported_codec` is a 400 and would stop the device
      // registering at all, so the floor must hold whatever happens.
      final selector = CodecSelector(probe: _ThrowingProbe());
      expect(await selector.select(), CaptureCodec.mjpeg);
    });
  });

  group('codec probes', () {
    test('the baseline probe reports mjpeg and nothing else', () async {
      expect(await const BaselineCodecProbe().availableCodecs(), {
        CaptureCodec.mjpeg,
      });
    });

    test('a composite probe unions every source', () async {
      final probe = CompositeCodecProbe(
        probes: [
          const StaticCodecProbe({CaptureCodec.h265}),
          const StaticCodecProbe({CaptureCodec.mjpeg}),
        ],
      );
      expect(await probe.availableCodecs(), {
        CaptureCodec.h265,
        CaptureCodec.mjpeg,
      });
    });

    test('a failing source does not take the others down', () async {
      final probe = CompositeCodecProbe(
        probes: [
          _ThrowingProbe(),
          const StaticCodecProbe({CaptureCodec.mjpeg}),
        ],
      );
      expect(await probe.availableCodecs(), {CaptureCodec.mjpeg});
    });
  });
}
