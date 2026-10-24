/// The restaurant-lookup request contract (stage R2a; design data_contracts
/// §4). Every provider gets the same request, built only here (and in its
/// Python twin, restaurant_lookup.py — the parity vectors in
/// shared/vectors/restaurant_lookup.json pin Dart == Python byte for byte):
///
/// {"items":[≤12×{"name":≤80, "qty":num, "unit":≤20, "brand":≤60}],
///  "order_merchant":≤60,
///  "chains":[≤3×{"key", "name" (canonical, from OUR table), "size"}],
///  "country":"US"|ISO2, "lang":"zh"?}
///
/// What can never be in it: coordinates, street, distance, city, timestamps,
/// meal_description, calories, the dietary profile, history or the image.
/// The composer reads only the keys above from its raw input and ignores
/// everything else, so a caller cannot widen the request by accident.
///
/// Printed text never goes out as printed: a receipt or order screen puts
/// store numbers, streets and cities next to the merchant ("Chipotle
/// Mexican Grill #2381 - 1540 Broadway, New York NY"), and a cup can carry
/// a city. So brand and order_merchant hold only the canonical name of the
/// table chain the printed text names, or "" ([chainNameOnly]).
///
/// Injection safety: every string goes through [cleanShortText] (the
/// brand cleaner: compatibility-folded, control, invisible and bidi
/// characters and every `<` `>` removed, whitespace collapsed, capped), so
/// nothing in the request can close the prompt's data block, and JSON
/// quoting handles the rest. Chain names come from the table by key, never
/// from the caller.
library;

import 'dart:convert';

import 'chain_match.dart';
import 'coerce.dart';
import 'shared_generated.dart';

const int kLookupMaxItems = 12;
const int kLookupItemNameMax = 80;
const int kLookupBrandMax = 60;
const int kLookupUnitMax = 20;
const int kLookupMerchantMax = 60;
const int kLookupMaxChains = 3;
const String kLookupDefaultCountry = 'US';
const String kLookupRequestToken = '<<REQUEST_JSON>>';

final RegExp _countryRe = RegExp(r'^[A-Za-z]{2}$');
final RegExp _langZhRe = RegExp(r'^[Zz][Hh](?:[-_][A-Za-z0-9]{1,8})*$');

/// The count as sent: [coerceQty], then hundredths rounded half up (at least
/// 0.01), an int when whole — identical to the Python composer.
num _requestQty(dynamic value) {
  final q = coerceQty(value).toDouble();
  var hundredths = (q * 100 + 0.5).floor();
  if (hundredths < 1) hundredths = 1;
  if (hundredths % 100 == 0) return hundredths ~/ 100;
  return hundredths / 100;
}

String _country(dynamic value) => value is String && _countryRe.hasMatch(value)
    ? value.toUpperCase()
    : kLookupDefaultCountry;

String? _lang(dynamic value) =>
    value is String && _langZhRe.hasMatch(value) ? 'zh' : null;

/// Where a printed name's suffix starts (chain_match.dart's cuts), and a
/// standalone number (a store or street number: "CHIPOTLE 2381").
const List<String> _headCuts = [
  '(', '[', '|', '#', ',', ' - ', ' – ', ' — ', ' @ ', ' · ', //
];
final RegExp _standaloneNumberRe = RegExp(r' [0-9]+(?= |$)');

/// [text] (already cleaned: single spaces) up to its first name separator
/// or standalone number, without leading or trailing spaces.
String _nameHead(String text) {
  var cut = text.length;
  for (final sep in _headCuts) {
    final i = text.indexOf(sep);
    if (i > 0 && i < cut) cut = i;
  }
  final m = _standaloneNumberRe.firstMatch(text);
  if (m != null && m.start > 0 && m.start < cut) cut = m.start;
  var head = text.substring(0, cut);
  while (head.startsWith(' ')) {
    head = head.substring(1);
  }
  while (head.endsWith(' ')) {
    head = head.substring(0, head.length - 1);
  }
  return head;
}

/// What a request carries for printed brand or merchant text: the
/// canonical name of the table chain it names ([matchChain] on the cleaned
/// text, then on its head before the first separator or standalone
/// number), or "" — never the printed text itself, which can carry a store
/// number, a street or a city. Identical to the Python composer's
/// chain_name_only.
String chainNameOnly(dynamic value, int maxChars) {
  final text = cleanShortText(value, maxChars);
  if (text.isEmpty) return '';
  var key = matchChain(text);
  if (key == null) {
    final head = _nameHead(text);
    if (head.isNotEmpty && head != text) key = matchChain(head);
  }
  final chain = chainByKey(key);
  return chain == null ? '' : cleanShortText(chain.name, maxChars);
}

/// One request item: name, count, unit and the chain its printed brand
/// names. [decideAssist] composes the meal's CURRENT items the same way to
/// notice an item that changed after the request was sent.
Map<String, Object?> composeLookupItem(dynamic item) {
  final m = item is Map ? item : const {};
  return {
    'name': cleanShortText(m['name'], kLookupItemNameMax),
    'qty': _requestQty(m['qty']),
    'unit': cleanShortText(m['unit'], kLookupUnitMax),
    'brand': chainNameOnly(m['brand'], kLookupBrandMax),
  };
}

List<Map<String, Object?>> _requestChains(dynamic value) {
  final out = <Map<String, Object?>>[];
  final seen = <String>{};
  for (final entry in value is List ? value : const []) {
    final key = entry is Map ? entry['key'] : entry;
    if (key is! String || seen.contains(key)) continue;
    final chain = chainByKey(key);
    if (chain == null) continue;
    seen.add(key);
    out.add({'key': chain.key, 'name': chain.name, 'size': chain.size});
    if (out.length == kLookupMaxChains) break;
  }
  return out;
}

/// The lookup request body from a raw input of the same shape. Only
/// items[].name/qty/unit/brand, order_merchant, chains (keys of OUR table,
/// in rank order, as strings or `{"key": ...}` maps), country and lang are
/// read; brand and order_merchant become a table chain's canonical name or
/// "" ([chainNameOnly]). Items keep their positions (the first 12), so a
/// response's item_index is the meal's food_items index. Idempotent.
Map<String, Object?> composeLookupRequest(dynamic raw) {
  final r = raw is Map ? raw : const {};
  final items = r['items'];
  final request = <String, Object?>{
    'items': [
      for (final i in (items is List ? items : const []).take(kLookupMaxItems))
        composeLookupItem(i),
    ],
    'order_merchant': chainNameOnly(r['order_merchant'], kLookupMerchantMax),
    'chains': _requestChains(r['chains']),
    'country': _country(r['country']),
  };
  final lang = _lang(r['lang']);
  if (lang != null) request['lang'] = lang;
  return request;
}

/// Compact JSON of a composed request — the same bytes as the Python
/// composer's canonical_lookup_json.
String canonicalLookupJson(Object? request) => jsonEncode(request);

/// The shared lookup prompt with the composed request in its data block.
String composeLookupPrompt(dynamic raw) =>
    sharedRestaurantLookupPrompt.replaceFirst(
      kLookupRequestToken,
      canonicalLookupJson(composeLookupRequest(raw)),
    );

/// A composed lookup request: the body every provider sends, and the prompt
/// built from it.
final class LookupRequest {
  LookupRequest._(this.body);

  /// Composes [raw] (see [composeLookupRequest]).
  factory LookupRequest.compose(dynamic raw) =>
      LookupRequest._(Map.unmodifiable(composeLookupRequest(raw)));

  /// The composed request (unmodifiable).
  final Map<String, Object?> body;

  /// The keys of the chains in the request, in rank order.
  List<String> get chainKeys => [
    for (final c in body['chains'] as List) (c as Map)['key'] as String,
  ];

  /// The request as compact JSON.
  String toJson() => canonicalLookupJson(body);

  /// The shared prompt with this request in its data block.
  String get prompt => composeLookupPrompt(body);
}
