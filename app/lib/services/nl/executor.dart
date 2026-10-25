/// NL executor — the hardened text-message pipeline (spec §4).
///
/// Direct port of handle_text_message / _normalize_nl_actions and the five
/// intent handlers (telegram_bot.py:3953-4376). The Python originals were
/// hardened after a 2026-07-16 production crash-loop on a compound
/// correction+delete message; every guard below is pinned by the tests named
/// in spec §4.10 and mirrored under test/nl/.
library;

import 'dart:math' as math;

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import '../../core/outcome_kind.dart';
import '../../core/prompts.dart';
import '../../core/restaurant_assist_logic.dart'
    show dropAssistClaims, supersedeAssist;
import '../../core/shared_generated.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/coach_strings.dart' show localizationsFor;
import '../../ui/format.dart' show byMealClock, displayClock;
import '../../ui/outcome_text.dart' show badModelText, regionProvider, serverReason;
import '../settings/app_settings.dart';

export '../../core/coerce.dart' show mealCalorieMismatch;

part 'nl_logic.dart';

/// Spec §1.2 / §8: TEXT_EDIT_WINDOW_DAYS (telegram_bot.py:161), from shared/.
const int textEditWindowDays = SharedConstants.textEditWindowDaysDefault;

/// Spec §4.1: NL_MAX_ACTIONS (telegram_bot.py:4181), from shared/.
const int nlMaxActions = SharedConstants.nlMaxActions;

/// Spec §4.8 clamps (telegram_bot.py:2971-2973), from shared/.
const num activityKcalMax = SharedConstants.activityKcalMax;
const num activityStepsMax = SharedConstants.activityStepsMax;
const num activityKmMax = SharedConstants.activityKmMax;

/// Spec §4.7 / §7.1 weight bounds (nutrition.py:429-430), from shared/.
const num minWeightKg = SharedConstants.weightMinKg;
const num maxWeightKg = SharedConstants.weightMaxKg;

NlExecutor createExecutor(
        MealsDao dao, AnalyzerService analyzer, AppSettings settings) =>
    DefaultNlExecutor(dao, analyzer, settings);

class DefaultNlExecutor implements NlExecutor {
  DefaultNlExecutor(this.dao, this.analyzer, this.settings, {this.l10n});

  final MealsDao dao;
  final AnalyzerService analyzer;
  final AppSettings settings;

  /// Test seam only. Every reply template below used to be an English
  /// literal, so the whole chat spoke English inside the Chinese UI (testing
  /// loop 2026-10-07). Production resolves the language LAZILY from the live
  /// settings on every reply — the executor is built once at startup and
  /// must follow a later language switch — the same localizationsFor the
  /// headless daily summary uses. Model-authored text (chat replies, the
  /// 💬 reason) is passed through untouched; only our own templates
  /// localize.
  final AppLocalizations? l10n;
  AppLocalizations get _l => l10n ?? localizationsFor(settings.appLanguage);

  /// Stored meal clocks keep the server-parity 12-hour shape; the user sees
  /// the locale clock (24-hour in Chinese). A stray intl locale-data gap
  /// must not turn a delete into "Something went wrong", so degrade to raw.
  String _clock(String raw) {
    try {
      return displayClock(raw, localeName: _l.localeName);
    } catch (_) {
      return raw;
    }
  }

  String _kcal(dynamic v) => _l.kcalAmount('$v');

  /// A meal name for the reply, or null when the analysis has none. Nothing
  /// guarantees meal_description: a direct-provider photo reply or a partial
  /// chat correction (updateMealAnalysis replaces the JSON wholesale) can
  /// leave a food row with the key missing or blank.
  static String? _namedDesc(dynamic d) {
    if (d == null) return null;
    final s = '$d'.trim();
    return s.isEmpty ? null : s;
  }

  /// The stored name, else the localized "unnamed meal" — never the English
  /// 'Unknown meal' inside an otherwise Chinese delete modal or snackbar.
  String _desc(Map a) => _namedDesc(a['meal_description']) ?? _l.nlUnnamedMeal;

  /// One pending confirmation slot (spec §4.5: one per chat; the app's modal
  /// dialog replaces the server's nonce/TTL machinery). id → display label.
  final Map<int, String> _pendingDeleteLabels = {};

  @override
  Future<List<NlReply>> handleText(String userText) async {
    // handle_text_message_safe parity (spec §4.9, telegram_bot.py:4359-4376):
    // no exception may escape into the caller's event loop.
    try {
      return await _handleTextInner(userText);
    } catch (_) {
      return [NlReply(_l.nlSomethingWrong)];
    }
  }

  /// Non-null when no analysis can succeed for lack of configuration. The
  /// analyzer seam folds its precise missing-key exception into null, which
  /// used to surface as "Error contacting AI. Please try again." — advice
  /// that can never work for a missing key (review 2026-07-31).
  String? _missingKeyMessage() {
    if ((settings.activeApiKey ?? '').trim().isNotEmpty) return null;
    if (settings.provider == AiProvider.server) {
      return _l.nlMissingServer;
    }
    return _l.nlMissingKey(settings.providerDisplayName);
  }

  Future<List<NlReply>> _handleTextInner(String userText) async {
    // Spec §4 step 2 (telegram_bot.py:4253-4261): during a daily-quota pause,
    // refuse with the pause summary and make NO model call.
    if (settings.isQuotaPaused) {
      return [NlReply(_quotaPauseMessage(settings.quotaPauseUntil!))];
    }
    final missingKey = _missingKeyMessage();
    if (missingKey != null) return [NlReply(missingKey)];

    // Snapshot: last TEXT_EDIT_WINDOW_DAYS of food meals (spec §1.2) in
    // MEAL-CLOCK order, matching every screen the owner reads; the DAO's
    // timestamp order is server parity, but backdated photos and catch-up
    // scans ingest out of eating order, so "第一顿" must mean the meal shown
    // first (spec §9). Every index in every action resolves against THIS
    // list — the prompt and executeParsed share it (spec §4.2).
    final meals = byMealClock(await dao.recentMeals(days: textEditWindowDays));
    final prompt = buildPrompt(meals, userText, DateTime.now());

    final TextIntentOutcome reply;
    try {
      reply = await askTextIntent(analyzer, prompt);
    } catch (_) {
      return [NlReply(_l.nlErrorContactingAi)];
    }
    final result = reply.json;
    if (result == null) {
      // The analyzer seam folds parse + transport failures into null
      // (contract: textIntent never throws); spec §4 step 4 wording,
      // except for the causes a retry cannot fix.
      return [NlReply(_textFailure(reply.error))];
    }
    return executeParsed(result, userText, meals);
  }

  /// The failed-text-request line. Spec §4 step 4's "Error contacting AI.
  /// Please try again." stays for network, busy, rate-limit, parse and
  /// unknown failures — a retry can fix those. A rejected key or model, or
  /// an empty provider balance, cannot be retried away: say so in the photo
  /// path's words, or a friend with a wrong key is told to retry forever
  /// (loop find 2026-10-08).
  /// Of the server's refusals only the plan's credits one is named (the
  /// selected model needs credits this plan lacks — the CLI's own words);
  /// busy, "later" and a reply that came back unusable can retry.
  String _textFailure(String? error) {
    final reason = error == null ? null : serverReason(error);
    return switch (classifyAnalysisError(error)) {
      AnalysisErrorKind.rejectedKey => '❌ ${_l.errRejectedKey}',
      AnalysisErrorKind.badModel => '❌ ${badModelText(_l, error)}',
      AnalysisErrorKind.billing => '❌ ${_l.errBillingText}',
      AnalysisErrorKind.regionBlocked =>
        '❌ ${_l.errRegionBlocked(regionProvider(_l, error))}',
      AnalysisErrorKind.serverError
          when reason != null && reason.toLowerCase().contains('credit') =>
        _l.nlServerModelRefused(reason),
      _ => _l.nlErrorContactingAi,
    };
  }

  /// Describe-only path (app-only, spec §9): analyze [text] as a brand-new
  /// meal and hand the analysis back for preview. NOTHING is saved.
  ///
  /// The prompt is built with an EMPTY meals list on purpose — the shared
  /// prompt's own rule ("If the user describes food but meals_list is empty,
  /// it MUST be a new_meal") then makes the intent deterministic, so no new
  /// prompt and no server divergence. Multi-action replies are normalized
  /// the same way handleText does, and the first new_meal wins.
  @override
  Future<DescribeOutcome> describeMeal(String text) async {
    final userText = text.trim();
    if (userText.isEmpty) {
      return DescribeOutcome(error: _l.nlTypeFirst);
    }
    if (settings.isQuotaPaused) {
      return DescribeOutcome(
          error: _quotaPauseMessage(settings.quotaPauseUntil!));
    }
    final missingKey = _missingKeyMessage();
    if (missingKey != null) return DescribeOutcome(error: missingKey);
    final prompt = buildPrompt(const [], userText, DateTime.now());
    final TextIntentOutcome reply;
    try {
      reply = await askTextIntent(analyzer, prompt);
    } catch (_) {
      return DescribeOutcome(error: _l.nlErrorContactingAi);
    }
    final result = reply.json;
    if (result == null) {
      return DescribeOutcome(error: _textFailure(reply.error));
    }
    // Reuse the hardened normalization: bare arrays, {actions:[...]},
    // single objects and junk all collapse to a list of actions (§4.1).
    // A compound description ("eggs for breakfast, then a salad for lunch")
    // legitimately yields SEVERAL new_meals — preview the first, but say so,
    // because dropping the rest in silence under-counts the day invisibly.
    final meals = <Map<String, dynamic>>[];
    for (final action in normalizeActions(result)) {
      if (action['intent'] != 'new_meal') continue;
      final dynamic analysis = action['analysis'];
      if (analysis is! Map || !isTruthy(analysis['is_food'])) continue;
      final sanitized = <String, dynamic>{
        for (final e in analysis.entries) '${e.key}': e.value,
      };
      if (sanitized.containsKey('food_items')) {
        sanitized['food_items'] = safeFoodItems(sanitized);
      }
      meals.add(sanitized);
    }
    if (meals.isEmpty) {
      return DescribeOutcome(error: _l.nlNoFoodDetected);
    }
    return DescribeOutcome(
      analysis: meals.first,
      warning:
          meals.length > 1 ? _l.nlDescribedMultiple(meals.length) : null,
    );
  }

  /// The full TEXT_HANDLER_PROMPT with the five placeholders (spec §1.2).
  /// Note the dietary profile is deliberately NOT appended here — spec §1.3
  /// pins it to the photo prompt only.
  String buildPrompt(List<Meal> meals, String userText, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    return textHandlerPrompt(
      mealsList: buildMealsList(meals),
      userMessage: userText,
      today: isoDate(today),
      weekday: _weekdayNames[today.weekday - 1],
      yesterday: isoDate(yesterday),
    );
  }

  /// Post-parse pipeline: normalize → dispatch → per-action containment
  /// (spec §4.1/§4.2/§4.9). Public and dynamically typed because production
  /// models have returned bare JSON arrays despite the prompt (spec §4.1);
  /// [snapshot] must be the same list the prompt showed so indices resolve
  /// to DB ids that earlier actions can never shift (spec §4.2).
  Future<List<NlReply>> executeParsed(
      dynamic result, String userText, List<Meal> snapshot) async {
    final actions = normalizeActions(result);
    if (actions.isEmpty) {
      return [NlReply(_l.nlNoActions)];
    }

    final replies = <NlReply>[];
    var failures = 0;
    for (final action in actions) {
      try {
        replies.add(await _dispatch(action, userText, snapshot));
      } catch (_) {
        // One malformed action must not abort its siblings (spec §4.9).
        failures++;
      }
    }
    if (failures == actions.length) {
      // The wording must never claim partial success (spec §4.9).
      replies.add(NlReply(failures == 1
          ? _l.nlRequestFailed
          : _l.nlAllActionsFailed(failures)));
    } else if (failures > 0) {
      replies.add(NlReply(_l.nlSomeActionsFailed(failures, actions.length)));
    }
    return replies;
  }

  Future<NlReply> _dispatch(Map action, String text, List<Meal> meals) {
    // Non-string / unknown intents fall back to chat (spec §4.2); switching
    // on the dynamic value cannot throw for list/map-typed intents.
    switch (action['intent']) {
      case 'correction':
        return _correction(text, meals, action);
      case 'delete':
        return _delete(text, meals, action);
      case 'new_meal':
        return _newMeal(action);
      case 'log_weight':
        return _logWeight(text, action);
      case 'log_activity':
        return _logActivity(action);
      default:
        return _chat(action);
    }
  }

  /// _nl_correction (spec §4.4, telegram_bot.py:3974-4032).
  Future<NlReply> _correction(String text, List<Meal> meals, Map action) async {
    final mealIndex =
        coerceMealIndex(action.containsKey('meal_index') ? action['meal_index'] : 0);
    final dynamic newAnalysis =
        action.containsKey('analysis') ? action['analysis'] : <String, dynamic>{};
    final dynamic reason = action['reason'] ?? '';

    if (meals.isEmpty) {
      return NlReply(_l.nlCannotCorrectNoMeals);
    }
    if (mealIndex == null || mealIndex < 0 || mealIndex >= meals.length) {
      // meal_index is raw model output: truncate to 40 chars so hallucinated
      // markup cannot flood the reply (spec §4.4.2; app renders plain text).
      var shown = '${action['meal_index']}';
      if (shown.length > 40) shown = shown.substring(0, 40);
      return NlReply(_l.nlInvalidMealIndex(shown, meals.length));
    }

    // Silent-delete guard (spec §4.4.3): an empty or non-food analysis would
    // overwrite the meal into a row every is_food view filters out — a
    // delete that skipped the delete confirmation. Refuse it.
    if (newAnalysis is! Map || !isTruthy(newAnalysis['is_food'])) {
      return NlReply(_l.nlCorrectionUnusable);
    }

    final sanitized = <String, dynamic>{
      for (final e in newAnalysis.entries) '${e.key}': e.value,
    };
    // A hostile food_items shape persisted here would crash every later
    // prompt build over the edit window; store maps only (spec §3.5).
    if (sanitized.containsKey('food_items')) {
      sanitized['food_items'] = safeFoodItems(sanitized);
    }

    // Compute EVERY reply input BEFORE the write: safeNumber means a
    // hallucinated string calorie can no longer throw after
    // updateMealAnalysis already ran (the user would be told "failed" for a
    // change that happened — spec §4.4.5).
    final target = meals[mealIndex];
    final old = target.analysis;
    // The row as it is NOW, for what the correction carries over: the
    // prompt's snapshot was taken before the model call, and a restaurant
    // lookup may have landed on this meal since (design R6a).
    final current = await _currentAnalysis(target.id) ?? old;
    // How the photo was taken (analysis.capture, design G2a) is the
    // intake's reading of the photo's own bytes, never a model's: the chat
    // model never even sees it (buildMealsList leaves it out). So the
    // stored block is carried over and anything the model wrote there is
    // dropped — the Meta glasses badge stays, and the duplicate-capture
    // guard (mealIdsWithShutterKey) still finds this shutter press, so a
    // later file of the same press is not logged as a second meal.
    sanitized.remove('capture');
    final capture = current['capture'];
    if (capture is Map) {
      sanitized['capture'] = Map<String, dynamic>.from(capture);
    }
    // The restaurant assist's block (design R6a), likewise never shown to
    // the model: whatever the model wrote there, or as a `published` flag,
    // is dropped, and the stored block is kept as provenance — an applied
    // or suggested one marked 'superseded', since its stamps describe
    // numbers this correction replaces.
    dropAssistClaims(sanitized);
    final assist = supersedeAssist(current['assist']);
    if (assist != null) sanitized['assist'] = assist;
    final oldCal = safeNumber(old['total_calories']);
    final newCal = safeNumber(sanitized['total_calories']);
    final oldDesc = _desc(old);
    final newDesc = _namedDesc(sanitized['meal_description']) ?? oldDesc;
    final diff = newCal - oldCal;
    final diffStr = diff > 0 ? '+$diff' : '$diff';
    // Which day's row was rewritten. A correction has no confirmation step
    // (unlike delete, whose modal lists date and time), and over the
    // seven-day window the same dish recurs — without this line the owner
    // could not tell whether today's or Tuesday's 白粥 changed. From the
    // snapshot row, so it names the row the write targets (spec §4.4.6).
    final when = '${target.date} ${_clock(target.time)}';

    // Update by the snapshot row's DB id, so a meal logged mid-conversation
    // cannot shift the target (spec §4.4.6). The DAO sets corrected=1
    // unconditionally (spec §2.4).
    await dao.updateMealAnalysis(target.id, sanitized);

    final lines = <String>[
      _l.nlCorrectedMeal(mealIndex + 1),
      '📅 $when',
      '',
      '$oldDesc → $newDesc',
      _l.nlKcalChange(_kcal(oldCal), _kcal(newCal), diffStr),
    ];
    if (isTruthy(reason)) lines.add('\n💬 $reason');
    return NlReply(lines.join('\n'), applied: true);
  }

  /// The stored analysis of meal [mealId] right now, or null when it is
  /// gone or cannot be read (the caller falls back to its snapshot).
  Future<Map<String, dynamic>?> _currentAnalysis(int mealId) async {
    try {
      return (await dao.mealSnapshot(mealId))?.meal.analysis;
    } catch (_) {
      return null;
    }
  }

  /// _nl_delete (spec §4.5, telegram_bot.py:4035-4094). Stages ids + labels
  /// and returns needsDeleteConfirmation — the executor NEVER deletes here;
  /// [confirmPendingDelete] performs the deletes after the modal confirm.
  Future<NlReply> _delete(String text, List<Meal> meals, Map action) async {
    final dynamic raw =
        action.containsKey('meal_indices') ? action['meal_indices'] : const [];
    List<dynamic> mealIndices;
    if (raw is List) {
      mealIndices = raw;
    } else if (raw is int) {
      // Honor a bare integer as [n]. In Python a scalar string "12" iterated
      // per character would stage meals 1 and 2 — anything non-list and
      // non-int means "no match". (Dart bool is not int, so the Python
      // bool-excluding check is implicit.)
      mealIndices = [raw];
    } else {
      mealIndices = const [];
    }
    final dynamic reason = action['reason'] ?? '';

    if (meals.isEmpty) return NlReply(_l.nlCannotDeleteNoMeals);
    if (mealIndices.isEmpty) return NlReply(_l.nlDeleteWhich);

    // Coerce, de-duplicate, ascending, in-range only (spec §4.5.3); resolve
    // ids and labels from the SNAPSHOT the model indexed.
    final valid = <int>{};
    for (final x in mealIndices) {
      final i = coerceMealIndex(x);
      if (i != null) valid.add(i);
    }
    final ids = <int>[];
    final labels = <String>[];
    for (final index in valid.toList()..sort()) {
      if (index >= 0 && index < meals.length) {
        final meal = meals[index];
        final a = meal.analysis;
        ids.add(meal.id);
        labels.add(_l.nlMealLabel(
            _desc(a),
            meal.date,
            _clock(meal.time),
            _kcal(_orElse(a['total_calories'], 0))));
      }
    }
    if (ids.isEmpty) return NlReply(_l.nlDeleteNoMatch);

    // One pending slot per chat (spec §4.5.4): staging a new delete
    // supersedes any older pending set.
    _pendingDeleteLabels
      ..clear()
      ..addEntries([
        for (var i = 0; i < ids.length; i++) MapEntry(ids[i], labels[i]),
      ]);

    final lines = <String>[_l.nlDeleteAsk(ids.length), ''];
    lines.addAll(labels.map((l) => '• $l'));
    if (isTruthy(reason)) lines.add('\n💬 $reason');
    lines.add('\n${_l.nlCannotUndo}');
    return NlReply(lines.join('\n'),
        needsDeleteConfirmation: true,
        pendingDeleteIds: ids,
        pendingDeleteLabels: labels);
  }

  @override
  Future<String> confirmPendingDelete(List<int> mealIds) async {
    if (mealIds.isEmpty) return _l.nlDeleteCancelled;
    final labels = <String>[];
    for (final id in mealIds) {
      // deleteMeal tombstones the ledger row (spec §2.4) so the backfill
      // scan never resurrects the photo.
      await dao.deleteMeal(id);
      labels.add(_pendingDeleteLabels[id] ?? 'meal #$id');
    }
    _pendingDeleteLabels.clear();
    return [
      _l.nlDeletedMeals(mealIds.length),
      ...labels.map((l) => '• $l'),
    ].join('\n');
  }

  /// _nl_new_meal (spec §4.6, telegram_bot.py:4097-4109).
  Future<NlReply> _newMeal(Map action) async {
    final dynamic analysis =
        action.containsKey('analysis') ? action['analysis'] : <String, dynamic>{};
    if (analysis is! Map || !isTruthy(analysis['is_food'])) {
      return NlReply(_l.nlNoFoodDetected);
    }
    final sanitized = <String, dynamic>{
      for (final e in analysis.entries) '${e.key}': e.value,
    };
    if (sanitized.containsKey('food_items')) {
      sanitized['food_items'] = safeFoodItems(sanitized);
    }
    // A text meal has no photo and no lookup behind it: a capture or
    // assist block the model wrote is not evidence of either (design R6a).
    sanitized.remove('capture');
    dropAssistClaims(sanitized);
    final now = DateTime.now();
    await dao.saveMeal(Meal(
      id: 0, // assigned by the DAO
      date: isoDate(now),
      time: _time12(now),
      timestamp: now.toIso8601String(),
      source: MealSource.manualText, // spec §4.6
      imageHash: '',
      fileId: '',
      analysis: sanitized,
    ));
    return NlReply(
        '${_l.nlAddedManualMeal}\n\n'
        '${formatFoodResult(sanitized, unnamed: _l.nlUnnamedMeal)}',
        applied: true);
  }

  /// _nl_log_weight (spec §4.7, telegram_bot.py:4112-4128): deterministic
  /// text parse first; the model's weight_kg is only a bounded-numeric
  /// fallback (string numerics are deliberately NOT trusted).
  Future<NlReply> _logWeight(String text, Map action) async {
    var kg = parseWeightKg(text);
    if (kg == null) {
      final field = safeNumber(action['weight_kg']);
      if (field >= minWeightKg && field <= maxWeightKg) kg = _round1(field);
    }
    if (kg == null) return NlReply(_l.nlWeightUnreadable);
    final date = isoDate(DateTime.now());
    // Upsert-by-day (spec §2.1 body_weight: re-log overwrites).
    await dao.saveBodyWeight(date, kg);
    return NlReply(_l.nlWeightLogged(_g(kg), date), applied: true);
  }

  /// _nl_log_activity (spec §4.8, telegram_bot.py:4131-4158).
  Future<NlReply> _logActivity(Map action) async {
    final kcal = _clamp(safeNumber(action['active_calories']), 0, activityKcalMax);
    final steps =
        _clamp(safeNumber(action['steps']), 0, activityStepsMax).round();
    final km = _clamp(safeNumber(action['distance_km']), 0, activityKmMax);
    if (kcal <= 0 && steps <= 0 && km <= 0) {
      return NlReply(_l.nlActivityUnreadable);
    }
    final date = isoDate(DateTime.now());
    // Zeros store as null; steps ride in raw={"steps": n} inside the DAO.
    await dao.saveActivity(date,
        activeCalories: kcal > 0 ? kcal : null,
        steps: steps > 0 ? steps : null,
        distanceKm: km > 0 ? km.toDouble() : null);
    final bits = <String>[
      if (kcal > 0) _kcal(_comma(kcal.round())),
      if (steps > 0) _l.nlStepsAmount(_comma(steps)),
      if (km > 0) _l.nlKmAmount(_g(km)),
    ];
    return NlReply(_l.nlActivityLogged(bits.join(' · '), date),
        applied: true);
  }

  /// _nl_chat (spec §4.9, telegram_bot.py:4161-4168): a null/non-string/blank
  /// reply must never render an empty bubble.
  Future<NlReply> _chat(Map action) async {
    final reply = action['reply'];
    if (reply is String && reply.trim().isNotEmpty) return NlReply(reply);
    return NlReply(_l.nlChatFallback);
  }
}
