/// Usual foods, the service (usual-foods spec §3.5-§3.7, §4.3, §5).
///
/// Worked out on the phone from the meals table: no model call, no lookup,
/// nothing sent. The pure rules live in core/usual_foods_logic.dart; this
/// file reads the meals, memoizes the index and writes through the DAO's
/// compare-and-set:
///   * Part 2, "your usual numbers": [UsualFoods.offersFor] /
///     [UsualFoods.offerFor] on Today's photo meals, [UsualFoods.accept]
///     (Use) and [UsualFoods.undoAccept], [UsualFoods.decline] (Keep AI
///     estimate).
///   * Part 3, "My usual foods": [UsualFoods.frequentMeals],
///     [UsualFoods.loggedRecently], [UsualFoods.logAgain] and
///     [UsualFoods.undoLog], [UsualFoods.hide] / [UsualFoods.unhide] /
///     [UsualFoods.hiddenMeals].
///
/// The index ([buildUsualIndex] over the last 90 days) is built only when
/// asked: never per photo, in the pipeline, in the background engine or at
/// launch. It is memoized per (local day, meals signal, epoch) and
/// single-flight; [UsualFoods.invalidate] bumps the epoch (My usual foods
/// calls it on open, since a background save bumps no signal).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import '../../core/usual_foods_logic.dart';
import '../assist/clients/lookup_client.dart' show LookupSupport;
import '../assist/meal_assist.dart'
    show AssistMode, AssistSettingsView, assistTriggerFor;
import 'usual_choices.dart';

export '../../core/usual_foods_logic.dart'
    show
        UsualIndex,
        UsualList,
        UsualMeal,
        UsualNumbers,
        UsualOffer,
        UsualOfferItem,
        UsualUndo,
        usualDisplayName,
        usualMealTitle;
export 'usual_choices.dart' show UsualChoices, UsualChoicesView;

/// Whether the restaurant lookup takes [analysis] (spec §3.7, M3), so
/// Part 2 offers nothing on it: lookups on, supported, consented to the
/// recipient they would reach now (a paused consent never runs a lookup),
/// and the meal triggers one ([assistTriggerFor]).
bool usualLookupTakesIt(
  Map<String, dynamic> analysis, {
  required AssistSettingsView settings,
  required LookupSupport support,
}) {
  if (settings.mode == AssistMode.off) return false;
  if (!support.supported) return false;
  if (!settings.consentCovers(support)) return false;
  return assistTriggerFor(analysis, settings.mode) != null;
}

/// What [UsualFoods.accept] did.
enum UsualAcceptStatus {
  /// Written: the meal holds the user's numbers and is corrected.
  written,

  /// Nothing written: the meal changed since the offer was shown (or the
  /// editor's text did), or it is no longer offered. Say
  /// editorSaveConflict.
  conflict,

  /// Nothing written: another Use of this meal is still running.
  busy,

  /// Nothing written: the meal no longer exists.
  gone,
}

/// [UsualFoods.accept]'s answer. [beforeKcal] / [afterKcal] are the meal
/// totals for the snackbar (usualUsedSnack).
final class UsualAcceptResult {
  const UsualAcceptResult({
    required this.status,
    required this.mealId,
    required this.beforeKcal,
    required this.afterKcal,
    this.undo,
  });
  final UsualAcceptStatus status;
  final int mealId;
  final num beforeKcal;
  final num afterKcal;

  /// What [UsualFoods.undoAccept] restores; null unless [status] is
  /// written.
  final UsualUndo? undo;
}

/// [UsualFoods.logAgain]'s answer: the new meal, and its stored text for
/// [UsualFoods.undoLog].
final class UsualLogResult {
  const UsualLogResult({
    required this.mealId,
    required this.rawAnalysis,
    required this.title,
    required this.kcal,
  });
  final int mealId;

  /// The analysis text as stored right after the save; null when the
  /// read back failed (Undo then says the meal changed).
  final String? rawAnalysis;

  /// For usualLoggedSnack.
  final String title;
  final num kcal;
}

/// The "Log it again?" window (D37).
const Duration kUsualAgainWindow = Duration(hours: 3);

class UsualFoods {
  /// [lookupTakesIt] is [usualLookupTakesIt] over the settings and the
  /// analyzer's lookup support (di.dart); [onMealsChanged] bumps
  /// [mealsChanged] (signalMealsChanged / mealsChangedSignal).
  UsualFoods({
    required this._dao,
    required this._choices,
    required this._mealsChanged,
    required this._onMealsChanged,
    required this._lookupTakesIt,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MealsDao _dao;
  final UsualChoices _choices;
  final ValueListenable<int> _mealsChanged;
  final void Function() _onMealsChanged;
  final bool Function(Map<String, dynamic>) _lookupTakesIt;
  final DateTime Function() _clock;

  int _epoch = 0;
  ({String day, int signal, int epoch})? _memoKey;
  Future<UsualIndex>? _memo;
  final Set<int> _accepting = {};
  bool _logging = false;

  // ─── The index ──────────────────────────────────────────────────────

  /// The index for today, memoized per (local day, meals signal, epoch).
  /// Concurrent callers share one read of the meals table; a failed read
  /// is not kept.
  Future<UsualIndex> index() {
    final now = _clock();
    final key = (day: isoDate(now), signal: _mealsChanged.value, epoch: _epoch);
    final memo = _memo;
    if (memo != null && _memoKey == key) return memo;
    final built = _build(now);
    _memoKey = key;
    _memo = built;
    built.then((_) {}, onError: (Object _) {
      if (identical(_memo, built)) {
        _memo = null;
        _memoKey = null;
      }
    });
    return built;
  }

  Future<UsualIndex> _build(DateTime now) async {
    final meals =
        await _dao.mealsBetween(usualWindowStart(now), isoDate(now));
    return buildUsualIndex(meals, now: now);
  }

  /// The next [index] reads the meals table again (My usual foods on
  /// open: a background save bumps no signal).
  void invalidate() => _epoch++;

  // ─── Part 2: your usual numbers ─────────────────────────────────────

  bool _takes(Map<String, dynamic> analysis) {
    try {
      return _lookupTakesIt(analysis);
    } catch (_) {
      return true; // unsure: leave the meal to the lookup, offer nothing
    }
  }

  /// The offers for [meals] (Today's), by meal id. The cheap meal gates
  /// run first: with no candidate meal, no index is built.
  Future<Map<int, UsualOffer>> offersFor(List<Meal> meals) async {
    final now = _clock();
    final choices = _choices.view();
    final candidates = <(Meal, bool)>[];
    for (final m in meals) {
      final takes = _takes(m.analysis);
      if (usualOfferCandidate(m,
          now: now, lookupTakesIt: takes, choices: choices)) {
        candidates.add((m, takes));
      }
    }
    if (candidates.isEmpty) return const {};
    final index = await this.index();
    final out = <int, UsualOffer>{};
    for (final (m, takes) in candidates) {
      final offer = usualOfferFor(m, index,
          now: now, lookupTakesIt: takes, choices: choices);
      if (offer != null) out[m.id] = offer;
    }
    return out;
  }

  /// The offer for one meal (the editor), or null.
  Future<UsualOffer?> offerFor(Meal meal) async =>
      (await offersFor([meal]))[meal.id];

  /// Use (spec §3.5): re-reads the meal, computes the offer again and
  /// writes the user's numbers through the compare-and-set
  /// (updateMealAnalysisIfUnchanged, which sets corrected = 1) only while
  /// every shown item is still offered with the same numbers and, from the
  /// editor, the stored text still equals [expectedRaw]. Signals the
  /// meals change on a write.
  Future<UsualAcceptResult> accept(int mealId,
      {required UsualOffer shown, String? expectedRaw}) async {
    UsualAcceptResult result(UsualAcceptStatus s) => UsualAcceptResult(
        status: s,
        mealId: mealId,
        beforeKcal: shown.beforeKcal,
        afterKcal: shown.afterKcal);
    if (!_accepting.add(mealId)) return result(UsualAcceptStatus.busy);
    try {
      final snap = await _dao.mealSnapshot(mealId);
      if (snap == null) return result(UsualAcceptStatus.gone);
      if (shown.mealId != mealId ||
          (expectedRaw != null && snap.rawAnalysis != expectedRaw)) {
        return result(UsualAcceptStatus.conflict);
      }
      final now = _clock();
      final index = await this.index();
      final again = usualOfferFor(snap.meal, index,
          now: now,
          lookupTakesIt: _takes(snap.meal.analysis),
          choices: _choices.view());
      final offer = _stillShown(shown, again);
      if (offer == null) return result(UsualAcceptStatus.conflict);
      final next = applyUsualOffer(snap.meal.analysis, offer, now: now);
      if (next == null) return result(UsualAcceptStatus.conflict);
      final ok = await _dao.updateMealAnalysisIfUnchanged(mealId,
          expectedRaw: snap.rawAnalysis, analysis: next);
      if (!ok) {
        final still = await _dao.mealSnapshot(mealId);
        return result(still == null
            ? UsualAcceptStatus.gone
            : UsualAcceptStatus.conflict);
      }
      _onMealsChanged();
      return UsualAcceptResult(
        status: UsualAcceptStatus.written,
        mealId: mealId,
        beforeKcal: offer.beforeKcal,
        afterKcal: offer.afterKcal,
        undo: UsualUndo(
          before: snap.meal.analysis,
          after: next,
          indices: [for (final i in offer.items) i.index],
        ),
      );
    } finally {
      _accepting.remove(mealId);
    }
  }

  /// [again] cut to the items [shown], or null unless every shown item is
  /// offered again with the same AI numbers and the same numbers of the
  /// user's.
  static UsualOffer? _stillShown(UsualOffer shown, UsualOffer? again) {
    if (again == null) return null;
    final byIndex = {for (final i in again.items) i.index: i};
    final items = <UsualOfferItem>[];
    num dk = 0;
    for (final s in shown.items) {
      final a = byIndex[s.index];
      if (a == null || a.ai != s.ai || a.mine != s.mine ||
          a.kcalOnly != s.kcalOnly) {
        return null;
      }
      items.add(a);
      dk += a.mine.kcal - a.ai.kcal;
    }
    if (items.isEmpty) return null;
    return UsualOffer(
      mealId: again.mealId,
      items: items,
      beforeKcal: again.beforeKcal,
      afterKcal: (again.beforeKcal + dk).round(),
    );
  }

  /// Undo of a [UsualAcceptStatus.written] Use: puts back the previous
  /// numbers and marks while every changed item still holds exactly what
  /// Use wrote, through the compare-and-set. False — say usualUndoStale —
  /// when the meal changed since, or is gone. corrected stays 1 (as with
  /// the leftover undo), and no decline is recorded.
  Future<bool> undoAccept(UsualAcceptResult result) async {
    final undo = result.undo;
    if (result.status != UsualAcceptStatus.written || undo == null) {
      return false;
    }
    if (!_accepting.add(result.mealId)) return false;
    try {
      final snap = await _dao.mealSnapshot(result.mealId);
      if (snap == null) return false;
      final back = revertUsualOffer(snap.meal.analysis, undo);
      if (back == null) return false;
      final ok = await _dao.updateMealAnalysisIfUnchanged(result.mealId,
          expectedRaw: snap.rawAnalysis, analysis: back);
      if (ok) _onMealsChanged();
      return ok;
    } finally {
      _accepting.remove(result.mealId);
    }
  }

  /// Keep AI estimate (spec §3.6): records one decline per offered food.
  /// The meal is not written. Two declines on different meals mute a
  /// food until its numbers are set again.
  Future<void> decline(UsualOffer offer) => _choices.decline(
      offer.mealId, [for (final i in offer.items) usualHideId(i.key)]);

  // ─── Part 3: My usual foods ─────────────────────────────────────────

  /// The list (spec §4.2), ranked for now. Call [invalidate] first when
  /// the screen opens.
  Future<UsualList> frequentMeals() async {
    final index = await this.index();
    return usualMealList(index, now: _clock(), choices: _choices.view());
  }

  /// The hidden meals the Hidden foods sheet can show again.
  Future<List<UsualMeal>> hiddenMeals() async {
    final index = await this.index();
    return usualHiddenMeals(index, now: _clock(), choices: _choices.view());
  }

  Future<void> hide(UsualMeal m) => _choices.hide(m.hideId);

  /// Show again: clears the row's own hide id and the ones of the meal
  /// keys an alias merged into it ([UsualMeal.mergedHideIds]), so a meal
  /// hidden before the alias is listed again.
  Future<void> unhide(UsualMeal m) async {
    for (final id in {m.hideId, ...m.mergedHideIds}) {
      await _choices.unhide(id);
    }
  }

  /// A food meal logged within [kUsualAgainWindow] of now (across
  /// midnight) that loosely shares a food with [m] ([usualLooselyShares]),
  /// or null; the latest when several. Reads the meals table FRESH at
  /// every call (M1): a meal the watcher saved a minute ago bumps no
  /// signal.
  Future<Meal?> loggedRecently(UsualMeal m) async {
    final now = _clock();
    final yesterday = isoDate(DateTime(now.year, now.month, now.day - 1));
    final meals = await _dao.mealsBetween(yesterday, isoDate(now));
    Meal? found;
    DateTime? foundAt;
    for (final x in meals) {
      if (!isFoodTruthy(x.analysis['is_food'])) continue;
      final at = _mealClock(x);
      if (at == null || now.difference(at).abs() > kUsualAgainWindow) {
        continue;
      }
      if (!usualLooselyShares(m.template.analysis, x.analysis)) continue;
      if (foundAt == null || at.isAfter(foundAt)) {
        found = x;
        foundAt = at;
      }
    }
    return found;
  }

  static DateTime? _mealClock(Meal m) {
    final d = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(m.date);
    final c = parseClock(m.time);
    if (d == null || c == null) return null;
    return DateTime(int.parse(d.group(1)!), int.parse(d.group(2)!),
        int.parse(d.group(3)!), c.hour, c.minute);
  }

  /// Logs [m] again, now (spec §4.3): one plain insert with source
  /// app_repeat, no photo hash, no file id, no ledger row, corrected 0,
  /// and the whitelisted analysis ([usualLogAnalysis]). Signals the meals
  /// change. Null — nothing written — while another log is still running
  /// (a double tap logs once); throws when the save fails.
  Future<UsualLogResult?> logAgain(UsualMeal m) async {
    if (_logging) return null;
    _logging = true;
    try {
      final now = _clock();
      final index = await this.index();
      final analysis = usualLogAnalysis(m, index, now: now);
      final id = await _dao.saveMeal(Meal(
        id: 0,
        date: isoDate(now),
        time: formatClock(now),
        timestamp: now.toIso8601String(),
        source: MealSource.appRepeat,
        imageHash: '',
        fileId: '',
        analysis: analysis,
      ));
      String? raw;
      try {
        raw = (await _dao.mealSnapshot(id))?.rawAnalysis;
      } catch (_) {
        raw = null;
      }
      _onMealsChanged();
      return UsualLogResult(
        mealId: id,
        rawAnalysis: raw,
        title: m.title,
        kcal: analysis['total_calories'] as num,
      );
    } finally {
      _logging = false;
    }
  }

  /// Undo of [logAgain]: deletes the meal while its stored text still
  /// equals what was logged (no photo hash, so no tombstone). False — say
  /// usualUndoStale — when it changed since or is gone.
  Future<bool> undoLog(UsualLogResult r) async {
    final raw = r.rawAnalysis;
    if (raw == null) return false;
    final snap = await _dao.mealSnapshot(r.mealId);
    if (snap == null ||
        snap.rawAnalysis != raw ||
        snap.meal.source != MealSource.appRepeat) {
      return false;
    }
    await _dao.deleteMeal(r.mealId);
    _onMealsChanged();
    return true;
  }
}
