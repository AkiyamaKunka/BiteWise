/// Anthropic Messages API with the web_search server tool (design R5b).
///
/// Shapes from platform.claude.com/docs/en/agents-and-tools/tool-use/
/// web-search-tool (read 2026-10-23):
///   - tool `{type: web_search_20250305, name: web_search, max_uses,
///     allowed_domains, user_location{type: approximate, country}}`;
///   - reply content: text, `server_tool_use`, `web_search_tool_result`
///     (`content` is a LIST of `web_search_result{url, title, page_age,
///     encrypted_content}` on success, a single
///     `web_search_tool_result_error{error_code}` OBJECT on error, HTTP 200
///     either way), text blocks with `citations` of type
///     `web_search_result_location{url, title, cited_text ≤150 chars}`;
///   - `usage.server_tool_use.web_search_requests`;
///   - `stop_reason: pause_turn` → send the paused assistant content back
///     unchanged in a new request.
///
/// The model is FIXED (claude-haiku-5-5), independent of the user's photo
/// model: search results are billed as input tokens, so the cheapest model
/// keeps a lookup at about 2–3¢. Haiku 5.5 is not on the dynamic-filtering
/// list, so the basic tool version is the right one.
library;

import 'http_lookup_client.dart';
import 'lookup_client.dart';
import 'lookup_contract_adapter.dart';
import 'lookup_cost.dart';

class AnthropicLookupClient extends HttpLookupClient {
  AnthropicLookupClient({
    required super.apiKey,
    super.client,
    super.budget,
    super.policy,
    super.perCallDeadline,
    super.overallDeadline,
    this.model = kLookupAnthropicModel,
    this.effort = 'low',
  });

  static const String kLookupAnthropicModel = 'claude-haiku-5-5';
  static const String kWebSearchToolType = 'web_search_20250305';
  static final Uri endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  final String model;

  /// `output_config.effort` (GA; Haiku 5.5 defaults to medium). Low keeps
  /// thinking short on a copy-the-number task. Null omits the field.
  final String? effort;

  @override
  String get providerLabel => 'Anthropic';
  @override
  LookupRecipient get recipient => LookupRecipient.anthropic;
  @override
  String get lookupModel => model;

  /// Worst case of request number [continuation] (0 = the first) when
  /// [searchesSoFar] searches already ran and this one may run [maxUses]:
  /// every earlier result is re-sent as input on a continuation.
  double worstCaseRequestUsd(
      {required int continuation,
      required int searchesSoFar,
      required int maxUses}) {
    final input = policy.promptTokensAllowance +
        (searchesSoFar + maxUses) * policy.tokensPerSearchAllowance +
        continuation * policy.maxOutputTokens;
    return maxUses * kAnthropicSearchUsd +
        haikuUsd(input, policy.maxOutputTokens);
  }

  @override
  double worstCaseFirstRequestUsd() => worstCaseRequestUsd(
      continuation: 0, searchesSoFar: 0, maxUses: policy.maxSearches);

  Map<String, String> _headers(String key) => {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
      };

  /// The request body (public for the request golden test).
  Map<String, Object?> buildBody(List<Map<String, Object?>> messages,
          {required int maxUses,
          String? country,
          List<String> domains = const []}) =>
      {
        'model': model,
        'max_tokens': policy.maxOutputTokens,
        if (effort != null) 'output_config': {'effort': effort},
        'messages': messages,
        'tools': [
          {
            'type': kWebSearchToolType,
            'name': 'web_search',
            'max_uses': maxUses,
            // Country only: never a city, region or timezone (design §4).
            if (country != null)
              'user_location': {'type': 'approximate', 'country': country},
            if (domains.isNotEmpty) 'allowed_domains': domains,
          }
        ],
      };

  @override
  Future<LookupAnswer> runLookup(String key, LookupRequest request,
      List<String> domains, LookupRun run) async {
    final messages = <Map<String, Object?>>[
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': composeLookupPrompt(request)}
        ],
      }
    ];
    final turn = <Map<String, dynamic>>[]; // the assistant turn, all parts
    for (var continuation = 0;; continuation++) {
      final searchesSoFar = run.cost.searches;
      // A continuation may only spend the searches the first request left.
      // max_uses is per REQUEST and the API needs it >= 1, so with nothing
      // left the continuation is not sent at all: a paused turn resumes a
      // trailing server_tool_use by running it, and no request field can
      // forbid that search (tool_choice none is undefined on a resume).
      final left = policy.maxSearches - searchesSoFar;
      if (continuation > 0 && left <= 0) {
        throw LookupAbort(LookupFailure(LookupFailureCode.truncated,
            // Permanent: a retry would spend the same searches again.
            transient: false,
            message: 'paused after $searchesSoFar searches; the lookup '
                'allows ${policy.maxSearches}'));
      }
      final maxUses = continuation == 0 ? policy.maxSearches : left;
      final worst = worstCaseRequestUsd(
          continuation: continuation,
          searchesSoFar: searchesSoFar,
          maxUses: maxUses);
      run.ensureWithinCap(worst);
      final body = await postJson(
          endpoint,
          _headers(key),
          buildBody(messages,
              maxUses: maxUses,
              country: request.iso2Country,
              domains: domains),
          run,
          worstCaseUsd: worst);
      run.add(_costOf(body));
      final content = body['content'];
      if (content is! List) {
        throw const LookupAbort(LookupFailure(LookupFailureCode.malformedReply,
            transient: false, message: 'reply has no content list'));
      }
      final blocks = [
        for (final b in content)
          if (b is Map<String, dynamic>) b
      ];
      turn.addAll(blocks);
      final stop = body['stop_reason'];
      if (stop == 'pause_turn') {
        if (continuation >= policy.maxContinuations) {
          throw const LookupAbort(LookupFailure(LookupFailureCode.truncated,
              transient: true, message: 'still paused after continuations'));
        }
        // Unchanged, encrypted fields and all: the API restores the search
        // results from them (a modified block is a 400).
        messages.add({'role': 'assistant', 'content': content});
        continue;
      }
      if (stop == 'refusal') {
        throw const LookupAbort(LookupFailure(LookupFailureCode.refused,
            transient: false, message: 'model refused'));
      }
      if (stop == 'max_tokens') {
        throw const LookupAbort(LookupFailure(LookupFailureCode.truncated,
            transient: false, message: 'answer cut at max_tokens'));
      }
      if (stop != 'end_turn' && stop != 'stop_sequence') {
        throw LookupAbort(LookupFailure(LookupFailureCode.malformedReply,
            transient: false, message: 'unexpected stop_reason $stop'));
      }
      return _answer(turn, request);
    }
  }

  LookupCost _costOf(Map<String, dynamic> body) {
    final usage = body['usage'];
    if (usage is! Map) return LookupCost.zero;
    final input = intOf(usage['input_tokens']) +
        intOf(usage['cache_creation_input_tokens']) +
        intOf(usage['cache_read_input_tokens']);
    final output = intOf(usage['output_tokens']);
    final stu = usage['server_tool_use'];
    var searches = stu is Map ? intOf(stu['web_search_requests']) : 0;
    if (stu is! Map) {
      // Older shapes: count the search calls themselves.
      final content = body['content'];
      if (content is List) {
        searches = content
            .where((b) =>
                b is Map &&
                b['type'] == 'server_tool_use' &&
                b['name'] == 'web_search')
            .length;
      }
    }
    return LookupCost(
      searches: searches,
      inputTokens: input,
      outputTokens: output,
      estimatedUsd:
          searches * kAnthropicSearchUsd + haikuUsd(input, output),
    );
  }

  LookupAnswer _answer(List<Map<String, dynamic>> turn, LookupRequest req) {
    final resultUrls = <String>[];
    final pageAges = <String, String>{};
    final errors = <String>[];
    var lastResultIndex = -1;
    for (var i = 0; i < turn.length; i++) {
      final b = turn[i];
      if (b['type'] != 'web_search_tool_result') continue;
      lastResultIndex = i;
      final c = b['content'];
      if (c is List) {
        for (final r in c) {
          if (r is Map && r['type'] == 'web_search_result') {
            final url = r['url'];
            if (url is String && url.isNotEmpty) {
              resultUrls.add(url);
              final age = r['page_age'];
              if (age is String && age.isNotEmpty) pageAges[url] = age;
            }
          }
        }
      } else if (c is Map && c['type'] == 'web_search_tool_result_error') {
        errors.add('${c['error_code']}');
      }
    }
    // A search error fails the lookup — except max_uses_exceeded, which
    // only means the model asked for one search too many after its
    // allowance: the searches that DID run still ground its answer.
    final hard = errors.where((e) => e != 'max_uses_exceeded').toList();
    if (hard.isNotEmpty) {
      final transient =
          hard.every((e) => e == 'too_many_requests' || e == 'unavailable');
      throw LookupAbort(LookupFailure(LookupFailureCode.searchError,
          transient: transient, message: 'web search error: ${hard.first}'));
    }
    final evidence = <LookupEvidence>[];
    for (final b in turn) {
      if (b['type'] != 'text') continue;
      final cites = b['citations'];
      if (cites is! List) continue;
      for (final c in cites) {
        if (c is! Map || c['type'] != 'web_search_result_location') continue;
        final url = c['url'], text = c['cited_text'];
        if (url is! String || text is! String || text.isEmpty) continue;
        evidence.add(LookupEvidence(
          url: url,
          text: text,
          verbatim: true,
          pageAge: pageAges[url],
          title: c['title'] is String ? c['title'] as String : null,
        ));
      }
    }
    // Citations SPLIT the answer into several text blocks (a cited number
    // becomes its own block), so "the last text block" is only a fragment
    // of the JSON. The answer is every text block after the last search
    // result, joined; when that holds no JSON (a preamble-only tail), all
    // text blocks joined.
    String join(Iterable<Map<String, dynamic>> blocks) => blocks
        .where((b) => b['type'] == 'text' && b['text'] is String)
        .map((b) => b['text'] as String)
        .join();
    var text = join(turn.skip(lastResultIndex + 1));
    if (decodeAnswerJson(text) is! Map) text = join(turn);
    final result = parseResult(text, req);
    return LookupAnswer(
      result: result,
      text: text,
      citedUrls: dedupe(resultUrls),
      evidence: evidence,
    );
  }
}
