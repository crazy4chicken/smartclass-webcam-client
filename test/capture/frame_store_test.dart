import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/frame_store.dart';

void main() {
  test('reads bytes then removes the file so nothing accumulates', () async {
    final dir = await Directory.systemTemp.createTemp('probe');
    final file = File('${dir.path}${Platform.pathSeparator}frame.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9]);

    expect(await const IoFrameStore().readAndDelete(file.path),
        [0xFF, 0xD8, 1, 0xFF, 0xD9]);
    expect(file.existsSync(), isFalse);

    await dir.delete(recursive: true);
  });

  test('delete tolerates a file that is already gone', () async {
    await const IoFrameStore().delete('definitely/not/here.jpg');
  });
}
