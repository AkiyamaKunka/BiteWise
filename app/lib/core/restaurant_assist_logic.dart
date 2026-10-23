/// The restaurant assist's ACCEPTANCE, APPLY and REVERT rules — the pure
/// half (stage R2b; design "APPLY policy", "Location-only APPLY", "Source
/// verification details", "Write safety", data_contracts §3 and §5).
///
/// A lookup (data_contracts §5) is the claim of a web-searching model about
/// what a chain publishes. Nothing here trusts it: the published numbers
/// replace the photo model's only when every rule below holds, and
/// otherwise the meal gets a one-tap suggestion, a context-only note, or
/// nothing at all.
///
/// APPLY needs ALL of these (the first one that fails is the decision's
/// reason code, for the diagnostics log):
///   * status found, and a chain_key that was in the request (our table);
///   * the normalized source_url EXACTLY equals a URL the provider's search
///     returned, its host is (a subdomain of) one of that chain's table
///     domains, source_type is official_*, and no date on it (source_year,
///     page_age, a year in its address or title) is more than 24 months old;
///   * the meal: not corrected by the user, no leftover block, portion_state
///     whole, not packaged, logged today (local) and at most 12 h ago, in
///     the US; item→menu-item mapping one-to-one, and no published component
///     that already stands as its own item in the meal;
///   * per covered item: exact_item (components_sum only on an item-brand
///     match); a single published value (no range), no combo or slash
///     alternatives; units agree when the item counts more than one; a
///     drink only with its own printed brand; the item's own printed brand
///     names the chain OR the place step auto-picked this chain at a spot
///     where the user confirmed it, with a verified fix in a non-dense area
///     and a restaurant meal; 0.6–1.7× the photo model's kcal; the macro
///     check (4p+4c+9f within ±35%, skipped for drinks and under 100 kcal);
///     the calorie number found word-bounded in the provider's verbatim
///     text for that exact URL; and not the same chain and menu item
///     applied in the last 6 h.
/// Otherwise items at 0.4–2.5× become a SUGGESTION. A lookup that found
/// nothing, an unusable source or only implausible numbers is CONTEXT ONLY;
/// a malformed lookup, a chain we never asked about, or a chain with no
/// evidence in the meal is REJECTED (nothing is written).
///
/// Writes keep the user's numbers safe ([applyAssist], [revertAssist]):
/// only the covered items' four numbers change (names and
/// meal_description never do), totals move by the same delta, and the
/// assist block stamps each covered item's before and applied values plus
/// the totals, so a revert restores EXACTLY — and refuses (null) once
/// anything changed after the application. A re-application starts from
/// the stamped before values, never from already-replaced numbers.
library;

import 'chain_match.dart';
import 'coerce.dart';
import 'contracts.dart';
import 'restaurant_lookup_contract.dart' show kLookupMaxItems;

// ─── Thresholds (named so the diagnostics log can quote them) ──────────

/// The assist block's schema version (data_contracts §3).
const int kAssistVersion = 2;

/// APPLY band: published kcal ÷ the photo model's kcal, per covered item.
const double kAssistApplyRatioMin = 0.6;
const double kAssistApplyRatioMax = 1.7;

/// SUGGESTION band; outside it the published numbers are implausible for
/// what was photographed and the meal gets context only.
const double kAssistSuggestRatioMin = 0.4;
const double kAssistSuggestRatioMax = 2.5;

/// The macro check: |4p + 4c + 9f − kcal| ≤ this share of kcal.
const double kAssistMacroTolerance = 0.35;

/// Below this many published kcal per serving the macro check is skipped
/// (whole-gram rounding dominates small items).
const int kAssistMacroCheckMinKcal = 100;

/// A source dated more than this many months ago can only be suggested.
const int kAssistSourceMaxAgeMonths = 24;

/// APPLY only for meals logged at most this long ago (and on today's local
/// date); older meals get a suggestion — reviewed days never change
/// silently.
const Duration kAssistApplyMaxMealAge = Duration(hours: 12);

/// The same chain and menu item applied within this window → suggestion.
const Duration kAssistRepeatWindow = Duration(hours: 6);

/// A published calorie value above this is not one menu item.
const int kAssistMaxPublishedKcal = 6000;

/// A published macro above this many grams is garbage.
const num kAssistMaxPublishedGrams = 1000;

/// At most this many options / components are read per match.
const int kAssistMaxOptions = 12;
const int kAssistMaxComponents = 20;

/// Caps (Unicode code points) for text kept from a lookup.
const int kAssistMenuItemMax = 60;
const int kAssistOptionLabelMax = 40;
const int kAssistServingMax = 40;
const int kAssistUnitMax = 20;
const int kAssistNotesMax = 200;
const int kAssistBrandNameMax = 60;
const int kAssistTitleMax = 120;

/// Evidence text read per entry (the server caps at 1,500 characters).
const int kAssistEvidenceTextMax = 20000;

const double _eps = 1e-9;
const double _stampEps = 1e-6;

// ─── Wire vocabularies ─────────────────────────────────────────────────

/// What a decision does.
enum AssistOutcome { apply, suggest, contextOnly, reject }

/// Why a lookup ran (`analysis.assist.trigger`).
enum AssistTrigger {
  autoLowConfidence('auto_low_confidence'),
  autoBranding('auto_branding'),
  always('always'),
  manual('manual');

  const AssistTrigger(this.wire);
  final String wire;

  static AssistTrigger? fromWire(dynamic v) {
    for (final t in values) {
      if (t.wire == v) return t;
    }
    return null;
  }
}

/// What ties the meal to the looked-up chain (`analysis.assist.evidence`).
/// Derived by [decideAssist] for the chain the lookup chose — never taken
/// on the caller's word.
enum AssistEvidenceKind {
  itemBrand('item_brand'),
  orderMerchant('order_merchant'),
  locationConfirmed('location_confirmed'),
  location('location');

  const AssistEvidenceKind(this.wire);
  final String wire;

  static AssistEvidenceKind? fromWire(dynamic v) {
    for (final e in values) {
      if (e.wire == v) return e;
    }
    return null;
  }
}

/// How the user undid an automatic application: 'Undo' on the snackbar
/// (declined) or 'Use AI estimate' in the editor (reverted).
enum AssistRevertKind { reverted, declined }

/// `analysis.assist.status` values (data_contracts §3).
abstract final class AssistStatus {
  static const String applied = 'applied';
  static const String suggested = 'suggested';
  static const String contextOnly = 'context_only';
  static const String notPublished = 'not_published';
  static const String noMatch = 'no_match';
  static const String unavailable = 'unavailable';
  static const String declined = 'declined';
  static const String reverted = 'reverted';
  static const String superseded = 'superseded';

  static const Set<String> all = {
    applied,
    suggested,
    contextOnly,
    notPublished,
    noMatch,
    unavailable,
    declined,
    reverted,
    superseded,
  };
}

/// Reason codes (diagnostics and the assist block; never names or places).
abstract final class AssistReason {
  static const String ok = 'ok';
  static const String userAccepted = 'user_accepted';
  static const String userReverted = 'user_reverted';
  static const String userDeclined = 'user_declined';
  static const String nlCorrection = 'nl_correction';

  // Reject: nothing is written.
  static const String malformed = 'lookup_malformed';
  static const String chainNotRequested = 'chain_not_requested';
  static const String chainBlocked = 'chain_blocked';
  static const String noEvidence = 'no_evidence';
  static const String locationNotRestaurant = 'location_not_restaurant';

  // Context only.
  static const String notPublished = 'not_published';
  static const String noMatch = 'no_match';
  static const String ambiguous = 'ambiguous';
  static const String noUsableMatch = 'no_usable_match';
  static const String sourceNotLaunchable = 'source_not_launchable';
  static const String ratioImplausible = 'ratio_implausible';

  // Suggest: the source.
  static const String sourceNotCited = 'source_not_cited';
  static const String sourceNotOfficial = 'source_not_official';
  static const String sourceTypeNotOfficial = 'source_type_not_official';
  static const String sourceOld = 'source_old';

  // Suggest: the meal.
  static const String mealCorrected = 'meal_corrected';
  static const String hasLeftover = 'has_leftover';
  static const String portionNotWhole = 'portion_not_whole';
  static const String contextPackaged = 'context_packaged';
  static const String notToday = 'not_today';
  static const String mealTimeUnknown = 'meal_time_unknown';
  static const String mealTooOld = 'meal_too_old';
  static const String notUs = 'not_us';
  static const String mappingNotOneToOne = 'mapping_not_one_to_one';
  static const String componentsOverlap = 'components_overlap';

  // Suggest: one item.
  static const String closestItem = 'closest_item';
  static const String combo = 'combo';
  static const String range = 'range';
  static const String unitMismatch = 'unit_mismatch';
  static const String drinkUnbranded = 'drink_unbranded';
  static const String orderMerchantOnly = 'order_merchant_only';
  static const String locationUnconfirmed = 'location_unconfirmed';
  static const String itemUnbranded = 'item_unbranded';
  static const String locationNeedsExactItem = 'location_needs_exact_item';
  static const String ratioOutOfBand = 'ratio_out_of_band';
  static const String macrosMissing = 'macros_missing';
  static const String macroMismatch = 'macro_mismatch';
  static const String notGrounded = 'not_grounded';
  static const String repeat = 'repeat_6h';
}

// ─── Text ──────────────────────────────────────────────────────────────

/// Lookup text as kept (menu_item, option label, serving, notes, chain
/// name): compatibility-folded, control, invisible and bidi characters and
/// every `<` `>` removed, whitespace collapsed, at most [maxChars] code
/// points — the brand cleaner of stage R1. Non-strings are "".
String sanitizeAssistText(dynamic value, int maxChars) =>
    cleanShortText(value, maxChars);

final RegExp _reasonRe = RegExp(r'^[a-z0-9_]{1,40}$');
final RegExp _providerRe = RegExp(r'^[a-z0-9_]{1,20}$');
final RegExp _isoDateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String _code(dynamic v, RegExp re) => v is String && re.hasMatch(v) ? v : '';

// ─── Source verification ───────────────────────────────────────────────

/// The last label must start with a letter (no bare IP addresses); labels
/// are LDH. Anything else — userinfo, a port, `%`, an IDN — fails.
final RegExp _hostRe = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z](?:[a-z0-9-]*[a-z0-9])?$',
);

bool _isAscii(String s) => s.codeUnits.every((c) => c < 0x80);

/// The one form a source URL is compared, stored and launched in: https
/// only, printable ASCII only (an IDN or any raw non-ASCII character is
/// never launchable), host lowercased with one trailing dot and a leading
/// `www.` removed, no userinfo or port, query and fragment dropped, trailing
/// slashes removed; the path keeps its case. Null for anything else.
String? normalizeSourceUrl(dynamic raw) {
  if (raw is! String) return null;
  final s = raw.trim();
  if (s.isEmpty || s.length > 2048) return null;
  // Spaces, controls, a backslash and any non-ASCII character (an IDN
  // host, a raw Unicode path) make a URL unlaunchable.
  for (final c in s.codeUnits) {
    if (c <= 0x20 || c >= 0x7F || c == 0x5C) return null;
  }
  if (!s.toLowerCase().startsWith('https://')) return null;
  var rest = s.substring(8);
  final hash = rest.indexOf('#');
  if (hash >= 0) rest = rest.substring(0, hash);
  final query = rest.indexOf('?');
  if (query >= 0) rest = rest.substring(0, query);
  final slash = rest.indexOf('/');
  var host = (slash >= 0 ? rest.substring(0, slash) : rest).toLowerCase();
  var path = slash >= 0 ? rest.substring(slash) : '';
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.startsWith('www.')) host = host.substring(4);
  if (!_hostRe.hasMatch(host)) return null;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return 'https://$host$path';
}

/// What [verifySource] found out about a claimed source.
final class SourceVerdict {
  const SourceVerdict({
    required this.url,
    required this.host,
    required this.cited,
    required this.official,
    required this.ascii,
  });

  /// The normalized URL; null when the claim is not launchable.
  final String? url;
  final String? host;

  /// The normalized claim EXACTLY equals a normalized URL the provider's
  /// search returned — another page on the same domain is not cited.
  final bool cited;

  /// The host is one of the chain's table domains or a subdomain of one.
  final bool official;

  /// The claim was plain ASCII (an IDN host never is).
  final bool ascii;

  bool get launchable => url != null;
}

/// Screens a claimed [sourceUrl] against the URLs the provider's search
/// returned ([citedUrls], compared normalized) and the table domains of
/// [chainKey]. A lookalike (chipotle-nutrition.com), a host that merely
/// contains the domain (chipotle.com.evil.example) or an IDN is never
/// official.
SourceVerdict verifySource(
  dynamic sourceUrl,
  Iterable<dynamic> citedUrls,
  String? chainKey,
) {
  final url = normalizeSourceUrl(sourceUrl);
  final host = url?.substring(8).split('/').first;
  return SourceVerdict(
    url: url,
    host: host,
    cited: url != null && citedUrls.any((u) => normalizeSourceUrl(u) == url),
    official: host != null && isChainHost(host, chainKey),
    ascii: sourceUrl is String && _isAscii(sourceUrl),
  );
}

/// Whether [number] appears in [evidenceText] as a whole number, the
/// thousands separator optional: 1050 is found in "1050 Cal", "1,050
/// calories" and "1050cal" but not in "11050", "10500", "1050.5" or
/// "1,0500". (Bounded by digits, as the clients lane's citation screen
/// does, so the two agree.) A negative or fractional number never is.
bool grounded(num number, String evidenceText) {
  if (!number.isFinite || number < 0 || number != number.roundToDouble()) {
    return false;
  }
  final digits = '${number.toInt()}';
  final pattern = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromRight = digits.length - i;
    if (i > 0 && fromRight % 3 == 0) pattern.write(',?');
    pattern.write(digits[i]);
  }
  return RegExp(
    '(?<![0-9])(?<![0-9][.,])$pattern(?![0-9])(?![.,][0-9])',
  ).hasMatch(evidenceText);
}

// ─── Numbers ───────────────────────────────────────────────────────────

/// Calories and macros. As an item stamp the keys are estimated_calories /
/// protein_g / carbs_g / fat_g; as published numbers, calories / ….
/// A null is "absent" (an item without that key, or a value the source
/// does not publish).
final class AssistNumbers {
  const AssistNumbers({this.calories, this.proteinG, this.carbsG, this.fatG});

  /// The four numbers of a food item or a stamp map, coerced (a non-number
  /// reads as absent).
  factory AssistNumbers.ofItem(dynamic item) {
    final m = item is Map ? item : const {};
    return AssistNumbers(
      calories: safeNumberOr(m['estimated_calories'], null),
      proteinG: safeNumberOr(m['protein_g'], null),
      carbsG: safeNumberOr(m['carbs_g'], null),
      fatG: safeNumberOr(m['fat_g'], null),
    );
  }

  /// The meal totals of an analysis (total_* keys), coerced.
  factory AssistNumbers.ofTotals(dynamic analysis) {
    final m = analysis is Map ? analysis : const {};
    return AssistNumbers(
      calories: safeNumberOr(m['total_calories'], null),
      proteinG: safeNumberOr(m['total_protein_g'], null),
      carbsG: safeNumberOr(m['total_carbs_g'], null),
      fatG: safeNumberOr(m['total_fat_g'], null),
    );
  }

  final num? calories;
  final num? proteinG;
  final num? carbsG;
  final num? fatG;

  bool get hasMacros => proteinG != null && carbsG != null && fatG != null;

  Map<String, Object?> toItemJson() => {
    'estimated_calories': calories,
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fat_g': fatG,
  };

  Map<String, Object?> toPublishedJson() => {
    'calories': calories,
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fat_g': fatG,
  };

  Map<String, Object?> toTotalsJson() => {
    'total_calories': calories,
    'total_protein_g': proteinG,
    'total_carbs_g': carbsG,
    'total_fat_g': fatG,
  };

  /// Equal value by value (absent == absent), within a tiny tolerance so
  /// a JSON round trip through another formatter (600 → 600.0) still
  /// matches.
  bool sameAs(AssistNumbers o) =>
      _numEq(calories, o.calories) &&
      _numEq(proteinG, o.proteinG) &&
      _numEq(carbsG, o.carbsG) &&
      _numEq(fatG, o.fatG);

  @override
  String toString() =>
      'AssistNumbers($calories, p $proteinG, '
      'c $carbsG, f $fatG)';
}

bool _numEq(num? a, num? b) {
  if (a == null || b == null) return a == null && b == null;
  return (a - b).abs() <= _stampEps;
}

num _round1(num v) => (v * 10).round() / 10;

int? _publishedKcal(dynamic v) {
  if (v is bool || v is! num || !v.isFinite) return null;
  if (v < 0 || v > kAssistMaxPublishedKcal) return null;
  // "Copy exactly": 590.0 is the published 590; 590.5 is no published
  // calorie value.
  if (v != v.roundToDouble()) return null;
  return v.toInt();
}

num? _publishedGrams(dynamic v) {
  if (v is bool || v is! num || !v.isFinite) return null;
  if (v < 0 || v > kAssistMaxPublishedGrams) return null;
  return v;
}

// ─── Tokens and word lists ─────────────────────────────────────────────

String _singular(String t) {
  if (t.length > 3 && t.endsWith('ies')) {
    return '${t.substring(0, t.length - 3)}y';
  }
  for (final suffix in const ['ches', 'shes', 'sses', 'xes']) {
    if (t.length > suffix.length && t.endsWith(suffix)) {
      return t.substring(0, t.length - 2);
    }
  }
  if (t.length > 2 && t.endsWith('s') && !t.endsWith('ss')) {
    return t.substring(0, t.length - 1);
  }
  return t;
}

const Map<String, String> _unitSynonyms = {
  'pc': 'piece',
  'pce': 'piece',
  'ea': 'piece',
  'each': 'piece',
};

/// A unit compared case-, plural- and spelling-insensitively ("Slices" ==
/// "slice", "pcs" == "piece"); "" when there is none.
String _unitKey(dynamic unit) {
  final tokens = chainTokens(cleanUnit(unit));
  if (tokens.isEmpty) return '';
  final key = [
    ...tokens.take(tokens.length - 1),
    _singular(tokens.last),
  ].join(' ');
  return _unitSynonyms[key] ?? key;
}

/// Each token and its singular ("Smoothies" → smoothies, smoothy …), so a
/// word list can name either form.
Set<String> _wordSet(String? text) => {
  for (final t in chainTokens(text)) ...[t, _singular(t)],
};

/// Words that make a menu item a set of several items (a combo meal,
/// a bucket to share) rather than one serving.
const Set<String> _comboWords = {
  'combo',
  'meal',
  'bundle',
  'bucket',
  'platter',
};

/// Drinks the model may forget to flag with is_drink. Treating a food as a
/// drink only ever narrows APPLY (a drink needs its own printed brand).
const Set<String> _drinkWords = {
  'coffee',
  'latte',
  'cappuccino',
  'macchiato',
  'americano',
  'espresso',
  'mocha',
  'frappuccino',
  'frappe',
  'tea',
  'chai',
  'soda',
  'cola',
  'coke',
  'pepsi',
  'sprite',
  'lemonade',
  'juice',
  'smoothie',
  'smoothy',
  'shake',
  'milkshake',
  'refresher',
  'drink',
  'beverage',
  'water',
  'milk',
  'slushie',
  'slushy',
  'slush',
  'horchata',
  'boba',
};

/// Alcohol: kcal ≠ 4p+4c+9f, so the macro check cannot apply.
const Set<String> _alcoholWords = {
  'beer',
  'ale',
  'lager',
  'ipa',
  'stout',
  'porter',
  'pilsner',
  'wine',
  'sangria',
  'margarita',
  'cocktail',
  'mimosa',
  'sake',
  'cider',
  'seltzer',
  'mojito',
  'martini',
  'whiskey',
  'vodka',
  'tequila',
  'rum',
  'bourbon',
};

/// A slash between two words separates alternatives ("Burrito/Bowl",
/// "Regular / Large"); a fraction ("1/2") or a unit conversion ("16 fl oz /
/// 473 mL") is not one.
final RegExp _altSlashRe = RegExp(r'[A-Za-z]\s*/\s*[A-Za-z]');

final RegExp _parenRe = RegExp(r'\([^)]*\)|（[^）]*）|\[[^\]]*\]');

const Set<String> _nameStopWords = {
  'and',
  'with',
  'of',
  'the',
  'a',
  'an',
  'on',
  'in',
  'side',
};

/// An item or component name as a word set, assumed weights in brackets
/// and filler words dropped ("Sour cream (~30 g)" → {sour, cream}).
Set<String> _nameWords(dynamic name) {
  if (name is! String) return const {};
  return {
    for (final t in chainTokens(name.replaceAll(_parenRe, ' ')))
      if (!_nameStopWords.contains(t) && !RegExp(r'^[0-9]+$').hasMatch(t))
        _singular(t),
  };
}

String _menuKey(dynamic name) => chainTokens(name).join(' ');

// ─── Options ───────────────────────────────────────────────────────────

/// One published size or variant, coerced.
final class _Option {
  const _Option({
    required this.index,
    required this.label,
    required this.serving,
    required this.unit,
    required this.calories,
    required this.range,
    required this.published,
  });

  final int index;
  final String label;
  final String serving;
  final String unit;

  /// A single published value, or null for a range.
  final int? calories;
  final List<int>? range;
  final AssistNumbers published;

  /// What the option is compared at: the value, or a range's middle.
  int get kcal => calories ?? ((range![0] + range![1]) / 2).round();
}

_Option? _parseOption(dynamic raw, int index) {
  if (raw is! Map) return null;
  List<int>? range;
  final r = raw['calories_range'];
  if (r is List && r.length == 2) {
    final lo = _publishedKcal(r[0]);
    final hi = _publishedKcal(r[1]);
    if (lo != null && hi != null && lo <= hi) range = [lo, hi];
  }
  // Both a value and a range breaks the contract; the range wins (it can
  // never apply).
  final calories = range == null ? _publishedKcal(raw['calories']) : null;
  if (calories == null && range == null) return null;
  return _Option(
    index: index,
    label: sanitizeAssistText(raw['label'], kAssistOptionLabelMax),
    serving: sanitizeAssistText(raw['serving'], kAssistServingMax),
    unit: sanitizeAssistText(raw['unit'], kAssistUnitMax),
    calories: calories,
    range: range,
    published: AssistNumbers(
      calories: calories,
      proteinG: _publishedGrams(raw['protein_g']),
      carbsG: _publishedGrams(raw['carbs_g']),
      fatG: _publishedGrams(raw['fat_g']),
    ),
  );
}

/// The published size chosen for one photographed item.
final class AssistPick {
  const AssistPick({
    required this.optionIndex,
    required this.label,
    required this.serving,
    required this.unit,
    required this.published,
    required this.caloriesRange,
    required this.multiplier,
    required this.kcal,
    required this.unitsAgree,
    this.components = const [],
  });

  /// The option's position in the match's options; -1 for a
  /// components_sum.
  final int optionIndex;
  final String label;
  final String serving;
  final String unit;

  /// ONE serving as published (calories null for a range). For a
  /// components_sum, the components' sum.
  final AssistNumbers published;

  /// A published range [low, high], or null.
  final List<int>? caloriesRange;

  /// How many servings the photo shows (the item's qty when the units
  /// agree, else 1 or qty, whichever is nearer the photo estimate).
  final num multiplier;

  /// What the pick is compared at: the published value (a range's middle)
  /// × [multiplier].
  final num kcal;

  /// False when the item counts several of something the option does not
  /// count in — the pick can then only be suggested.
  final bool unitsAgree;

  /// components_sum only: each component's published calories (grounding).
  final List<int> components;

  bool get isRange => caloriesRange != null;

  /// The calorie numbers that must be found on the source page.
  List<int> get figures {
    if (optionIndex < 0) return components;
    final range = caloriesRange;
    if (range != null) return range;
    final value = published.calories;
    return value == null ? const [] : [value.toInt()];
  }
}

num? _visionKcal(dynamic item) {
  final v = safeNumberOr(item is Map ? item['estimated_calories'] : null, null);
  return v != null && v > 0 ? v : null;
}

AssistPick? _pickFrom(
  dynamic item,
  List<_Option> options, {
  List<int> components = const [],
}) {
  final vision = _visionKcal(item);
  if (vision == null || options.isEmpty) return null;
  final fields = itemContextFields(item);
  final qty = fields.qty;
  final single = (qty - 1).abs() < _eps;
  final itemUnit = _unitKey(fields.unit);
  final candidates = <AssistPick>[];
  void add(_Option o, num multiplier, bool agree) => candidates.add(
    AssistPick(
      optionIndex: components.isEmpty ? o.index : -1,
      label: o.label,
      serving: o.serving,
      unit: o.unit,
      published: o.published,
      caloriesRange: o.range,
      multiplier: multiplier,
      kcal: o.kcal * multiplier,
      unitsAgree: agree,
      components: components,
    ),
  );
  for (final o in options) {
    if (single) {
      add(o, 1, true);
    } else if (itemUnit.isNotEmpty && _unitKey(o.unit) == itemUnit) {
      add(o, qty, true);
    } else {
      // The option counts in something else: it may be per piece or the
      // whole order. Both are candidates; neither can apply.
      add(o, 1, false);
      add(o, qty, false);
    }
  }
  candidates.sort((a, b) {
    final d = (a.kcal - vision).abs().compareTo((b.kcal - vision).abs());
    if (d != 0) return d;
    if (a.isRange != b.isRange) return a.isRange ? 1 : -1;
    if (a.unitsAgree != b.unitsAgree) return a.unitsAgree ? -1 : 1;
    final k = a.kcal.compareTo(b.kcal);
    if (k != 0) return k;
    return a.optionIndex.compareTo(b.optionIndex);
  });
  return candidates.first;
}

/// The published option nearest the photographed [item]'s kcal (its
/// estimated_calories, the TOTAL for its qty). When the item counts more
/// than one (qty ≠ 1), an option counted in the same unit is multiplied by
/// qty; an option in another or no unit is tried at 1× and at qty× and
/// flagged [AssistPick.unitsAgree] false. Ties go to a single value over a
/// range, then to agreeing units, then to the smaller value. Null when the
/// item has no positive kcal or no option carries a usable number.
AssistPick? pickOption(dynamic item, dynamic options) {
  final parsed = <_Option>[];
  var i = 0;
  for (final raw in (options is List ? options : const []).take(
    kAssistMaxOptions,
  )) {
    final o = _parseOption(raw, i++);
    if (o != null) parsed.add(o);
  }
  return _pickFrom(item, parsed);
}

/// A components_sum match as one pick: every component must publish
/// calories; macros are summed only when every component publishes all
/// three.
AssistPick? _pickComponents(dynamic item, dynamic components) {
  final list = (components is List ? components : const [])
      .take(kAssistMaxComponents)
      .toList();
  if (list.isEmpty) return null;
  var kcal = 0;
  num p = 0, c = 0, f = 0;
  var macros = true;
  final figures = <int>[];
  for (final raw in list) {
    if (raw is! Map) return null;
    final k = _publishedKcal(raw['calories']);
    if (k == null) return null;
    kcal += k;
    figures.add(k);
    final pp = _publishedGrams(raw['protein_g']);
    final cc = _publishedGrams(raw['carbs_g']);
    final ff = _publishedGrams(raw['fat_g']);
    if (pp == null || cc == null || ff == null) {
      macros = false;
    } else {
      p += pp;
      c += cc;
      f += ff;
    }
  }
  if (kcal > kAssistMaxPublishedKcal) return null;
  final sum = _Option(
    index: -1,
    label: '',
    serving: '',
    unit: '',
    calories: kcal,
    range: null,
    published: AssistNumbers(
      calories: kcal,
      proteinG: macros ? _round1(p) : null,
      carbsG: macros ? _round1(c) : null,
      fatG: macros ? _round1(f) : null,
    ),
  );
  return _pickFrom(item, [sum], components: figures);
}

/// What applying [pick] writes over [before]: kcal rounded; each macro the
/// published one × multiplier, or — when the source publishes none — the
/// item's own macro scaled by the same kcal ratio.
AssistNumbers _proposed(AssistPick pick, AssistNumbers before) {
  final kcal = pick.kcal.round();
  final old = before.calories;
  num? macro(num? published, num? mine) {
    if (published != null) return _round1(published * pick.multiplier);
    if (mine == null) return null;
    if (old == null || old <= 0) return mine;
    return _round1(mine * kcal / old);
  }

  return AssistNumbers(
    calories: kcal,
    proteinG: macro(pick.published.proteinG, before.proteinG),
    carbsG: macro(pick.published.carbsG, before.carbsG),
    fatG: macro(pick.published.fatG, before.fatG),
  );
}

// ─── Source dates ──────────────────────────────────────────────────────

final RegExp _yearRe = RegExp(r'(?<![0-9])(19[9][0-9]|20[0-9]{2})(?![0-9])');
final RegExp _monthDateRe = RegExp(
  r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+'
  r'(\d{1,2}),?\s+(\d{4})\b',
  caseSensitive: false,
);
const List<String> _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// Every date a source shows: a full page_age date, or January 1 of any
/// year in [text] (conservative: a bare year counts from its start).
/// Years after next year are ignored as noise.
List<DateTime> _datesIn(String? text, DateTime now) {
  if (text == null || text.isEmpty) return const [];
  final out = <DateTime>[];
  final iso = DateTime.tryParse(text.trim());
  if (iso != null) return [iso];
  for (final m in _monthDateRe.allMatches(text)) {
    final month = _months.indexOf(m.group(1)!.toLowerCase()) + 1;
    final y = int.parse(m.group(3)!);
    if (y <= now.year + 1) out.add(DateTime(y, month, int.parse(m.group(2)!)));
  }
  if (out.isNotEmpty) return out;
  for (final m in _yearRe.allMatches(text)) {
    final y = int.parse(m.group(1)!);
    if (y <= now.year + 1) out.add(DateTime(y));
  }
  return out;
}

// ─── Inputs ────────────────────────────────────────────────────────────

/// One piece of grounding text a provider returned for one URL.
final class AssistEvidence {
  const AssistEvidence({
    required this.url,
    required this.text,
    this.verbatim = true,
    this.pageAge,
  });

  final String url;
  final String text;

  /// True when the provider's search system extracted [text] FROM THE PAGE
  /// (Anthropic cited_text, OpenRouter/Exa content, the server's WebSearch
  /// result text). A span of the model's own answer is not, and never
  /// grounds a number.
  final bool verbatim;

  /// The page date the search reported (Anthropic page_age), if any.
  final String? pageAge;
}

/// A finished lookup: the §5 object as decoded, plus what the provider's
/// search returned.
final class AssistLookup {
  const AssistLookup({
    required this.result,
    required this.provider,
    this.citedUrls = const [],
    this.evidence = const [],
  });

  final Object? result;

  /// `analysis.assist.provider`: claude_plan | anthropic | openrouter.
  final String provider;
  final List<String> citedUrls;
  final List<AssistEvidence> evidence;
}

/// An earlier automatic or accepted application (any meal but this one).
final class AssistRecentApply {
  const AssistRecentApply({
    required this.chainKey,
    required this.menuItem,
    required this.at,
  });

  final String chainKey;
  final String menuItem;
  final DateTime at;
}

/// The facts [decideAssist] needs besides the meal and the lookup. The
/// caller reports what it KNOWS; the evidence kind is derived here for the
/// chain the lookup actually chose.
final class AssistContext {
  const AssistContext({
    required this.now,
    required this.trigger,
    this.country,
    this.requestChainKeys = const [],
    this.locationChainKeys = const [],
    this.placeChainKey,
    this.confirmedChainKeys = const {},
    this.blockedChainKeys = const {},
    this.placeVerified = false,
    this.dense = false,
    this.recentApplies = const [],
  });

  /// The device clock, local time.
  final DateTime now;
  final AssistTrigger trigger;

  /// Where the meal was eaten, ISO2; null when unknown (never applies).
  final String? country;

  /// The chain keys the request named, in rank order (LookupRequest
  /// .chainKeys). A lookup that picks any other chain is rejected.
  final List<String> requestChainKeys;

  /// Of those, the chains that came from the photo's location.
  final List<String> locationChainKeys;

  /// The chain the place step AUTO-PICKED (a single chain within 2σ, not
  /// dense), or null.
  final String? placeChainKey;

  /// Chains the user confirmed in this ~100 m cell ('Correct' or an
  /// accepted suggestion).
  final Set<String> confirmedChainKeys;

  /// Chains the user blocked in this cell ('Wrong restaurant'): their
  /// location evidence does not count.
  final Set<String> blockedChainKeys;

  /// The photo's location fix is trusted (fresh, or a verified glasses
  /// fix). An unverified fix only ever suggests.
  final bool placeVerified;

  /// The dense-area guard tripped: location never confirms anything.
  final bool dense;

  /// Applications on OTHER meals (this meal's own is re-based instead).
  final List<AssistRecentApply> recentApplies;
}

// ─── The decision ──────────────────────────────────────────────────────

/// The verdict for one looked-up item.
final class AssistItemDecision {
  const AssistItemDecision({
    required this.itemIndex,
    required this.menuItem,
    required this.matchType,
    required this.isDrink,
    required this.pick,
    required this.before,
    required this.proposed,
    required this.ratio,
    required this.grounded,
    required this.applyOk,
    required this.suggestOk,
    required this.reason,
  });

  /// The position in the meal's food_items (= the request's items).
  final int itemIndex;
  final String menuItem;
  final String matchType;
  final bool isDrink;
  final AssistPick pick;

  /// The item's numbers the decision compared against (the stamped
  /// before values when an earlier application is re-based).
  final AssistNumbers before;

  /// What applying writes.
  final AssistNumbers proposed;

  /// pick.kcal ÷ the photo model's kcal.
  final double ratio;

  /// Every figure of the pick was found in verbatim text for the source.
  final bool grounded;
  final bool applyOk;
  final bool suggestOk;

  /// [AssistReason.ok], or the first item rule that blocked APPLY.
  final String reason;
}

/// What to do with one lookup for one meal.
final class AssistDecision {
  const AssistDecision({
    required this.outcome,
    required this.status,
    required this.reason,
    required this.trigger,
    required this.provider,
    required this.decidedOn,
    this.evidence,
    this.chainKey,
    this.brandName = '',
    this.items = const [],
    this.source,
    this.sourceType = 'other',
    this.sourceYear,
    this.grounded = false,
    this.notes = '',
  });

  final AssistOutcome outcome;

  /// The `analysis.assist.status` this decision writes; "" for a reject.
  final String status;
  final String reason;
  final AssistTrigger trigger;
  final String provider;

  /// YYYY-MM-DD (local) of the decision.
  final String decidedOn;
  final AssistEvidenceKind? evidence;
  final String? chainKey;

  /// The chain's name from OUR table (never the model's spelling).
  final String brandName;

  /// The covered items: apply → the items that passed every rule;
  /// suggest → the items inside the suggestion band; otherwise empty.
  final List<AssistItemDecision> items;
  final SourceVerdict? source;

  /// official | third_party | other — official only when the model said
  /// so AND the host is the chain's own.
  final String sourceType;

  /// The OLDEST year the source shows (claimed, in its address or title,
  /// or its page date), or null.
  final int? sourceYear;

  /// Every covered figure was found on the source page.
  final bool grounded;
  final String notes;

  /// For the decision log (codes and kcal only).
  int get oldKcal =>
      items.fold<num>(0, (s, i) => s + (i.before.calories ?? 0)).round();
  int get newKcal =>
      items.fold<num>(0, (s, i) => s + (i.proposed.calories ?? 0)).round();
}

AssistDecision _terminal(
  AssistOutcome outcome,
  String status,
  String reason,
  AssistContext ctx,
  String provider, {
  AssistEvidenceKind? evidence,
}) => AssistDecision(
  outcome: outcome,
  status: status,
  reason: reason,
  trigger: ctx.trigger,
  provider: provider,
  decidedOn: isoDate(ctx.now),
  evidence: evidence,
);

/// Decides what a finished [lookup] may do to [meal] (see the library
/// doc for the policy). Pure and total: any shape of lookup, meal or
/// context yields a decision, never an exception.
AssistDecision decideAssist(Meal meal, AssistLookup lookup, AssistContext ctx) {
  final provider = _code(lookup.provider, _providerRe);
  final r = lookup.result;
  final status = r is Map ? r['status'] : null;
  if (r is! Map ||
      status is! String ||
      !const {
        'found',
        'not_published',
        'no_match',
        'ambiguous',
      }.contains(status)) {
    return _terminal(
      AssistOutcome.reject,
      '',
      AssistReason.malformed,
      ctx,
      provider,
    );
  }
  final rawKey = r['chain_key'];
  final chainKey =
      rawKey is String &&
          chainByKey(rawKey) != null &&
          ctx.requestChainKeys.contains(rawKey)
      ? rawKey
      : null;
  if (status == 'not_published') {
    return _terminal(
      AssistOutcome.contextOnly,
      AssistStatus.notPublished,
      AssistReason.notPublished,
      ctx,
      provider,
    );
  }
  if (status != 'found') {
    return _terminal(
      AssistOutcome.contextOnly,
      AssistStatus.noMatch,
      status == 'ambiguous' ? AssistReason.ambiguous : AssistReason.noMatch,
      ctx,
      provider,
    );
  }
  if (chainKey == null) {
    return _terminal(
      AssistOutcome.reject,
      '',
      AssistReason.chainNotRequested,
      ctx,
      provider,
    );
  }
  final chain = chainByKey(chainKey)!;

  // The meal as the decision sees it: an earlier, still-intact application
  // is re-based on its stamped before values.
  final base = assistBase(meal.analysis);
  final fields = mealContextFields(base);
  final rawItems = base['food_items'] is List
      ? base['food_items'] as List
      : const [];
  final itemCount = rawItems.length < kLookupMaxItems
      ? rawItems.length
      : kLookupMaxItems;

  // ── Evidence for THIS chain ──
  final brandItems = <int>{
    for (var i = 0; i < itemCount; i++)
      if (rawItems[i] is Map &&
          matchChain(itemContextFields(rawItems[i]).brand) == chainKey)
        i,
  };
  final merchant =
      fields.orderMerchant.isNotEmpty &&
      matchChain(fields.orderMerchant) == chainKey;
  final isRestaurant = fields.restaurantContext == RestaurantContext.restaurant;
  final fromLocation = ctx.locationChainKeys.contains(chainKey);
  final blocked = ctx.blockedChainKeys.contains(chainKey);
  final locationChain = fromLocation && isRestaurant && !blocked;
  final locationConfirmed =
      locationChain &&
      ctx.placeChainKey == chainKey &&
      ctx.confirmedChainKeys.contains(chainKey) &&
      ctx.placeVerified &&
      !ctx.dense;
  final AssistEvidenceKind? evidence = brandItems.isNotEmpty
      ? AssistEvidenceKind.itemBrand
      : locationConfirmed
      ? AssistEvidenceKind.locationConfirmed
      : merchant
      ? AssistEvidenceKind.orderMerchant
      : locationChain
      ? AssistEvidenceKind.location
      : null;
  if (evidence == null) {
    final reason = !fromLocation
        ? AssistReason.noEvidence
        : blocked
        ? AssistReason.chainBlocked
        : AssistReason.locationNotRestaurant;
    return _terminal(AssistOutcome.reject, '', reason, ctx, provider);
  }

  // ── The source ──
  final src = verifySource(r['source_url'], lookup.citedUrls, chainKey);
  if (!src.launchable) {
    return _terminal(
      AssistOutcome.contextOnly,
      AssistStatus.contextOnly,
      AssistReason.sourceNotLaunchable,
      ctx,
      provider,
      evidence: evidence,
    );
  }
  final evidenceText = StringBuffer();
  final dates = <DateTime>[
    ..._datesIn(
      sanitizeAssistText(r['source_title'], kAssistTitleMax),
      ctx.now,
    ),
    ..._datesIn(src.url, ctx.now),
  ];
  final claimedYear = r['source_year'];
  if (claimedYear is int &&
      claimedYear >= 1990 &&
      claimedYear <= ctx.now.year + 1) {
    dates.add(DateTime(claimedYear));
  }
  for (final e in lookup.evidence) {
    if (normalizeSourceUrl(e.url) != src.url) continue;
    if (e.verbatim) {
      final t = e.text;
      evidenceText
        ..write(
          t.length > kAssistEvidenceTextMax
              ? t.substring(0, kAssistEvidenceTextMax)
              : t,
        )
        ..write('\n');
    }
    dates.addAll(_datesIn(e.pageAge, ctx.now));
  }
  DateTime? oldest;
  for (final d in dates) {
    if (oldest == null || d.isBefore(oldest)) oldest = d;
  }
  final cutoff = DateTime(
    ctx.now.year,
    ctx.now.month - kAssistSourceMaxAgeMonths,
    ctx.now.day,
  );
  final sourceOld = oldest != null && oldest.isBefore(cutoff);
  final rawType = r['source_type'];
  final typeOfficial =
      rawType == 'official_site' ||
      rawType == 'official_pdf' ||
      rawType == 'official_app';
  final sourceType = typeOfficial && src.official
      ? 'official'
      : rawType == 'third_party_db'
      ? 'third_party'
      : 'other';

  // ── Matches ──
  final rawMatches = r['matches'] is List ? r['matches'] as List : const [];
  final parsed =
      <
        ({
          int index,
          String menuItem,
          String matchType,
          bool isDrinkFlag,
          Map raw,
        })
      >[];
  final seenIndex = <int>{};
  final seenMenu = <String>{};
  var oneToOne = true;
  for (final m in rawMatches.take(kLookupMaxItems)) {
    if (m is! Map) continue;
    final idx = m['item_index'];
    final type = m['match_type'];
    final menu = sanitizeAssistText(m['menu_item'], kAssistMenuItemMax);
    if (idx is! int || idx < 0 || idx >= itemCount || rawItems[idx] is! Map) {
      continue;
    }
    if (type != 'exact_item' &&
        type != 'closest_item' &&
        type != 'components_sum') {
      continue;
    }
    if (menu.isEmpty) continue;
    if (!seenIndex.add(idx)) {
      oneToOne = false;
      continue;
    }
    if (!seenMenu.add(_menuKey(menu))) oneToOne = false;
    parsed.add((
      index: idx,
      menuItem: menu,
      matchType: type as String,
      isDrinkFlag: m['is_drink'] == true,
      raw: m,
    ));
  }

  // A published component that also stands as its own item in the meal
  // (the bowl's sour cream logged as a separate line) would count twice.
  var overlap = false;
  for (final p in parsed) {
    if (p.matchType != 'components_sum') continue;
    final comps = p.raw['components'];
    for (final c in (comps is List ? comps : const []).take(
      kAssistMaxComponents,
    )) {
      final cw = _nameWords(c is Map ? c['name'] : null);
      if (cw.isEmpty) continue;
      for (var j = 0; j < itemCount && !overlap; j++) {
        if (j == p.index) continue;
        final item = rawItems[j];
        final iw = _nameWords(item is Map ? item['name'] : null);
        if (iw.isEmpty) continue;
        if (iw.containsAll(cw) || cw.containsAll(iw)) overlap = true;
      }
    }
  }

  // ── Meal-level APPLY gates (any one → suggestion at most) ──
  String? mealReason;
  final mealAt = DateTime.tryParse(meal.timestamp);
  if (!src.cited) {
    mealReason = AssistReason.sourceNotCited;
  } else if (!src.official) {
    mealReason = AssistReason.sourceNotOfficial;
  } else if (!typeOfficial) {
    mealReason = AssistReason.sourceTypeNotOfficial;
  } else if (sourceOld) {
    mealReason = AssistReason.sourceOld;
  } else if (meal.corrected) {
    mealReason = AssistReason.mealCorrected;
  } else if (base['leftover'] is Map) {
    mealReason = AssistReason.hasLeftover;
  } else if (fields.portionState != PortionState.whole) {
    mealReason = AssistReason.portionNotWhole;
  } else if (fields.restaurantContext == RestaurantContext.packaged) {
    mealReason = AssistReason.contextPackaged;
  } else if (meal.date != isoDate(ctx.now)) {
    mealReason = AssistReason.notToday;
  } else if (mealAt == null) {
    mealReason = AssistReason.mealTimeUnknown;
  } else if (ctx.now.difference(mealAt).abs() > kAssistApplyMaxMealAge) {
    mealReason = AssistReason.mealTooOld;
  } else if ((ctx.country ?? '').toUpperCase() != 'US') {
    mealReason = AssistReason.notUs;
  } else if (!oneToOne) {
    mealReason = AssistReason.mappingNotOneToOne;
  } else if (overlap) {
    mealReason = AssistReason.componentsOverlap;
  }

  // ── Per item ──
  final evaluated = <AssistItemDecision>[];
  for (final p in parsed) {
    final item = rawItems[p.index] as Map;
    final before = AssistNumbers.ofItem(item);
    final vision = _visionKcal(item);
    final pick = p.matchType == 'components_sum'
        ? _pickComponents(item, p.raw['components'])
        : pickOption(item, p.raw['options']);
    if (pick == null || vision == null) continue;
    final ratio = (pick.kcal / vision).toDouble();
    final words = _wordSet(p.menuItem);
    final alcohol = words.any(_alcoholWords.contains);
    final isDrink = p.isDrinkFlag || alcohol || words.any(_drinkWords.contains);
    final ownBrand = brandItems.contains(p.index);
    final figures = pick.figures;
    final isGrounded =
        figures.isNotEmpty &&
        figures.every((f) => grounded(f, evidenceText.toString()));
    final perServing = pick.published.calories ?? pick.kcal / pick.multiplier;
    final skipMacros =
        p.isDrinkFlag || alcohol || perServing < kAssistMacroCheckMinKcal;
    final pub = pick.published;
    final menuKey = _menuKey(p.menuItem);
    final repeat = ctx.recentApplies.any(
      (a) =>
          a.chainKey == chainKey &&
          _menuKey(a.menuItem) == menuKey &&
          ctx.now.difference(a.at) < kAssistRepeatWindow,
    );
    final comboText = [p.menuItem, pick.label];

    String reason;
    if (p.matchType == 'closest_item') {
      reason = AssistReason.closestItem;
    } else if (comboText.any(
      (t) => _altSlashRe.hasMatch(t) || _wordSet(t).any(_comboWords.contains),
    )) {
      reason = AssistReason.combo;
    } else if (pick.isRange) {
      reason = AssistReason.range;
    } else if (!pick.unitsAgree) {
      reason = AssistReason.unitMismatch;
    } else if (isDrink && !ownBrand) {
      reason = AssistReason.drinkUnbranded;
    } else if (!ownBrand && !locationConfirmed) {
      reason = switch (evidence) {
        AssistEvidenceKind.orderMerchant => AssistReason.orderMerchantOnly,
        AssistEvidenceKind.location => AssistReason.locationUnconfirmed,
        _ => AssistReason.itemUnbranded,
      };
    } else if (!ownBrand && p.matchType != 'exact_item') {
      reason = AssistReason.locationNeedsExactItem;
    } else if (ratio < kAssistApplyRatioMin - _eps ||
        ratio > kAssistApplyRatioMax + _eps) {
      reason = AssistReason.ratioOutOfBand;
    } else if (!skipMacros && !pub.hasMacros) {
      reason = AssistReason.macrosMissing;
    } else if (!skipMacros &&
        (4 * pub.proteinG! + 4 * pub.carbsG! + 9 * pub.fatG! - perServing)
                .abs() >
            kAssistMacroTolerance * perServing) {
      reason = AssistReason.macroMismatch;
    } else if (!isGrounded) {
      reason = AssistReason.notGrounded;
    } else if (repeat) {
      reason = AssistReason.repeat;
    } else {
      reason = AssistReason.ok;
    }
    evaluated.add(
      AssistItemDecision(
        itemIndex: p.index,
        menuItem: p.menuItem,
        matchType: p.matchType,
        isDrink: isDrink,
        pick: pick,
        before: before,
        proposed: _proposed(pick, before),
        ratio: ratio,
        grounded: isGrounded,
        applyOk: mealReason == null && reason == AssistReason.ok,
        suggestOk:
            ratio >= kAssistSuggestRatioMin - _eps &&
            ratio <= kAssistSuggestRatioMax + _eps,
        reason: reason,
      ),
    );
  }

  AssistDecision covering(
    AssistOutcome outcome,
    String status,
    String reason,
    List<AssistItemDecision> items,
  ) => AssistDecision(
    outcome: outcome,
    status: status,
    reason: reason,
    trigger: ctx.trigger,
    provider: provider,
    decidedOn: isoDate(ctx.now),
    evidence: evidence,
    chainKey: chainKey,
    brandName: sanitizeAssistText(chain.name, kAssistBrandNameMax),
    items: List.unmodifiable(items),
    source: src,
    sourceType: sourceType,
    sourceYear: oldest?.year,
    grounded: items.isNotEmpty && items.every((i) => i.grounded),
    notes: sanitizeAssistText(r['notes'], kAssistNotesMax),
  );

  if (evaluated.isEmpty) {
    return _terminal(
      AssistOutcome.contextOnly,
      AssistStatus.contextOnly,
      AssistReason.noUsableMatch,
      ctx,
      provider,
      evidence: evidence,
    );
  }
  final applying = [
    for (final e in evaluated)
      if (e.applyOk) e,
  ];
  if (applying.isNotEmpty) {
    return covering(
      AssistOutcome.apply,
      AssistStatus.applied,
      AssistReason.ok,
      applying,
    );
  }
  final suggesting = [
    for (final e in evaluated)
      if (e.suggestOk) e,
  ];
  if (suggesting.isEmpty) {
    return _terminal(
      AssistOutcome.contextOnly,
      AssistStatus.contextOnly,
      AssistReason.ratioImplausible,
      ctx,
      provider,
      evidence: evidence,
    );
  }
  // With no meal-level reason, a suggested item always carries its own
  // (an item that passed everything would have been applied).
  final reason =
      mealReason ??
      suggesting
          .map((e) => e.reason)
          .firstWhere(
            (x) => x != AssistReason.ok,
            orElse: () => AssistReason.ok,
          );
  return covering(
    AssistOutcome.suggest,
    AssistStatus.suggested,
    reason,
    suggesting,
  );
}

// ─── Stamps, base, apply, revert ───────────────────────────────────────

Map? _block(dynamic analysis) {
  if (analysis is! Map) return null;
  final b = analysis['assist'];
  return b is Map && b['v'] == kAssistVersion ? b : null;
}

/// The covered items of a block as (index, stamp) pairs, or null when any
/// entry is malformed or repeats an index.
List<({int index, Map stamp, Map before})>? _stamps(
  Map block,
  List rawItems,
  String stampKey,
) {
  final matches = block['matches'];
  if (matches is! List || matches.isEmpty) return null;
  final seen = <int>{};
  final out = <({int index, Map stamp, Map before})>[];
  for (final m in matches) {
    if (m is! Map) return null;
    final idx = m['item_index'];
    final stamp = m[stampKey];
    final before = m['before'];
    if (idx is! int || idx < 0 || idx >= rawItems.length) return null;
    if (rawItems[idx] is! Map || stamp is! Map || before is! Map) return null;
    if (!seen.add(idx)) return null;
    out.add((index: idx, stamp: stamp, before: before));
  }
  return out;
}

/// True while the meal still shows exactly what its assist block stamped:
/// for an APPLIED block, every covered item's four numbers equal the
/// applied stamps and the totals equal the applied totals; for a
/// SUGGESTED block, every covered item still equals its before stamp. Any
/// edit, leftover or correction since makes it false — the chip, the
/// Undo and the revert exist only while this holds.
bool assistStampValid(dynamic analysis) {
  final block = _block(analysis);
  if (block == null) return false;
  final raw = (analysis as Map)['food_items'];
  if (raw is! List) return false;
  final status = block['status'];
  if (status == AssistStatus.applied) {
    final stamps = _stamps(block, raw, 'applied');
    if (stamps == null) return false;
    for (final s in stamps) {
      if (!AssistNumbers.ofItem(
        raw[s.index],
      ).sameAs(AssistNumbers.ofItem(s.stamp))) {
        return false;
      }
    }
    final totals = block['totals'];
    if (totals is! Map || totals['before'] is! Map) return false;
    final applied = totals['applied'];
    if (applied is! Map) return false;
    final current = AssistNumbers.ofTotals(analysis);
    if (!current.sameAs(AssistNumbers.ofTotals(applied))) return false;
    return _numEq(current.calories, safeNumberOr(block['applied_total'], null));
  }
  if (status == AssistStatus.suggested) {
    final stamps = _stamps(block, raw, 'before');
    if (stamps == null) return false;
    return stamps.every(
      (s) => AssistNumbers.ofItem(
        raw[s.index],
      ).sameAs(AssistNumbers.ofItem(s.before)),
    );
  }
  return false;
}

void _writeNumbers(Map<String, dynamic> target, Map<String, Object?> values) {
  for (final e in values.entries) {
    if (e.value == null) {
      target.remove(e.key);
    } else {
      target[e.key] = e.value;
    }
  }
}

/// [analysis] with an intact applied block undone: covered items back to
/// their before stamps (without `published`), totals back to the stamped
/// before totals, and no assist block. Assumes [assistStampValid].
Map<String, dynamic> _restore(Map analysis, Map block) {
  final raw = analysis['food_items'] as List;
  final items = [
    for (final e in raw) e is Map ? Map<String, dynamic>.from(e) : e,
  ];
  for (final s in _stamps(block, raw, 'applied')!) {
    final item = items[s.index] as Map<String, dynamic>;
    _writeNumbers(item, AssistNumbers.ofItem(s.before).toItemJson());
    item.remove('published');
  }
  final out = Map<String, dynamic>.from(analysis)
    ..['food_items'] = items
    ..remove('assist');
  _writeNumbers(
    out,
    AssistNumbers.ofTotals((block['totals'] as Map)['before']).toTotalsJson(),
  );
  return out;
}

/// The analysis a decision compares against and an application starts
/// from: with an intact APPLIED block, the meal as it was before that
/// application (so a second lookup never stacks on replaced numbers);
/// otherwise [analysis] itself.
Map<String, dynamic> assistBase(Map<String, dynamic> analysis) {
  final block = _block(analysis);
  if (block != null &&
      block['status'] == AssistStatus.applied &&
      assistStampValid(analysis)) {
    return _restore(analysis, block);
  }
  return analysis;
}

Map<String, Object?> _matchJson(AssistItemDecision d, {required bool applied}) {
  final p = d.pick;
  return {
    'item_index': d.itemIndex,
    'menu_item': d.menuItem,
    'match_type': d.matchType,
    'option_label': p.label,
    'serving': p.serving,
    'qty': p.multiplier,
    'published': p.published.toPublishedJson(),
    if (p.caloriesRange != null) 'calories_range': p.caloriesRange,
    'before': d.before.toItemJson(),
    if (applied) 'applied': d.proposed.toItemJson(),
  };
}

Map<String, Object?> _header(AssistDecision d, String status) => {
  'v': kAssistVersion,
  'status': status,
  'trigger': d.trigger.wire,
  if (d.evidence != null) 'evidence': d.evidence!.wire,
};

Map<String, Object?> _sourceJson(AssistDecision d) => {
  'url': d.source?.url,
  'host': d.source?.host,
  'type': d.sourceType,
  'year': d.sourceYear,
};

/// Writes an APPLY decision — or a suggestion the user accepted — into
/// [analysis]. Starts from [assistBase] (a re-application keeps the FIRST
/// before values), and returns null — write nothing — unless every
/// covered item there still holds the numbers the decision compared
/// against. Only the covered items' four numbers change and they gain
/// `published: true` (any other item loses a stale flag); names,
/// meal_description and every other key stay byte-identical; totals move
/// by the covered items' delta. The block stamps before/applied per item
/// and the totals, for [revertAssist].
Map<String, dynamic>? applyAssist(
  Map<String, dynamic> analysis,
  AssistDecision decision,
) {
  if (decision.outcome != AssistOutcome.apply &&
      decision.outcome != AssistOutcome.suggest) {
    return null;
  }
  if (decision.items.isEmpty || decision.chainKey == null) return null;
  final base = assistBase(analysis);
  final raw = base['food_items'];
  if (raw is! List) return null;
  final seen = <int>{};
  for (final d in decision.items) {
    if (d.itemIndex < 0 ||
        d.itemIndex >= raw.length ||
        raw[d.itemIndex] is! Map ||
        !seen.add(d.itemIndex) ||
        !AssistNumbers.ofItem(raw[d.itemIndex]).sameAs(d.before)) {
      return null;
    }
  }
  final items = <dynamic>[
    for (final e in raw)
      e is Map ? (Map<String, dynamic>.from(e)..remove('published')) : e,
  ];
  num dk = 0, dp = 0, dc = 0, df = 0;
  for (final d in decision.items) {
    final item = items[d.itemIndex] as Map<String, dynamic>;
    _writeNumbers(item, d.proposed.toItemJson());
    item['published'] = true;
    dk += (d.proposed.calories ?? 0) - (d.before.calories ?? 0);
    dp += (d.proposed.proteinG ?? 0) - (d.before.proteinG ?? 0);
    dc += (d.proposed.carbsG ?? 0) - (d.before.carbsG ?? 0);
    df += (d.proposed.fatG ?? 0) - (d.before.fatG ?? 0);
  }
  final before = AssistNumbers.ofTotals(base);
  num? moved(num? total, num delta, {bool whole = false}) {
    if (total == null && delta.abs() < _eps) return null;
    final v = (total ?? 0) + delta;
    return whole ? v.round() : _round1(v);
  }

  final after = AssistNumbers(
    calories: moved(before.calories, dk, whole: true) ?? 0,
    proteinG: moved(before.proteinG, dp),
    carbsG: moved(before.carbsG, dc),
    fatG: moved(before.fatG, df),
  );
  final out = Map<String, dynamic>.from(base)..['food_items'] = items;
  _writeNumbers(out, after.toTotalsJson());
  final reason = decision.outcome == AssistOutcome.apply
      ? decision.reason
      : AssistReason.userAccepted;
  out['assist'] = {
    ..._header(decision, AssistStatus.applied),
    'chain_key': decision.chainKey,
    'brand_name': decision.brandName,
    'matches': [for (final d in decision.items) _matchJson(d, applied: true)],
    'applied_total': after.calories,
    'totals': {
      'before': before.toTotalsJson(),
      'applied': after.toTotalsJson(),
    },
    'source': _sourceJson(decision),
    'grounded': decision.grounded,
    'provider': decision.provider,
    'decided_on': decision.decidedOn,
    'reason': reason,
    'notes': decision.notes,
  };
  return out;
}

/// Records any decision on [analysis]: an apply through [applyAssist]; a
/// suggestion as a block of the covered items' published numbers and
/// before stamps (the meal's numbers are untouched); a context-only
/// outcome as a block with NO chain, brand, match or source (the screen
/// says "no published nutrition found" without naming a restaurant).
/// Null — write nothing — for a reject, when an apply's stamps no longer
/// match, and for a suggestion or context-only result on a meal whose
/// earlier application still stands: a weaker answer never silently
/// undoes published numbers (the caller reverts first if the user asks).
Map<String, dynamic>? recordAssistDecision(
  Map<String, dynamic> analysis,
  AssistDecision decision,
) {
  if (decision.outcome != AssistOutcome.apply &&
      _block(analysis)?['status'] == AssistStatus.applied &&
      assistStampValid(analysis)) {
    return null;
  }
  switch (decision.outcome) {
    case AssistOutcome.apply:
      return applyAssist(analysis, decision);
    case AssistOutcome.reject:
      return null;
    case AssistOutcome.suggest:
      if (decision.items.isEmpty || decision.chainKey == null) return null;
      return Map<String, dynamic>.from(analysis)
        ..['assist'] = {
          ..._header(decision, AssistStatus.suggested),
          'chain_key': decision.chainKey,
          'brand_name': decision.brandName,
          'matches': [
            for (final d in decision.items) _matchJson(d, applied: false),
          ],
          'source': _sourceJson(decision),
          'grounded': decision.grounded,
          'provider': decision.provider,
          'decided_on': decision.decidedOn,
          'reason': decision.reason,
          'notes': decision.notes,
        };
    case AssistOutcome.contextOnly:
      return Map<String, dynamic>.from(analysis)
        ..['assist'] = {
          ..._header(decision, decision.status),
          'brand_name': '',
          'provider': decision.provider,
          'decided_on': decision.decidedOn,
          'reason': decision.reason,
        };
  }
}

/// The small provenance block kept after a revert or a correction: no
/// matches, stamps, totals or source — nothing a chip or Undo could act
/// on. Every value is re-validated (an imported block is untrusted).
Map<String, Object?> _residualBlock(Map block, String status, String reason) {
  final key = block['chain_key'];
  final trigger = AssistTrigger.fromWire(block['trigger']);
  final evidence = AssistEvidenceKind.fromWire(block['evidence']);
  final decided = block['decided_on'];
  return {
    'v': kAssistVersion,
    'status': status,
    if (trigger != null) 'trigger': trigger.wire,
    if (evidence != null) 'evidence': evidence.wire,
    if (key is String && chainByKey(key) != null) 'chain_key': key,
    'brand_name': sanitizeAssistText(block['brand_name'], kAssistBrandNameMax),
    'provider': _code(block['provider'], _providerRe),
    if (decided is String && _isoDateRe.hasMatch(decided))
      'decided_on': decided,
    'reason': reason,
  };
}

/// Undoes an APPLIED block while its stamps still match: the covered
/// items get their before values back (and lose `published`), the totals
/// get the stamped before totals, and the block shrinks to a 'declined'
/// (snackbar Undo) or 'reverted' (editor) record. Null — write nothing —
/// when the block is not applied or anything changed since (an editor
/// save, a leftover deduction, a correction): that is the user's newer
/// truth.
Map<String, dynamic>? revertAssist(
  Map<String, dynamic> analysis, {
  AssistRevertKind kind = AssistRevertKind.reverted,
}) {
  final block = _block(analysis);
  if (block == null ||
      block['status'] != AssistStatus.applied ||
      !assistStampValid(analysis)) {
    return null;
  }
  final declined = kind == AssistRevertKind.declined;
  return _restore(analysis, block)
    ..['assist'] = _residualBlock(
      block,
      declined ? AssistStatus.declined : AssistStatus.reverted,
      declined ? AssistReason.userDeclined : AssistReason.userReverted,
    );
}

/// The block an NL chat correction carries onto the corrected analysis:
/// an applied or suggested block becomes 'superseded' (its stamps refer
/// to numbers that no longer exist); any other terminal block keeps its
/// status. Only provenance survives. Null for anything that is not an
/// assist block.
Map<String, Object?>? supersedeAssist(dynamic assist) {
  if (assist is! Map || assist['v'] != kAssistVersion) return null;
  final status = assist['status'];
  if (status is! String || !AssistStatus.all.contains(status)) return null;
  if (status == AssistStatus.applied || status == AssistStatus.suggested) {
    return _residualBlock(
      assist,
      AssistStatus.superseded,
      AssistReason.nlCorrection,
    );
  }
  final reason = _code(assist['reason'], _reasonRe);
  return _residualBlock(assist, status, reason);
}
