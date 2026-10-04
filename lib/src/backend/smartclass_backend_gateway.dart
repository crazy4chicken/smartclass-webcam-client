import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'backend_gateway.dart';
import 'device_credentials.dart';
import 'protocol/binary_frame.dart';
import 'protocol/device_command.dart';
import 'protocol/device_message.dart';
import 'protocol/envelope.dart';
import 'registration_client.dart';
import 'registration_request.dart';
import 'unrecognized_command_log.dart';

/// The outbound half of a socket, narrowed to what the gateway uses.
abstract interface class ChannelSink {
  void add(dynamic data);

  Future<void> close([int? closeCode, String? closeReason]);
}

/// The inbound half plus the close code.
///
/// A minimal seam over `WebSocketChannel` so the whole link can be driven from
/// a test without a socket. It also keeps the plugin type out of the gateway's
/// constructor signature.
abstract interface class BackendChannel {
  Stream<dynamic> get stream;

  ChannelSink get sink;

  /// Completes once the upgrade handshake succeeded; fails if it did not.
  Future<void> get ready;

  /// The close code once the socket closed, when the transport reports one.
  ///
  /// `1008` means the ticket was already attached by another connection,
  /// `1009` means a frame exceeded the 16 MiB read limit, and `1006` is an
  /// abnormal closure — which for this protocol is normal operation, because a
  /// replaced connection is closed without a handshake.
  int? get closeCode;
}

/// How a [BackendChannel] is obtained. Injectable so tests never touch the
/// network.
typedef ChannelFactory = BackendChannel Function(Uri uri);

/// [BackendChannel] over the real `web_socket_channel`.
class WebSocketBackendChannel implements BackendChannel {
  WebSocketBackendChannel(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  ChannelSink get sink => _WebSocketChannelSink(_channel.sink);

  @override
  Future<void> get ready => _channel.ready;

  @override
  int? get closeCode => _channel.closeCode;
}

class _WebSocketChannelSink implements ChannelSink {
  _WebSocketChannelSink(this._sink);

  final WebSocketSink _sink;

  @override
  void add(dynamic data) => _sink.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _sink.close(closeCode, closeReason);
}

/// Jittered exponential backoff: 1s, 2s, 4s, 8s, 16s, capped at 16s.
///
/// The jitter matters more than the curve: every device in a room loses the
/// server at the same moment, and without it they would all come back at once.
Duration backoffFor(int attempt, {Random? random}) {
  const maxSeconds = 16;
  final seconds = attempt >= 5
      ? maxSeconds
      : (1 << attempt).clamp(1, maxSeconds);
  final jitterMs = (random ?? Random()).nextInt(250);
  return Duration(seconds: seconds, milliseconds: jitterMs);
}

/// The real backend link: register → attach → keepalive → backoff → register.
///
/// Every rule below comes from `smartclass-webcam-server/docs/protocol/`:
///
/// - Registration is a `GET` carrying a JSON body and a `Bearer wdt_…` token.
/// - The returned ticket is **single use** and dies with its connection, so a
///   reconnect always starts with a fresh registration. There is no resume.
/// - `ping` is answered here with `pong`; the coordinator never sees it.
/// - A device that stays silent for 60 seconds is disconnected, so an idle
///   `status` goes out on a timer even when nothing is recording.
/// - `401` is terminal: the token was rotated or the device deleted, and only
///   an operator can fix that.
class SmartClassBackendGateway implements BackendGateway {
  SmartClassBackendGateway({
    required Uri base,
    required RegistrationClient registration,
    required ChannelFactory channelFactory,
    required List<CameraAnnouncement> cameras,
    Duration? idleStatusInterval,
    Duration Function(int attempt)? backoff,
    Map<String, Object?> Function()? statusReport,
    UnrecognizedCommandLog? unrecognizedLog,
  }) : _base = base,
       _registration = registration,
       _channelFactory = channelFactory,
       _cameras = List<CameraAnnouncement>.unmodifiable(cameras),
       _idleStatusInterval =
           idleStatusInterval ?? const Duration(seconds: idleStatusSeconds),
       _backoff = backoff ?? backoffFor,
       _statusReport = statusReport ?? (() => {'ts': rfc3339(DateTime.now())}),
       _unrecognized = unrecognizedLog ?? UnrecognizedCommandLog();

  /// How often an idle `status` is sent. Must stay well under the server's
  /// 60-second read deadline.
  static const int idleStatusSeconds = 30;

  final Uri _base;
  final RegistrationClient _registration;
  final ChannelFactory _channelFactory;
  final List<CameraAnnouncement> _cameras;
  final Duration _idleStatusInterval;
  final Duration Function(int attempt) _backoff;
  final Map<String, Object?> Function() _statusReport;

  final StreamController<DeviceCommand> _commands =
      StreamController<DeviceCommand>.broadcast();
  final StreamController<LinkState> _states =
      StreamController<LinkState>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final UnrecognizedCommandLog _unrecognized;

  DeviceCredentials? _credentials;
  BackendChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  Timer? _idleTimer;

  LinkState _state = LinkState.idle;
  int _attempt = 0;

  /// Bumped on every teardown. A late callback from a previous connection
  /// carries an old generation and is ignored, which is what stops a replaced
  /// connection from tearing down the new one.
  int _generation = 0;

  bool _stopped = true;

  String? _lastError;
  String? _ticket;

  @override
  Stream<DeviceCommand> get commands => _commands.stream;

  @override
  Stream<LinkState> get states => _states.stream;

  /// Human-readable problems that have no other channel to an operator:
  /// a rejected token, an oversized frame, a malformed registration response.
  Stream<String> get errors => _errors.stream;

  @override
  LinkState get state => _state;

  @override
  UnrecognizedCommandLog get unrecognizedCommands => _unrecognized;

  /// The most recent [errors] message, or null.
  String? get lastError => _lastError;

  /// The ticket currently held, if any. Exposed for diagnostics only.
  String? get ticket => _ticket;

  // --- lifecycle ------------------------------------------------------------

  @override
  Future<void> start(DeviceCredentials credentials) async {
    _credentials = credentials;
    _stopped = false;
    _attempt = 0;
    await _registerAndAttach();
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    await _teardown();
    _setState(LinkState.idle);
  }

  /// Test hook: behaves exactly as an unexpected socket close.
  void simulateClose({int? closeCode}) {
    _onClosed(_generation, closeCode: closeCode);
  }

  // --- register → attach ----------------------------------------------------

  Future<void> _registerAndAttach() async {
    final credentials = _credentials;
    if (_stopped || credentials == null) return;

    final generation = _generation;
    _setState(LinkState.registering);

    final RegistrationResult result;
    try {
      result = await _registration.register(_base, credentials, _cameras);
    } on RegistrationException catch (error) {
      if (_isStale(generation)) return;
      if (error.failure == RegistrationFailure.unauthorized) {
        // Retrying cannot fix a rotated or deleted credential.
        _fail(
          '设备令牌被拒绝（401）：${error.detail ?? 'device authentication failed'}。'
          '需要运营侧重新下发凭据。',
        );
        return;
      }
      _reportError('注册失败（${error.failure.name}）：${error.detail ?? ''}');
      _scheduleRetry();
      return;
    } catch (error) {
      if (_isStale(generation)) return;
      _reportError('注册请求异常：$error');
      _scheduleRetry();
      return;
    }

    if (_isStale(generation)) return;

    _ticket = result.ticket;
    _setState(LinkState.attaching);

    final BackendChannel channel;
    try {
      channel = _channelFactory(
        toWebSocketUri(resolveDevicePath(_base, result.websocketPath)),
      );
      await channel.ready;
    } catch (error) {
      if (_isStale(generation)) return;
      // 404 (unknown or expired ticket) and 409 (the ticket is still the live
      // session) are both "this ticket is unusable": register again.
      _reportError('挂载失败，将重新注册：$error');
      _scheduleRetry();
      return;
    }

    if (_isStale(generation)) {
      // A newer attempt won the race; do not leave this socket dangling.
      unawaited(channel.sink.close());
      return;
    }

    _attach(channel, generation);
  }

  void _attach(BackendChannel channel, int generation) {
    _channel = channel;
    _attempt = 0;
    _setState(LinkState.live);

    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(_idleStatusInterval, (_) => _sendIdleStatus());

    _subscription = channel.stream.listen(
      (data) => _onData(data, generation),
      onError: (Object _) => _onClosed(generation),
      onDone: () => _onClosed(generation),
      cancelOnError: false,
    );
  }

  void _onData(dynamic data, int generation) {
    if (_isStale(generation)) return;

    // The server never sends binary frames; anything non-text is not ours.
    if (data is! String) return;

    final command = parseDeviceCommand(data, log: _unrecognized);
    if (command == null) {
      // Already recorded locally. Never close the connection over an
      // unrecognised message.
      return;
    }

    if (command is PingCommand) {
      // Answered here, not by the coordinator: the pong is a transport
      // obligation, not an application decision.
      send(PongMessage(ts: command.ts));
      return;
    }

    if (!_commands.isClosed) _commands.add(command);
  }

  void _onClosed(int generation, {int? closeCode}) {
    if (_isStale(generation)) return;

    final code = closeCode ?? _channel?.closeCode;
    _idleTimer?.cancel();
    _idleTimer = null;
    unawaited(_teardown());

    if (code == 1009) {
      // A frame exceeded the 16 MiB read limit. The socket is already gone, so
      // this is a local diagnosis rather than a message to the server.
      _reportError('单帧超过 16 MiB，连接被服务端以 1009 关闭。');
    } else if (code == 1008) {
      _reportError('ticket 已被其它连接挂载（1008），将重新注册。');
    }

    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_stopped || _retryTimer != null) return;
    final delay = _backoff(_attempt);
    _attempt++;
    _setState(LinkState.backoff);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_registerAndAttach());
    });
  }

  Future<void> _teardown() async {
    _generation++;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    _ticket = null;

    try {
      await subscription?.cancel();
    } catch (_) {
      // Cancelling an already-dead subscription is not worth surfacing.
    }
    try {
      await channel?.sink.close();
    } catch (_) {
      // Closing an already-dead socket is not an error.
    }
  }

  void _fail(String reason) {
    // Terminal: `_stopped` also blocks every retry path.
    _stopped = true;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    unawaited(_teardown());
    _reportError(reason);
    _setState(LinkState.failed);
  }

  // --- outbound -------------------------------------------------------------

  @override
  void send(DeviceMessage message) {
    final channel = _channel;
    if (channel == null || _state != LinkState.live) return;
    try {
      channel.sink.add(message.encode());
    } catch (_) {
      // A dead sink means the close handler is about to fire; it will
      // schedule the reconnect.
    }
  }

  @override
  void sendRecordingFrame(RecordingFrameMeta meta, Uint8List bytes) =>
      _sendBinary(meta.toMessage(), bytes);

  @override
  void sendPhoto(PhotoMeta meta, Uint8List bytes) =>
      _sendBinary(meta.toMessage(), bytes);

  void _sendBinary(Message header, Uint8List bytes) {
    final channel = _channel;
    if (channel == null || _state != LinkState.live) return;
    try {
      channel.sink.add(encodeBinaryFrame(header, bytes));
    } on BinaryFrameError catch (error) {
      // Sending it would kill the connection with a 1009, so drop it and say
      // why instead.
      _reportError(error.message);
    } catch (_) {
      // Same reasoning as `send`.
    }
  }

  void _sendIdleStatus() {
    if (_state != LinkState.live) return;
    send(StatusMessage(report: _statusReport()));
  }

  // --- helpers --------------------------------------------------------------

  bool _isStale(int generation) => _stopped || generation != _generation;

  void _setState(LinkState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  void _reportError(String message) {
    _lastError = message;
    if (!_errors.isClosed) _errors.add(message);
  }
}
