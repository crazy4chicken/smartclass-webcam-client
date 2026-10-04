import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/main.dart';
import 'package:webcam_client/src/config/app_config.dart';

void main() {
  test('AppConfig exposes a usable endpoint and sane capture defaults', () {
    expect(AppConfig.wsUrl, startsWith('ws://'));
    expect(AppConfig.defaultWidth, 1280);
    expect(AppConfig.defaultHeight, 720);
    expect(AppConfig.defaultQuality, inInclusiveRange(1, 100));
    expect(AppConfig.defaultChunkSeconds, 3);
    expect(AppConfig.defaultPreviewEnabled, isTrue);
    expect(AppConfig.heartbeatSeconds, 15);
  });

  test('backend chain starts with camera_desktop', () {
    expect(buildBackendChain().first.id, 'camera_desktop');
  });
}
