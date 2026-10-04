import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:webcam_client/src/capture/frame_pump.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/video_encoder.dart';

import '../support/doubles.dart';

void main() {
  late MockCameraService camera;

  setUp(() {
    camera = MockCameraService();
    when(() => camera.isInitialized).thenReturn(true);
    when(() => camera.captureFrame(any()))
        .thenAnswer((_) async => Uint8List.fromList([1]));
  });

  test('emits monotonically increasing seq starting at zero', () async {
    final pump = TakePictureFramePump(camera: camera);
    final received = <CapturedFrame>[];
    final subscription = pump.frames.listen(received.add);

    await pump.start(cameraEnum: 0, streamId: 's', fps: 20, quality: 80);
    await pump.frames.take(3).toList().timeout(const Duration(seconds: 5));
    await pump.stop();

    expect(received.take(3).map((f) => f.seq), [0, 1, 2]);
    expect(received.first.ts, isA<DateTime>());
    await subscription.cancel();
  });

  test('stop ends the stream and no further frames are produced', () async {
    final pump = TakePictureFramePump(camera: camera);
    final received = <CapturedFrame>[];
    final subscription = pump.frames.listen(received.add);

    await pump.start(cameraEnum: 0, streamId: 's', fps: 20, quality: 80);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    final delivered = received.length;
    expect(delivered, greaterThan(0));

    await pump.stop();
    await pump.stop(); // idempotent

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(received.length, delivered);
    expect(pump.isRunning, isFalse);
    await subscription.cancel();
  });

  test('a failing capture is skipped without killing the pump', () async {
    var calls = 0;
    when(() => camera.captureFrame(any())).thenAnswer((_) async {
      if (calls++ == 0) throw StateError('camera busy');
      return Uint8List.fromList([1]);
    });

    final pump = TakePictureFramePump(camera: camera);
    final first = pump.frames.first;
    await pump.start(cameraEnum: 0, streamId: 's', fps: 20, quality: 80);
    final frame = await first.timeout(const Duration(seconds: 5));
    await pump.stop();

    // seq counts attempts, so the gap is visible to a consumer: one frame was
    // attempted and did not make it.
    expect(frame.seq, 1);
    expect(pump.droppedFrames, 1);
  });

  test('a slow capture sheds ticks instead of queueing them', () async {
    var concurrent = 0;
    var maxConcurrent = 0;
    when(() => camera.captureFrame(any())).thenAnswer((_) async {
      concurrent++;
      maxConcurrent = max(maxConcurrent, concurrent);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      concurrent--;
      return Uint8List.fromList([1]);
    });

    final pump = TakePictureFramePump(camera: camera);
    // 50 ms ticks against a 100 ms capture: every other tick must be shed.
    await pump.start(cameraEnum: 0, streamId: 's', fps: 20, quality: 80);
    await Future<void>.delayed(const Duration(milliseconds: 280));
    await pump.stop();

    expect(maxConcurrent, 1, reason: 'captures must never overlap');
  });

  test('an empty capture is counted as a drop, not emitted', () async {
    when(() => camera.captureFrame(any()))
        .thenAnswer((_) async => Uint8List(0));

    final pump = TakePictureFramePump(camera: camera);
    final received = <CapturedFrame>[];
    final subscription = pump.frames.listen(received.add);

    await pump.start(cameraEnum: 0, streamId: 's', fps: 30, quality: 80);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await pump.stop();

    expect(received, isEmpty);
    expect(pump.droppedFrames, greaterThan(0));
    await subscription.cancel();
  });

  test('nothing is captured while the camera is not initialised', () async {
    when(() => camera.isInitialized).thenReturn(false);

    final pump = TakePictureFramePump(camera: camera);
    await pump.start(cameraEnum: 0, streamId: 's', fps: 30, quality: 80);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await pump.stop();

    verifyNever(() => camera.captureFrame(any()));
  });

  test('a fractional rate is rejected rather than silently rounded', () async {
    final pump = TakePictureFramePump(camera: camera);
    expect(
      () => pump.start(cameraEnum: 0, streamId: 's', fps: 0, quality: 80),
      throwsArgumentError,
    );
  });

  test('the pump records which camera and stream it is feeding', () async {
    final pump = TakePictureFramePump(camera: camera);
    await pump.start(cameraEnum: 2, streamId: 'stream-1', fps: 30, quality: 80);

    expect(pump.cameraEnum, 2);
    expect(pump.streamId, 'stream-1');

    await pump.stop();
    expect(pump.streamId, isNull);
  });

  group('MjpegEncoder', () {
    test('passes JPEG frames through as key frames', () async {
      final pump = MockFramePump();
      when(() => pump.frames).thenAnswer(
        (_) => Stream.fromIterable([
          CapturedFrame(
            seq: 0,
            ts: DateTime.utc(2026),
            bytes: Uint8List.fromList([0xFF, 0xD8]),
          ),
        ]),
      );
      when(
        () => pump.start(
          cameraEnum: any(named: 'cameraEnum'),
          streamId: any(named: 'streamId'),
          fps: any(named: 'fps'),
          quality: any(named: 'quality'),
        ),
      ).thenAnswer((_) async {});
      when(() => pump.stop()).thenAnswer((_) async {});

      final encoder = MjpegEncoder(
        camera: camera,
        cameraEnum: 0,
        streamId: 'stream-1',
        pump: pump,
      );

      expect(encoder.codec, CaptureCodec.mjpeg);

      final first = encoder.frames.first;
      await encoder.start(width: 1280, height: 720, fps: 5, quality: 80);
      final frame = await first.timeout(const Duration(seconds: 5));

      expect(frame.seq, 0);
      expect(frame.bytes, [0xFF, 0xD8]);
      // A JPEG carries everything needed to decode it.
      expect(frame.isKeyFrame, isTrue);

      verify(
        () => pump.start(
          cameraEnum: 0,
          streamId: 'stream-1',
          fps: 5,
          quality: 80,
        ),
      ).called(1);
      await encoder.stop();
    });
  });
}
