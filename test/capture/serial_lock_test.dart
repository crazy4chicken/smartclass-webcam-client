import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/serial_lock.dart';

void main() {
  test('runs items in call order, not completion order', () async {
    final lock = SerialLock();
    final order = <String>[];

    // Queued longest-first: a lock that merely awaited everything at once
    // would finish b before a.
    final futures = <Future<void>>[
      lock.run(() async {
        order.add('start-a');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add('end-a');
      }),
      lock.run(() async {
        order.add('start-b');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add('end-b');
      }),
    ];

    await Future.wait(futures);
    expect(order, ['start-a', 'end-a', 'start-b', 'end-b']);
  });

  test('never lets two items overlap', () async {
    final lock = SerialLock();
    var concurrent = 0;
    var maxConcurrent = 0;

    await Future.wait([
      for (var i = 0; i < 5; i++)
        lock.run(() async {
          concurrent++;
          maxConcurrent = maxConcurrent < concurrent ? concurrent : maxConcurrent;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          concurrent--;
        }),
    ]);

    expect(maxConcurrent, 1);
    expect(lock.pending, 0);
  });

  test('a failing item releases the lock for the next one', () async {
    final lock = SerialLock();
    final done = <String>[];

    // The error belongs to this caller — a failed capture is that capture's
    // problem — but it must not wedge the queue behind it.
    final failing = lock.run<void>(() async => throw StateError('camera busy'));
    await expectLater(failing, throwsStateError);

    await lock.run(() async => done.add('after'));
    expect(done, ['after']);
    expect(lock.pending, 0);
  });

  test('the result of an item is returned to its caller', () async {
    final lock = SerialLock();
    expect(await lock.run(() async => 42), 42);
  });
}
