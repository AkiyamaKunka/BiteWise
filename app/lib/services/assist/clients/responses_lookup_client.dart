/// OpenAI and xAI lookups through their Responses APIs (design L2).
///
/// OpenAI (developers.openai.com/api/docs/guides/tools-web-search, read
/// 2026-10-23): POST /v1/responses with `tools: [{type: web_search,
/// search_context_size, user_location{type: approximate, country},
/// filters{allowed_domains ≤100}}]` and `include:
/// [web_search_call.action.sources]`. Output: `web_search_call` items
/// (`action{type: search, query, sources[{type: url, url}]}`) and a
/// `message` whose `output_text` carries `url_citation{url, title,
/// start_index, end_index}` annotations. Citation URLs come back with
/// `?utm_source=openai` appended. Supported models per the guide: gpt-5.5
/// (recommended), gpt-4.1, gpt-4.1-mini, o4-mini (shut down 2026-10-23);
/// gpt-6-luna, the app's photo default, is NOT listed, so lookups use a
/// fixed listed model.
///
/// xAI (docs.x.ai search-tools, citations, API reference, read
/// 2026-10-23): POST https://api.x.ai/v1/responses with `tools: [{type:
/// web_search, filters{allowed_domains ≤5}}]`, `max_turns` (caps agentic
/// TURNS, not individual searches — a turn may search in parallel),
/// `store`. Output annotations are `url_citation{url, start_index,
/// end_index, title: "1"}` over inline `[[1]](url)` markers in the text;
/// the SDK also exposes a `citations` URL list. Usage reports
/// `cost_in_usd_ticks` (1e10 per USD) and server-side tool counts.
///
/// Neither returns any text FROM the cited page — only the model's own
/// answer spans. Evidence from these clients is therefore `verbatim:
/// false`, and under the design's grounding rule an OpenAI or xAI lookup
/// can only ever produce a suggestion, never an automatic APPLY.
///
/// A `url_citation` annotation is the MODEL's claim: xAI builds it from the
/// inline `[[n]](url)` marker the model wrote, and nothing makes an OpenAI
/// annotation URL one the search returned. So [LookupOutcome.citedUrls]
/// holds only what the search itself returned — OpenAI's
/// `web_search_call.action.sources` and xAI's top-level `citations` (the
/// URLs its search encountered) — plus an annotation URL only when it
/// normalizes to one of those. An invented link never counts as cited, so
/// it can never become the source of a suggestion.
library;

import 'citation_check.dart';
import 'http_lookup_client.dart';
import 'lookup_client.dart';
import 'lookup_contract_adapter.dart';
import 'lookup_cost.dart';

final RegExp _xaiInlineCite = RegExp(r'\[\[\d+\]\]\([^)\s]*\)');
final RegExp _mdLinkCite = RegExp(r'\s*\(\[[^\]]*\]\([^)\s]*\)\)');

abstract class _ResponsesLookupClient extends HttpLookupClient {
  _ResponsesLookupClient({
    required super.apiKey,
    super.client,
    super.budget,
    super.policy,
    super.perCallDeadline,
    super.overallDeadline,
  });

  Uri get endpoint;

  /// The request body (public for the request golden tests).
  Map<String, Object?> buildBody(String prompt,
      {String? country, List<String> domains = const []});

  LookupCost costOf(Map<String, dynamic> body, int searchCalls);

  /// Inline citation markup removed so a marker the model put INSIDE the
  /// JSON (right after a number) cannot break the parse.
  String stripCitationMarkup(String text) =>
      text.replaceAll(_xaiInlineCite, '').replaceAll(_mdLinkCite, '');

  @override
  Future<LookupAnswer> runLookup(String key, LookupRequest request,
      List<String> domains, LookupRun run) async {
    final worst = worstCaseFirstRequestUsd();
    run.ensureWithinCap(worst);
    final body = await postJson(
        endpoint,
        {'Authorization': 'Bearer $key'},
        buildBody(request.prompt,
            country: request.iso2Country, domains: domains),
        run,
        worstCaseUsd: worst);
    final output = body['output'];
    var searchCalls = 0;
    if (output is List) {
      for (final item in output) {
        if (item is Map && item['type'] == 'web_search_call') {
          final action = item['action'];
          // open_page / find_in_page actions are not billed searches.
          if (action is! Map || action['type'] == 'search') searchCalls++;
        }
      }
    }
    run.add(costOf(body, searchCalls));
    final err = body['error'];
    if (err is Map) throw LookupAbort(responsesErrorFailure(err));
    final status = body['status'];
    if (status == 'incomplete') {
      final details = body['incomplete_details'];
      final reason = details is Map ? details['reason'] : null;
      throw LookupAbort(reason == 'content_filter'
          ? const LookupFailure(LookupFailureCode.refused,
              transient: false, message: 'content filter')
          : const LookupFailure(LookupFailureCode.truncated,
              transient: false, message: 'response incomplete'));
    }
    if (status != 'completed') {
      throw LookupAbort(LookupFailure(
          status == 'failed'
              ? LookupFailureCode.server
              : LookupFailureCode.malformedReply,
          transient: status == 'failed',
          message: 'response status $status'));
    }
    if (output is! List) {
      throw const LookupAbort(LookupFailure(LookupFailureCode.malformedReply,
          transient: false, message: 'reply has no output list'));
    }
    final searchUrls = <String>[]; // returned by the search itself
    final claimedUrls = <String>[]; // annotation URLs: the model's claim
    final evidence = <LookupEvidence>[];
    final texts = <String>[];
    for (final item in output) {
      if (item is! Map) continue;
      if (item['type'] == 'web_search_call') {
        final action = item['action'];
        final sources = action is Map ? action['sources'] : null;
        if (sources is List) {
          for (final s in sources) {
            if (s is Map && s['url'] is String) {
              searchUrls.add(s['url'] as String);
            }
          }
        }
        continue;
      }
      if (item['type'] != 'message') continue;
      final content = item['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is! Map) continue;
        if (part['type'] == 'refusal') {
          throw const LookupAbort(LookupFailure(LookupFailureCode.refused,
              transient: false, message: 'model refused'));
        }
        if (part['type'] != 'output_text' || part['text'] is! String) continue;
        final text = part['text'] as String;
        texts.add(text);
        final ann = part['annotations'];
        if (ann is! List) continue;
        for (final a in ann) {
          if (a is! Map || a['type'] != 'url_citation') continue;
          final url = a['url'];
          if (url is! String || url.isEmpty) continue;
          claimedUrls.add(url);
          final s = a['start_index'], e = a['end_index'];
          if (s is int && e is int && s >= 0 && e > s && e <= text.length) {
            evidence.add(LookupEvidence(
              url: url,
              text: text.substring(s, e),
              verbatim: false, // the model's own words, not the page's
              title: a['title'] is String ? a['title'] as String : null,
            ));
          }
        }
      }
    }
    final top = body['citations'];
    if (top is List) searchUrls.addAll(top.whereType<String>());
    final raw = texts.join('\n');
    var text = raw;
    if (decodeAnswerJson(text) is! Map) text = stripCitationMarkup(raw);
    final result = parseResult(text, request);
    return LookupAnswer(
        result: result,
        text: raw,
        citedUrls: searchReturnedUrls(searchUrls, claimedUrls),
        evidence: evidence);
  }
}

/// What the search returned ([searchUrls], as sent), then each of
/// [claimedUrls] whose normalized form is one of them — OpenAI's
/// `?utm_source=openai` copy of a source, say. A claimed URL that matches
/// nothing the search returned is dropped: the model invented it.
List<String> searchReturnedUrls(
    List<String> searchUrls, List<String> claimedUrls) {
  final returned = {
    for (final u in searchUrls) ?normalizeSourceUrl(u),
  };
  return dedupe([
    ...searchUrls,
    for (final u in claimedUrls)
      if (returned.contains(normalizeSourceUrl(u))) u,
  ]);
}

final RegExp _errorCodeShape = RegExp(r'^[a-z0-9_]{1,48}$');

/// An `error` object inside a Responses reply (`{code, message}`),
/// classified by its code: a rate limit is transient and says so, an
/// `invalid_*` request is permanent (a retry would spend again on the same
/// refusal), anything else is a transient server failure. Only a plain
/// identifier-shaped code reaches the diagnostics line, never the message.
LookupFailure responsesErrorFailure(Map error) {
  final raw = error['code'];
  final code = raw is String && _errorCodeShape.hasMatch(raw) ? raw : '';
  if (code == 'rate_limit_exceeded') {
    return const LookupFailure(LookupFailureCode.rateLimited,
        transient: true, message: 'response failed: rate_limit_exceeded');
  }
  if (code.startsWith('invalid_')) {
    return LookupFailure(LookupFailureCode.badRequest,
        transient: false, message: 'response failed: $code');
  }
  return LookupFailure(LookupFailureCode.server,
      transient: true,
      message: code.isEmpty ? 'response failed' : 'response failed: $code');
}

class OpenAiLookupClient extends _ResponsesLookupClient {
  OpenAiLookupClient({
    required super.apiKey,
    super.client,
    super.budget,
    super.policy,
    super.perCallDeadline,
    super.overallDeadline,
    this.model = kLookupOpenAiModel,
  });

  /// Listed as web_search-capable in OpenAI's guide, and cheap. The app's
  /// photo default (gpt-6-luna) is not listed; switching needs a live
  /// check first (design L2).
  static const String kLookupOpenAiModel = 'gpt-4.1-mini';

  final String model;

  @override
  Uri get endpoint => Uri.parse('https://api.openai.com/v1/responses');
  @override
  String get providerLabel => 'OpenAI';
  @override
  LookupRecipient get recipient => LookupRecipient.openai;
  @override
  String get lookupModel => model;

  @override
  double worstCaseFirstRequestUsd() =>
      policy.maxSearches * kOpenAiSearchCallUsd +
      kGpt41MiniPrice.usd(
          policy.promptTokensAllowance +
              policy.maxSearches * policy.tokensPerSearchAllowance,
          policy.maxOutputTokens);

  @override
  Map<String, Object?> buildBody(String prompt,
          {String? country, List<String> domains = const []}) =>
      {
        'model': model,
        'input': prompt,
        'tools': [
          {
            'type': 'web_search',
            'search_context_size': 'low',
            if (country != null)
              'user_location': {'type': 'approximate', 'country': country},
            if (domains.isNotEmpty) 'filters': {'allowed_domains': domains},
          }
        ],
        'include': ['web_search_call.action.sources'],
        'max_tool_calls': policy.maxSearches,
        'max_output_tokens': policy.maxOutputTokens,
        // Not kept on OpenAI's side for later retrieval.
        'store': false,
      };

  @override
  LookupCost costOf(Map<String, dynamic> body, int searchCalls) {
    final usage = body['usage'];
    final input = usage is Map ? intOf(usage['input_tokens']) : 0;
    final output = usage is Map ? intOf(usage['output_tokens']) : 0;
    return LookupCost(
      searches: searchCalls,
      inputTokens: input,
      outputTokens: output,
      estimatedUsd: searchCalls * kOpenAiSearchCallUsd +
          kGpt41MiniPrice.usd(input, output),
    );
  }
}

class XaiLookupClient extends _ResponsesLookupClient {
  XaiLookupClient({
    required super.apiKey,
    required this.modelOf,
    super.client,
    super.budget,
    super.policy,
    super.perCallDeadline,
    super.overallDeadline,
    this.searchesPerTurnAllowance = 2,
  });

  /// The user's selected xAI model, read per call.
  final String Function() modelOf;

  /// xAI caps TURNS (`max_turns`), and one turn may run several searches
  /// in parallel; the worst case assumes this many per turn.
  final int searchesPerTurnAllowance;

  @override
  Uri get endpoint => Uri.parse('https://api.x.ai/v1/responses');
  @override
  String get providerLabel => 'xAI';
  @override
  LookupRecipient get recipient => LookupRecipient.xai;
  @override
  String get lookupModel => modelOf().trim();

  /// Priced at grok-4.7 (the app default, $2 / $6 per MTok): with search
  /// results billed as input, this is the expensive provider — at the
  /// default 5¢ cap the pre-flight refuses it (see notes).
  @override
  double worstCaseFirstRequestUsd() {
    final searches = policy.maxSearches * searchesPerTurnAllowance;
    return searches * kXaiSearchCallUsd +
        kGrok47Price.usd(
            policy.promptTokensAllowance +
                searches * policy.tokensPerSearchAllowance,
            policy.maxOutputTokens);
  }

  @override
  Map<String, Object?> buildBody(String prompt,
          {String? country, List<String> domains = const []}) =>
      {
        'model': lookupModel,
        'input': [
          {'role': 'user', 'content': prompt}
        ],
        'tools': [
          {
            'type': 'web_search',
            // xAI's filter takes at most 5 domains (cleanDomains caps at 5).
            if (domains.isNotEmpty) 'filters': {'allowed_domains': domains},
          }
        ],
        'max_turns': policy.maxSearches,
        'max_output_tokens': policy.maxOutputTokens,
        'store': false,
      };

  @override
  LookupCost costOf(Map<String, dynamic> body, int searchCalls) {
    final usage = body['usage'];
    final input = usage is Map ? intOf(usage['input_tokens']) : 0;
    final output = usage is Map ? intOf(usage['output_tokens']) : 0;
    var searches = searchCalls;
    if (searches == 0 && usage is Map) {
      final details = usage['server_side_tool_usage_details'];
      if (details is Map) {
        for (final e in details.entries) {
          if ('${e.key}'.contains('web_search')) searches += intOf(e.value);
        }
      }
    }
    double? reported;
    if (usage is Map) {
      final ticks = usage['cost_in_usd_ticks'];
      final nano = usage['cost_in_nano_usd'];
      if (ticks is num) {
        reported = ticks / kXaiTicksPerUsd;
      } else if (nano is num) {
        reported = nano / 1e9;
      }
    }
    return LookupCost(
      searches: searches,
      inputTokens: input,
      outputTokens: output,
      estimatedUsd:
          searches * kXaiSearchCallUsd + kGrok47Price.usd(input, output),
      reportedUsd: reported,
    );
  }
}
