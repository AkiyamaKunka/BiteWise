// OpenAI and xAI Responses-API lookups (design L2) against documented
// shapes. Neither provider returns page text, so their evidence is the
// model's own span and can never ground an APPLY.
import 'package:calorie_tracker/services/assist/clients/citation_check.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:calorie_tracker/services/assist/clients/responses_lookup_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _bigMac = 'https://www.mcdonalds.com/us/en-us/product/big-mac.html';

void main() {
  group('OpenAI', () {
    OpenAiLookupClient client(ScriptedClient s) =>
        OpenAiLookupClient(apiKey: () => 'test-key', client: s.client);

    test('golden: fixed listed model, sources included, not stored',
        () async {
      final s = ScriptedClient([(_) => fixture200('openai_found.json')]);
      await client(s).submit(bigMacRequest, chainDomains: mcdDomains);
      final req = s.requests.single;
      expect(req.url.toString(), 'https://api.openai.com/v1/responses');
      expect(req.headers['authorization'], 'Bearer test-key');
      final body = s.bodies.single;
      expect(body['model'], 'gpt-4.1-mini');
      expect(body['tools'], [
        {
          'type': 'web_search',
          'search_context_size': 'low',
          'user_location': {'type': 'approximate', 'country': 'US'},
          'filters': {
            'allowed_domains': ['mcdonalds.com']
          },
        }
      ]);
      expect(body['include'], ['web_search_call.action.sources']);
      expect(body['max_tool_calls'], 2);
      expect(body['max_output_tokens'], 1500);
      expect(body['store'], false);
      expect(dataBlock(body['input'] as String),
          bigMacRequest.toContractJson());
    });

    test('found: utm-tagged citation matches; evidence is model-only',
        () async {
      final s = ScriptedClient([(_) => fixture200('openai_found.json')]);
      final o = await client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect(o.provider, LookupRecipient.openai);
      expect(o.result!.matches.single.publishedCalories, 590);
      expect(o.citedUrls, contains(_bigMac));
      expect(o.citedUrls, contains('$_bigMac?utm_source=openai'));
      expect(o.evidence, hasLength(1));
      expect(o.evidence.single.verbatim, isFalse);
      expect(o.evidence.single.text, startsWith('([mcdonalds.com]'));
      expect(o.searches, 1);
      expect(o.cost.usd,
          closeTo(0.01 + 8721 * 0.40 / 1e6 + 412 * 1.60 / 1e6, 1e-9));
      final c = checkSource(
          sourceUrl: o.result!.sourceUrl,
          citedUrls: o.citedUrls,
          evidence: o.evidence,
          chainDomains: mcdDomains,
          figures: o.result!.matches.single.allFigures);
      expect(c.cited, isTrue);
      expect(c.official, isTrue);
      expect(c.passes, isFalse, reason: 'no page text → suggestion at most');
    });

    test('incomplete → truncated; failed status → transient server', () async {
      final a = await client(
              ScriptedClient([(_) => fixture200('openai_incomplete.json')]))
          .submit(bigMacRequest);
      expect(a.failure!.code, LookupFailureCode.truncated);
      final body = fixture('openai_found.json')
        ..['status'] = 'failed'
        ..['error'] = {'code': 'server_error', 'message': 'x'};
      final b = await client(ScriptedClient([(_) => json200(body)]))
          .submit(bigMacRequest);
      expect(b.failure!.code, LookupFailureCode.server);
      expect(b.failure!.transient, isTrue);
    });

    test('a refusal part → refused', () async {
      final body = fixture('openai_found.json');
      final msg = (body['output'] as List)[1] as Map;
      msg['content'] = [
        {'type': 'refusal', 'refusal': 'I cannot help with that.'}
      ];
      final o = await client(ScriptedClient([(_) => json200(body)]))
          .submit(bigMacRequest);
      expect(o.failure!.code, LookupFailureCode.refused);
    });

    test('worst case fits the default cap', () {
      final c = client(ScriptedClient([(_) => json200({})]));
      expect(c.worstCaseFirstRequestUsd(), lessThan(0.05));
    });
  });

  group('xAI', () {
    XaiLookupClient client(ScriptedClient s,
            {LookupCostPolicy policy =
                const LookupCostPolicy(maxUsdPerLookup: 0.20)}) =>
        XaiLookupClient(
            apiKey: () => 'test-key',
            modelOf: () => 'grok-4.7',
            client: s.client,
            policy: policy);

    test('golden: user model, max_turns, filters ≤5 domains, not stored',
        () async {
      final s = ScriptedClient([(_) => fixture200('xai_found.json')]);
      await client(s).submit(bigMacRequest, chainDomains: const [
        'mcdonalds.com', 'a.com', 'b.com', 'c.com', 'd.com', 'e.com'
      ]);
      final req = s.requests.single;
      expect(req.url.toString(), 'https://api.x.ai/v1/responses');
      final body = s.bodies.single;
      expect(body.keys.toSet(),
          {'model', 'input', 'tools', 'max_turns', 'max_output_tokens', 'store'});
      expect(body['model'], 'grok-4.7');
      expect(body['max_turns'], 2);
      expect(body['store'], false);
      final tool = (body['tools'] as List).single as Map;
      expect(tool['type'], 'web_search');
      expect((tool['filters'] as Map)['allowed_domains'], hasLength(5));
      final input = (body['input'] as List).single as Map;
      expect(input['role'], 'user');
      expect(dataBlock(input['content'] as String),
          bigMacRequest.toContractJson());
    });

    test('found: an inline [[1]](url) inside the JSON is stripped', () async {
      final s = ScriptedClient([(_) => fixture200('xai_found.json')]);
      final o = await client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect(o.provider, LookupRecipient.xai);
      expect(o.result!.matches.single.publishedCalories, 590);
      expect(o.rawText, contains('[[1]]'), reason: 'raw text kept as sent');
      expect(o.citedUrls, [
        _bigMac,
        'https://www.fastfoodnutrition.org/mcdonalds/big-mac'
      ]);
      expect(o.evidence.single.verbatim, isFalse);
      expect(o.evidence.single.text, startsWith('[[1]]('));
      expect(o.cost.reportedUsd, closeTo(0.01967, 1e-9));
      expect(o.searches, 1);
    });

    test('at the default 5¢ cap the pre-flight refuses: zero calls', () async {
      final s = ScriptedClient([(_) => fixture200('xai_found.json')]);
      final o = await client(s, policy: const LookupCostPolicy())
          .submit(bigMacRequest);
      expect(o.failure!.code, LookupFailureCode.costCap);
      expect(s.requests, isEmpty);
      expect(
          client(s).worstCaseFirstRequestUsd(), greaterThan(0.05));
    });

    test('searches fall back to the usage details', () {
      final c = client(ScriptedClient([(_) => json200({})]));
      final cost = c.costOf({
        'usage': {
          'input_tokens': 100,
          'output_tokens': 10,
          'server_side_tool_usage_details': {'web_search_calls': 2},
          'cost_in_nano_usd': 12000000,
        }
      }, 0);
      expect(cost.searches, 2);
      expect(cost.reportedUsd, closeTo(0.012, 1e-12));
    });
  });
}
