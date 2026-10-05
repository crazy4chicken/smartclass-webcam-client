import 'dart:async';

/// Runs asynchronous work one item at a time, in call order.
///
/// Two places in this app need it for the same reason — the underlying
/// platform call cannot overlap with itself:
///
/// - **Camera rebuilds.** `initialize` / `reconfigure` / `switchCamera` all
///   tear the controller down and build a new one, so letting two of them
///   interleave would leave the app with no camera at all.
/// - **Still captures.** `takePicture()` cannot run twice at once on one
///   controller, and `take_photo` legitimately races the frame pump while a
///   stream is active. Unserialised, whichever call loses throws, the frame
///   source swallows it into a `null`, and the photo is silently never
///   uploaded.
///
/// A failure in one item does not poison the queue: the next item still runs.
class SerialLock {
  Future<void> _tail = Future<void>.value();

  /// Number of items that have been queued but not yet finished.
  int get pending => _pending;
  int _pending = 0;

  /// Queues [action] behind whatever is already running.
  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    _pending++;

    return previous
        // An earlier item failing must not stop this one from running.
        .catchError((Object _) {})
        .then((_) => action())
        .whenComplete(() {
          _pending--;
          completer.complete();
        });
  }
}
