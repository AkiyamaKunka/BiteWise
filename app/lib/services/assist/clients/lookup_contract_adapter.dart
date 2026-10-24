/// The ONE seam between the direct lookup clients and the restaurant
/// lookup contract (design data_contracts §4 request, §5 response).
///
/// The contract is lane B's (R2a/R2b), and the clients use it as is:
///   - the request is [LookupRequest] from core/restaurant_lookup_contract
///     .dart — composed only by lane B's composer (caps, cleaning, printed
///     text reduced to a table chain's canonical name, chains only from OUR
///     table), the same bytes the owner's server and every other provider
///     get (the parity vectors pin Dart == Python);
///   - the prompt is [LookupRequest.prompt]: the shared
///     shared/prompts/restaurant_lookup_prompt.txt with the request in its
///     single data block;
///   - the §5 enums come from the shared response schema, and [LookupResult]
///     reads an answer with lane B's acceptance limits and cleaner
///     (core/restaurant_assist_logic.dart), so the typed view never keeps a
///     number lane B would refuse or drops one it would use;
///   - the APPLY decision stays lane B's: `LookupOutcome.toAssistLookup()`
///     hands the raw answer and the search's URLs and text to decideAssist.
/// Nothing else in clients/ knows the contract's shape.
library;

import 'dart:convert';

import '../../../core/chain_match.dart' show chainByKey, matchChain;
import '../../../core/restaurant_assist_logic.dart'
    show
        kAssistBrandNameMax,
        kAssistMaxComponents,
        kAssistMaxOptions,
        kAssistMaxPublishedGrams,
        kAssistMaxPublishedKcal,
        kAssistMenuItemMax,
        kAssistNotesMax,
        kAssistOptionLabelMax,
        kAssistServingMax,
        kAssistTitleMax,
        kAssistUnitMax,
        sanitizeAssistText;
import '../../../core/restaurant_lookup_contract.dart';
import '../../../core/shared_generated.dart' show sharedRestaurantLookupSchema;

export '../../../core/restaurant_lookup_contract.dart'
    show
        LookupRequest,
        kLookupBrandMax,
        kLookupItemNameMax,
        kLookupMaxChains,
        kLookupMaxItems,
        kLookupMerchantMax,
        kLookupUnitMax;

final RegExp _iso2 = RegExp(r'^[A-Z]{2}$');

/// What the direct clients read from lane B's composed request.
extension LookupRequestForClients on LookupRequest {
  /// The composed items (at most 12; item_index in an answer is a position
  /// here).
  List<Object?> get items => body['items'] as List<Object?>;

  /// The ISO2 country of the meal (lane B composes "US" for anything that
  /// is not one), for a provider's approximate user_location — a country,
  /// never a city. Null only for a body that is not a composed request.
  String? get iso2Country {
    final c = body['country'];
    return c is String && _iso2.hasMatch(c) ? c : null;
  }

  /// This request without the chains that came from the photo's location
  /// (design §4: the brand path when the location path is not allowed).
  /// Chains a printed brand or the receipt merchant named are kept;
  /// everything else is recomposed unchanged.
  LookupRequest withoutLocationChains(Iterable<String> locationChainKeys) {
    final drop = locationChainKeys.toSet();
    return LookupRequest.compose({
      ...body,
      'chains': [
        for (final key in chainKeys)
          if (!drop.contains(key)) key,
      ],
    });
  }

  /// The OFFICIAL domains (from our chain table) of every chain this
  /// request names — its chains, and the chains its printed brands and
  /// receipt merchant name — for a provider's domain filter and the source
  /// screen. They add nothing a provider does not already learn from the
  /// chain names in the request.
  List<String> get chainDomains {
    final keys = <String>[...chainKeys];
    void addNamed(Object? name) {
      if (name is! String || name.isEmpty) return;
      final key = matchChain(name);
      if (key != null && !keys.contains(key)) keys.add(key);
    }

    for (final item in items) {
      if (item is Map) addNamed(item['brand']);
    }
    addNamed(body['order_merchant']);
    return [
      for (final key in keys) ...?chainByKey(key)?.domains,
    ];
  }
}

// ---------------------------------------------------------------------------
// §5 response
// ---------------------------------------------------------------------------

final Map<String, dynamic> _schema =
    jsonDecode(sharedRestaurantLookupSchema) as Map<String, dynamic>;

Set<String> _schemaEnum(Map<String, dynamic> node) =>
    {for (final v in node['enum'] as List) v as String};

Map<String, dynamic> _props(Map<String, dynamic> node) =>
    node['properties'] as Map<String, dynamic>;

/// The status, match_type and source_type values of the shared response
/// schema (shared/prompts/restaurant_lookup_schema.json).
final Set<String> kLookupStatuses = _schemaEnum(_props(_schema)['status']);
final Set<String> kLookupMatchTypes = _schemaEnum(_props(
  (_props(_schema)['matches'] as Map<String, dynamic>)['items'],
)['match_type']);
final Set<String> kLookupSourceTypes =
    _schemaEnum(_props(_schema)['source_type']);

/// A published calorie value as lane B reads one: a whole number in
/// [0, 6000] (590.0 is the published 590; 590.5 is no published value).
int? _kcal(Object? v) {
  if (v is bool || v is! num || !v.isFinite) return null;
  if (v < 0 || v > kAssistMaxPublishedKcal) return null;
  if (v != v.roundToDouble()) return null;
  return v.toInt();
}

num? _grams(Object? v) {
  if (v is bool || v is! num || !v.isFinite) return null;
  if (v < 0 || v > kAssistMaxPublishedGrams) return null;
  return v;
}

String _str(Object? v, int max) => sanitizeAssistText(v, max);

class LookupOption {
  const LookupOption({
    this.label = '',
    this.serving = '',
    this.unit = '',
    this.calories,
    this.caloriesRange,
    this.proteinG,
    this.carbsG,
    this.fatG,
  });
  final String label;
  final String serving;
  final String unit;
  final int? calories;
  final List<int>? caloriesRange;
  final num? proteinG;
  final num? carbsG;
  final num? fatG;

  /// Null when the option publishes no calorie value (lane B skips it). A
  /// valid range wins over a single value given next to it: both at once
  /// breaks the contract, and a range can never apply.
  static LookupOption? parse(Object? raw) {
    if (raw is! Map) return null;
    List<int>? range;
    final r = raw['calories_range'];
    if (r is List && r.length == 2) {
      final lo = _kcal(r[0]), hi = _kcal(r[1]);
      if (lo != null && hi != null && lo <= hi) range = [lo, hi];
    }
    final calories = range == null ? _kcal(raw['calories']) : null;
    if (calories == null && range == null) return null;
    return LookupOption(
      label: _str(raw['label'], kAssistOptionLabelMax),
      serving: _str(raw['serving'], kAssistServingMax),
      unit: _str(raw['unit'], kAssistUnitMax),
      calories: calories,
      caloriesRange: range,
      proteinG: _grams(raw['protein_g']),
      carbsG: _grams(raw['carbs_g']),
      fatG: _grams(raw['fat_g']),
    );
  }
}

class LookupComponent {
  const LookupComponent(
      {required this.name, this.calories, this.proteinG, this.carbsG, this.fatG});
  final String name;
  final int? calories;
  final num? proteinG;
  final num? carbsG;
  final num? fatG;

  /// Every map is kept, even without a name or calories: lane B sums a
  /// components_sum match only when every component publishes calories,
  /// so a dropped entry would turn "no total" into a smaller one.
  static LookupComponent? parse(Object? raw) {
    if (raw is! Map) return null;
    return LookupComponent(
      name: _str(raw['name'], kAssistMenuItemMax),
      calories: _kcal(raw['calories']),
      proteinG: _grams(raw['protein_g']),
      carbsG: _grams(raw['carbs_g']),
      fatG: _grams(raw['fat_g']),
    );
  }
}

class LookupMatch {
  const LookupMatch({
    required this.itemIndex,
    required this.menuItem,
    required this.matchType,
    this.isDrink = false,
    this.components = const [],
    this.options = const [],
  });
  final int itemIndex;
  final String menuItem;
  final String matchType;
  final bool isDrink;
  final List<LookupComponent> components;
  final List<LookupOption> options;

  /// THE figure, when the match states exactly one: a single option with a
  /// plain calorie number (no range). Anything else (several sizes, a
  /// range, components only) is for lane B's pickOption, so null here.
  int? get publishedCalories {
    if (options.length != 1) return null;
    final o = options.single;
    return o.caloriesRange == null ? o.calories : null;
  }

  /// Every calorie number this match publishes (options, ranges and
  /// components) — the numbers a grounding check must find in evidence.
  List<int> get allFigures => [
        for (final o in options) ...[
          if (o.calories != null) o.calories!,
          ...?o.caloriesRange,
        ],
        for (final c in components)
          if (c.calories != null) c.calories!,
      ];

  /// [itemCount] bounds item_index (a match for an item we never sent is
  /// dropped, not trusted). Reads the first 12 options and 20 components,
  /// as lane B does.
  static LookupMatch? parse(Object? raw, {required int itemCount}) {
    if (raw is! Map) return null;
    final idx = raw['item_index'];
    if (idx is! int || idx < 0 || idx >= itemCount) return null;
    final type = raw['match_type'];
    if (type is! String || !kLookupMatchTypes.contains(type)) return null;
    final menu = _str(raw['menu_item'], kAssistMenuItemMax);
    if (menu.isEmpty) return null;
    final comps = raw['components'];
    final opts = raw['options'];
    return LookupMatch(
      itemIndex: idx,
      menuItem: menu,
      matchType: type,
      isDrink: raw['is_drink'] == true,
      components: [
        if (comps is List)
          for (final c in comps.take(kAssistMaxComponents))
            ?LookupComponent.parse(c),
      ],
      options: [
        if (opts is List)
          for (final o in opts.take(kAssistMaxOptions)) ?LookupOption.parse(o),
      ],
    );
  }
}

/// data_contracts §5, coerced. Construction only through [parse].
class LookupResult {
  const LookupResult._({
    required this.status,
    required this.chainKey,
    required this.restaurantName,
    required this.matches,
    required this.sourceUrl,
    required this.sourceTitle,
    required this.sourceType,
    required this.sourceYear,
    required this.matchConfidence,
    required this.notes,
    required this.json,
  });

  final String status;

  /// The chosen chain when it is a key of OUR table, else null (lane B
  /// then rejects the lookup: a chain we never asked about).
  final String? chainKey;
  final String restaurantName;
  final List<LookupMatch> matches;

  /// The model's CLAIMED source, raw (trimmed). Never trusted: the
  /// citation check compares it with what the search actually returned.
  final String? sourceUrl;
  final String? sourceTitle;
  final String sourceType;
  final int? sourceYear;
  final double matchConfidence;
  final String notes;

  /// The decoded object as the model sent it: what lane B's decideAssist
  /// judges (`LookupOutcome.toAssistLookup`), and diagnostics.
  final Map<String, dynamic> json;

  bool get found => status == 'found';

  /// Null when [raw] is not a §5 object (no valid status) — the caller
  /// reports a malformed reply. Everything below the status is coerced
  /// field by field: a bad match is dropped, a bad number becomes null.
  static LookupResult? parse(Object? raw, {required int itemCount}) {
    if (raw is! Map) return null;
    final status = raw['status'];
    if (status is! String || !kLookupStatuses.contains(status)) return null;
    final matches = raw['matches'];
    final src = raw['source_url'];
    final type = raw['source_type'];
    final year = raw['source_year'];
    final conf = raw['match_confidence'];
    final key = raw['chain_key'];
    return LookupResult._(
      status: status,
      chainKey: key is String && chainByKey(key) != null ? key : null,
      restaurantName: _str(raw['restaurant_name'], kAssistBrandNameMax),
      matches: [
        if (matches is List)
          for (final m in matches.take(kLookupMaxItems))
            ?LookupMatch.parse(m, itemCount: itemCount),
      ],
      sourceUrl: src is String && src.trim().isNotEmpty ? src.trim() : null,
      sourceTitle: raw['source_title'] is String
          ? _str(raw['source_title'], kAssistTitleMax)
          : null,
      sourceType:
          type is String && kLookupSourceTypes.contains(type) ? type : 'other',
      sourceYear:
          year is int && year >= 1990 && year <= 2100 ? year : null,
      matchConfidence: conf is num && conf.isFinite
          ? conf.toDouble().clamp(0.0, 1.0)
          : 0.0,
      notes: _str(raw['notes'], kAssistNotesMax),
      json: Map<String, dynamic>.from(raw),
    );
  }
}
