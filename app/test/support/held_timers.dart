/// Timers a test holds instead of the event loop, so that nothing in it
/// waits on the real clock (a wait there passes or fails with the load of
/// the machine). Code run in [holdingTimers]'s zone arms [HeldTimer]s; the
/// test reads which are armed and for how long, and fires them itself.
///
/// A timer belongs to the zone it was created in: the engine's call that
/// arms it must run in the zone (`zone.run(...)`), and so must the signal
/// whose listener arms one. What a fired timer starts stays in the zone.
library;

import 'dart:async';

/// A timer the test holds instead of the event loop ([holdingTimers]), so
/// nothing waits on the real clock: [fire] runs it once, as the loop would
/// after [wait].
class HeldTimer implements Timer {
  HeldTimer(this.wait, this._run);

  final Duration wait;
  final void Function() _run;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _run();
  }
}

/// A zone in which every new timer goes to [held] instead of the event
/// loop: a test reads the timers the engine arms and fires them itself.
Zone holdingTimers(List<HeldTimer> held) => Zone.current.fork(
  specification: ZoneSpecification(
    createTimer: (self, parent, zone, wait, run) {
      final timer = HeldTimer(wait, run);
      held.add(timer);
      return timer;
    },
  ),
);
