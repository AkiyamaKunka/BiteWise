/// Which meals a screen is working on right now (design R6a, "Assist
/// architecture: save first, enrich later").
///
/// The restaurant assist (MealAssist, R6b) enriches a meal in the
/// foreground some time after it was saved. Every analysis writer is
/// compare-and-set (MealsDao.mealSnapshot / applyAssist /
/// …IfUnchanged), so a race can never lose a write silently — but the
/// loser still loses: an editor full of typed numbers is answered with
/// "this meal was just updated", a leftover selection is re-based. The
/// registry keeps those races from starting: the assist skips a meal while
///   * its editor is open,
///   * a leftover flow has it selected,
///   * a fix-meal (chat) request is pending — the model picks the target,
///     so that hold covers every meal ([acquireAll]).
///
/// One registry per app engine, built in di.dart; screens take it as an
/// optional dependency (null in tests that do not care). Holds are counted,
/// so two holders of one meal both have to let go, and releasing a hold
/// twice is harmless — a screen's dispose may follow an explicit release.
library;

/// One holder's claim on a meal (or on every meal). Pass it back to
/// [MealInUseRegistry.release], or call [release] on it.
final class MealInUseHold {
  MealInUseHold._(this._registry, this.mealId);

  final MealInUseRegistry _registry;

  /// The meal held, or null for every meal ([MealInUseRegistry.acquireAll]).
  final int? mealId;

  bool _released = false;

  /// Whether this hold was let go.
  bool get released => _released;

  /// Let go of the claim; a second call does nothing.
  void release() => _registry.release(this);
}

class MealInUseRegistry {
  final Map<int, int> _holds = {};
  int _allHolds = 0;

  /// Claim [mealId] until the returned hold is released.
  MealInUseHold acquire(int mealId) {
    _holds[mealId] = (_holds[mealId] ?? 0) + 1;
    return MealInUseHold._(this, mealId);
  }

  /// Claim every meal until the returned hold is released: a request whose
  /// target is not known yet (the fix-meal chat, where the model picks it).
  MealInUseHold acquireAll() {
    _allHolds++;
    return MealInUseHold._(this, null);
  }

  /// Let go of [hold]. Idempotent; a hold from another registry is ignored.
  void release(MealInUseHold hold) {
    if (hold._released || !identical(hold._registry, this)) return;
    hold._released = true;
    final id = hold.mealId;
    if (id == null) {
      if (_allHolds > 0) _allHolds--;
      return;
    }
    final n = (_holds[id] ?? 0) - 1;
    if (n > 0) {
      _holds[id] = n;
    } else {
      _holds.remove(id);
    }
  }

  /// Whether any screen is working on [mealId] — or on every meal.
  bool isInUse(int mealId) => _allHolds > 0 || _holds.containsKey(mealId);
}
