/// MealAssist — the restaurant assist's engine (design R6b, the brand path;
/// R6c, the location path, job polling, retries and the cache; decisions
/// "Assist architecture: save first, enrich later", "Triggers", "Chain-first
/// data minimization", "Location-only APPLY", "Day window", "Write safety",
/// "Consent", "Storage").
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
/// The BRAND path: the chains the items' printed brands and the receipt
/// merchant name (core/restaurant_lookup_contract.dart composes them from
/// OUR table) → the cache, else submit (a direct provider answers at once;
/// the owner's server answers with a job, kept in 'assist_jobs') →
/// decideAssist → recordAssistDecision → MealsDao.applyAssist against the
/// raw text read before the lookup. A false return (the meal changed while
/// the lookup ran) drops the result and counts a miss.
///
/// The LOCATION path (R6c) adds the chains around where the photo was
/// taken. It runs only with a location reader and a places resolver (iOS;
/// di.dart builds neither on Android), the 'Use photo location' sub-toggle
/// on (or the editor's "Use location"), LookupSupport.locationAllowed (an
/// http:// own server is brand-only), capture.has_gps, and a RESTAURANT meal
/// — never takeout, packaged, home or unknown, whose location is never
/// read. Steps ([MealAssist._locate]): the fix's own gate (accuracy,
/// freshness; place_match.dart placeGate) → PhotoLocationReader → a point
/// in memory → its ~100 m cell against the 'Not from a restaurant' zones
/// (no places call inside one) → Apple Maps' nearby food places → matchPlaces
/// → chain keys of OUR table, a pick, the dense flag, whether the fix is
/// verified → the point, the cell and every place are dropped. The request
/// names at most 3 chains (1 when one was auto-picked); decideAssist
/// derives location_confirmed when the user confirmed that chain at that
/// spot, otherwise location (a suggestion at most).
///
/// Jobs and retries (R6c): a pending Claude Plan job is polled every 10 s
/// for 2 minutes while the app is in the foreground, later on the next
/// sweep. Busy, rate limited (not the daily cap), a timeout or a 5xx is
/// tried again after 5 min, 30 min and 2 h; a 4th such failure and the
/// meal is written 'unavailable'; offline, or a failure because the app left the
/// foreground, is not a try. What the location path found is kept with the
/// job or retry record, so a poll, a resubmit or a retry never reads the
/// position again.
///
/// The cache (R6c, 'assist_cache', 30 days, 200): a finished answer keyed by
/// its chain and the meal's item names (sorted, parenthetical weights
/// dropped). An automatic lookup's hit makes no lookup call — only an
/// answer from the provider a lookup would reach now counts (one cached
/// from Anthropic never answers on Claude Plan, whose lookups are
/// suggestions only). The editor's lookup never reads the cache: the user
/// asked again. Once the user turns an answer down (Undo, Use AI estimate,
/// Wrong restaurant, Not from a restaurant) that chain and those items are
/// marked declined: an APPLY for them, cached or fresh, is written as a
/// suggestion (reason declined_before) until the user accepts or confirms
/// one (Use published numbers, Correct).
///
/// After an automatic APPLY: the meal joins the unseen set (the card's dot,
/// R7b), the meals-changed signal, and a snackbar with Undo
/// ([AssistAppliedNotice]; Undo writes revertAssist 'declined' through
/// applyAssist). Every lookup leaves one entry in the decision log (codes
/// and kcal only).
///
/// Mode Off cancels the call in flight (LookupCancelToken) and discards its
/// result: every write a run makes — the meal, a job or retry record, the
/// cache, the miss list — first checks that no Off (or dispose) came since
/// the run started, and for an automatic run that Settings still say on.
/// Off also forgets pending jobs. [MealAssist.lookupNow] is the editor's
/// manual lookup (R7b), also with the chain the user picked after 'Wrong
/// restaurant'; its result on a meal the user already corrected is written
/// through the user's own compare-and-set. [MealAssist.act] is the editor's
/// answer to a result — Use AI estimate, Use published numbers, Wrong
/// restaurant, Not from a restaurant, Correct: the user's own change
/// (updateMealAnalysisIfUnchanged, corrected = 1), and the photo's ~100 m
/// cell taught to the places store only where its location may be read
/// ('Use photo location' on, a consent for the current recipient). A
/// chain is confirmed at a spot only when the place step named it there
/// (evidence location or location_confirmed) — accepting a printed
/// brand's numbers says nothing about the spot.
///
/// Nothing here logs. A coordinate exists only inside [MealAssist._locate],
/// for one places query; MapKit's places only inside matchPlaces. Neither
/// is stored, sent, logged or shown — only chain keys of OUR table leave
/// that method.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../../core/chain_match.dart' show chainByKey;
import '../../core/coerce.dart';
import '../../core/contracts.dart';
import '../../core/place_match.dart';
import '../../core/restaurant_assist_logic.dart';
import '../../core/restaurant_lookup_contract.dart';
import '../photo/glasses.dart' show isMetaGlassesAnalysis;
import '../photo/photo_location.dart' show PhotoLocationReader;
import '../places/places.dart'
    show PlaceResolver, PlacesStatus, placesThrottleBackoff;
import 'assist_local_state.dart';
import 'assist_places_store.dart';
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
/// automatic lookup starts for this long; the meal itself waits for its
/// own next try (assistRetryDelays).
const Duration kAssistTransientBackoff = Duration(minutes: 5);

/// A pending Claude Plan job is polled this often while the app is in the
/// foreground, for [kAssistPollWindow] after it was submitted; after that,
/// on the next sweep (design R6c).
const Duration kAssistPollInterval = Duration(seconds: 10);
const Duration kAssistPollWindow = Duration(minutes: 2);

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

  /// Failed again after [assistMaxRetries] retries: written 'unavailable'.
  static const String retriesExhausted = 'retries_exhausted';

  // The location path (with place_match.dart's PlaceMatchReason codes).
  static const String placeNoFix = 'place_no_fix';
  static const String placeThrottled = 'place_throttled';
  static const String placeError = 'place_error';
  static const String placeUnsupported = 'place_unsupported';
  static const String mealGone = 'meal_gone';
  static const String mealChanged = 'meal_changed';
  static const String inUse = 'in_use';
  static const String casMiss = 'cas_miss';
  static const String working = 'working';
  static const String pending = 'pending';
  static const String cancelled = 'cancelled';
  static const String applied = 'applied';
  static const String error = 'error';

  /// The editor's lookup of a chain the user picked, to the owner's server
  /// over http: the pick would be stripped with the location-derived
  /// chains (ServerLookupClient's https gate), so nothing is sent.
  static const String pickNeedsHttps = 'pick_needs_https';
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

  /// 'Use photo location' (R6c; iOS only): automatic lookups of
  /// restaurant meals may add the chains around where the photo was taken.
  /// Off, they are brand-only and no location is read.
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

/// The lookup request for [analysis]: its items (positions kept) and
/// receipt merchant — the composer lists the chains the printed brands and
/// the merchant name first, from OUR table only — then [chains], the keys
/// the location path found (best first; none on the brand path), at most 3
/// in all. [country] is the device region (ISO2; the composer defaults to
/// US), [zh] asks for Chinese notes.
LookupRequest composeAssistRequest(
  Map<String, dynamic> analysis, {
  String? country,
  bool zh = false,
  List<String> chains = const [],
}) => LookupRequest.compose({
  'items': analysis['food_items'] is List
      ? analysis['food_items']
      : const <Object?>[],
  'order_merchant': analysis['order_merchant'],
  'chains': chains,
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

// ─── The on-device cache's key (design R6c) ────────────────────────────

/// A parenthetical holding a digit: an assumed weight or count the model
/// added to a name ("Big Mac (220 g)", "Fries (约117克)", "Nuggets [6 pc]").
final RegExp _measureRe = RegExp(
  r'\([^()]*[0-9][^()]*\)|\[[^\[\]]*[0-9][^\[\]]*\]|【[^【】]*[0-9][^【】]*】',
);
final RegExp _spacesRe = RegExp(r'\s+');

/// An item name as the cache compares it: the request's cleaned name,
/// lower-cased, parenthetical weights removed, spaces collapsed.
String assistCacheItemName(Object? name) => (name is String ? name : '')
    .replaceAll(_measureRe, ' ')
    .toLowerCase()
    .replaceAll(_spacesRe, ' ')
    .trim();

/// [request]'s item names as the cache compares them, in request order.
List<String> assistCacheNames(LookupRequest request) => [
  for (final item in request.items)
    assistCacheItemName(item is Map ? item['name'] : null),
];

/// The cache key: [chainKey] and [names] sorted — the first 32 hex
/// characters of SHA-256 over them. The same items in another order, or
/// with another assumed weight, are the same lookup.
String assistCacheKey(String chainKey, List<String> names) {
  final sorted = [...names]..sort();
  return sha256
      .convert(utf8.encode(jsonEncode([chainKey, sorted])))
      .toString()
      .substring(0, 32);
}

/// [lookup] — cached for a request whose items were named [from] — with
/// every match's item_index moved onto [to], the same names in this meal's
/// order (the k-th "fries" there is the k-th "fries" here). Null when the
/// two are not the same names, so a cached answer can never land on
/// another item.
AssistLookup? remapCachedLookup(
  AssistLookup lookup, {
  required List<String> from,
  required List<String> to,
}) {
  if (from.length != to.length) return null;
  final a = [...from]..sort();
  final b = [...to]..sort();
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return null;
  }
  final result = lookup.result;
  if (result is! Map) return null;
  final matches = result['matches'];
  final moved = <Object?>[];
  for (final m in matches is List ? matches : const []) {
    if (m is! Map) continue;
    final i = m['item_index'];
    if (i is! int || i < 0 || i >= from.length) continue;
    final name = from[i];
    var k = 0;
    for (var x = 0; x < i; x++) {
      if (from[x] == name) k++;
    }
    var j = -1;
    for (var y = 0, seen = 0; y < to.length; y++) {
      if (to[y] != name) continue;
      if (seen == k) {
        j = y;
        break;
      }
      seen++;
    }
    if (j < 0) return null;
    moved.add(<String, Object?>{
      for (final e in m.entries) '${e.key}': e.value,
      'item_index': j,
    });
  }
  return AssistLookup(
    result: <String, Object?>{
      for (final e in result.entries) '${e.key}': e.value,
      'matches': moved,
    },
    provider: lookup.provider,
    citedUrls: lookup.citedUrls,
    evidence: lookup.evidence,
  );
}

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

/// The editor's answers to a restaurant result (R7b; design "Feedback
/// actions").
enum AssistUserAction {
  /// 'Use AI estimate': an applied block reverted exactly.
  useEstimate,

  /// 'Use published numbers': a suggestion applied as accepted; the chain
  /// is confirmed at the photo's spot.
  acceptSuggestion,

  /// 'Wrong restaurant': reverted (or the suggestion declined), the chain
  /// blocked at the photo's spot; the editor then asks which chain it was.
  wrongRestaurant,

  /// 'Not from a restaurant': reverted (or declined), and the photo's spot
  /// becomes a zone where no places are looked up.
  notFromRestaurant,

  /// 'Correct': the chain confirmed at the photo's spot; the meal itself
  /// is not written.
  correct,
}

/// How an editor action ended.
enum AssistActionStatus {
  /// Written (or, for 'Correct', taken note of).
  done,

  /// The meal changed since the editor read it (or is gone): nothing was
  /// written; the editor reloads it.
  changed,

  /// Nothing to act on: no such block, or its stamps no longer match the
  /// meal (the user's later edit stands).
  nothing,
}

/// What [MealAssist.act] did: its status, and whether the photo's spot was
/// learned ([AssistPlacesStore]) — false wherever no location may be read.
final class AssistActionResult {
  const AssistActionResult(this.status, {this.placeLearned = false});
  final AssistActionStatus status;
  final bool placeLearned;
}

/// What the location path made of one meal ([MealAssist._locate]): a code
/// for the decision log, and the chain keys it found — nothing else.
final class _Located {
  const _Located(
    this.code, {
    this.place,
    this.later = false,
    this.failed = false,
  });

  /// A PlaceMatchReason wire code or one of [AssistSkip]'s place codes.
  final String code;

  /// The chains (keys of OUR table) and flags, when places were matched.
  final AssistPlaceContext? place;

  /// Apple Maps asked us to wait: the meal is tried again later.
  final bool later;

  /// The places query failed: the brand path goes on alone.
  final bool failed;
}

/// One meal's request, composed: what is sent, its hash, and what the
/// location path contributed to it.
final class _Prepared {
  const _Prepared(this.request, this.hash, this.place, this.pick, this.country);
  final LookupRequest request;
  final String hash;
  final AssistPlaceContext? place;

  /// The chain the user picked in the editor (R7b), or null.
  final String? pick;

  /// The device region the request was composed with (ISO2), read once,
  /// so the decision judges the same country the request named. Null
  /// (unknown) asks for the table's US menu and applies nothing.
  final String? country;
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
final RegExp _providerCodeRe = RegExp(r'^[a-z0-9_]{1,20}$');

/// A block's provider as the decision log may keep it (an imported block
/// is untrusted), else ''.
String _providerCode(Object? v) =>
    v is String && _providerCodeRe.hasMatch(v) ? v : '';
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
    this._location,
    this._places,
    this._placesStore,
    DateTime Function()? clock,
    this.settleDelay = kAssistSettleDelay,
    this.busyRetry = kAssistBusyRetry,
    this.pollInterval = kAssistPollInterval,
    this.pollWindow = kAssistPollWindow,
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

  /// The location path's seams (R6c). Without a reader and a resolver
  /// (Android; di.dart builds neither there) every lookup is brand-only.
  final PhotoLocationReader? _location;
  final PlaceResolver? _places;
  final AssistPlacesStore? _placesStore;
  final DateTime Function() _clock;

  final Duration settleDelay;
  final Duration busyRetry;
  final Duration pollInterval;
  final Duration pollWindow;

  /// Bumped by Off and dispose: every result of an older generation is
  /// discarded.
  int _generation = 0;
  final Set<LookupCancelToken> _tokens = {};
  final Set<int> _working = {};
  Future<void>? _sweeping;
  bool _sweepAgain = false;
  Timer? _settleTimer;
  Timer? _retryTimer;
  Timer? _pollTimer;

  /// Bumped each time the app leaves the foreground: a call that ended in
  /// a failure across a bump failed because of it, which is not a try.
  int _backgroundEpoch = 0;

  /// Apple Maps throttled: no location is read before this.
  DateTime? _placesHoldUntil;
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

  /// 'Clear learned places' (R7a): the places the user taught — the 'Not
  /// from a restaurant' zones and the confirmed and blocked chains — are
  /// forgotten, through the same store instance the location path reads;
  /// so are the other records that hold chains found near a photo: the
  /// 30-day answer cache (with the answers the user turned down) and the
  /// pending jobs and retries with what their location path found (the
  /// next sweep asks again). True when the places are gone (none were ever
  /// kept without a store). Never throws.
  Future<bool> clearLearnedPlaces() async {
    try {
      await _state.clearCache();
      await _state.clearJobs();
    } catch (_) {}
    final store = _placesStore;
    if (store == null) return true;
    try {
      return await store.clear();
    } catch (_) {
      return false;
    }
  }

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
    _pollTimer?.cancel();
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

  /// The app left the foreground: a call failing from now on is not a try.
  void onBackgrounded() => _backgroundEpoch++;

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

  /// [job] is a pending server job: its next poll, while it is younger
  /// than [pollWindow] (later polls wait for the next sweep).
  void _schedulePoll(AssistJob job) {
    if (_disposed || !job.isPending) return;
    final now = _clock();
    if (!now.isBefore(job.at.add(pollWindow))) return;
    if (_pollTimer?.isActive ?? false) return;
    var wait = job.nextAt.difference(now);
    if (wait.isNegative) wait = Duration.zero;
    if (wait > pollInterval) wait = pollInterval;
    _pollTimer = Timer(wait, () => unawaited(sweep()));
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
    _pollTimer?.cancel();
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

  /// A run started in generation [gen] may still write — the meal, a job
  /// or retry record, the cache, the miss list: no Off (or dispose) came
  /// since, and for an automatic run Settings still say on (read fresh,
  /// in case the change notification has not landed yet). The editor's
  /// lookup ignores the mode, so only Off's generation stops it. Checked
  /// right before each write, after every await in between.
  bool _current(int gen, {required bool manual}) {
    if (_disposed || gen != _generation) return false;
    return manual || _readSettings().mode != AssistMode.off;
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
        if (_eligible(m, now, consentAt, misses) ||
            _manualPending(m, jobs[m.id]))
          m,
    ]..sort((a, b) => _timeOf(b).compareTo(_timeOf(a)));
    for (final meal in ordered) {
      if (gen != _generation || _disposed) return;
      s = _readSettings();
      final job = jobs[meal.id];
      // The editor's own lookup still running on the server: polled
      // whatever the triggers say, with the location choice it was made
      // with (its kept place), and answered as a manual lookup.
      final manualJob = job != null && job.manual && job.isPending;
      final trigger = manualJob
          ? AssistTrigger.manual
          : assistTriggerFor(meal.analysis, s.mode);
      final useLocation = manualJob ? job.place != null : s.useLocation;
      final printed = assistBrandEvidence(meal.analysis);
      if (trigger == null ||
          (!manualJob &&
              !printed.itemBrand &&
              !printed.merchant &&
              !(useLocation && _locationPossible(meal, support)))) {
        // Not looked up (any more): no trigger, or nothing printed names a
        // chain and the location may not be read. An automatic job or
        // retry kept for it answers nothing now.
        if (job != null && !job.manual) await _state.removeJob(meal.id);
        continue;
      }
      if (job != null && _clock().isBefore(job.nextAt)) {
        // Its job's next poll, or its next try, is not due yet.
        _schedulePoll(job);
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
        job: job,
        manual: manualJob,
        useLocation: useLocation,
        pick: manualJob ? job.pick : null,
      );
      if (run.stop) {
        _lastSkip = run.code;
        return;
      }
    }
  }

  static DateTime _timeOf(Meal m) =>
      DateTime.tryParse(m.timestamp) ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// The editor's own lookup is still running on the server for [m]
  /// (R7b): polled even on a meal the automatic sweep would skip — one the
  /// user corrected (a 'Wrong restaurant' revert is a user write), one
  /// with an assist block, one logged before the consent — once the editor
  /// that started it is closed.
  bool _manualPending(Meal m, AssistJob? job) =>
      job != null && job.manual && job.isPending && !_mealInUse(m.id);

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

  /// The editor's manual lookup (R7b). Needs the app in the foreground, a
  /// consent that names the current recipient (else [consentNeeded] asks
  /// for one) and room under the daily cap; ignores the mode, the
  /// triggers, the 24 h window, the miss list and a retry's wait — the
  /// user asked — and the cache: it always asks the provider again.
  /// [useLocation] is the user's choice ("Use location" / "Brand only"):
  /// with it, a restaurant meal takes the location path under the same
  /// gates as an automatic lookup (locationAllowed, has_gps, restaurant);
  /// without it no location is read. A failure here is shown, not retried.
  ///
  /// [chainKey] is the chain the user picked in the editor's 'Which
  /// restaurant?' search after 'Wrong restaurant' (R7b): the request names
  /// it (after any chain a printed brand names — the composer's rule), no
  /// location is read, and decideAssist accepts an answer for that chain
  /// alone, as a suggestion at most. To the owner's server over http,
  /// where the pick would be stripped with the location-derived chains,
  /// nothing is sent ([AssistSkip.pickNeedsHttps]). Calling again while
  /// the server still runs this meal's job polls it (no new lookup, so not
  /// held by the daily cap).
  Future<AssistRun> lookupNow(
    int mealId, {
    bool useLocation = false,
    String? chainKey,
  }) async {
    try {
      if (_disposed) return const AssistRun(AssistSkip.off);
      if (chainKey != null && chainByKey(chainKey) == null) {
        return const AssistRun(AssistSkip.error);
      }
      // Foreground only (a backgrounded editor's poll loop, say): the job
      // stays, and the sweep collects it when the app is back.
      if (!_foreground()) return const AssistRun(AssistSkip.background);
      final s = _readSettings();
      final support = _support();
      if (!support.supported) return const AssistRun(AssistSkip.unsupported);
      if (!s.consentCovers(support)) {
        _consentNeeded.value = support;
        return const AssistRun(AssistSkip.consentNeeded);
      }
      final jobs = await _state.jobs();
      final job = jobs[mealId];
      final polling = job != null && job.manual && job.isPending;
      if (!polling && _budget.capReached) {
        return const AssistRun(AssistSkip.dailyCap);
      }
      final run = await _run(
        mealId,
        AssistTrigger.manual,
        gen: _generation,
        settings: s,
        support: support,
        job: job,
        manual: true,
        useLocation: chainKey == null && useLocation,
        pick: chainKey,
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
    required bool useLocation,
    String? pick,
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

      // ── Where (R6c): the location path, or what a job kept of it ──
      AssistPlaceContext? place;
      String? placeCode;
      var placeFailed = false;
      if (useLocation && _locationPossible(meal, support)) {
        final kept = job?.place;
        if (kept != null) {
          // A job or a retry: the position is not read again.
          place = kept;
        } else {
          final located = await _locate(meal);
          if (gen != _generation) return _Run.cancelled;
          if (located.later) {
            _scheduleRetry();
            return _Run(located.code);
          }
          place = located.place;
          placeCode = located.code;
          placeFailed = located.failed;
        }
      }

      final country = _region();
      final request = composeAssistRequest(
        base,
        country: country,
        zh: _zh(),
        chains: pick != null ? [pick] : place?.chains ?? const [],
      );
      if (request.chainKeys.isEmpty) {
        // Nothing names a chain from OUR table: no lookup. The location
        // found none (or could not be read): this meal is not asked again
        // automatically — another sweep would only ask Apple Maps the same
        // question; a failed places query gets one more chance. A job kept
        // for a request this meal no longer makes answers nothing.
        if (job != null) await _state.removeJob(mealId);
        if (placeCode == null) return const _Run(AssistSkip.noBrand);
        if (!manual) {
          await _logCode(placeCode);
          await _state.addMiss(mealId, denylist: !placeFailed);
        }
        return _Run(placeCode);
      }
      if (pick != null &&
          !support.locationAllowed &&
          !request
              .withoutLocationChains(request.chainKeys)
              .chainKeys
              .contains(pick)) {
        // The owner's server over http: its https gate would strip the
        // pick with the location-derived chains, and the lookup would ask
        // about the chain the user just called wrong (or nothing). Nothing
        // is sent.
        if (job != null) await _state.removeJob(mealId);
        return const _Run(AssistSkip.pickNeedsHttps);
      }
      place = place?.within(request.chainKeys);
      if (place != null && place.chains.isEmpty) place = null;
      final prepared = _Prepared(
        request,
        lookupRequestHash(request),
        place,
        pick,
        country,
      );

      // ── The cache (R6c): the same items at the same chain, answered by
      // the provider a lookup would reach now. Never for the editor's
      // lookup: the user asked again. ──
      final cached = manual
          ? null
          : await _fromCache(request, provider: support.recipient.wire);
      if (gen != _generation) return _Run.cancelled;
      if (cached != null) {
        if (job != null) await _state.removeJob(mealId);
        return await _decide(
          cached,
          snap: snap,
          base: base,
          trigger: trigger,
          prepared: prepared,
          manual: manual,
          gen: gen,
        );
      }

      final token = LookupCancelToken();
      _tokens.add(token);
      final epoch = _backgroundEpoch;
      LookupOutcome outcome;
      var polled = false;
      try {
        final jobId = job?.jobId;
        if (jobId != null && job!.reqHash == prepared.hash) {
          polled = true;
          outcome = await _lookups.poll(jobId);
          if (gen == _generation && outcome.needsResubmit) {
            // The server lost the job: the same request again (a request
            // it still holds is the same job, a finished one a cache hit).
            polled = false;
            outcome = await _submit(request, settings, support, token);
          }
        } else {
          outcome = await _submit(request, settings, support, token);
        }
      } finally {
        _tokens.remove(token);
      }
      // Off (or dispose) during the call: whatever came back is dropped.
      if (gen != _generation || token.isCancelled) return _Run.cancelled;
      return await _settle(
        outcome,
        snap: snap,
        base: base,
        trigger: trigger,
        prepared: prepared,
        job: job,
        polled: polled,
        support: support,
        manual: manual,
        gen: gen,
        wentBackground: _backgroundEpoch != epoch || !_foreground(),
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

  // ── The location path (R6c) ──

  /// Whether [meal] may take the location path at all — no read yet: a
  /// location reader and a places resolver (iOS), a recipient that may
  /// receive location-derived chains (locationAllowed: not an http://
  /// own server), a library photo with GPS, and a RESTAURANT meal (never
  /// takeout, packaged, home or unknown).
  bool _locationPossible(Meal meal, LookupSupport support) {
    final reader = _location;
    if (reader == null || !reader.enabled || _places == null) return false;
    if (!support.supported || !support.locationAllowed) return false;
    if (meal.fileId.trim().isEmpty) return false;
    final capture = meal.analysis['capture'];
    if (capture is! Map || capture['has_gps'] != true) return false;
    return mealContextFields(meal.analysis).restaurantContext ==
        RestaurantContext.restaurant;
  }

  /// The location path for [meal] (see the library doc). The photo's
  /// position is read here, lives in [point] for one places query, and is
  /// gone when this returns: what comes back is a code and chain keys.
  /// Never throws.
  Future<_Located> _locate(Meal meal) async {
    try {
      final reader = _location;
      final places = _places;
      if (reader == null || places == null) {
        return const _Located(AssistSkip.placeUnsupported);
      }
      final analysis = meal.analysis;
      final geo = PhotoGeo.fromCapture(
        analysis['capture'],
        glasses: isMetaGlassesAnalysis(analysis),
      );
      // The fix's own quality first: a coarse or stale fix is never read.
      final gate = placeGate(geo);
      final refused = gate.reason;
      if (refused != null) return _Located(refused.wire);
      final hold = _placesHoldUntil;
      if (hold != null && _clock().isBefore(hold)) {
        return const _Located(AssistSkip.placeThrottled, later: true);
      }
      final point = await reader.forAsset(meal.fileId);
      if (point == null) return const _Located(AssistSkip.placeNoFix);
      final cell = PlaceCell.fromLatLon(point.lat, point.lon);
      if (cell == null) return const _Located(AssistSkip.placeNoFix);
      final learned = await _learnedPlaces();
      // A 'Not from a restaurant' zone: Apple Maps is not asked.
      if (learned.inZone(cell)) return _Located(PlaceMatchReason.zone.wire);
      final near = await places.nearbyFood(point, radiusM: gate.radiusM);
      switch (near.status) {
        case PlacesStatus.throttled:
          _placesHoldUntil = _clock().add(placesThrottleBackoff);
          return const _Located(AssistSkip.placeThrottled, later: true);
        case PlacesStatus.error:
          return const _Located(AssistSkip.placeError, failed: true);
        case PlacesStatus.unsupported:
          return const _Located(AssistSkip.placeUnsupported);
        case PlacesStatus.ok:
        case PlacesStatus.none:
          break;
      }
      final match = matchPlaces(
        geo: geo,
        cell: cell,
        context: mealContextFields(analysis).restaurantContext,
        places: near.places,
        learned: learned,
      );
      return _Located(
        match.reason.wire,
        place: AssistPlaceContext(
          chains: match.lookupChainKeys,
          picked: match.picked,
          confirmed: match.confirmed,
          blocked: match.blocked,
          verified: match.verified,
          dense: match.dense,
        ),
      );
    } catch (_) {
      return const _Located(AssistSkip.placeError, failed: true);
    }
  }

  Future<LearnedPlaces> _learnedPlaces() async {
    try {
      return await _placesStore?.read() ?? LearnedPlaces.empty;
    } catch (_) {
      return LearnedPlaces.empty;
    }
  }

  // ── The cache (R6c) ──

  /// A cached answer for [request]: the first of its chains (rank order)
  /// with one for these item names from [provider] — the provider a lookup
  /// would reach now (an answer kept from another provider is a miss: a
  /// direct provider's page text never stands in for Claude Plan's
  /// suggestions-only search) — moved onto this meal's item order.
  Future<AssistLookup?> _fromCache(
    LookupRequest request, {
    required String provider,
  }) async {
    final names = assistCacheNames(request);
    for (final chain in request.chainKeys) {
      final hit = await _state.cachedLookup(assistCacheKey(chain, names));
      if (hit == null ||
          hit.chainKey != chain ||
          hit.lookup.provider != provider) {
        continue;
      }
      final moved = remapCachedLookup(hit.lookup, from: hit.names, to: names);
      if (moved != null) return moved;
    }
    return null;
  }

  /// The cache key of [analysis]'s items at [chainKey] — the names its
  /// lookup request composes, as [_remember] keyed the answer — or null.
  static String? _cacheKeyOf(String chainKey, Map<String, dynamic> analysis) {
    try {
      final names = assistCacheNames(
        composeAssistRequest(assistBase(analysis)),
      );
      if (names.isEmpty) return null;
      return assistCacheKey(chainKey, names);
    } catch (_) {
      return null;
    }
  }

  /// The user turned the published numbers for [analysis]'s items at
  /// [chainKey] down ([declined]) or took them ([declined] false): the
  /// cached answer is marked so. Never throws.
  Future<void> _markCached(
    String? chainKey,
    Map<String, dynamic> analysis, {
    required bool declined,
  }) async {
    if (chainKey == null) return;
    final key = _cacheKeyOf(chainKey, analysis);
    if (key == null) return;
    try {
      await _state.markCachedLookup(key, declined: declined);
    } catch (_) {}
  }

  /// The user turned the published numbers for [request]'s items at
  /// [chainKey] down before (see [_markCached]).
  Future<bool> _declinedBefore(String? chainKey, LookupRequest request) async {
    if (chainKey == null) return false;
    try {
      final hit = await _state.cachedLookup(
        assistCacheKey(chainKey, assistCacheNames(request)),
      );
      return hit != null && hit.chainKey == chainKey && hit.declined;
    } catch (_) {
      return false;
    }
  }

  /// Keeps a finished [outcome] for [request] when it answers for one of
  /// the request's chains: the answer, the search's URLs and its text for
  /// the claimed source only (bounded; cutting text can only make a later
  /// check stricter).
  Future<void> _remember(LookupRequest request, LookupOutcome outcome) async {
    final result = outcome.result;
    final chain = result?.chainKey;
    if (result == null ||
        chain == null ||
        !request.chainKeys.contains(chain) ||
        outcome.provider == LookupRecipient.none) {
      return;
    }
    final names = assistCacheNames(request);
    final source = normalizeSourceUrl(result.sourceUrl);
    final evidence = <AssistEvidence>[];
    var room = assistCacheEvidenceMaxChars;
    for (final e in outcome.evidence) {
      if (source == null ||
          evidence.length == assistCacheMaxEvidence ||
          room <= 0) {
        break;
      }
      if (normalizeSourceUrl(e.url) != source) continue;
      final text = e.text.length > room ? e.text.substring(0, room) : e.text;
      room -= text.length;
      evidence.add(
        AssistEvidence(
          url: e.url,
          text: text,
          verbatim: e.verbatim,
          pageAge: e.pageAge,
        ),
      );
    }
    await _state.putCachedLookup(
      AssistCachedLookup(
        key: assistCacheKey(chain, names),
        chainKey: chain,
        names: names,
        lookup: AssistLookup(
          result: result.json,
          provider: outcome.provider.wire,
          citedUrls: outcome.citedUrls.take(assistCacheMaxCitedUrls).toList(),
          evidence: evidence,
        ),
        at: _clock(),
      ),
    );
  }

  // ── After the call ──

  /// Failures that are not the lookup's fault and not a try: no network,
  /// or a portal answering in the recipient's place.
  static bool _offline(LookupOutcome o) {
    final code = o.failure?.code;
    if (code == null) return o.kind == LookupOutcomeKind.offline;
    return code == LookupFailureCode.network ||
        code == LookupFailureCode.captivePortal;
  }

  Future<_Run> _settle(
    LookupOutcome outcome, {
    required MealSnapshot snap,
    required Map<String, dynamic> base,
    required AssistTrigger trigger,
    required _Prepared prepared,
    required AssistJob? job,
    required bool polled,
    required LookupSupport support,
    required bool manual,
    required int gen,
    required bool wentBackground,
  }) async {
    final mealId = snap.meal.id;
    final now = _clock();
    final provider = outcome.provider.wire;
    final failure = outcome.failure;
    switch (outcome.kind) {
      case LookupOutcomeKind.done:
        final lookup = outcome.toAssistLookup();
        if (lookup == null) break;
        if (job != null) await _state.removeJob(mealId);
        // Off since the answer arrived: discarded, not even cached.
        if (!_current(gen, manual: manual)) return _Run.cancelled;
        await _remember(prepared.request, outcome);
        return _decide(
          lookup,
          snap: snap,
          base: base,
          trigger: trigger,
          prepared: prepared,
          manual: manual,
          gen: gen,
        );
      case LookupOutcomeKind.pending:
        final jobId = outcome.jobId;
        if (jobId != null) {
          if (!_current(gen, manual: manual)) return _Run.cancelled;
          final next = AssistJob(
            jobId: jobId,
            reqHash: prepared.hash,
            // The poll window runs from when THIS job was submitted.
            at: job?.jobId == jobId ? job!.at : now,
            nextAt: now.add(pollInterval),
            attempts: job?.attempts ?? 0,
            place: prepared.place,
            manual: manual,
            pick: prepared.pick,
          );
          await _state.putJob(mealId, next);
          _schedulePoll(next);
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
      case LookupOutcomeKind.busy:
      case LookupOutcomeKind.offline:
      case LookupOutcomeKind.failed:
        break;
    }
    // A failed lookup (or a "done" without an answer).
    if (failure?.code == LookupFailureCode.cancelled) return _Run.cancelled;
    final code = _failureCode(outcome);
    await _logFailure(code, provider);
    // Off since: no job, retry record, miss or 'unavailable' is written
    // (Off forgot the jobs; one written now would outlive it).
    if (!_current(gen, manual: manual)) return _Run.cancelled;
    if (failure != null && _recipientFailures.contains(failure.code)) {
      _holdRecipient(support, now);
      return _Run(code, stop: true);
    }
    if (failure?.code == LookupFailureCode.dailyCap) {
      // A day's cap (the app's or the server's): tomorrow. Not a try.
      _backoffUntil = DateTime(now.year, now.month, now.day + 1);
      return _Run(code, stop: true);
    }
    final transient =
        failure == null ||
        failure.transient ||
        outcome.kind == LookupOutcomeKind.busy ||
        outcome.kind == LookupOutcomeKind.rateLimited ||
        outcome.kind == LookupOutcomeKind.offline;
    if (!transient) {
      // Permanent for THIS meal (nothing sendable, a malformed or refused
      // answer): never asked again automatically.
      if (job != null) await _state.removeJob(mealId);
      if (!manual) await _state.addMiss(mealId, denylist: true);
      return _Run(code);
    }
    if (wentBackground || _offline(outcome)) {
      // Not a try: the network was gone, or the app left the foreground
      // mid-call. What the location found is kept (a polled job keeps its
      // id), so the next sweep asks again without reading it twice.
      if (!wentBackground) _backoffUntil = now.add(kAssistTransientBackoff);
      if (!manual || polled) {
        // (The editor's lookup keeps only a job the server still runs.)
        await _state.putJob(
          mealId,
          AssistJob(
            jobId: polled ? job?.jobId : null,
            reqHash: prepared.hash,
            at: job?.at ?? now,
            nextAt: now,
            attempts: job?.attempts ?? 0,
            place: prepared.place,
            manual: manual,
            pick: prepared.pick,
          ),
        );
      }
      return _Run(code, stop: true);
    }
    // A try that failed: busy, rate limited, a timeout, a 5xx.
    _backoffUntil = now.add(kAssistTransientBackoff);
    if (manual) {
      // Shown to the user, not retried: the editor's lookup ends here.
      if (job != null) await _state.removeJob(mealId);
      return _Run(code, stop: true);
    }
    final attempts = (job?.attempts ?? 0) + 1;
    if (attempts > assistMaxRetries) {
      await _state.removeJob(mealId);
      final wrote = await _writeUnavailable(
        snap,
        trigger,
        provider,
        code,
        gen: gen,
      );
      return _Run(AssistSkip.retriesExhausted, wrote: wrote, stop: true);
    }
    await _state.putJob(
      mealId,
      AssistJob(
        reqHash: prepared.hash,
        at: job?.at ?? now,
        nextAt: now.add(assistRetryDelays[attempts - 1]),
        attempts: attempts,
        place: prepared.place,
      ),
    );
    return _Run(code, stop: true);
  }

  /// The meal's last try failed: it is written 'unavailable' (reason: the
  /// last failure's code; no chain, brand, match or source), against the
  /// raw text read before the lookup. False when it changed since (a miss),
  /// is open in a screen, or the mode turned Off since generation [gen].
  Future<bool> _writeUnavailable(
    MealSnapshot snap,
    AssistTrigger trigger,
    String provider,
    String reason, {
    required int gen,
  }) async {
    final meal = snap.meal;
    final next = recordAssistDecision(
      meal.analysis,
      AssistDecision(
        outcome: AssistOutcome.contextOnly,
        status: AssistStatus.unavailable,
        reason: reason,
        trigger: trigger,
        provider: provider == LookupRecipient.none.wire ? '' : provider,
        decidedOn: isoDate(_clock()),
      ),
    );
    if (next == null) return false;
    if (_mealInUse(meal.id)) {
      await _state.addMiss(meal.id);
      return false;
    }
    if (!_current(gen, manual: false)) return false;
    final ok = await _dao.applyAssist(
      meal.id,
      expectedRaw: snap.rawAnalysis,
      analysis: next,
    );
    if (!ok) {
      await _state.addMiss(meal.id);
      return false;
    }
    _signal();
    return true;
  }

  Future<_Run> _decide(
    AssistLookup lookup, {
    required MealSnapshot snap,
    required Map<String, dynamic> base,
    required AssistTrigger trigger,
    required _Prepared prepared,
    required bool manual,
    required int gen,
  }) async {
    final meal = snap.meal;
    final now = _clock();
    final request = prepared.request;
    final place = prepared.place;
    // Read now, not at the sweep's start: an application this sweep just
    // wrote on another meal counts for the 6 h repeat rule.
    final recent = await _dao.mealsBetween(
      isoDate(now.subtract(const Duration(days: 1))),
      isoDate(now),
    );
    // Off while the answer was on its way here: discarded.
    if (!_current(gen, manual: manual)) return _Run.cancelled;
    var decision = decideAssist(
      meal,
      lookup,
      AssistContext(
        now: now,
        trigger: trigger,
        country: prepared.country,
        requestChainKeys: request.chainKeys,
        requestItems: request.items,
        locationChainKeys: place?.chains ?? const [],
        placeChainKey: place?.picked,
        confirmedChainKeys: place?.confirmed ?? const {},
        blockedChainKeys: place?.blocked ?? const {},
        placeVerified: place?.verified ?? false,
        dense: place?.dense ?? false,
        recentApplies: _recentApplies(recent, meal.id),
        userChainKey: prepared.pick,
      ),
    );
    if (decision.outcome == AssistOutcome.apply &&
        await _declinedBefore(decision.chainKey, request)) {
      // The user turned these numbers down for these items at this chain:
      // one tap away, never written by themselves again.
      decision = _asSuggestion(decision, AssistReason.declinedBefore);
    }
    final next = recordAssistDecision(meal.analysis, decision);
    final decided = decision.outcome == AssistOutcome.apply
        ? AssistSkip.applied
        : decision.reason;
    if (!_current(gen, manual: manual)) return _Run.cancelled;
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
    // Right before the write, with no await between: Off now still wins.
    if (!_current(gen, manual: manual)) return _Run.cancelled;
    final ok = await _writeDecision(snap, next, manual: manual);
    if (!ok) {
      // The meal changed while the lookup ran: the result is dropped.
      await _log(decision, AssistSkip.casMiss);
      if (!manual) await _state.addMiss(meal.id);
      return _Run(AssistSkip.casMiss, decision: decision);
    }
    await _log(decision, decided);
    final automatic = decision.outcome == AssistOutcome.apply && !manual;
    // The dot first: the reload the signal starts reads the unseen set.
    if (automatic) await _state.addUnseen(meal.id);
    _signal();
    if (automatic && gen == _generation) {
      _announce(meal.id, decision, base, next);
    }
    return _Run(decided, decision: decision, wrote: true);
  }

  /// [d], an APPLY, as a one-tap suggestion of the same items with
  /// [reason]: nothing in the meal changes until the user accepts it.
  static AssistDecision _asSuggestion(AssistDecision d, String reason) =>
      AssistDecision(
        outcome: AssistOutcome.suggest,
        status: AssistStatus.suggested,
        reason: reason,
        trigger: d.trigger,
        provider: d.provider,
        decidedOn: d.decidedOn,
        evidence: d.evidence,
        chainKey: d.chainKey,
        brandName: d.brandName,
        items: d.items,
        source: d.source,
        sourceType: d.sourceType,
        sourceYear: d.sourceYear,
        grounded: d.grounded,
        notes: d.notes,
      );

  /// The decision's write, against the raw text read before the lookup.
  /// The editor's lookup on a meal the user already corrected writes
  /// through the user's own compare-and-set (corrected stays 1);
  /// everything else through applyAssist, which never sets corrected and
  /// never writes over a corrected meal.
  Future<bool> _writeDecision(
    MealSnapshot snap,
    Map<String, dynamic> next, {
    required bool manual,
  }) => manual && snap.corrected
      ? _dao.updateMealAnalysisIfUnchanged(
          snap.meal.id,
          expectedRaw: snap.rawAnalysis,
          analysis: next,
        )
      : _dao.applyAssist(
          snap.meal.id,
          expectedRaw: snap.rawAnalysis,
          analysis: next,
        );

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
      final key = block is Map ? block['chain_key'] : null;
      // Turned down: these numbers for these items are only ever
      // suggested again.
      await _markCached(
        key is String && chainByKey(key) != null ? key : null,
        applied,
        declined: true,
      );
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

  // ── The editor's actions (R7b) ──

  /// One of the editor's answers to the meal's assist block ([action]),
  /// written as the user's own change: compare-and-set against
  /// [expectedRaw] — the stored text the editor shows — through
  /// updateMealAnalysisIfUnchanged (corrected = 1). The spot is learned in
  /// the backup-excluded places store only where the photo's location may
  /// be read at all ([canLearnPlace]) and the answer teaches something:
  /// 'Not from a restaurant' a zone, 'Wrong restaurant' a blocked chain,
  /// and 'Use published numbers' or 'Correct' a confirmed chain only when
  /// the place step named that chain there (evidence location or
  /// location_confirmed) — a printed brand's numbers say nothing about the
  /// spot. Otherwise nothing is read. The coordinate lives in memory for
  /// the one conversion to a ~100 m cell. 'Wrong restaurant' and 'Not from
  /// a restaurant' still teach the spot when stale stamps leave nothing to
  /// revert. Use AI estimate, Wrong restaurant and Not from a restaurant
  /// mark the cached answer for these items at this chain declined; Use
  /// published numbers and Correct unmark it. One decision-log entry
  /// (codes and kcal only). Never throws.
  Future<AssistActionResult> act(
    int mealId,
    AssistUserAction action, {
    required String expectedRaw,
  }) async {
    try {
      final snap = await _dao.mealSnapshot(mealId);
      if (snap == null || snap.rawAnalysis != expectedRaw) {
        return const AssistActionResult(AssistActionStatus.changed);
      }
      final meal = snap.meal;
      final analysis = meal.analysis;
      final block = analysis['assist'];
      if (block is! Map || block['v'] != kAssistVersion) {
        return const AssistActionResult(AssistActionStatus.nothing);
      }
      final status = block['status'];
      final key = block['chain_key'];
      final chainKey = key is String && chainByKey(key) != null ? key : null;
      Map<String, dynamic>? withdrawn(String reason) =>
          status == AssistStatus.applied
          ? revertAssist(analysis, reason: reason)
          : status == AssistStatus.suggested
          ? declineAssistSuggestion(analysis, reason: reason)
          : null;
      final (next, code) = switch (action) {
        AssistUserAction.useEstimate => (
          revertAssist(analysis),
          AssistReason.userReverted,
        ),
        AssistUserAction.acceptSuggestion => (
          acceptAssistSuggestion(analysis, now: _clock()),
          AssistReason.userAccepted,
        ),
        AssistUserAction.wrongRestaurant => (
          withdrawn(AssistReason.userWrongRestaurant),
          AssistReason.userWrongRestaurant,
        ),
        AssistUserAction.notFromRestaurant => (
          withdrawn(AssistReason.userNotRestaurant),
          AssistReason.userNotRestaurant,
        ),
        AssistUserAction.correct => (null, AssistReason.userConfirmed),
      };
      final placeOnly =
          action == AssistUserAction.correct ||
          action == AssistUserAction.wrongRestaurant ||
          action == AssistUserAction.notFromRestaurant;
      if (next == null && !placeOnly) {
        return const AssistActionResult(AssistActionStatus.nothing);
      }
      if (next == null &&
          action != AssistUserAction.notFromRestaurant &&
          chainKey == null) {
        return const AssistActionResult(AssistActionStatus.nothing);
      }
      if (next != null) {
        final ok = await _dao.updateMealAnalysisIfUnchanged(
          mealId,
          expectedRaw: expectedRaw,
          analysis: next,
        );
        if (!ok) return const AssistActionResult(AssistActionStatus.changed);
      }
      final evidence = AssistEvidenceKind.fromWire(block['evidence']);
      final placeNamedIt =
          evidence == AssistEvidenceKind.location ||
          evidence == AssistEvidenceKind.locationConfirmed;
      // What this answer would teach about the spot; nothing, and the
      // photo's position is not read at all.
      final teaches = switch (action) {
        AssistUserAction.notFromRestaurant => true,
        AssistUserAction.wrongRestaurant => chainKey != null,
        AssistUserAction.acceptSuggestion ||
        AssistUserAction.correct => chainKey != null && placeNamedIt,
        AssistUserAction.useEstimate => false,
      };
      var learned = false;
      final store = _placesStore;
      if (teaches && store != null && canLearnPlace(meal)) {
        final cell = await _photoCell(meal);
        if (cell != null) {
          learned = switch (action) {
            AssistUserAction.notFromRestaurant => await store.addZone(cell),
            AssistUserAction.wrongRestaurant =>
              chainKey != null && await store.block(chainKey, cell),
            AssistUserAction.acceptSuggestion || AssistUserAction.correct =>
              chainKey != null && await store.confirm(chainKey, cell),
            AssistUserAction.useEstimate => false,
          };
        }
      }
      // The answer for these items at this chain: turned down, or taken.
      await _markCached(
        chainKey,
        analysis,
        declined: switch (action) {
          AssistUserAction.useEstimate ||
          AssistUserAction.wrongRestaurant ||
          AssistUserAction.notFromRestaurant => true,
          AssistUserAction.acceptSuggestion ||
          AssistUserAction.correct => false,
        },
      );
      await _state.markSeen(mealId);
      await _state.logDecision(
        AssistDecisionEntry(
          at: _clock(),
          code: code,
          oldKcal: next == null
              ? null
              : safeNumber(analysis['total_calories']).round(),
          newKcal: next == null
              ? null
              : safeNumber(next['total_calories']).round(),
          provider: _providerCode(block['provider']),
        ),
      );
      if (next != null) _signal();
      return AssistActionResult(AssistActionStatus.done, placeLearned: learned);
    } catch (_) {
      return const AssistActionResult(AssistActionStatus.nothing);
    }
  }

  /// Whether the editor's feedback on [meal] may learn the photo's spot
  /// (no read yet): the mode is on, 'Use photo location' is on — Brand
  /// only reads no photo location, whatever an older result was based on
  /// (docs/PRIVACY.md, the consent sheet) — the consent names the
  /// recipient a lookup would reach now (no location is read while the
  /// assist waits for one), the photo's location may be read for this
  /// meal at all (iOS, a recipient that may receive location-derived
  /// chains, GPS, a RESTAURANT meal — [_locationPossible]), and the fix
  /// passes the place step's own gate (no coarse or stale fix becomes a
  /// cell). Never throws.
  bool canLearnPlace(Meal meal) {
    try {
      final s = _readSettings();
      if (_disposed || s.mode == AssistMode.off || !s.useLocation) {
        return false;
      }
      final support = _support();
      if (!s.consentCovers(support)) return false;
      if (!_locationPossible(meal, support)) return false;
      final geo = PhotoGeo.fromCapture(
        meal.analysis['capture'],
        glasses: isMetaGlassesAnalysis(meal.analysis),
      );
      return placeGate(geo).reason == null;
    } catch (_) {
      return false;
    }
  }

  /// The ~100 m cell [meal]'s photo was taken in, or null. The coordinate
  /// is read here and dropped when this returns.
  Future<PlaceCell?> _photoCell(Meal meal) async {
    try {
      final reader = _location;
      if (reader == null) return null;
      final point = await reader.forAsset(meal.fileId);
      if (point == null) return null;
      return PlaceCell.fromLatLon(point.lat, point.lon);
    } catch (_) {
      return null;
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

  /// A code with no lookup behind it (the location path found no chain).
  Future<void> _logCode(String code) =>
      _state.logDecision(AssistDecisionEntry(at: _clock(), code: code));

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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _assist.onBackgrounded();
    }
  }
}
