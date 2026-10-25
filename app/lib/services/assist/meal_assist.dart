/// MealAssist — the restaurant assist's engine, BRAND path (design R6b;
/// decisions "Assist architecture: save first, enrich later", "Triggers",
/// "Day window", "Write safety", "Consent", "Storage").
///
/// The meal is saved first; this enriches it later, in the app's own engine
/// and in the foreground only. di.dart builds the one instance;
/// background_glue never references it (production_wiring_test pins
/// that), so nothing here can slow or destabilize automatic photo logging.
///
/// [MealAssist.sweep] is single-flight. It runs after the launch catch-up
/// (di.dart), 5 s after a meals-changed signal, on resume, and when the mode
/// turns on. Before it looks anything up, and again before EACH lookup:
///   * the mode is not Off;
///   * the app is in the foreground;
///   * the photo pipeline is idle (no reservation held, its queue drained)
///     and no foreground analyzer call is in flight (analyzerBusy == 0) —
///     a lookup never competes with a photo or the user's own request;
///     either busy, it tries again 30 s later;
///   * the provider supports lookups (unsupported providers make zero
///     calls);
///   * the consent is stamped with the CURRENT recipient — otherwise the
///     assist pauses and [MealAssist.consentNeeded] asks R7a's sheet;
///   * today's lookups are under the daily cap (20, [AssistDailyBudget]).
///
/// Eligible meals: a photo meal (app_watch / app_photo), not corrected, no
/// assist block yet, logged at or after the consent and at most 24 h ago,
/// not in use (MealInUseRegistry: editor, leftover selection, pending fix)
/// and not denylisted after [assistMissesBeforeDenylist] dropped results.
/// The trigger is [assistTriggerFor] (decision "Triggers").
///
/// The BRAND path (this stage): the chains the items' printed brands and
/// the receipt merchant name (core/restaurant_lookup_contract.dart composes
/// them from OUR table; nothing location-derived is in the request) →
/// submit (a direct provider answers at once; the owner's server answers
/// with a job, kept in 'assist_jobs' and polled on the next sweep) →
/// decideAssist → recordAssistDecision → MealsDao.applyAssist against the
/// raw text read before the lookup. A false return (the meal changed while
/// the lookup ran) drops the result and counts a miss. The location path
/// (R6c) comes later: a restaurant meal without a printed brand is skipped
/// here.
///
/// After an automatic APPLY: a snackbar with Undo ([AssistAppliedNotice];
/// Undo writes revertAssist 'declined' through applyAssist), the meal joins
/// the unseen set (the card's dot, R7b), and the meals-changed signal.
/// Every lookup leaves one entry in the decision log (codes and kcal only).
///
/// Mode Off cancels the call in flight (LookupCancelToken), discards its
/// result and forgets pending jobs. [MealAssist.lookupNow] is the editor's
/// manual lookup (R7b).
///
/// Nothing here logs. No coordinate, place or MapKit text exists on this
/// path at all.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import '../../core/restaurant_assist_logic.dart';
import '../../core/restaurant_lookup_contract.dart';
import 'assist_local_state.dart';
import 'clients/lookup_client.dart';
import 'clients/lookup_contract_adapter.dart' show LookupRequestForClients;

// ─── Knobs ─────────────────────────────────────────────────────────────

/// Automatic eligibility: meals logged at most this long ago (decision
/// "Day window"; APPLY itself needs today and ≤ 12 h, decideAssist).
const Duration kAssistEligibleMaxAge = Duration(hours: 24);

/// How long after a meals-changed signal (or a resume) the sweep runs: a
/// burst of saves settles first.
const Duration kAssistSettleDelay = Duration(seconds: 5);

/// The next try when the pipeline or the analyzer was busy.
const Duration kAssistBusyRetry = Duration(seconds: 30);

/// After a transient failure (offline, busy, rate limited, a 5xx) no
/// automatic lookup starts for this long. (R6c adds per-meal retries.)
const Duration kAssistTransientBackoff = Duration(minutes: 5);

/// After the recipient said it cannot look up at all (an old server, the
/// server's lookup knob off, a rejected key, no key, no search) no
/// automatic lookup starts for this long, or until the recipient, the
/// consent or the mode changes. (A manual lookup is never held.)
const Duration kAssistUnavailableHold = Duration(hours: 1);

// ─── Skip and run codes (diagnostics; never names or places) ───────────

abstract final class AssistSkip {
  static const String off = 'off';
  static const String background = 'background';
  static const String pipelineBusy = 'pipeline_busy';
  static const String analyzerBusy = 'analyzer_busy';
  static const String unsupported = 'unsupported';
  static const String consentNeeded = 'consent_needed';
  static const String dailyCap = 'daily_cap';
  static const String unavailable = 'unavailable';
  static const String backoff = 'backoff';

  // Per meal.
  static const String noBrand = 'no_brand';
  static const String mealGone = 'meal_gone';
  static const String mealChanged = 'meal_changed';
  static const String inUse = 'in_use';
  static const String casMiss = 'cas_miss';
  static const String working = 'working';
  static const String pending = 'pending';
  static const String cancelled = 'cancelled';
  static const String applied = 'applied';
  static const String error = 'error';
}

// ─── Settings as the assist reads them ─────────────────────────────────

/// `settings.restaurant_assist` (data_contracts §9a): off | auto ('When
/// unsure') | always. Anything else reads as off.
enum AssistMode {
  off('off'),
  auto('auto'),
  always('always');

  const AssistMode(this.wire);
  final String wire;

  static AssistMode fromWire(Object? v) {
    for (final m in values) {
      if (m.wire == v) return m;
    }
    return off;
  }
}

/// What the assist reads from Settings each time it decides: the mode, the
/// location sub-toggle (R6c), and the consent — when it was given and to
/// which recipient (LookupSupport.recipientStamp). R7a stores these; the
/// default is Off with no consent.
final class AssistSettingsView {
  const AssistSettingsView({
    this.mode = AssistMode.off,
    this.useLocation = false,
    this.consentAt,
    this.consentRecipient,
  });

  static const AssistSettingsView off = AssistSettingsView();

  final AssistMode mode;

  /// 'Use photo location' (R6c; iOS only). The brand path ignores it.
  final bool useLocation;
  final DateTime? consentAt;
  final String? consentRecipient;

  /// The consent names exactly the recipient a lookup would reach now.
  bool consentCovers(LookupSupport support) =>
      consentAt != null &&
      support.supported &&
      consentRecipient != null &&
      consentRecipient == support.recipientStamp;
}

// ─── Triggers (decision "Triggers") ────────────────────────────────────

/// Which printed evidence names a chain from OUR table: an item's own
/// brand, and the receipt or order screen's merchant — read exactly as
/// the request composer reads them (chainNameOnly), so "has a brand" here
/// means "the request will name that chain".
({bool itemBrand, bool merchant}) assistBrandEvidence(dynamic analysis) {
  final a = analysis is Map ? analysis : const {};
  final items = a['food_items'];
  var itemBrand = false;
  for (final item in (items is List ? items : const []).take(kLookupMaxItems)) {
    if ((composeLookupItem(item)['brand'] as String).isNotEmpty) {
      itemBrand = true;
      break;
    }
  }
  return (
    itemBrand: itemBrand,
    merchant: chainNameOnly(a['order_merchant'], kLookupMerchantMax).isNotEmpty,
  );
}

/// Why [analysis] is looked up automatically under [mode], or null:
///   * When unsure (auto): estimate_confidence low AND a restaurant or
///     takeout meal (takeout only ever takes the brand path). Medium, high
///     or unknown confidence never triggers; home, packaged and unknown
///     meals never do.
///   * Always: skips only the confidence check. A restaurant or takeout
///     meal triggers; a home, packaged or unknown meal only with an item's
///     own printed brand (its location is never read either way).
///   * Off: never.
/// The proposed medium-confidence + brand extension (auto_branding) waits
/// for the owner's answer and is not built.
AssistTrigger? assistTriggerFor(dynamic analysis, AssistMode mode) {
  if (mode == AssistMode.off) return null;
  final fields = mealContextFields(analysis);
  final context = fields.restaurantContext;
  final atRestaurant =
      context == RestaurantContext.restaurant ||
      context == RestaurantContext.takeout;
  if (mode == AssistMode.auto) {
    if (fields.estimateConfidence != EstimateConfidence.low) return null;
    return atRestaurant ? AssistTrigger.autoLowConfidence : null;
  }
  if (atRestaurant) return AssistTrigger.always;
  return assistBrandEvidence(analysis).itemBrand ? AssistTrigger.always : null;
}

/// The brand-path request for [analysis]: its items (positions kept) and
/// receipt merchant, with no caller chains — the composer lists the chains
/// the printed brands and the merchant name, from OUR table only. [country]
/// is the device region (ISO2; the composer defaults to US), [zh] asks for
/// Chinese notes.
LookupRequest composeAssistRequest(
  Map<String, dynamic> analysis, {
  String? country,
  bool zh = false,
}) => LookupRequest.compose({
  'items': analysis['food_items'] is List
      ? analysis['food_items']
      : const <Object?>[],
  'order_merchant': analysis['order_merchant'],
  'chains': const <String>[],
  'country': ?country,
  if (zh) 'lang': 'zh',
});

/// The region a locale name carries ("zh-Hans_US", "en_US" → US;
/// "zh_Hant_TW" → TW), or null: where the phone is set to be, the only
/// country the brand path knows (it reads no location). decideAssist
/// applies published numbers only for the US; anything else, or none, is a
/// suggestion at most.
String? regionOfLocale(String localeName) {
  for (final part in localeName.split(RegExp('[-_.@]')).reversed) {
    if (_iso2Re.hasMatch(part)) return part;
  }
  return null;
}

/// The first 16 hex characters of SHA-256 over [request]'s canonical JSON:
/// a stored job answers the meal only while its request still hashes the
/// same.
String lookupRequestHash(LookupRequest request) =>
    sha256.convert(utf8.encode(request.toJson())).toString().substring(0, 16);

// ─── Public results ────────────────────────────────────────────────────

/// What the snackbar says after an automatic APPLY, and its Undo.
final class AssistAppliedNotice {
  const AssistAppliedNotice({
    required this.mealId,
    required this.chainKey,
    required this.brandName,
    required this.oldKcal,
    required this.newKcal,
    required this.undo,
  });

  final int mealId;
  final String chainKey;

  /// The chain's name from OUR table (decision.brandName).
  final String brandName;

  /// The meal's total before and after.
  final int oldKcal;
  final int newKcal;

  /// Reverts the application ('declined'); false when the meal changed
  /// since, which is then the user's newer truth.
  final Future<bool> Function() undo;
}

/// One lookup's end, for the editor's manual lookup (R7b): a skip or
/// failure code, or the decision and whether it was written.
final class AssistRun {
  const AssistRun(this.code, {this.decision, this.wrote = false});
  final String code;
  final AssistDecision? decision;
  final bool wrote;
}

final class _Run {
  const _Run(this.code, {this.decision, this.wrote = false, this.stop = false});
  static const _Run cancelled = _Run(AssistSkip.cancelled, stop: true);

  final String code;
  final AssistDecision? decision;
  final bool wrote;

  /// The rest of the sweep waits (a failure that would repeat for every
  /// meal, a pause, a cancel).
  final bool stop;

  AssistRun get public => AssistRun(code, decision: decision, wrote: wrote);
}

/// Failures that say nothing about the meal: every lookup to this
/// recipient would end the same way until the user's setup changes.
const Set<LookupFailureCode> _recipientFailures = {
  LookupFailureCode.noKey,
  LookupFailureCode.auth,
  LookupFailureCode.billing,
  LookupFailureCode.regionBlocked,
  LookupFailureCode.modelNotFound,
  LookupFailureCode.searchDisabled,
};

final RegExp _iso2Re = RegExp(r'^[A-Z]{2}$');
final RegExp _upperRe = RegExp('[A-Z]');

String _snake(String camel) =>
    camel.replaceAllMapped(_upperRe, (m) => '_${m[0]!.toLowerCase()}');

// ─── The engine ────────────────────────────────────────────────────────

class MealAssist {
  MealAssist({
    required this._dao,
    required this._lookups,
    required this._analyzerBusy,
    required this._pipelineIdle,
    required this._inUse,
    required this._budget,
    required this._state,
    required this._settings,
    this._settingsChanges,
    this._mealsChanged,
    this._onMealsChanged,
    this._onApplied,
    this._inForeground,
    this._country,
    this._repliesInChinese,
    DateTime Function()? clock,
    this.settleDelay = kAssistSettleDelay,
    this.busyRetry = kAssistBusyRetry,
  }) : _clock = clock ?? DateTime.now;

  final MealsDao _dao;
  final LookupClient _lookups;
  final ValueListenable<int> _analyzerBusy;
  final bool Function() _pipelineIdle;
  final bool Function(int mealId) _inUse;
  final AssistDailyBudget _budget;
  final AssistLocalState _state;
  final AssistSettingsView Function() _settings;
  final Listenable? _settingsChanges;
  final Listenable? _mealsChanged;
  final void Function()? _onMealsChanged;
  final void Function(AssistAppliedNotice notice)? _onApplied;
  final bool Function()? _inForeground;
  final String? Function()? _country;
  final bool Function()? _repliesInChinese;
  final DateTime Function() _clock;

  final Duration settleDelay;
  final Duration busyRetry;

  /// Bumped by Off and dispose: every result of an older generation is
  /// discarded.
  int _generation = 0;
  final Set<LookupCancelToken> _tokens = {};
  final Set<int> _working = {};
  Future<void>? _sweeping;
  bool _sweepAgain = false;
  Timer? _settleTimer;
  Timer? _retryTimer;
  bool _started = false;
  bool _disposed = false;
  bool _ownSignal = false;
  _AssistLifecycle? _observer;
  AssistMode _lastMode = AssistMode.off;
  String _lastConsent = '';
  String _lastRecipient = '';
  ({String stamp, DateTime until})? _hold;
  DateTime? _backoffUntil;
  String? _lastSkip;

  final ValueNotifier<LookupSupport?> _consentNeeded =
      ValueNotifier<LookupSupport?>(null);

  /// Non-null while the assist is paused for a consent: the recipient a
  /// lookup would reach now, which the consent does not name (a new
  /// provider or server, or none given). R7a's sheet answers it; a
  /// settings change that stamps a covering consent clears it.
  ValueListenable<LookupSupport?> get consentNeeded => _consentNeeded;

  /// Why the last sweep stopped early (diagnostics), or null.
  String? get lastSkip => _lastSkip;

  /// Today's lookups and the cap (diagnostics, R7b).
  int get lookupsToday => _budget.lookupsToday;
  int get dailyCap => _budget.cap;

  /// The last decisions (codes and kcal only), oldest first.
  Future<List<AssistDecisionEntry>> decisions() => _state.decisions();

  /// Meals an automatic apply changed that were not opened since.
  Future<Set<int>> unseen() => _state.unseen();

  /// The meal was opened: its dot goes.
  Future<bool> markSeen(int mealId) => _state.markSeen(mealId);

  /// Starts listening: meals-changed (a sweep 5 s later), settings (Off
  /// cancels, on sweeps), and — with [observeLifecycle] — the app coming
  /// back to the foreground. Idempotent.
  void start({bool observeLifecycle = true}) {
    if (_started || _disposed) return;
    _started = true;
    final s = _readSettings();
    _lastMode = s.mode;
    _lastConsent = _consentKey(s);
    // Off never touches the lookup client (MultiProviderAnalyzer builds its
    // lookup router on first use).
    if (s.mode != AssistMode.off) _lastRecipient = _recipientKey(_support());
    _settingsChanges?.addListener(_onSettingsChanged);
    _mealsChanged?.addListener(_onMealsSignal);
    if (observeLifecycle) {
      try {
        final observer = _AssistLifecycle(this);
        WidgetsBinding.instance.addObserver(observer);
        _observer = observer;
      } catch (_) {}
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    for (final t in _tokens) {
      t.cancel();
    }
    _tokens.clear();
    _settleTimer?.cancel();
    _retryTimer?.cancel();
    _settingsChanges?.removeListener(_onSettingsChanged);
    _mealsChanged?.removeListener(_onMealsSignal);
    final observer = _observer;
    if (observer != null) {
      try {
        WidgetsBinding.instance.removeObserver(observer);
      } catch (_) {}
    }
    _consentNeeded.dispose();
  }

  /// The app came back to the foreground.
  void onResumed() => _schedule(settleDelay);

  void _onMealsSignal() {
    // Our own write's signal: nothing new to look at.
    if (_ownSignal) return;
    _schedule(settleDelay);
  }

  void _onSettingsChanged() {
    if (_disposed) return;
    final s = _readSettings();
    final was = _lastMode;
    final consent = _consentKey(s);
    final consentChanged = consent != _lastConsent;
    _lastMode = s.mode;
    _lastConsent = consent;
    if (s.mode == AssistMode.off) {
      _lastRecipient = '';
      if (was != AssistMode.off) unawaited(turnOff());
      return;
    }
    final support = _support();
    final recipient = _recipientKey(support);
    final recipientChanged = recipient != _lastRecipient;
    _lastRecipient = recipient;
    // Another provider or server, a new consent or mode: whatever held the
    // lookups back may not hold any more. Other settings (a photo's
    // credentials bookkeeping, the language) leave the holds alone, so a
    // failing provider is not asked again on every notification.
    if (recipientChanged || consentChanged || was != s.mode) {
      _hold = null;
      _backoffUntil = null;
    }
    if (_consentNeeded.value != null && s.consentCovers(support)) {
      _consentNeeded.value = null;
    }
    // Turned on, switched between When unsure and Always, or a consent
    // answered: look now.
    if (was != s.mode || consentChanged) _schedule(Duration.zero);
  }

  static String _consentKey(AssistSettingsView s) =>
      '${s.consentRecipient}|${s.consentAt?.toIso8601String()}';

  static String _recipientKey(LookupSupport s) =>
      '${s.supported}|${s.recipientStamp}|${s.locationAllowed}|${s.reason}';

  void _schedule(Duration delay) {
    if (_disposed) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(delay, () => unawaited(sweep()));
  }

  void _scheduleRetry() {
    if (_disposed || (_retryTimer?.isActive ?? false)) return;
    _retryTimer = Timer(busyRetry, () => unawaited(sweep()));
  }

  /// Mode Off: the call in flight is cancelled and its result discarded,
  /// pending jobs are forgotten, the consent prompt is withdrawn.
  Future<void> turnOff() async {
    _generation++;
    for (final t in _tokens) {
      t.cancel();
    }
    _tokens.clear();
    _settleTimer?.cancel();
    _retryTimer?.cancel();
    if (!_disposed) _consentNeeded.value = null;
    await _state.clearJobs();
  }

  // ── Reading the seams (contained: a throwing seam reads as "not now") ──

  AssistSettingsView _readSettings() {
    try {
      return _settings();
    } catch (_) {
      return AssistSettingsView.off;
    }
  }

  LookupSupport _support() {
    try {
      return _lookups.lookupSupport();
    } catch (_) {
      return const LookupSupport.unsupported('error');
    }
  }

  bool _foreground() {
    try {
      return _inForeground?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  bool _idle() {
    try {
      return _pipelineIdle();
    } catch (_) {
      return false;
    }
  }

  bool _mealInUse(int mealId) {
    try {
      return _inUse(mealId);
    } catch (_) {
      return true;
    }
  }

  String? _region() {
    try {
      final c = _country?.call();
      return c != null && _iso2Re.hasMatch(c) ? c : null;
    } catch (_) {
      return null;
    }
  }

  bool _zh() {
    try {
      return _repliesInChinese?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  void _signal() {
    final f = _onMealsChanged;
    if (f == null) return;
    _ownSignal = true;
    try {
      f();
    } catch (_) {
    } finally {
      _ownSignal = false;
    }
  }

  /// The first precondition that fails for an automatic lookup, or null.
  String? _gate(AssistSettingsView s, LookupSupport support) {
    if (_disposed || s.mode == AssistMode.off) return AssistSkip.off;
    if (!_foreground()) return AssistSkip.background;
    final now = _clock();
    final hold = _hold;
    if (hold != null &&
        hold.stamp == support.recipientStamp &&
        now.isBefore(hold.until)) {
      return AssistSkip.unavailable;
    }
    final backoff = _backoffUntil;
    if (backoff != null && now.isBefore(backoff)) return AssistSkip.backoff;
    if (!_idle()) return AssistSkip.pipelineBusy;
    if (_analyzerBusy.value > 0) return AssistSkip.analyzerBusy;
    if (!support.supported) return AssistSkip.unsupported;
    if (!s.consentCovers(support)) return AssistSkip.consentNeeded;
    if (_budget.capReached) return AssistSkip.dailyCap;
    return null;
  }

  void _skip(String code, LookupSupport? support) {
    _lastSkip = code;
    if (code == AssistSkip.pipelineBusy || code == AssistSkip.analyzerBusy) {
      _scheduleRetry();
    }
    if (code == AssistSkip.consentNeeded && support != null && !_disposed) {
      _consentNeeded.value = support;
    }
  }

  // ── The sweep ──

  /// Looks at today's and yesterday's meals once (single-flight: a call
  /// while one runs makes it run once more after). Never throws.
  Future<void> sweep() {
    if (_disposed) return Future<void>.value();
    final running = _sweeping;
    if (running != null) {
      _sweepAgain = true;
      return running;
    }
    return _sweeping = _sweepLoop();
  }

  Future<void> _sweepLoop() async {
    try {
      do {
        _sweepAgain = false;
        try {
          await _sweepOnce();
        } catch (_) {
          _lastSkip = AssistSkip.error;
        }
      } while (_sweepAgain && !_disposed);
    } finally {
      // In the same step as the last check of _sweepAgain: a sweep() call
      // can never land between them and be lost.
      _sweeping = null;
    }
  }

  Future<void> _sweepOnce() async {
    final gen = _generation;
    var s = _readSettings();
    if (_disposed || s.mode == AssistMode.off) {
      // Off: not a read, not even of the lookup client.
      _skip(AssistSkip.off, null);
      return;
    }
    var support = _support();
    final gate = _gate(s, support);
    if (gate != null) {
      _skip(gate, support);
      return;
    }
    _lastSkip = null;
    if (_consentNeeded.value != null) _consentNeeded.value = null;
    final consentAt = s.consentAt!;
    final now = _clock();
    final meals = await _dao.mealsBetween(
      isoDate(now.subtract(const Duration(days: 1))),
      isoDate(now),
    );
    if (gen != _generation) return;
    final misses = await _state.misses();
    final jobs = await _state.jobs();
    if (jobs.isNotEmpty) {
      await _state.retainJobs({for (final m in meals) m.id});
    }
    final ordered = [
      for (final m in meals)
        if (_eligible(m, now, consentAt, misses)) m,
    ]..sort((a, b) => _timeOf(b).compareTo(_timeOf(a)));
    for (final meal in ordered) {
      if (gen != _generation || _disposed) return;
      s = _readSettings();
      final trigger = assistTriggerFor(meal.analysis, s.mode);
      if (trigger == null) continue;
      final printed = assistBrandEvidence(meal.analysis);
      if (!printed.itemBrand && !printed.merchant) {
        // No printed chain: only the location path (R6c) could look this
        // meal up.
        continue;
      }
      // Every precondition again, right before each lookup.
      support = _support();
      final again = _gate(s, support);
      if (again != null) {
        _skip(again, support);
        return;
      }
      if (_mealInUse(meal.id)) continue;
      final run = await _run(
        meal.id,
        trigger,
        gen: gen,
        settings: s,
        support: support,
        job: jobs[meal.id],
        manual: false,
      );
      if (run.stop) {
        _lastSkip = run.code;
        return;
      }
    }
  }

  static DateTime _timeOf(Meal m) =>
      DateTime.tryParse(m.timestamp) ?? DateTime.fromMillisecondsSinceEpoch(0);

  bool _eligible(
    Meal m,
    DateTime now,
    DateTime consentAt,
    Map<int, int> misses,
  ) {
    if (m.source != MealSource.appWatch && m.source != MealSource.appPhoto) {
      return false;
    }
    if (m.corrected || m.analysis.containsKey('assist')) return false;
    if (coerceIsFood(m.analysis) == false) return false;
    final at = DateTime.tryParse(m.timestamp);
    if (at == null || at.isBefore(consentAt)) return false;
    if (now.difference(at) > kAssistEligibleMaxAge) return false;
    if ((misses[m.id] ?? 0) >= assistMissesBeforeDenylist) return false;
    return !_mealInUse(m.id);
  }

  /// The editor's manual lookup (R7b), brand path. Needs a consent that
  /// names the current recipient (else [consentNeeded] asks for one) and
  /// room under the daily cap; ignores the mode, the triggers, the 24 h
  /// window and the miss list — the user asked. [useLocation] is the
  /// location path's (R6c); the brand path never reads a location.
  Future<AssistRun> lookupNow(int mealId, {bool useLocation = false}) async {
    try {
      if (_disposed) return const AssistRun(AssistSkip.off);
      final s = _readSettings();
      final support = _support();
      if (!support.supported) return const AssistRun(AssistSkip.unsupported);
      if (!s.consentCovers(support)) {
        _consentNeeded.value = support;
        return const AssistRun(AssistSkip.consentNeeded);
      }
      if (_budget.capReached) return const AssistRun(AssistSkip.dailyCap);
      final jobs = await _state.jobs();
      final run = await _run(
        mealId,
        AssistTrigger.manual,
        gen: _generation,
        settings: s,
        support: support,
        job: jobs[mealId],
        manual: true,
      );
      return run.public;
    } catch (_) {
      return const AssistRun(AssistSkip.error);
    }
  }

  Future<_Run> _run(
    int mealId,
    AssistTrigger trigger, {
    required int gen,
    required AssistSettingsView settings,
    required LookupSupport support,
    required AssistJob? job,
    required bool manual,
  }) async {
    if (!_working.add(mealId)) return const _Run(AssistSkip.working);
    try {
      final snap = await _dao.mealSnapshot(mealId);
      if (gen != _generation) return _Run.cancelled;
      if (snap == null) return const _Run(AssistSkip.mealGone);
      final meal = snap.meal;
      if (!manual &&
          (snap.corrected ||
              meal.analysis.containsKey('assist') ||
              _mealInUse(mealId))) {
        return const _Run(AssistSkip.mealChanged);
      }
      final base = assistBase(meal.analysis);
      final request = composeAssistRequest(base, country: _region(), zh: _zh());
      if (request.chainKeys.isEmpty) return const _Run(AssistSkip.noBrand);
      final hash = lookupRequestHash(request);

      final token = LookupCancelToken();
      _tokens.add(token);
      LookupOutcome outcome;
      var fromJob = false;
      try {
        if (job != null && job.reqHash == hash) {
          fromJob = true;
          outcome = await _lookups.poll(job.jobId);
          if (gen == _generation && outcome.needsResubmit) {
            // The server lost the job: the same request again (a request
            // it still holds is the same job, a finished one a cache hit).
            await _state.removeJob(mealId);
            fromJob = false;
            outcome = await _submit(request, settings, support, token);
          }
        } else {
          if (job != null) await _state.removeJob(mealId);
          outcome = await _submit(request, settings, support, token);
        }
      } finally {
        _tokens.remove(token);
      }
      // Off (or dispose) during the call: whatever came back is dropped.
      if (gen != _generation || token.isCancelled) return _Run.cancelled;
      if (fromJob && outcome.kind != LookupOutcomeKind.pending) {
        await _state.removeJob(mealId);
      }
      return await _settle(
        outcome,
        snap: snap,
        base: base,
        trigger: trigger,
        request: request,
        hash: hash,
        job: job,
        support: support,
        manual: manual,
        gen: gen,
      );
    } catch (_) {
      return const _Run(AssistSkip.error, stop: true);
    } finally {
      _working.remove(mealId);
    }
  }

  Future<LookupOutcome> _submit(
    LookupRequest request,
    AssistSettingsView settings,
    LookupSupport support,
    LookupCancelToken token,
  ) => _lookups.submit(
    request,
    chainDomains: request.chainDomains,
    cancel: token,
    expectedRecipient: support.recipient,
    expectedRecipientStamp: settings.consentRecipient,
  );

  Future<_Run> _settle(
    LookupOutcome outcome, {
    required MealSnapshot snap,
    required Map<String, dynamic> base,
    required AssistTrigger trigger,
    required LookupRequest request,
    required String hash,
    required AssistJob? job,
    required LookupSupport support,
    required bool manual,
    required int gen,
  }) async {
    final mealId = snap.meal.id;
    final now = _clock();
    final provider = outcome.provider.wire;
    final failure = outcome.failure;
    switch (outcome.kind) {
      case LookupOutcomeKind.done:
        final lookup = outcome.toAssistLookup();
        if (lookup == null) break;
        return _decide(
          lookup,
          snap: snap,
          base: base,
          trigger: trigger,
          request: request,
          manual: manual,
          gen: gen,
        );
      case LookupOutcomeKind.pending:
        final jobId = outcome.jobId;
        if (jobId != null) {
          await _state.putJob(
            mealId,
            AssistJob(
              jobId: jobId,
              reqHash: hash,
              at: job?.at ?? now,
              nextAt: now,
              attempts: job?.attempts ?? 0,
            ),
          );
        }
        return const _Run(AssistSkip.pending);
      case LookupOutcomeKind.unsupported:
        if (failure?.code == LookupFailureCode.consentChanged) {
          // The provider or server changed after the consent check: the
          // assist pauses until the new recipient is consented to.
          _consentNeeded.value = _support();
          return const _Run(AssistSkip.consentNeeded, stop: true);
        }
        await _logFailure('lookup_unsupported', provider);
        _holdRecipient(support, now);
        return const _Run(AssistSkip.unsupported, stop: true);
      case LookupOutcomeKind.serverOutdated:
      case LookupOutcomeKind.disabled:
        await _logFailure('lookup_${_snake(outcome.kind.name)}', provider);
        _holdRecipient(support, now);
        return const _Run(AssistSkip.unavailable, stop: true);
      case LookupOutcomeKind.rateLimited:
        await _logFailure(_failureCode(outcome), provider);
        _backoffUntil = failure?.code == LookupFailureCode.dailyCap
            ? DateTime(now.year, now.month, now.day + 1)
            : now.add(kAssistTransientBackoff);
        return const _Run(AssistSkip.backoff, stop: true);
      case LookupOutcomeKind.busy:
      case LookupOutcomeKind.offline:
        await _logFailure(_failureCode(outcome), provider);
        _backoffUntil = now.add(kAssistTransientBackoff);
        return const _Run(AssistSkip.backoff, stop: true);
      case LookupOutcomeKind.failed:
        break;
    }
    // A failed lookup (or a "done" without an answer).
    if (failure?.code == LookupFailureCode.cancelled) return _Run.cancelled;
    final code = _failureCode(outcome);
    await _logFailure(code, provider);
    if (failure != null && _recipientFailures.contains(failure.code)) {
      _holdRecipient(support, now);
      return _Run(code, stop: true);
    }
    if (failure == null || failure.transient) {
      _backoffUntil = now.add(kAssistTransientBackoff);
      return _Run(code, stop: true);
    }
    // Permanent for THIS meal (nothing sendable, a malformed or refused
    // answer): never asked again automatically.
    if (!manual) await _state.addMiss(mealId, denylist: true);
    return _Run(code);
  }

  Future<_Run> _decide(
    AssistLookup lookup, {
    required MealSnapshot snap,
    required Map<String, dynamic> base,
    required AssistTrigger trigger,
    required LookupRequest request,
    required bool manual,
    required int gen,
  }) async {
    final meal = snap.meal;
    final now = _clock();
    // Read now, not at the sweep's start: an application this sweep just
    // wrote on another meal counts for the 6 h repeat rule.
    final recent = await _dao.mealsBetween(
      isoDate(now.subtract(const Duration(days: 1))),
      isoDate(now),
    );
    final decision = decideAssist(
      meal,
      lookup,
      AssistContext(
        now: now,
        trigger: trigger,
        country: _region(),
        requestChainKeys: request.chainKeys,
        requestItems: request.items,
        recentApplies: _recentApplies(recent, meal.id),
      ),
    );
    final next = recordAssistDecision(meal.analysis, decision);
    final decided = decision.outcome == AssistOutcome.apply
        ? AssistSkip.applied
        : decision.reason;
    if (next == null) {
      await _log(decision, decided);
      // A rejected lookup writes nothing; the meal is not asked again.
      if (decision.outcome == AssistOutcome.reject && !manual) {
        await _state.addMiss(meal.id, denylist: true);
      }
      return _Run(decided, decision: decision);
    }
    if (!manual && _mealInUse(meal.id)) {
      // Opened while the lookup ran: the editor's copy wins.
      await _log(decision, AssistSkip.inUse);
      await _state.addMiss(meal.id);
      return _Run(AssistSkip.inUse, decision: decision);
    }
    final ok = await _dao.applyAssist(
      meal.id,
      expectedRaw: snap.rawAnalysis,
      analysis: next,
    );
    if (!ok) {
      // The meal changed while the lookup ran: the result is dropped.
      await _log(decision, AssistSkip.casMiss);
      if (!manual) await _state.addMiss(meal.id);
      return _Run(AssistSkip.casMiss, decision: decision);
    }
    await _log(decision, decided);
    _signal();
    if (decision.outcome == AssistOutcome.apply && !manual) {
      await _state.addUnseen(meal.id);
      if (gen == _generation) _announce(meal.id, decision, base, next);
    }
    return _Run(decided, decision: decision, wrote: true);
  }

  void _announce(
    int mealId,
    AssistDecision decision,
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    final f = _onApplied;
    final key = decision.chainKey;
    if (f == null || key == null) return;
    try {
      f(
        AssistAppliedNotice(
          mealId: mealId,
          chainKey: key,
          brandName: decision.brandName,
          oldKcal: safeNumber(before['total_calories']).round(),
          newKcal: safeNumber(after['total_calories']).round(),
          undo: () => undo(mealId),
        ),
      );
    } catch (_) {}
  }

  /// The snackbar's Undo: the application is reverted ('declined') while
  /// the meal still shows exactly what it applied. False — nothing written
  /// — when the meal changed since (or is gone). Never throws.
  Future<bool> undo(int mealId) async {
    try {
      final snap = await _dao.mealSnapshot(mealId);
      if (snap == null) return false;
      final applied = snap.meal.analysis;
      final reverted = revertAssist(applied, kind: AssistRevertKind.declined);
      if (reverted == null) return false;
      final ok = await _dao.applyAssist(
        mealId,
        expectedRaw: snap.rawAnalysis,
        analysis: reverted,
      );
      if (!ok) return false;
      await _state.markSeen(mealId);
      final block = applied['assist'];
      await _state.logDecision(
        AssistDecisionEntry(
          at: _clock(),
          code: AssistReason.userDeclined,
          oldKcal: safeNumber(applied['total_calories']).round(),
          newKcal: safeNumber(reverted['total_calories']).round(),
          provider: block is Map && block['provider'] is String
              ? block['provider'] as String
              : '',
        ),
      );
      _signal();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _holdRecipient(LookupSupport support, DateTime now) {
    _hold = (
      stamp: support.recipientStamp,
      until: now.add(kAssistUnavailableHold),
    );
  }

  static String _failureCode(LookupOutcome o) {
    final f = o.failure;
    return f == null
        ? 'lookup_${_snake(o.kind.name)}'
        : 'lookup_${_snake(f.code.name)}';
  }

  Future<void> _log(AssistDecision d, String code) => _state.logDecision(
    AssistDecisionEntry(
      at: _clock(),
      code: code,
      oldKcal: d.items.isEmpty ? null : d.oldKcal,
      newKcal: d.items.isEmpty ? null : d.newKcal,
      provider: d.provider,
    ),
  );

  Future<void> _logFailure(String code, String provider) => _state.logDecision(
    AssistDecisionEntry(at: _clock(), code: code, provider: provider),
  );

  /// Applications standing on the OTHER meals of [meals] (the 6 h repeat
  /// rule): each covered menu item, at the time its meal was logged.
  static List<AssistRecentApply> _recentApplies(List<Meal> meals, int mealId) {
    final out = <AssistRecentApply>[];
    for (final m in meals) {
      if (m.id == mealId) continue;
      final b = m.analysis['assist'];
      if (b is! Map ||
          b['v'] != kAssistVersion ||
          b['status'] != AssistStatus.applied) {
        continue;
      }
      final key = b['chain_key'];
      final at = DateTime.tryParse(m.timestamp);
      final matches = b['matches'];
      if (key is! String || at == null || matches is! List) continue;
      for (final x in matches) {
        if (x is Map && x['menu_item'] is String) {
          out.add(
            AssistRecentApply(
              chainKey: key,
              menuItem: x['menu_item'] as String,
              at: at,
            ),
          );
        }
      }
    }
    return out;
  }
}

class _AssistLifecycle with WidgetsBindingObserver {
  _AssistLifecycle(this._assist);
  final MealAssist _assist;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _assist.onResumed();
  }
}
