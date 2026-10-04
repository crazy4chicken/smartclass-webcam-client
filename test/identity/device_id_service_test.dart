import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webcam_client/src/identity/device_id_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generates an id once and reuses it on the next call', () async {
    SharedPreferences.setMockInitialValues({});
    final service = DeviceIdService();
    final first = await service.getOrCreateDeviceId();
    final second = await service.getOrCreateDeviceId();
    expect(first, isNotEmpty);
    expect(second, first);
  });

  test('persists the generated id so a fresh instance sees the same value',
      () async {
    SharedPreferences.setMockInitialValues({});
    final generated = await DeviceIdService().getOrCreateDeviceId();

    final restored = await DeviceIdService().getOrCreateDeviceId();
    expect(restored, generated);
  });

  test('keeps an id that already exists in storage', () async {
    SharedPreferences.setMockInitialValues(
      {DeviceIdService.storageKey: 'existing-id'},
    );
    expect(await DeviceIdService().getOrCreateDeviceId(), 'existing-id');
  });
}
