import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webcam_client/src/capture/camera_resolution.dart';
import 'package:webcam_client/src/capture/frame_store.dart';
import 'package:webcam_client/src/capture/stream_settings.dart';
import 'package:webcam_client/src/capture/video_chunk_recorder.dart';

class FakeRecorderHost implements RecorderHost {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> startRecording() async {
    startCalls++;
  }

  @override
  Future<XFile> stopRecording() async {
    stopCalls++;
    return XFile('x.mp4');
  }

  @override
  Future<Uint8List> readFile(String path) async =>
      Uint8List.fromList([0, 0, 0, 24]);
}

class _NoopFileStore implements FrameStore {
  @override
  Future<Uint8List> readAndDelete(String path) async => Uint8List(0);

  @override
  Future<void> delete(String path) async {}
}

void main() {
  test('starts a segment immediately and rotates it every chunkSeconds', () {
    fakeAsync((async) {
      final host = FakeRecorderHost();
      final rec = CameraPluginVideoChunkRecorder(
        host: host,
        fileStore: _NoopFileStore(),
      );

      rec.start(
        codec: VideoCodec.avc,
        chunkSeconds: 1,
        config: CaptureConfig.defaults(),
      );
      async.flushMicrotasks();
      expect(host.startCalls, 1, reason: 'first segment opens at once');

      async.elapse(const Duration(milliseconds: 2300));
      // Two rotations happened: each closes the in-flight segment and opens
      // the next one immediately, so there is no gap in coverage.
      expect(host.startCalls, 3);
      expect(host.stopCalls, 2);

      rec.stop();
      async.flushMicrotasks();
      expect(host.stopCalls, 3, reason: 'the tail segment is flushed');
      expect(host.startCalls, 3);
    });
  });

  test('reports avc as the applied codec when hevc was requested', () {
    fakeAsync((async) {
      final host = FakeRecorderHost();
      final rec = CameraPluginVideoChunkRecorder(
        host: host,
        fileStore: _NoopFileStore(),
      );
      final received = <VideoChunk>[];
      rec.chunks.listen(received.add);

      rec.start(
        codec: VideoCodec.hevc,
        chunkSeconds: 1,
        config: CaptureConfig.defaults(),
      );
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));

      expect(received, isNotEmpty);
      final chunk = received.first;
      expect(chunk.codec, VideoCodec.avc);
      expect(chunk.requestedCodec, VideoCodec.hevc);
      expect(chunk.isCodecMismatch, isTrue);
      expect(chunk.width, 1280);
      expect(chunk.height, 720);

      rec.stop();
      async.flushMicrotasks();
    });
  });

  test('supportedCodecs only lists what the plugin can really do', () {
    expect(
      CameraPluginVideoChunkRecorder(
        host: FakeRecorderHost(),
        fileStore: _NoopFileStore(),
      ).supportedCodecs,
      {VideoCodec.avc},
    );
  });

  test('stop is idempotent and emits no further chunks', () {
    fakeAsync((async) {
      final host = FakeRecorderHost();
      final rec = CameraPluginVideoChunkRecorder(
        host: host,
        fileStore: _NoopFileStore(),
      );

      rec.start(
        codec: VideoCodec.avc,
        chunkSeconds: 1,
        config: CaptureConfig.defaults(),
      );
      async.flushMicrotasks();

      rec.stop();
      async.flushMicrotasks();
      rec.stop();
      async.flushMicrotasks();

      expect(host.stopCalls, 1);

      // No timers are left behind to fire after the recorder was stopped.
      async.elapse(const Duration(seconds: 5));
      expect(host.startCalls, 1);
    });
  });
}
