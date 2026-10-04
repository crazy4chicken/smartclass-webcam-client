import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

void main() {
  group('CaptureCodec', () {
    test('preference puts h265 ahead of h264 ahead of mjpeg', () {
      expect(CaptureCodec.preference.first, CaptureCodec.h265);
      expect(CaptureCodec.preference, [
        CaptureCodec.h265,
        CaptureCodec.h264,
        CaptureCodec.mjpeg,
      ]);
    });

    test('wire names are the closed set and never emit the hevc alias', () {
      expect(CaptureCodec.values.map((c) => c.wireName).toList(), [
        'h265',
        'h264',
        'mjpeg',
        'mpeg4',
        'vp8',
        'vp9',
        'av1',
      ]);
      // `hevc` is H.265's other name, and the server rejects it.
      expect(
        CaptureCodec.values.map((c) => c.wireName),
        isNot(contains('hevc')),
      );
    });

    test('tryParse is exact and rejects case variants', () {
      expect(CaptureCodec.tryParse('mjpeg'), CaptureCodec.mjpeg);
      expect(CaptureCodec.tryParse('hevc'), isNull);
      expect(CaptureCodec.tryParse('H264'), isNull);
      expect(CaptureCodec.tryParse(null), isNull);
    });

    test('only mjpeg is intra-only', () {
      expect(CaptureCodec.mjpeg.isIntraOnly, isTrue);
      expect(CaptureCodec.h265.isIntraOnly, isFalse);
    });
  });

  group('StreamSettings', () {
    test('defaults to the guaranteed codec and a whole-number rate', () {
      final settings = StreamSettings.defaults();
      // mjpeg is the floor: the still-picture path produces JPEG on every
      // platform, so the pipeline works before any probe has run.
      expect(settings.codec, CaptureCodec.mjpeg);
      expect(settings.fps, greaterThan(0));
      expect(settings.fps, isA<int>());
      expect(settings.previewEnabled, isTrue);
    });

    test('copyWith changes only what is given', () {
      final settings = StreamSettings.defaults().copyWith(
        codec: CaptureCodec.h265,
        fps: 15,
        previewEnabled: false,
      );

      expect(settings.codec, CaptureCodec.h265);
      expect(settings.fps, 15);
      expect(settings.previewEnabled, isFalse);
      expect(settings.quality, StreamSettings.defaults().quality);
    });

    test('equality covers every field', () {
      final base = StreamSettings.defaults();
      expect(base.copyWith(), base);
      expect(base.copyWith(fps: base.fps + 1), isNot(base));
      expect(base.copyWith(codec: CaptureCodec.h264), isNot(base));
      expect(base.copyWith(previewEnabled: !base.previewEnabled), isNot(base));
    });
  });
}
