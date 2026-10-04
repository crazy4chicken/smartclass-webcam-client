import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import 'backend_gateway.dart';
import 'client_signal.dart';
import 'command_codec.dart';
import 'server_command.dart';
import 'unrecognized_command_log.dart';

/// How a [WebSocketChannel] is obtained. Injectable so tests never touch the
/// network.
typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

/// Exponential reconnect backoff: 1s, 2s, 4s, 8s, 16s, then capped at 16s.
Duration backoffFor(int attempt) {
  if (attempt <= 0) return const Duration(seconds: 1);
  if (attempt >= 5) return const Duration(seconds: AppConfig.maxBackoffSeconds);
  final seconds = 1 << attempt;
  return Duration(
    seconds: seconds > AppConfig.maxBackoffSeconds
        ? AppConfig.maxBackoffSeconds
        : seconds,
  );
}

/// [BackendGateway] over a raw WebSocket.
///
/// Text frames are JSON signals; binary frames are raw payload bytes. Frames
/// the codec cannot understand are logged locally and dropped — the channel
/// stays open and the next valid frame parses normally.
class WebSocketBackendGateway implements BackendGateway {
  WebSocketBackendGateway({
    required CommandCodec codec,
    required WebSocketChannelFactory channelFactory,
    Duration? heartbeatInterval,
    Duration Function(int attempt)? backoff,
    this.deviceId = '',
  }) : _codec = codec,
       _channelFactory = channelFactory,
       _heartbeatInterval =
           heartbeatInterval ??
           const Duration(seconds: AppConfig.heartbeatSeconds),
       _backoff = backoff ?? backoffFor;

  final CommandCodec _codec;
  final WebSocketChannelFactory _channelFactory;
  final Duration _heartbeatInterval;
  final Duration Function(int attempt) _backoff;

  /// Used as the `deviceId` on outgoing heartbeats.
  String deviceId;

  final StreamController<ServerCommand> _commands =
      StreamController<ServerCommand>.broadcast();
  final StreamController<ConnectionState> _connectionChanges =
      StreamController<ConnectionState>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _attempt = 0;
  String? _url;
  bool _connected = false;
  bool _closedByUser = false;

  @override
  Stream<ServerCommand> get commands => _commands.stream;

  @override
  Stream<ConnectionState> get connectionChanges => _connectionChanges.stream;

  @override
  bool get isConnected => _connected;

  @override
  UnrecognizedCommandLog get unrecognizedCommands =>
      _codec.unrecognizedCommands;

  @override
  Future<void> connect(String url) async {
    _url = url;
    _closedByUser = false;
    _attempt = 0;
    await _open();
  }

  Future<void> _open() async {
    if (_url == null || _closedByUser) return;
    try {
      final channel = _channelFactory(Uri.parse(_url!));
      _channel = channel;
      _subscription = channel.stream.listen(
        _onData,
        onError: (Object _) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: false,
      );
      _connected = true;
      _attempt = 0;
      _emit(ConnectionState.connected);
      _startHeartbeat();
    } catch (_) {
      _handleDisconnect();
    }
  }

  void _onData(dynamic data) {
    if (data is String) {
      final command = _codec.decode(data);
      if (command != null && !_commands.isClosed) {
        _commands.add(command);
      }
      return;
    }
    // Inbound binary frames are not consumed by the client today.
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      sendSignal(HeartbeatSignal(deviceId: deviceId));
    });
  }

  void _handleDisconnect() {
    if (_closedByUser) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;

    if (_connected) {
      _connected = false;
      _emit(ConnectionState.reconnecting);
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closedByUser || _reconnectTimer != null) return;
    final delay = _backoff(_attempt);
    _attempt++;
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      await _open();
    });
  }

  void _emit(ConnectionState state) {
    if (!_connectionChanges.isClosed) {
      _connectionChanges.add(state);
    }
  }

  @override
  Future<void> disconnect() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {
      // Closing an already-dead socket is not an error worth surfacing.
    }
    _channel = null;
    if (_connected) {
      _connected = false;
      _emit(ConnectionState.offline);
    }
  }

  @override
  void sendSignal(ClientSignal signal) {
    _channel?.sink.add(_codec.encode(signal));
  }

  @override
  void sendFrameMeta(FrameMeta meta) {
    _channel?.sink.add(_codec.encode(FrameMetaSignal(meta: meta)));
  }

  @override
  void sendFrameBytes(Uint8List bytes) {
    _channel?.sink.add(bytes);
  }

  @override
  void sendVideoMeta(VideoMeta meta) {
    _channel?.sink.add(_codec.encode(VideoMetaSignal(meta: meta)));
  }

  @override
  void sendVideoBytes(Uint8List bytes) {
    _channel?.sink.add(bytes);
  }
}
