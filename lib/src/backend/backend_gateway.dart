import 'dart:typed_data';

import 'device_credentials.dart';
import 'protocol/device_command.dart';
import 'protocol/device_message.dart';
import 'unrecognized_command_log.dart';

/// Where the link to the backend currently is.
///
/// The device holds exactly one live session at a time, so the states form a
/// loop rather than a set: `idle → registering → attaching → live`, and any
/// close sends it to `backoff` before it re-registers from scratch.
///
/// There is **no session resume**: a ticket is single-use and dies with its
/// connection, so [backoff] always leads back through a fresh registration
/// rather than a reconnect.
enum LinkState {
  /// Never started, or deliberately stopped.
  idle,

  /// `GET /ws/register` is in flight, minting a ticket.
  registering,

  /// Upgrading the WebSocket at `websocket_path` with the ticket.
  attaching,

  /// Attached: commands flow, media may be pushed.
  live,

  /// The link dropped and a jittered exponential retry is scheduled.
  backoff,

  /// Terminal. The credential was rejected (`401`), which retrying cannot fix.
  failed;

  bool get isConnected => this == LinkState.live;

  bool get isTerminal => this == LinkState.failed;
}

/// The single seam between this app and `smartclass-webcam-server`.
///
/// Nothing above this interface knows about HTTP registration, tickets,
/// WebSocket framing or reconnect policy. The interface deliberately does
/// **not** leak `WebSocketChannel`, `http.Client` or JSON: swapping the
/// transport must not reach the coordinator.
abstract interface class BackendGateway {
  /// Registers and attaches. Resolves as soon as the attempt is under way —
  /// the link keeps retrying in the background.
  Future<void> start(DeviceCredentials credentials);

  /// Deliberately closes the link and cancels every retry.
  Future<void> stop();

  /// Commands from the server, already parsed. `ping` is answered inside the
  /// gateway and never appears here.
  Stream<DeviceCommand> get commands;

  /// Link transitions, for the status bar.
  Stream<LinkState> get states;

  /// Human-readable problems that have no other route to an operator: a
  /// rejected token, a frame above the 16 MiB limit, a malformed registration
  /// response.
  ///
  /// The protocol deliberately tells the device nothing about dropped frames
  /// or refused commands, so this local surface is the only feedback there is.
  Stream<String> get errors;

  /// Sends one control message (`ack` / `pong` / `status` / `error`).
  void send(DeviceMessage message);

  /// Sends one `recording.frame`: a JSON header plus one encoded video frame.
  ///
  /// Returns whether the frame was handed to the wire. **False is a real
  /// answer, not a formality**: a frame sent while the link is down, or one
  /// that would exceed the 16 MiB frame limit, is dropped here rather than
  /// killing the connection — and a caller that counted it as delivered would
  /// report a healthy stream over a link that is delivering nothing. That is
  /// the difference between "the network is behind" and "everything is fine",
  /// which is exactly the question the diagnostics have to answer.
  bool sendRecordingFrame(RecordingFrameMeta meta, Uint8List bytes);

  /// Sends one `photo.photo`: a JSON header plus one image.
  void sendPhoto(PhotoMeta meta, Uint8List bytes);

  LinkState get state;

  /// Local record of inbound messages we could not understand. Never sent
  /// back to the server.
  UnrecognizedCommandLog get unrecognizedCommands;
}
