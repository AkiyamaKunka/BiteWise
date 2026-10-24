/// Matches a place or brand name, and optionally a web host, against
/// BiteWise's own table of US chains (shared/chains/us_chains.json, emitted
/// as [sharedUsChains]). Stage R2a of the restaurant assist.
///
/// The restaurant assist only ever sends a chain's canonical name from this
/// table to an AI provider, so a nearby place or a printed brand counts only
/// once it maps to a key here. Precision beats recall: an unknown or
/// ambiguous name is null and the assist simply does nothing.
///
/// Rules (restaurant_lookup.py holds the Python twin; the parity vectors in
/// shared/vectors/restaurant_lookup.json pin them):
///   * Tokens: [nfkcLite], apostrophes and the degree sign dropped, Latin-1
///     letters folded to ASCII, ASCII lowercased, "&" and "+" read as "and",
///     each CJK character its own token, anything else a separator, and a
///     leading "the" ignored when more follows.
///   * A name equal to a variant (the chain's name, an alias or its Chinese
///     name) matches; so does a compact (space-free) equality when one side
///     is a single token of 5+ characters ("Chickfila", "Wing Stop").
///   * A name that STARTS with a variant of two or more tokens matches
///     ("Taco Bell Cantina"); single-token variants never prefix-match, so
///     "Jack's Bar" is not a chain. The longest prefix wins.
///   * Two chains tied at the best score match nothing.
///   * When nothing matched, the name is cut at its first suffix separator
///     ("McDonald's (Times Sq)", "Starbucks - Midtown") and tried again.
///   * A name that looks like a web address never matches by name.
///   * A host matches when it equals, or is a subdomain of, a table domain;
///     non-ASCII (IDN) hosts never match. When the name and the host match
///     different chains, the result is null.
library;

import 'coerce.dart';
import 'shared_generated.dart';

/// Dropped while tokenizing: apostrophes and the degree sign (85°C).
const Set<int> _dropped = {0x27, 0x60, 0xB4, 0x2BC, 0x2018, 0x2019, 0xB0};

const Map<int, String> _latinFold = {
  0xC0: 'a', 0xC1: 'a', 0xC2: 'a', 0xC3: 'a', 0xC4: 'a', 0xC5: 'a', //
  0xE0: 'a', 0xE1: 'a', 0xE2: 'a', 0xE3: 'a', 0xE4: 'a', 0xE5: 'a', //
  0xC6: 'ae', 0xE6: 'ae', //
  0xC7: 'c', 0xE7: 'c', //
  0xC8: 'e', 0xC9: 'e', 0xCA: 'e', 0xCB: 'e', //
  0xE8: 'e', 0xE9: 'e', 0xEA: 'e', 0xEB: 'e', //
  0xCC: 'i', 0xCD: 'i', 0xCE: 'i', 0xCF: 'i', //
  0xEC: 'i', 0xED: 'i', 0xEE: 'i', 0xEF: 'i', //
  0xD1: 'n', 0xF1: 'n', //
  0xD2: 'o', 0xD3: 'o', 0xD4: 'o', 0xD5: 'o', 0xD6: 'o', 0xD8: 'o', //
  0xF2: 'o', 0xF3: 'o', 0xF4: 'o', 0xF5: 'o', 0xF6: 'o', 0xF8: 'o', //
  0x152: 'oe', 0x153: 'oe', //
  0xD9: 'u', 0xDA: 'u', 0xDB: 'u', 0xDC: 'u', //
  0xF9: 'u', 0xFA: 'u', 0xFB: 'u', 0xFC: 'u', //
  0xDD: 'y', 0xFD: 'y', 0xFF: 'y', //
  0xDF: 'ss',
};

/// Where a place name's suffix starts.
const List<String> _nameCuts = [
  '(', '[', '|', '#', ',', ' - ', ' – ', ' — ', ' @ ', ' · ', //
];

final RegExp _hostLikeRe = RegExp(r'[a-z0-9]\.[a-z]{2,}');
final RegExp _hostRe = RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$');

/// A compact (space-free) comparison needs at least this many characters.
const int _compactMin = 5;

bool _isCjk(int r) =>
    (r >= 0x3040 && r <= 0x30FF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0xAC00 && r <= 0xD7AF) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0x20000 && r <= 0x2FA1F);

String _asciiLower(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    out.writeCharCode(r >= 0x41 && r <= 0x5A ? r + 32 : r);
  }
  return out.toString();
}

/// The match tokens of [value] (see the library doc). Non-strings have none.
List<String> chainTokens(dynamic value) {
  if (value is! String) return const [];
  final buf = StringBuffer();
  for (final r in nfkcLite(value).runes) {
    if (_dropped.contains(r)) continue;
    if (r >= 0x41 && r <= 0x5A) {
      buf.writeCharCode(r + 32);
    } else if ((r >= 0x61 && r <= 0x7A) || (r >= 0x30 && r <= 0x39)) {
      buf.writeCharCode(r);
    } else if (_latinFold.containsKey(r)) {
      buf.write(_latinFold[r]);
    } else if (r == 0x26 || r == 0x2B) {
      buf.write(' and ');
    } else if (_isCjk(r)) {
      buf
        ..write(' ')
        ..writeCharCode(r)
        ..write(' ');
    } else {
      buf.write(' ');
    }
  }
  var tokens = buf.toString().split(' ').where((t) => t.isNotEmpty).toList();
  if (tokens.length > 1 && tokens.first == 'the') {
    tokens = tokens.sublist(1);
  }
  return tokens;
}

bool _isHostLike(String value) {
  final lowered = _asciiLower(nfkcLite(value));
  return lowered.contains('://') ||
      lowered.contains('www.') ||
      _hostLikeRe.hasMatch(lowered);
}

final class _Variant {
  const _Variant(this.key, this.tokens, this.compact);
  final String key;
  final List<String> tokens;
  final String compact;
}

final List<_Variant> _index = [
  for (final c in sharedUsChains)
    for (final v in [c.name, ...c.aliases, if (c.zhName != null) c.zhName!])
      if (chainTokens(v).isNotEmpty)
        _Variant(c.key, chainTokens(v), chainTokens(v).join()),
];

final Map<String, SharedChain> _byKey = {
  for (final c in sharedUsChains) c.key: c,
};

/// The table row for [key], or null.
SharedChain? chainByKey(String? key) => key == null ? null : _byKey[key];

bool _listEq(List<String> a, List<String> b, [int? n]) {
  final len = n ?? a.length;
  if (n == null && a.length != b.length) return false;
  if (a.length < len || b.length < len) return false;
  for (var i = 0; i < len; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// (key or null, matched anything).
(String?, bool) _matchTokens(List<String> tokens) {
  if (tokens.isEmpty) return (null, false);
  final compact = tokens.join();
  int? bestRank;
  var bestLen = 0;
  final keys = <String>{};
  for (final v in _index) {
    int? rank;
    var len = 0;
    if (_listEq(tokens, v.tokens)) {
      rank = 2;
    } else if ((tokens.length == 1 || v.tokens.length == 1) &&
        compact == v.compact &&
        compact.runes.length >= _compactMin) {
      rank = 2;
    } else if (v.tokens.length >= 2 &&
        tokens.length > v.tokens.length &&
        _listEq(tokens, v.tokens, v.tokens.length)) {
      rank = 1;
      len = v.tokens.length;
    }
    if (rank == null) continue;
    final better =
        bestRank == null ||
        rank > bestRank ||
        (rank == bestRank && len > bestLen);
    if (better) {
      bestRank = rank;
      bestLen = len;
      keys
        ..clear()
        ..add(v.key);
    } else if (rank == bestRank && len == bestLen) {
      keys.add(v.key);
    }
  }
  if (bestRank == null) return (null, false);
  return (keys.length == 1 ? keys.first : null, true);
}

String? _cutName(String value) {
  final s = nfkcLite(value);
  var cut = s.length;
  for (final sep in _nameCuts) {
    final i = s.indexOf(sep);
    if (i > 0 && i < cut) cut = i;
  }
  return cut < s.length ? s.substring(0, cut) : null;
}

/// The chain a place or brand [name] belongs to, or null.
String? matchChainName(dynamic name) {
  if (name is! String || _isHostLike(name)) return null;
  final (key, matched) = _matchTokens(chainTokens(name));
  if (matched) return key;
  final cut = _cutName(name);
  if (cut == null) return null;
  return _matchTokens(chainTokens(cut)).$1;
}

/// An ASCII host lowercased with one trailing dot removed; null for
/// anything else (non-ASCII/IDN, ports, paths, empty labels).
String? normalizeHost(dynamic host) {
  if (host is! String) return null;
  var h = _asciiLower(host);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  return _hostRe.hasMatch(h) ? h : null;
}

/// [host] equals [domain] or is a subdomain of it (both normalized).
bool hostMatchesDomain(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// The chain whose table domain [host] equals or is a subdomain of.
String? matchChainHost(dynamic host) {
  final h = normalizeHost(host);
  if (h == null) return null;
  for (final c in sharedUsChains) {
    for (final d in c.domains) {
      if (hostMatchesDomain(h, d)) return c.key;
    }
  }
  return null;
}

/// True when [host] is (a subdomain of) one of [chainKey]'s own domains.
bool isChainHost(dynamic host, String? chainKey) {
  final h = normalizeHost(host);
  final chain = chainByKey(chainKey);
  if (h == null || chain == null) return false;
  return chain.domains.any((d) => hostMatchesDomain(h, d));
}

/// The chain key for a place or brand [name] and an optional [urlHost]
/// (a place's web host). When both match different chains, null.
String? matchChain(dynamic name, {String? urlHost}) {
  final hostKey = urlHost == null ? null : matchChainHost(urlHost);
  final nameKey = matchChainName(name);
  if (hostKey != null && nameKey != null && hostKey != nameKey) return null;
  return hostKey ?? nameKey;
}
