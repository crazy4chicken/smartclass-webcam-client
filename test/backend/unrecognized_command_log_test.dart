import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/backend/unrecognized_command_log.dart';

void main() {
  test('is bounded and keeps the newest entries', () {
    final log = UnrecognizedCommandLog(capacity: 3, sink: null);
    for (var i = 0; i < 5; i++) {
      log.record('raw-$i', UnrecognizedReason.unknownType);
    }
    expect(log.entries.map((e) => e.raw), ['raw-2', 'raw-3', 'raw-4']);
    expect(log.droppedCount, 2);
  });

  test(
    'truncates oversized raw payloads so one huge frame cannot exhaust memory',
    () {
      final log = UnrecognizedCommandLog(sink: null);
      log.record('x' * 20000, UnrecognizedReason.malformedJson);
      expect(log.entries.single.raw.length, lessThanOrEqualTo(512));
    },
  );

  test('sink receives a human readable message', () {
    final messages = <String>[];
    UnrecognizedCommandLog(sink: messages.add)
        .record('{"type":"nope"}', UnrecognizedReason.unknownType);
    expect(messages.single, contains('unknownType'));
    expect(messages.single, contains('nope'));
  });

  test('clear empties the buffer and the drop counter', () {
    final log = UnrecognizedCommandLog(capacity: 1, sink: null);
    log.record('a', UnrecognizedReason.unknownType);
    log.record('b', UnrecognizedReason.unknownType);
    expect(log.droppedCount, 1);
    log.clear();
    expect(log.entries, isEmpty);
    expect(log.droppedCount, 0);
  });
}
