// OpenRouter lookups: web plugin pinned to Exa (default) and the
// openrouter:web_search server tool, against documented response shapes.
import 'package:calorie_tracker/services/assist/clients/citation_check.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:calorie_tracker/services/assist/clients/openrouter_lookup_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

OpenRouterLookupClient _client(ScriptedClient s,
        {String model = '~google/gemini-flash-latest',
        OpenRouterSearchMode mode = OpenRouterSearchMode.webPlugin,
        LookupCostPolicy policy = const LookupCostPolicy()}) =>
    OpenRouterLookupClient(
        apiKey: () => 'test-key',
        modelOf: () => model,
        client: s.client,
        mode: mode,
        policy: policy);

void main() {
  test('golden (plugin): the user\'s model, Exa pinned, 3 results, domains',
      () async {
    final s = ScriptedClient([(_) => fixture200('openrouter_found.json')]);
    await _client(s).submit(bigMacRequest, chainDomains: mcdDomains);
    final req = s.requests.single;
    expect(req.url.toString(), 'https://openrouter.ai/api/v1/chat/completions');
    expect(req.headers['authorization'], 'Bearer test-key');
    expect(req.headers['http-referer'], 'https://github.com/AkiyamaKunka/BiteWise');
    expect(req.headers['x-openrouter-title'], 'Chopstats');
    final body = s.bodies.single;
    expect(body.keys.toSet(), {'model', 'messages', 'plugins', 'max_tokens'});
    expect(body['model'], '~google/gemini-flash-latest');
    expect(body['plugins'], [
      {
        'id': 'web',
        'engine': 'exa',
        'max_results': 3,
        'include_domains': ['mcdonalds.com'],
      }
    ]);
    expect(body['max_tokens'], 1500);
    final prompt = ((body['messages'] as List).single as Map)['content'];
    expect(prompt, bigMacRequest.prompt);
    expect(dataBlock(prompt as String), bigMacRequest.body);
  });

  test('a :online model is not double-searched', () async {
    final s = ScriptedClient([(_) => fixture200('openrouter_found.json')]);
    final c = _client(s, model: 'openai/gpt-5.2:online');
    final o = await c.submit(bigMacRequest);
    expect(s.bodies.single['model'], 'openai/gpt-5.2');
    expect(o.model, 'openai/gpt-5.2');
  });

  test('golden (server tool): openrouter:web_search with max_uses', () async {
    final s = ScriptedClient([(_) => fixture200('openrouter_found.json')]);
    await _client(s, mode: OpenRouterSearchMode.serverTool)
        .submit(bigMacRequest, chainDomains: mcdDomains);
    final body = s.bodies.single;
    expect(body.containsKey('plugins'), isFalse);
    expect(body['tools'], [
      {
        'type': 'openrouter:web_search',
        'parameters': {
          'engine': 'exa',
          'max_results': 3,
          'max_uses': 2,
          'allowed_domains': ['mcdonalds.com'],
        }
      }
    ]);
  });

  test('found: fenced JSON parsed; Exa content is verbatim evidence',
      () async {
    final s = ScriptedClient([(_) => fixture200('openrouter_found.json')]);
    final o = await _client(s).submit(bigMacRequest);
    expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
    expect(o.provider, LookupRecipient.openrouter);
    expect(o.result!.matches.single.publishedCalories, 590);
    expect(o.citedUrls, hasLength(3));
    expect(o.evidence, hasLength(3));
    expect(o.evidence.every((e) => e.verbatim), isTrue);
    final c = checkSource(
        sourceUrl: o.result!.sourceUrl,
        citedUrls: o.citedUrls,
        evidence: o.evidence,
        chainDomains: mcdDomains,
        figures: o.result!.matches.single.allFigures);
    expect(c.passes, isTrue, reason: c.reason);
  });

  test('cost: the reported usage.cost wins over the estimate', () async {
    final s = ScriptedClient([(_) => fixture200('openrouter_found.json')]);
    final o = await _client(s).submit(bigMacRequest);
    expect(o.cost.reportedUsd, 0.00912);
    expect(o.cost.usd, 0.00912);
    expect(o.cost.searches, 1, reason: 'the plugin bills one Exa request');
    expect(o.cost.estimatedUsd, closeTo(0.007 + 0.02, 1e-9));
  });

  test('an annotation without Exa content is a claim: not cited', () async {
    // Possibly built from a markdown link the model wrote: nothing proves
    // the search returned it, so it can never be a suggestion's source.
    final s = ScriptedClient([(_) => fixture200('openrouter_no_content.json')]);
    final o = await _client(s).submit(bigMacRequest);
    expect(o.isDone, isTrue);
    expect(o.citedUrls, isEmpty);
    expect(o.evidence, isEmpty);
    final c = checkSource(
        sourceUrl: o.result!.sourceUrl,
        citedUrls: o.citedUrls,
        evidence: o.evidence,
        chainDomains: mcdDomains,
        figures: o.result!.matches.single.allFigures);
    expect(c.cited, isFalse);
    expect(c.reason, 'source_not_cited');
    expect(c.passes, isFalse);
  });

  test('only content-bearing annotations count, whitespace is no content',
      () async {
    final body = fixture('openrouter_found.json');
    final ann = (((body['choices'] as List).first as Map)['message']
        as Map)['annotations'] as List;
    ((ann[1] as Map)['url_citation'] as Map)['content'] = '   ';
    ((ann[2] as Map)['url_citation'] as Map).remove('content');
    final o = await _client(ScriptedClient([(_) => json200(body)]))
        .submit(bigMacRequest);
    expect(o.citedUrls,
        ['https://www.mcdonalds.com/us/en-us/product/big-mac.html']);
    expect(o.evidence, hasLength(1));
  });

  test('an upstream error inside a 200 is classified by its code', () async {
    final s =
        ScriptedClient([(_) => fixture200('openrouter_error_in_200.json')]);
    final o = await _client(s).submit(bigMacRequest);
    expect(o.failure!.code, LookupFailureCode.server);
    expect(o.failure!.transient, isTrue);
  });

  test('finish_reason length → truncated; content_filter → refused',
      () async {
    final a = await _client(
            ScriptedClient([(_) => fixture200('openrouter_length.json')]))
        .submit(bigMacRequest);
    expect(a.failure!.code, LookupFailureCode.truncated);
    final body = fixture('openrouter_found.json');
    ((body['choices'] as List).first as Map)['finish_reason'] =
        'content_filter';
    final b = await _client(ScriptedClient([(_) => json200(body)]))
        .submit(bigMacRequest);
    expect(b.failure!.code, LookupFailureCode.refused);
  });

  test('content as a parts list is read too', () async {
    final body = fixture('openrouter_found.json');
    final msg = ((body['choices'] as List).first as Map)['message'] as Map;
    msg['content'] = [
      {'type': 'text', 'text': msg['content']}
    ];
    final o = await _client(ScriptedClient([(_) => json200(body)]))
        .submit(bigMacRequest);
    expect(o.isDone, isTrue, reason: '${o.failure}');
  });

  test('402 out of credits → billing, no retry', () async {
    final s = ScriptedClient([
      (_) => http.Response(
          '{"error":{"code":402,"message":"Insufficient credits"}}', 402)
    ]);
    final o = await _client(s).submit(bigMacRequest);
    expect(o.failure!.code, LookupFailureCode.billing);
    expect(s.requests, hasLength(1));
  });

  test('an unaffordable cap refuses before any call', () async {
    final s = ScriptedClient([(_) => fixture200('openrouter_found.json')]);
    final o = await _client(s,
            policy: const LookupCostPolicy(maxUsdPerLookup: 0.01))
        .submit(bigMacRequest);
    expect(o.failure!.code, LookupFailureCode.costCap);
    expect(s.requests, isEmpty);
  });

  test('a malformed reply never yields a result', () async {
    final o = await _client(ScriptedClient([
      (_) => json200({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'content': 'Sorry, I cannot browse.'}
              }
            ]
          })
    ])).submit(itemRequest('x'));
    expect(o.failure!.code, LookupFailureCode.malformedReply);
    expect(o.result, isNull);
  });
}
