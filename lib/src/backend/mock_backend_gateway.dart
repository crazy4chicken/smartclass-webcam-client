import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'backend_gateway.dart';
import 'device_credentials.dart';
import 'protocol/device_command.dart';
import 'protocol/device_message.dart';
import 'unrecognized_command_log.dart';

const String _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Mints a 26-character ULID: a 48-bit millisecond timestamp followed by 80
/// random bits, Crockford base32.
///
/// The server mints every real `id`, `stream_id` and `request_id`; this exists
/// so the offline mock hands out identifiers of exactly the same shape, which
/// is what makes "does the client echo them back verbatim?" a meaningful test.
String generateUlid([DateTime? at, Random? random]) {
  final millis = (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
  final rng = random ?? Random();

  final chars = List<String>.filled(26, '0');
  var remaining = millis;
  for (var i = 9; i >= 0; i--) {
    chars[i] = _crockford[remaining & 31];
    remaining >>= 5;
  }
  for (var i = 10; i < 26; i++) {
    chars[i] = _crockford[rng.nextInt(32)];
  }
  return chars.join();
}

/// An in-process fake backend for offline development and demos.
///
/// Enabled with `--dart-define=USE_MOCK_BACKEND=true`. It never touches the
/// network: it mints server-shaped identifiers, walks the same command cycle
/// the operator endpoints would trigger, and counts what the device would have
/// uploaded.
///
/// Because it speaks the *real* protocol vocabulary, the coordinator and the
/// frame pump are exercised end to end without a server.
class MockBackendGateway implements BackendGateway {
  MockBackendGateway({
    Duration? commandInterval,
    Random? random,
    UnrecognizedCommandLog? unrecognizedLog,
  }) : commandInterval = commandInterval ?? const Duration(seconds: 2),
       _random = random ?? Random(),
       _unrecognized = unrecognizedLog ?? UnrecognizedCommandLog(sink: null);

  final Duration commandInterval;
  final Random _random;

  final StreamController<DeviceCommand> _commands =
      StreamController<DeviceCommand>.broadcast();
  final StreamController<LinkState> _states =
      StreamController<LinkState>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final UnrecognizedCommandLog _unrecognized;

  Timer? _timer;
  int _tick = 0;
  LinkState _state = LinkState.idle;

  /// The stream id handed out by the last `start_recording`, so the mock's
  /// `stop_recording` names the same stream the way the server would.
  String? _activeStreamId;

  /// Frames the device handed over.
  int recordedFrames = 0;

  /// Photos the device handed over.
  int recordedPhotos = 0;

  /// Control messages the device sent (`ack` / `pong` / `status` / `error`).
  final List<DeviceMessage> sentMessages = <DeviceMessage>[];

  /// The most recent `start_recording` the mock issued, if any.
  String? get activeStreamId => _activeStreamId;

  @override
  Stream<DeviceCommand> get commands => _commands.stream;

  @override
  Stream<LinkState> get states => _states.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  LinkState get state => _state;

  @override
  UnrecognizedCommandLog get unrecognizedCommands => _unrecognized;

  @override
  Future<void> start(DeviceCredentials credentials) async {
    _setState(LinkState.registering);
    _setState(LinkState.attaching);
    _setState(LinkState.live);
    _timer?.cancel();
    _timer = Timer.periodic(commandInterval, (_) => _emitNext());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _activeStreamId = null;
    _setState(LinkState.idle);
  }

  void _setState(LinkState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// One step of the operator-triggered command cycle.
  ///
  /// Mirrors the four HTTP endpoints in the order a demo would use them:
  /// start a recording, take a photo, stop the recording, then keepalive.
  void _emitNext() {
    if (_commands.isClosed) return;

    switch (_tick++ % 4) {
      case 0:
        final streamId = generateUlid(null, _random);
        _activeStreamId = streamId;
        _commands.add(
          StartRecordingCommand(
            id: generateUlid(null, _random),
            cameraEnum: 0,
            streamId: streamId,
          ),
        );
      case 1:
        _commands.add(
          TakePhotoCommand(
            id: generateUlid(null, _random),
            cameraEnum: 0,
            requestId: generateUlid(null, _random),
          ),
        );
      case 2:
        final streamId = _activeStreamId;
        _activeStreamId = null;
        _commands.add(
          StopRecordingCommand(
            id: generateUlid(null, _random),
            cameraEnum: 0,
            streamId: streamId ?? generateUlid(null, _random),
          ),
        );
      case 3:
        _commands.add(
          PingCommand(ts: DateTime.now().toUtc().toIso8601String()),
        );
    }
  }

  @override
  void send(DeviceMessage message) => sentMessages.add(message);

  @override
  bool sendRecordingFrame(RecordingFrameMeta meta, Uint8List bytes) {
    recordedFrames++;
    // The mock has no wire to lose a frame on.
    return true;
  }

  @override
  void sendPhoto(PhotoMeta meta, Uint8List bytes) {
    recordedPhotos++;
  }
}
