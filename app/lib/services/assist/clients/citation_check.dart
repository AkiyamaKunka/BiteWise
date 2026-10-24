/// Client-side citation screening: is the model's claimed source a URL the
/// SEARCH actually returned, is it on the chain's official domain, and do
/// the published numbers appear in text the search system extracted from
/// that page?
///
/// The rules are the design's (R2b "Source verification details"):
/// https only, lowercase host, `www.` / query / fragment / trailing slash
/// stripped; a non-ASCII host is never launchable or official; a host is
/// official when it equals, or is a subdomain of, one of the chain's table
/// domains; a number matches word-bounded with the thousands separator
/// optional. Lane B's core/restaurant_assist_logic.dart owns the APPLY
/// decision and carries the same rules; at integration one of the two
/// copies should call the other (see notes). This copy exists so every
/// client outcome can be screened and logged the same way, and so the
/// provider fixtures are tested against the rules they must satisfy.
library;

import 'lookup_client.dart';

final RegExp _asciiHost = RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$');
final RegExp _nonAscii = RegExp(r'[^\x21-\x7E]');

String _stripWww(String host) =>
    host.startsWith('www.') ? host.substring(4) : host;

/// The text between `scheme://` and the first `/`, `?`, `#` or `\` of
/// [s] (the whole remainder when there is no `://`).
String _rawAuthority(String s) {
  final start = s.indexOf('://');
  final rest = start < 0 ? s : s.substring(start + 3);
  final end = rest.indexOf(RegExp(r'[/?#\\]'));
  return end < 0 ? rest : rest.substring(0, end);
}

/// The comparable, launchable form of [raw], or null when it is not an
/// https URL with a plain ASCII host (IDN / percent-encoded / userinfo /
/// odd port / whitespace → null: never launchable, never official).
///
/// A `%` anywhere in the raw authority is refused BEFORE parsing: Dart's
/// Uri decodes `%2e` in a host, so `https://chipotle.com%2eevil.com/` would
/// otherwise come out as the launchable `https://chipotle.com.evil.com`.
String? normalizeSourceUrl(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty || _nonAscii.hasMatch(s)) return null;
  if (_rawAuthority(s).contains('%')) return null;
  final Uri uri;
  try {
    uri = Uri.parse(s);
  } on FormatException {
    return null;
  }
  if (uri.scheme.toLowerCase() != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (uri.hasPort && uri.port != 443) return null;
  final host = _stripWww(uri.host.toLowerCase());
  if (!_asciiHost.hasMatch(host)) return null;
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return 'https://$host$path';
}

/// The normalized host of [raw], or null (same rules as
/// [normalizeSourceUrl]).
String? sourceHost(String? raw) {
  final n = normalizeSourceUrl(raw);
  return n == null ? null : Uri.parse(n).host;
}

/// A table/filter domain in canonical form, or null when it is not a
/// plain ASCII registrable-looking name (`chipotle.com`, not a URL).
String? canonicalDomain(String raw) {
  var d = raw.trim().toLowerCase();
  if (d.startsWith('https://')) d = d.substring(8);
  if (d.startsWith('http://')) d = d.substring(7);
  while (d.endsWith('/')) {
    d = d.substring(0, d.length - 1);
  }
  d = _stripWww(d);
  return _asciiHost.hasMatch(d) ? d : null;
}

/// [domains] canonicalized, de-duplicated, at most [max] — what a client
/// passes to a provider's domain filter.
List<String> cleanDomains(Iterable<String> domains, {int max = 5}) {
  final out = <String>[];
  for (final d in domains) {
    final c = canonicalDomain(d);
    if (c != null && !out.contains(c)) out.add(c);
    if (out.length >= max) break;
  }
  return out;
}

/// True when [host] equals one of [domains] or is a subdomain of one.
/// `chipotle.com.evil.net` and `notchipotle.com` are not.
bool hostOnDomains(String host, Iterable<String> domains) {
  final h = _stripWww(host.toLowerCase());
  if (!_asciiHost.hasMatch(h)) return false;
  for (final raw in domains) {
    final d = canonicalDomain(raw);
    if (d == null) continue;
    if (h == d || h.endsWith('.$d')) return true;
  }
  return false;
}

/// Whether [kcal] appears in [text] as a whole number: `1050` matches
/// "1050 Cal" and "1,050 calories" but not "11050", "1050.5" or "1,0500".
bool numberGrounded(int kcal, String text) {
  if (kcal < 0) return false;
  final digits = kcal.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromRight = digits.length - i;
    if (i > 0 && fromRight % 3 == 0) buf.write(',?');
    buf.write(digits[i]);
  }
  final re = RegExp('(?<![0-9])(?<![0-9][.,])${buf.toString()}'
      r'(?![0-9])(?![.,][0-9])');
  return re.hasMatch(text);
}

/// The screen for one outcome's claimed source.
class SourceCheck {
  const SourceCheck({
    required this.normalizedUrl,
    required this.host,
    required this.cited,
    required this.official,
    required this.groundedFigures,
    required this.ungroundedFigures,
    required this.modelOnlyFigures,
  });

  /// Null when the claimed URL is missing or not launchable.
  final String? normalizedUrl;
  final String? host;

  /// The normalized claim EXACTLY equals a normalized URL the search
  /// returned (a URL elsewhere on a cited domain is not cited).
  final bool cited;

  /// [host] is on one of the chain's table domains.
  final bool official;

  /// Figures found in VERBATIM evidence for this exact URL.
  final List<int> groundedFigures;

  /// Figures found nowhere in verbatim evidence for this URL.
  final List<int> ungroundedFigures;

  /// Of [ungroundedFigures], those that appear only in the model's own
  /// attributed spans (OpenAI / xAI) — never enough to APPLY.
  final List<int> modelOnlyFigures;

  bool get launchable => normalizedUrl != null;

  /// Cited, official, and every published figure verbatim-grounded.
  bool get passes =>
      cited &&
      official &&
      groundedFigures.isNotEmpty &&
      ungroundedFigures.isEmpty;

  /// The first failed rule, for the decision log (reason codes only).
  String get reason {
    if (normalizedUrl == null) return 'source_not_launchable';
    if (!cited) return 'source_not_cited';
    if (!official) return 'source_not_official';
    if (groundedFigures.isEmpty && ungroundedFigures.isEmpty) {
      return 'no_figures';
    }
    if (ungroundedFigures.isNotEmpty) {
      return modelOnlyFigures.length == ungroundedFigures.length
          ? 'grounded_by_model_only'
          : 'figure_not_grounded';
    }
    return 'ok';
  }
}

/// Screens [sourceUrl] against what the search returned.
SourceCheck checkSource({
  required String? sourceUrl,
  required List<String> citedUrls,
  required List<LookupEvidence> evidence,
  List<String> chainDomains = const [],
  List<int> figures = const [],
}) {
  final norm = normalizeSourceUrl(sourceUrl);
  final host = norm == null ? null : Uri.parse(norm).host;
  final cited =
      norm != null && citedUrls.any((u) => normalizeSourceUrl(u) == norm);
  final official = host != null && hostOnDomains(host, chainDomains);
  final verbatim = StringBuffer();
  final modelSpans = StringBuffer();
  if (norm != null) {
    for (final e in evidence) {
      if (normalizeSourceUrl(e.url) != norm) continue;
      (e.verbatim ? verbatim : modelSpans)
        ..write(e.text)
        ..write('\n');
    }
  }
  final grounded = <int>[];
  final ungrounded = <int>[];
  final modelOnly = <int>[];
  for (final f in figures.toSet()) {
    if (numberGrounded(f, verbatim.toString())) {
      grounded.add(f);
    } else {
      ungrounded.add(f);
      if (numberGrounded(f, modelSpans.toString())) modelOnly.add(f);
    }
  }
  return SourceCheck(
    normalizedUrl: norm,
    host: host,
    cited: cited,
    official: official,
    groundedFigures: grounded,
    ungroundedFigures: ungrounded,
    modelOnlyFigures: modelOnly,
  );
}
