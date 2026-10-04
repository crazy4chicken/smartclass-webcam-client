import 'dart:async';

import 'package:flutter/widgets.dart';

/// Whether the app should stop capturing for a lifecycle transition.
///
/// `inactive` on desktop means "window visible but unfocused", which for a
/// kiosk must **keep** streaming. Only genuinely going away pauses us.
///
/// iOS and Android forbid background camera access outright, so `paused` and
/// `hidden` are not a choice — they are a requirement.
bool shouldPauseFor(AppLifecycleState state) {
  switch (state) {
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
    case AppLifecycleState.detached:
      return true;
    case AppLifecycleState.resumed:
    case AppLifecycleState.inactive:
      return false;
  }
}

/// Bridges [WidgetsBindingObserver] lifecycle events to pause/resume callbacks.
class LifecycleController with WidgetsBindingObserver {
  LifecycleController({required this.onPause, required this.onResume});

  final Future<void> Function() onPause;
  final Future<void> Function() onResume;

  bool _paused = false;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (shouldPauseFor(state)) {
      if (_paused) return;
      _paused = true;
      unawaited(onPause());
      return;
    }

    // Only a genuine `resumed` rebuilds the pipeline; `inactive` is a no-op so
    // a transient focus loss does not tear the camera down and back up.
    if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      unawaited(onResume());
    }
  }
}
