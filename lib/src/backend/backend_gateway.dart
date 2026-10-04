import 'dart:typed_data';

import 'client_signal.dart';
import 'server_command.dart';
import 'unrecognized_command_log.dart';

/// State of the link to the backend.
enum ConnectionState {
  /// Socket is open and heartbeats are flowing.
  connected,

  /// Socket dropped; a backoff retry is scheduled.
  reconnecting,

  /// Deliberately closed (app backgrounded or shutting down).
  offline,
}

/// The single seam between this app and the backend.
///
/// Nothing above this interface knows about WebSockets, JSON, or reconnect
/// policy. That keeps a not-yet-finalised protocol — and a future `wss://`
/// with auth — replaceable without touching the coordinator.
///
/// Note the interface deliberately does **not** leak `WebSocketChannel`.
abstract interface class BackendGateway {
  Future<void> connect(String url);

  Future<void> disconnect();

  /// Sends a control signal (register, heartbeat, state_sync, ...).
  void sendSignal(ClientSignal signal);

  /// Sends the `frame_meta` text frame that must precede a JPEG binary frame.
  void sendFrameMeta(FrameMeta meta);

  /// Sends raw JPEG bytes as a binary frame.
  void sendFrameBytes(Uint8List bytes);

  /// Sends the `video_meta` text frame that must precede an mp4 chunk.
  void sendVideoMeta(VideoMeta meta);

  /// Sends raw mp4 chunk bytes as a binary frame.
  void sendVideoBytes(Uint8List bytes);

  Stream<ServerCommand> get commands;

  Stream<ConnectionState> get connectionChanges;

  bool get isConnected;

  UnrecognizedCommandLog get unrecognizedCommands;
}
