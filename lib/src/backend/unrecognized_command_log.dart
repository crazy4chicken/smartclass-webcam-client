import 'dart:collection';

/// Why a payload could not be turned into a [ServerCommand].
enum UnrecognizedReason {
  /// Not valid JSON, or not a JSON object envelope.
  malformedJson,

  /// Valid envelope, but `type` is missing or not a command we know.
  unknownType,

  /// Known `type`, but a field has an unusable type.
  invalidPayload,
}

/// One locally recorded inbound message that could not be understood.
class UnrecognizedEntry {
  UnrecognizedEntry({
    required this.raw,
    required this.reason,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String raw;
  final UnrecognizedReason reason;
  final DateTime timestamp;
}

const Object _unsetSink = Object();

/// Default destination for local diagnostics.
///
/// Deliberately `print`, not Flutter's `debugPrint`: the protocol layer must
/// not depend on Flutter, so the whole stack stays runnable and testable on a
/// plain Dart VM. `main.dart` wires `debugPrint` in explicitly.
void _defaultSink(String message) => print(message);

/// Bounded, local-only record of inbound messages we could not parse.
///
/// While the backend protocol is not final this is the primary diagnostic
/// surface: unknown or malformed messages are recorded here and shown in the
/// console. They are **never** sent back to the backend, never thrown, and
/// never allowed to break the connection or the next frame parse.
class UnrecognizedCommandLog {
  UnrecognizedCommandLog({this.capacity = 50, Object? sink = _unsetSink})
      : _sink = identical(sink, _unsetSink)
            ? _defaultSink
            : sink as void Function(String)?;

  /// Maximum raw payload retained per entry. Keeps one hostile frame from
  /// exhausting memory.
  static const int maxRawLength = 512;

  final int capacity;
  final void Function(String)? _sink;

  final Queue<UnrecognizedEntry> _entries = Queue<UnrecognizedEntry>();

  int _droppedCount = 0;

  /// Oldest first, newest last.
  List<UnrecognizedEntry> get entries => List.unmodifiable(_entries);

  /// How many entries fell out of the ring buffer.
  int get droppedCount => _droppedCount;

  void record(String raw, UnrecognizedReason reason) {
    final trimmed = raw.length > maxRawLength
        ? raw.substring(0, maxRawLength)
        : raw;

    _entries.addLast(
      UnrecognizedEntry(raw: trimmed, reason: reason),
    );
    while (_entries.length > capacity) {
      _entries.removeFirst();
      _droppedCount++;
    }

    _sink?.call(
      '[unrecognized:${reason.name}] $trimmed',
    );
  }

  void clear() {
    _entries.clear();
    _droppedCount = 0;
  }
}
