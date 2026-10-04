import 'dart:async';
import 'dart:typed_data';

import '../capture/stream_settings.dart';
import 'backend_gateway.dart';
import 'client_signal.dart';
import 'server_command.dart';
import 'unrecognized_command_log.dart';

/// An in-process fake backend for offline development and demos.
///
/// Enabled with `--dart-define=USE_MOCK_BACKEND=true`. It never touches the
/// network: it just emits a rotating script of commands and counts the frames
/// and video chunks the client would have uploaded.
class MockBackendGateway implements BackendGateway {
  MockBackendGateway({Duration? commandInterval})
      : commandInterval = commandInterval ?? const Duration(seconds: 2);

  final Duration commandInterval;

  final StreamController<ServerCommand> _commands =
      StreamController<ServerCommand>.broadcast();
  final StreamController<ConnectionState> _connectionChanges =
      StreamController<ConnectionState>.broadcast();
  final UnrecognizedCommandLog _unrecognized =
      UnrecognizedCommandLog(sink: null);

  Timer? _timer;
  int _tick = 0;
  bool _connected = false;

  /// Number of still frames the client handed over.
  int frameCount = 0;

  /// Number of video chunks the client handed over.
  int videoChunkCount = 0;

  /// Number of control signals the client sent.
  int signalCount = 0;

  @override
  Stream<ServerCommand> get commands => _commands.stream;

  @override
  Stream<ConnectionState> get connectionChanges => _connectionChanges.stream;

  @override
  bool get isConnected => _connected;

  @override
  UnrecognizedCommandLog get unrecognizedCommands => _unrecognized;

  @override
  Future<void> connect(String url) async {
    _connected = true;
    _connectionChanges.add(ConnectionState.connected);
    _timer?.cancel();
    _timer = Timer.periodic(commandInterval, (_) => _emitNext());
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    if (_connected) {
      _connected = false;
      _connectionChanges.add(ConnectionState.offline);
    }
  }

  void _emitNext() {
    if (_commands.isClosed) return;
    final step = _tick++ % 3;
    switch (step) {
      case 0:
        _commands.add(const SetStreamModeCommand(
          mode: StreamMode.video,
          codec: VideoCodec.avc,
          chunkSeconds: 3,
        ));
      case 1:
        _commands.add(const SetPreviewCommand(enabled: true));
      case 2:
        _commands.add(const FaceResultCommand(
          result: FaceResult(name: '演示用户', status: 'approved'),
        ));
    }
  }

  @override
  void sendSignal(ClientSignal signal) => signalCount++;

  @override
  void sendFrameMeta(FrameMeta meta) {}

  @override
  void sendFrameBytes(Uint8List bytes) => frameCount++;

  @override
  void sendVideoMeta(VideoMeta meta) {}

  @override
  void sendVideoBytes(Uint8List bytes) => videoChunkCount++;
}
