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
  /// Chains a printed brand or the receipt merchant names are kept even
  /// when the location found them too (lane B's composer always lists
  /// them); everything else is recomposed unchanged.
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

  /// This request as the owner's server gate (lookup_contract.py) reads
  /// it: every item name or unit that gate would refuse is sent as "" (the
  /// item keeps its slot), so a request lane B's composer accepted is not
  /// answered 400, which writes the meal's automatic lookup off for good.
  /// The direct providers get the request unchanged; nothing here ever
  /// adds text.
  ///
  /// The composer checks one field at a time as nfkcLite leaves it. The
  /// gate is stricter in three ways:
  ///   - it reads every Unicode decimal digit as its ASCII digit;
  ///   - it also reads each field under full NFKC with format and private
  ///     characters removed ("85℃" is "85°C" there, so "S 85℃" reads as a
  ///     hemisphere and degrees, and "40° \u00ad W" as "40° W");
  ///   - it reads the items' names and units as one line (name, unit, next
  ///     name, …), the names alone and the units alone, so the name
  ///     "Junmai sake 15°" with the unit "12 oz" reads as degrees and
  ///     minutes, and "Combo 12.99" before "0.50 L lemonade" as a pair.
  /// Here fields join each line in that order, under both readings, and
  /// the field that first makes a line coordinate-shaped is blanked, until
  /// no line is. A field the gate would read as empty is blanked too.
  ///
  /// Dart has no full NFKC: [_gateNfkc] covers the forms above plus º and
  /// ˚, the superscript, subscript and enclosed numbers and the vulgar
  /// fractions.
  /// Rarer compatibility forms (squared units such as ㎖, parenthesized
  /// ideographs such as ㈱, Roman numerals, mathematical letters) and
  /// unassigned code points can still differ either way: the server then
  /// refuses that request as before, or a field is blanked that it would
  /// have taken.
  LookupRequest withoutGateCoordinates() {
    final copy = [
      for (final i in items)
        <String, Object?>{if (i is Map) ...i.cast<String, Object?>()},
    ];
    String text(int i, String key) {
      final v = copy[i][key];
      return v is String ? v : '';
    }

    final lines = [
      [
        for (var i = 0; i < copy.length; i++) ...[(i, 'name'), (i, 'unit')],
      ],
      [for (var i = 0; i < copy.length; i++) (i, 'name')],
      [for (var i = 0; i < copy.length; i++) (i, 'unit')],
    ];
    var blanked = false;
    var again = true;
    while (again) {
      again = false;
      for (final line in lines) {
        final nfkcParts = <String>[];
        final digitParts = <String>[];
        for (final (i, key) in line) {
          final t = text(i, key);
          if (t.isEmpty) continue;
          final full = _gateNfkc(t);
          if (full.isEmpty || coordinateShaped(full)) {
            copy[i][key] = '';
            blanked = true;
            if (full.isEmpty) continue;
            again = true;
            break;
          }
          // The gate's line holds each field at its cap, in code points.
          final cap = key == 'name' ? kLookupItemNameMax : kLookupUnitMax;
          final runes = full.runes;
          nfkcParts.add(runes.length <= cap
              ? full
              : String.fromCharCodes(runes.take(cap)));
          digitParts.add(_gateDigits(t));
          if (coordinateShaped(nfkcParts.join(' ')) ||
              coordinateShaped(digitParts.join(' '))) {
            copy[i][key] = '';
            blanked = again = true;
            break;
          }
        }
        if (again) break;
      }
    }
    if (!blanked) return this;
    return LookupRequest.compose({...body, 'items': copy});
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

/// [text] (a composed name or unit) with every Unicode decimal digit read
/// as its ASCII digit, as the gate reads the composer's own text.
String _gateDigits(String text) {
  final out = StringBuffer();
  for (final r in text.runes) {
    final digit = _unicodeDecimal(r);
    out.writeCharCode(digit == null ? r : 0x30 + digit);
  }
  return out.toString();
}

/// [text] (a composed name or unit) as the gate's full-NFKC cleaner leaves
/// it, for the forms that can make or break a coordinate shape: format,
/// private-use and noncharacter code points removed (the composer keeps
/// them), º and ˚ (degrees to the composer, not here), ℃ ℉, superscript
/// and subscript digits, vulgar fractions and enclosed numbers and letters
/// spelled out, every Unicode decimal digit as ASCII; spaces collapsed and
/// trimmed.
String _gateNfkc(String text) {
  final out = StringBuffer();
  for (final r in text.runes) {
    if (_gateDrops(r)) continue;
    final compat = _gateCompat(r);
    if (compat != null) {
      out.write(compat);
      continue;
    }
    final digit = _unicodeDecimal(r);
    out.writeCharCode(digit == null ? r : 0x30 + digit);
  }
  return out.toString().replaceAll(_spaces, ' ').trim();
}

final RegExp _spaces = RegExp(' {2,}');

/// Category C code points the gate removes and the composer keeps.
bool _gateDrops(int r) =>
    r == 0x00AD ||
    (r >= 0x0600 && r <= 0x0605) ||
    r == 0x06DD ||
    r == 0x070F ||
    (r >= 0x0890 && r <= 0x0891) ||
    r == 0x08E2 ||
    r == 0x180E ||
    r == 0x2065 ||
    (r >= 0x206A && r <= 0x206F) ||
    (r >= 0xE000 && r <= 0xF8FF) ||
    (r >= 0xFFF9 && r <= 0xFFFB) ||
    r == 0xFFFE ||
    r == 0xFFFF ||
    r == 0x110BD ||
    r == 0x110CD ||
    (r >= 0x13430 && r <= 0x1343F) ||
    (r >= 0x1BCA0 && r <= 0x1BCA3) ||
    (r >= 0x1D173 && r <= 0x1D17A) ||
    r == 0xE0001 ||
    (r >= 0xE0020 && r <= 0xE007F) ||
    r >= 0xF0000;

/// The NFKC of one code point, for the compatibility forms that read as
/// digits, degrees or letters next to a number; null for any other.
String? _gateCompat(int r) {
  final listed = _gateCompatTable[r];
  if (listed != null) return listed;
  if (r >= 0x2460 && r <= 0x2473) return '${r - 0x245F}'; // ①
  if (r >= 0x2474 && r <= 0x2487) return '(${r - 0x2473})'; // ⑴
  if (r >= 0x2488 && r <= 0x249B) return '${r - 0x2487}.'; // ⒈
  if (r >= 0x249C && r <= 0x24B5) {
    return '(${String.fromCharCode(0x61 + r - 0x249C)})'; // ⒜
  }
  if (r >= 0x24B6 && r <= 0x24CF) {
    return String.fromCharCode(0x41 + r - 0x24B6); // Ⓐ
  }
  if (r >= 0x24D0 && r <= 0x24E9) {
    return String.fromCharCode(0x61 + r - 0x24D0); // ⓐ
  }
  if (r >= 0x3251 && r <= 0x325F) return '${r - 0x3251 + 21}'; // ㉑
  if (r >= 0x32B1 && r <= 0x32BF) return '${r - 0x32B1 + 36}'; // ㊱
  return null;
}

const String _fractionSlash = '\u2044';
const Map<int, String> _gateCompatTable = {
  0x00AA: 'a', // ª
  0x00BA: 'o', // º: a degree only to the composer
  0x02DA: ' \u030a', // ˚: likewise
  0x2103: '\u00b0C', // ℃
  0x2109: '\u00b0F', // ℉
  0x24EA: '0', // ⓪
  0x00B9: '1', 0x00B2: '2', 0x00B3: '3', 0x2070: '0', //
  0x2074: '4', 0x2075: '5', 0x2076: '6', 0x2077: '7', 0x2078: '8', //
  0x2079: '9', 0x207A: '+', //
  0x2080: '0', 0x2081: '1', 0x2082: '2', 0x2083: '3', 0x2084: '4', //
  0x2085: '5', 0x2086: '6', 0x2087: '7', 0x2088: '8', 0x2089: '9', //
  0x208A: '+', //
  0x00BC: '1${_fractionSlash}4', 0x00BD: '1${_fractionSlash}2', //
  0x00BE: '3${_fractionSlash}4', 0x2150: '1${_fractionSlash}7', //
  0x2151: '1${_fractionSlash}9', 0x2152: '1${_fractionSlash}10', //
  0x2153: '1${_fractionSlash}3', 0x2154: '2${_fractionSlash}3', //
  0x2155: '1${_fractionSlash}5', 0x2156: '2${_fractionSlash}5', //
  0x2157: '3${_fractionSlash}5', 0x2158: '4${_fractionSlash}5', //
  0x2159: '1${_fractionSlash}6', 0x215A: '5${_fractionSlash}6', //
  0x215B: '1${_fractionSlash}8', 0x215C: '3${_fractionSlash}8', //
  0x215D: '5${_fractionSlash}8', 0x215E: '7${_fractionSlash}8', //
  0x215F: '1$_fractionSlash', 0x2189: '0${_fractionSlash}3', //
};

/// The value of a non-ASCII Unicode decimal digit (general category Nd),
/// or null: Python's unicodedata.decimal, which the gate applies. Each
/// entry is the zero of a block of ten (Unicode 15.0).
int? _unicodeDecimal(int r) {
  if (r < 0x0660) return null;
  for (final zero in _decimalZeros) {
    if (r >= zero && r < zero + 10) return r - zero;
  }
  return null;
}

const List<int> _decimalZeros = [
  0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66, //
  0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0DE6, 0x0E50, 0x0ED0, 0x0F20, //
  0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80, 0x1A90, //
  0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, //
  0xA9F0, 0xAA50, 0xABF0, 0xFF10, 0x104A0, 0x10D30, 0x11066, 0x110F0, //
  0x11136, 0x111D0, 0x112F0, 0x11450, 0x114D0, 0x11650, 0x116C0, //
  0x11730, 0x118E0, 0x11950, 0x11C50, 0x11D50, 0x11DA0, 0x11F50, //
  0x16A60, 0x16AC0, 0x16B50, 0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, //
  0x1D7F6, 0x1E140, 0x1E2F0, 0x1E4F0, 0x1E950, 0x1FBF0,
];

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
