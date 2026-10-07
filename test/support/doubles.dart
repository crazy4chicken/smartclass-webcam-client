import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
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
import 'package:webcam_client/src/capture/frame_store.dart';
import 'package:webcam_client/src/config/connection_settings.dart';

/// A credential pair of the shape the server issues.
const DeviceCredentials testCredentials = DeviceCredentials(
  deviceId: '01J8ZK9WQ7X3YV0M4N5P6Q7R8S',
  deviceToken: 'wdt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);

/// A provisioned connection pointing at the built-in default address.
///
/// Not `const` because `Uri.parse` is not — hence `final`.
final ConnectionSettings testConnection = ConnectionSettings(
  baseUrl: Uri.parse(defaultBaseUrl),
  credentials: testCredentials,
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
  // Needed for `when(() => gateway.start(any()))`.
  registerFallbackValue(testCredentials);
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

// --- camera plugin doubles --------------------------------------------------

/// A `CameraController` that answers without touching any platform channel.
///
/// `CameraController` extends `ValueNotifier<CameraValue>` and its constructor
/// makes **no** platform calls, so overriding `initialize` and writing `value`
/// is enough — no `CameraPlatform` double is needed. That matters because a
/// real `CameraValue` cannot be constructed from outside the package (its
/// constructor takes a private `_isRecordingPaused`), but `copyWith` is public.
///
/// Used by both the ranking pass and the capability probe, which are the only
/// two places that open a camera outside the capture path.
class FakeCameraController extends CameraController {
  FakeCameraController(
    CameraDescription description,
    ResolutionPreset preset, {
    int? fps,
    this.previewSize,
    this.picturePath = 'fake-picture.jpg',
    this.pictureBytes,
    this.failOnInitialize,
    this.failOnTakePicture,
    this.initializeDelay = Duration.zero,
  }) : super(description, preset, enableAudio: false, fps: fps);

  /// What `value.previewSize` reports once initialized.
  final Size? previewSize;

  /// The path `takePicture()` pretends to have written.
  final String picturePath;

  /// Handed to the frame store when set; null makes the store answer null.
  final Uint8List? pictureBytes;

  final Object? failOnInitialize;
  final Object? failOnTakePicture;
  final Duration initializeDelay;

  bool initialized = false;
  bool disposed = false;
  int pictures = 0;

  @override
  Future<void> initialize() async {
    if (initializeDelay > Duration.zero)
      await Future<void>.delayed(initializeDelay);
    final failure = failOnInitialize;
    if (failure != null) throw failure;
    initialized = true;
    value = value.copyWith(isInitialized: true, previewSize: previewSize);
  }

  @override
  Future<XFile> takePicture() async {
    pictures++;
    final failure = failOnTakePicture;
    if (failure != null) throw failure;
    return XFile(picturePath);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    super.dispose();
  }
}

/// A [FrameStore] that hands back whatever it was told to, keyed by path.
class FakeFrameStore implements FrameStore {
  FakeFrameStore([Map<String, Uint8List>? files]) : _files = files ?? {};

  final Map<String, Uint8List> _files;
  final List<String> reads = <String>[];
  final List<String> deletes = <String>[];

  @override
  Future<Uint8List> readAndDelete(String path) async {
    reads.add(path);
    final bytes = _files.remove(path);
    if (bytes == null) throw StateError('no such capture file: $path');
    return bytes;
  }

  @override
  Future<void> delete(String path) async => deletes.add(path);
}

/// A camera description with the plugin's own shape.
const CameraDescription fakeCameraDescription = CameraDescription(
  name: 'fake camera',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 0,
);
