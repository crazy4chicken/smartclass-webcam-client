import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';

void main() {
  test(
    'defaults to video with the most widely supported codec and preview on',
    () {
      final s = StreamSettings.defaults();
      expect(s.mode, StreamMode.video);
      expect(s.codec, VideoCodec.avc);
      expect(s.chunkSeconds, 3);
      expect(s.previewEnabled, isTrue);
    },
  );

  test('copyWith changes only what is given', () {
    final s = StreamSettings.defaults().copyWith(
      codec: VideoCodec.hevc,
      previewEnabled: false,
    );
    expect(s.mode, StreamMode.video);
    expect(s.codec, VideoCodec.hevc);
    expect(s.previewEnabled, isFalse);
    expect(s.chunkSeconds, 3);
  });

  test('lenient parsing accepts known wire names and rejects the rest', () {
    expect(StreamMode.tryParse('video'), StreamMode.video);
    expect(StreamMode.tryParse('still'), StreamMode.still);
    expect(StreamMode.tryParse('banana'), isNull);
    expect(VideoCodec.tryParse('avc'), VideoCodec.avc);
    expect(VideoCodec.tryParse('hevc'), VideoCodec.hevc);
    expect(VideoCodec.tryParse(null), isNull);
  });
}
