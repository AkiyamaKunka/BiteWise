/// Client-side citation screening: is the model's claimed source a URL the
/// SEARCH actually returned, is it on the chain's official domain, and do
/// the published numbers appear in text the search system extracted from
/// that page?
///
/// The rules are lane B's (core/restaurant_assist_logic.dart, R2b "Source
/// verification details"), called, not copied: [normalizeSourceUrl] (https
/// only, printable ASCII, lowercase host without `www.`, a trailing dot,
/// userinfo or a port; query, fragment and trailing slashes dropped),
/// [grounded] (word-bounded, thousands separator optional) and
/// core/chain_match.dart's host rules (equal to, or a subdomain of, a table
/// domain; never an IDN). Lane B's decideAssist owns the APPLY decision;
/// this screen exists so every client outcome can be checked and logged
/// the same way, and so the provider fixtures are tested against the rules
/// they must satisfy.
library;

import '../../../core/chain_match.dart' show hostMatchesDomain, normalizeHost;
import '../../../core/restaurant_assist_logic.dart'
    show grounded, normalizeSourceUrl;
import 'lookup_client.dart';

export '../../../core/restaurant_assist_logic.dart'
    show grounded, normalizeSourceUrl;

final RegExp _scheme = RegExp(r'^https?://', caseSensitive: false);

String _stripWww(String host) =>
    host.startsWith('www.') ? host.substring(4) : host;

/// The normalized host of [raw], or null ([normalizeSourceUrl]'s rules).
String? sourceHost(String? raw) {
  final n = normalizeSourceUrl(raw);
  return n?.substring('https://'.length).split('/').first;
}

/// A table/filter domain in canonical form, or null when it is not a
/// plain ASCII host name (`chipotle.com`, not a URL).
String? canonicalDomain(String raw) {
  var d = raw.trim().replaceFirst(_scheme, '');
  while (d.endsWith('/')) {
    d = d.substring(0, d.length - 1);
  }
  final host = normalizeHost(d);
  return host == null ? null : _stripWww(host);
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

/// True when [host] equals one of [domains] or is a subdomain of one
/// (lane B's hostMatchesDomain on normalized hosts).
/// `chipotle.com.evil.net` and `notchipotle.com` are not.
bool hostOnDomains(String host, Iterable<String> domains) {
  final h = normalizeHost(host);
  if (h == null) return false;
  final bare = _stripWww(h);
  for (final raw in domains) {
    final d = canonicalDomain(raw);
    if (d != null && hostMatchesDomain(bare, d)) return true;
  }
  return false;
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
  final host = sourceHost(sourceUrl);
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
  final groundedFigures = <int>[];
  final ungrounded = <int>[];
  final modelOnly = <int>[];
  for (final f in figures.toSet()) {
    if (grounded(f, verbatim.toString())) {
      groundedFigures.add(f);
    } else {
      ungrounded.add(f);
      if (grounded(f, modelSpans.toString())) modelOnly.add(f);
    }
  }
  return SourceCheck(
    normalizedUrl: norm,
    host: host,
    cited: cited,
    official: official,
    groundedFigures: groundedFigures,
    ungroundedFigures: ungrounded,
    modelOnlyFigures: modelOnly,
  );
}
