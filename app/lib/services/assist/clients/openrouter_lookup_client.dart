/// OpenRouter chat completions with web search (design R5b).
///
/// Shapes from openrouter.ai/docs/guides/features/web-search and
/// …/server-tools/web-search (read 2026-10-23):
///   - web plugin: `plugins: [{id: web, engine: exa, max_results,
///     include_domains}]` (`:online` is a shortcut for it);
///   - server tool: `tools: [{type: openrouter:web_search, parameters:
///     {engine, max_results, max_uses, allowed_domains}}]`;
///   - results: `choices[0].message.annotations[]` of
///     `{type: url_citation, url_citation: {url, title, content,
///     start_index, end_index}}`; `content` is "added by OpenRouter if
///     available" — for Exa, extractive highlights from the page;
///   - Exa: $0.007 per request (up to 10 results).
///
/// The server-tool page now calls the plugin and `:online` DEPRECATED in
/// favour of the server tool. The design pinned the plugin, and it is kept
/// as the default because it does not depend on the user's model calling a
/// tool (the default model is a `~google/…-latest` alias, and the user can
/// pick any slug): the plugin searches once, before the model runs. The
/// server-tool mode is implemented and tested for the day the plugin goes.
library;

import 'http_failure.dart';
import 'http_lookup_client.dart';
import 'lookup_client.dart';
import 'lookup_contract_adapter.dart';
import 'lookup_cost.dart';

enum OpenRouterSearchMode { webPlugin, serverTool }

class OpenRouterLookupClient extends HttpLookupClient {
  OpenRouterLookupClient({
    required super.apiKey,
    required this.modelOf,
    super.client,
    super.budget,
    super.policy,
    super.perCallDeadline,
    super.overallDeadline,
    this.mode = OpenRouterSearchMode.webPlugin,
    this.maxResults = 3,
  });

  static final Uri endpoint =
      Uri.parse('https://openrouter.ai/api/v1/chat/completions');

  /// The user's selected OpenRouter model, read per call.
  final String Function() modelOf;
  final OpenRouterSearchMode mode;
  final int maxResults;

  /// The user's selected model, minus a `:online` suffix (we attach the
  /// search ourselves; the suffix would add a second, unpinned plugin).
  @override
  String get lookupModel {
    final m = modelOf().trim();
    return m.endsWith(':online') ? m.substring(0, m.length - 7) : m;
  }

  @override
  String get providerLabel => 'OpenRouter';
  @override
  LookupRecipient get recipient => LookupRecipient.openrouter;

  int get _maxSearches =>
      mode == OpenRouterSearchMode.webPlugin ? 1 : policy.maxSearches;

  /// Exa fees for every search the request may run, plus an allowance for
  /// the user's model tokens (its price is unknown here; the reply's
  /// `usage.cost` replaces the estimate).
  @override
  double worstCaseFirstRequestUsd() =>
      _maxSearches * kOpenRouterExaRequestUsd + policy.unknownModelAllowanceUsd;

  Map<String, String> _headers(String key) => {
        'HTTP-Referer': 'https://github.com/AkiyamaKunka/BiteWise',
        'X-OpenRouter-Title': 'BiteWise',
        'Authorization': 'Bearer $key',
      };

  /// The request body (public for the request golden test).
  Map<String, Object?> buildBody(String prompt,
          {List<String> domains = const []}) =>
      {
        'model': lookupModel,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
        if (mode == OpenRouterSearchMode.webPlugin)
          'plugins': [
            {
              'id': 'web',
              // Pinned: the recipient chain is fixed and disclosable
              // (design D19). Unpinned, a native-search model would send
              // the query to its own provider's search instead.
              'engine': 'exa',
              'max_results': maxResults,
              if (domains.isNotEmpty) 'include_domains': domains,
            }
          ]
        else
          'tools': [
            {
              'type': 'openrouter:web_search',
              'parameters': {
                'engine': 'exa',
                'max_results': maxResults,
                'max_uses': policy.maxSearches,
                if (domains.isNotEmpty) 'allowed_domains': domains,
              }
            }
          ],
        'max_tokens': policy.maxOutputTokens,
      };

  @override
  Future<LookupAnswer> runLookup(String key, LookupRequest request,
      List<String> domains, LookupRun run) async {
    run.ensureWithinCap(worstCaseFirstRequestUsd());
    final body = await postJson(endpoint, _headers(key),
        buildBody(composeLookupPrompt(request), domains: domains), run);
    run.add(_costOf(body));
    // OpenRouter can answer an upstream failure inside a 200.
    final err = body['error'];
    if (err is Map) throw LookupAbort(_errorFailure(err));
    final choices = body['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const LookupAbort(LookupFailure(LookupFailureCode.malformedReply,
          transient: false, message: 'reply has no choices'));
    }
    final choice = choices.first as Map;
    final cErr = choice['error'];
    if (cErr is Map) throw LookupAbort(_errorFailure(cErr));
    switch (choice['finish_reason']) {
      case 'length':
        throw const LookupAbort(LookupFailure(LookupFailureCode.truncated,
            transient: false, message: 'answer cut at max_tokens'));
      case 'content_filter':
        throw const LookupAbort(LookupFailure(LookupFailureCode.refused,
            transient: false, message: 'content filter'));
      case 'error':
        throw const LookupAbort(LookupFailure(LookupFailureCode.server,
            transient: true, message: 'upstream error'));
    }
    final message = choice['message'];
    if (message is! Map) {
      throw const LookupAbort(LookupFailure(LookupFailureCode.malformedReply,
          transient: false, message: 'reply has no message'));
    }
    final text = _contentText(message['content']);
    final urls = <String>[];
    final evidence = <LookupEvidence>[];
    final ann = message['annotations'];
    if (ann is List) {
      for (final a in ann) {
        if (a is! Map || a['type'] != 'url_citation') continue;
        final c = a['url_citation'];
        if (c is! Map) continue;
        final url = c['url'];
        if (url is! String || url.isEmpty) continue;
        urls.add(url);
        final content = c['content'];
        if (content is String && content.trim().isNotEmpty) {
          evidence.add(LookupEvidence(
            url: url,
            text: content,
            verbatim: true, // Exa highlights: extracted from the page
            title: c['title'] is String ? c['title'] as String : null,
          ));
        }
      }
    }
    final result = parseResult(text, request);
    return LookupAnswer(
        result: result,
        text: text,
        citedUrls: dedupe(urls),
        evidence: evidence);
  }

  /// `message.content` is a string, or (some upstreams) a list of parts.
  String _contentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((p) => p['type'] == 'text' && p['text'] is String)
          .map((p) => p['text'] as String)
          .join();
    }
    return '';
  }

  LookupFailure _errorFailure(Map err) {
    final code = err['code'];
    final status = code is int ? code : int.tryParse('$code') ?? 502;
    if (status == 200) {
      return const LookupFailure(LookupFailureCode.server,
          transient: true, message: 'upstream error');
    }
    return classifyHttpFailureFromErrorObject(status, err);
  }

  LookupCost _costOf(Map<String, dynamic> body) {
    final usage = body['usage'];
    final input = usage is Map ? intOf(usage['prompt_tokens']) : 0;
    final output = usage is Map ? intOf(usage['completion_tokens']) : 0;
    final stu = usage is Map ? usage['server_tool_use'] : null;
    final searches = mode == OpenRouterSearchMode.webPlugin
        // The plugin runs (and bills) one Exa request per call.
        ? 1
        : (stu is Map ? intOf(stu['web_search_requests']) : 0);
    final reported = usage is Map && usage['cost'] is num
        ? (usage['cost'] as num).toDouble()
        : null;
    return LookupCost(
      searches: searches,
      inputTokens: input,
      outputTokens: output,
      estimatedUsd: searches * kOpenRouterExaRequestUsd +
          policy.unknownModelAllowanceUsd,
      reportedUsd: reported,
    );
  }
}
