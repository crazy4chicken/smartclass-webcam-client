import 'dart:async';
import 'dart:typed_data';

import 'package:mocktail/mocktail.dart';
import 'package:webcam_client/src/backend/backend_gateway.dart';
import 'package:webcam_client/src/backend/device_credentials.dart';
import 'package:webcam_client/src/backend/protocol/device_message.dart';
import 'package:webcam_client/src/backend/protocol/envelope.dart';
import 'package:webcam_client/src/backend/registration_client.dart';
import 'package:webcam_client/src/backend/registration_request.dart';
import 'package:webcam_client/src/backend/smartclass_backend_gateway.dart';
import 'package:webcam_client/src/capture/camera_backend.dart';
import 'package:webcam_client/src/capture/camera_service.dart';
import 'package:webcam_client/src/capture/frame_pump.dart';

/// A credential pair of the shape the server issues.
const DeviceCredentials testCredentials = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

/// A 64-character lowercase hex ticket, as `GET /ws/register` returns.
final String testTicket = List<String>.filled(64, 'b').join();

/// A 26-character ULID, as the server mints for commands and streams.
const String testUlid = '01J8ZKQ3B5N7P9R1T3V5X7Z9B2';

const CameraAnnouncement testCamera = CameraAnnouncement(
  cameraEnum: 0,
  resolution: '1280x720',
  fps: 5,
  supportedCodec: <WireCodec>[WireCodec.mjpeg],
);

/// mocktail's `registerFallbackValue` is **not** generic in 1.0.5 — it takes a
/// `dynamic` and matches with `is`. So one concrete instance per abstract type
/// is enough, and `registerFallbackValue<ClientSignal>(...)` would not compile.
void registerCommonFallbacks() {
  registerFallbackValue(AckMessage(id: 'fallback', ok: true));
  registerFallbackValue(
    RecordingFrameMeta(
      cameraEnum: 0,
      streamId: 'fallback',
      seq: 0,
      ts: DateTime.utc(2026),
    ),
  );
  registerFallbackValue(PhotoMeta(cameraEnum: 0, ts: DateTime.utc(2026)));
  registerFallbackValue(Uint8List(0));
}

// --- mocktail mocks ---------------------------------------------------------

/// A mocktail double for the gateway seam.
///
/// Named `MockGateway` rather than `MockBackendGateway` so it never clashes
/// with the real `MockBackendGateway` from the library.
class MockGateway extends Mock implements BackendGateway {}

class MockCameraService extends Mock implements CameraService {}

class MockCameraBackend extends Mock implements CameraBackend {}

class MockFramePump extends Mock implements FramePump {}

// --- channel doubles --------------------------------------------------------

class FakeChannelSink implements ChannelSink {
  final List<dynamic> records = <dynamic>[];
  bool closed = false;

  /// Everything sent, decoded as text frames.
  List<String> get text => records.whereType<String>().toList();

  /// Everything sent, as binary frames.
  List<Uint8List> get binary => records.whereType<Uint8List>().toList();

  @override
  void add(dynamic data) => records.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }
}

class FakeChannel implements BackendChannel {
  FakeChannel(this.stream, this.sink, {this.readyError, this.closeCode});

  @override
  final Stream<dynamic> stream;

  @override
  final FakeChannelSink sink;

  /// When set, [ready] fails the way a failed handshake does (`404` / `409`).
  final Object? readyError;

  @override
  int? closeCode;

  @override
  Future<void> get ready => readyError == null
      ? Future<void>.value()
      : Future<void>.error(readyError!);
}

/// A registration client that never touches the network.
class FakeRegistrationClient implements RegistrationClient {
  FakeRegistrationClient({
    this.failure,
    this.ticket,
    this.websocketPath,
    this.expiresAt,
  });

  final RegistrationFailure? failure;
  final String? ticket;
  final String? websocketPath;
  final DateTime? expiresAt;

  int calls = 0;
  Uri? lastBase;
  DeviceCredentials? lastCredentials;
  List<CameraAnnouncement>? lastCameras;

  @override
  Future<RegistrationResult> register(
    Uri base,
    DeviceCredentials credentials,
    List<CameraAnnouncement> cameras,
  ) async {
    calls++;
    lastBase = base;
    lastCredentials = credentials;
    lastCameras = cameras;

    final failure = this.failure;
    if (failure != null) throw RegistrationException(failure);

    final resolved = ticket ?? testTicket;
    return RegistrationResult(
      ticket: resolved,
      expiresAt:
          expiresAt ?? DateTime.now().toUtc().add(const Duration(seconds: 60)),
      websocketPath: websocketPath ?? '/ws/device/$resolved',
    );
  }
}

/// Opens a stream that stays open, so a gateway under test is not torn down by
/// an immediate `onDone`.
({StreamController<dynamic> controller, FakeChannelSink sink}) openChannel() {
  final controller = StreamController<dynamic>();
  return (controller: controller, sink: FakeChannelSink());
}
