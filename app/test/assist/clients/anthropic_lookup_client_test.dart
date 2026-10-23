// Anthropic web_search lookups against fixtures built from the documented
// response shapes (scripts/generate_lookup_client_fixtures.py).
import 'dart:async';
import 'dart:convert';

import 'package:calorie_tracker/services/assist/clients/anthropic_lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/citation_check.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

const _bigMac = 'https://www.mcdonalds.com/us/en-us/product/big-mac.html';

AnthropicLookupClient _client(ScriptedClient s,
        {String? key = 'test-key',
        LookupCostPolicy policy = const LookupCostPolicy(),
        LookupBudget? budget,
        Duration perCall = const Duration(seconds: 45)}) =>
    AnthropicLookupClient(
        apiKey: () => key,
        client: s.client,
        policy: policy,
        budget: budget,
        perCallDeadline: perCall);

void main() {
  group('request', () {
    test('golden: fixed haiku, basic tool, max_uses 2, country only, domains',
        () async {
      final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
      await _client(s).submit(bigMacRequest, chainDomains: mcdDomains);
      final req = s.requests.single;
      expect(req.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(req.method, 'POST');
      expect(req.headers['x-api-key'], 'test-key');
      expect(req.headers['anthropic-version'], '2023-06-01');
      expect(req.headers['content-type'], startsWith('application/json'));
      final body = s.bodies.single;
      expect(body.keys.toSet(),
          {'model', 'max_tokens', 'output_config', 'messages', 'tools'});
      expect(body['model'], 'claude-haiku-5-5');
      expect(body['max_tokens'], 1500);
      expect(body['output_config'], {'effort': 'low'});
      expect(body['tools'], [
        {
          'type': 'web_search_20250305',
          'name': 'web_search',
          'max_uses': 2,
          'user_location': {'type': 'approximate', 'country': 'US'},
          'allowed_domains': ['mcdonalds.com'],
        }
      ]);
      final messages = body['messages'] as List;
      expect(messages, hasLength(1));
      final content = (messages.single as Map)['content'] as List;
      expect(content.single['type'], 'text');
      final prompt = content.single['text'] as String;
      expect(prompt, startsWith(kPlaceholderLookupPrompt));
      expect(dataBlock(prompt), bigMacRequest.toContractJson());
      // Never the user's photo model, never an image.
      expect(jsonEncode(body).contains('"image"'), isFalse);
    });

    test('no domains → no allowed_domains; bad country → no user_location',
        () async {
      final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
      await _client(s).submit(const LookupRequest(
          items: [LookupRequestItem(name: 'Big Mac')], country: 'Earth'));
      final tool = (s.bodies.single['tools'] as List).single as Map;
      expect(tool.containsKey('allowed_domains'), isFalse);
      expect(tool.containsKey('user_location'), isFalse);
    });
  });

  group('parsing', () {
    test('found: JSON split by citations is reassembled; evidence verbatim',
        () async {
      final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect(o.provider, LookupRecipient.anthropic);
      expect(o.model, 'claude-haiku-5-5');
      final r = o.result!;
      expect(r.status, 'found');
      expect(r.matches.single.menuItem, 'Big Mac');
      expect(r.matches.single.publishedCalories, 590);
      expect(r.sourceUrl, _bigMac);
      expect(o.citedUrls, [
        _bigMac,
        'https://www.mcdonalds.com/us/en-us/about-our-food/nutrition-calculator.html',
        'https://www.fastfoodnutrition.org/mcdonalds/big-mac',
      ]);
      expect(o.evidence, hasLength(2));
      expect(o.evidence.every((e) => e.verbatim && e.url == _bigMac), isTrue);
      expect(o.evidence.first.text, contains('590 Cal'));
      expect(o.evidence.first.pageAge, 'October 2, 2026', reason: 'page_age');
      expect(o.searches, 1);
      expect(o.rawText, startsWith('{"status": "found"'));
      // Diagnostics copy carries no opaque blobs.
      final raw = jsonEncode(o.raw);
      expect(raw.contains('encrypted_content'), isFalse);
      expect(raw.contains('encrypted_index'), isFalse);
      expect(raw.contains('signature'), isFalse);
      expect(raw.contains('web_search_result'), isTrue);

      final check = checkSource(
          sourceUrl: r.sourceUrl,
          citedUrls: o.citedUrls,
          evidence: o.evidence,
          chainDomains: mcdDomains,
          figures: r.matches.single.allFigures);
      expect(check.passes, isTrue, reason: check.reason);
    });

    test('cost: tokens at haiku rates plus \$10 per 1,000 searches', () async {
      final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.cost.inputTokens, 9812);
      expect(o.cost.outputTokens, 402);
      expect(o.cost.httpCalls, 1);
      expect(o.cost.reportedUsd, isNull);
      expect(o.cost.usd,
          closeTo(0.01 + 9812 * 0.10 / 1e6 + 402 * 0.50 / 1e6, 1e-9));
      expect(o.cost.usd, lessThan(0.05));
    });

    test('pause_turn: the paused content goes back unchanged, then done',
        () async {
      final s = ScriptedClient([
        (_) => fixture200('anthropic_pause_1.json'),
        (_) => fixture200('anthropic_pause_2.json'),
      ]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect(s.requests, hasLength(2));
      final second = s.bodies[1];
      final msgs = second['messages'] as List;
      expect(msgs, hasLength(2));
      expect((msgs[1] as Map)['role'], 'assistant');
      expect((msgs[1] as Map)['content'],
          fixture('anthropic_pause_1.json')['content'],
          reason: 'encrypted_content and all, byte for byte');
      // The first request used 1 search: 1 left for the continuation.
      expect(((second['tools'] as List).single as Map)['max_uses'], 1);
      // Citations from the second reply, results from the first.
      expect(o.citedUrls.first, _bigMac);
      expect(o.evidence, isNotEmpty);
      expect(o.result!.matches.single.publishedCalories, 590);
      expect(o.cost.httpCalls, 2);
      expect(o.cost.searches, 1);
    });

    test('pause_turn past the continuation limit → truncated', () async {
      final s = ScriptedClient([(_) => fixture200('anthropic_pause_1.json')]);
      final o = await _client(s,
              policy: const LookupCostPolicy(maxUsdPerLookup: 1))
          .submit(bigMacRequest);
      expect(s.requests, hasLength(3), reason: '1 + 2 continuations');
      expect(o.kind, LookupOutcomeKind.failed);
      expect(o.failure!.code, LookupFailureCode.truncated);
      expect(o.cost.httpCalls, 3, reason: 'spend is still reported');
    });

    test('a search error object (HTTP 200) fails the lookup', () async {
      final s =
          ScriptedClient([(_) => fixture200('anthropic_search_error.json')]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.failed);
      expect(o.failure!.code, LookupFailureCode.searchError);
      expect(o.failure!.transient, isTrue, reason: 'too_many_requests');
      expect(o.failure!.message, contains('too_many_requests'));
    });

    test('max_uses_exceeded after a good search still answers', () async {
      final s = ScriptedClient([(_) => fixture200('anthropic_max_uses.json')]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect(o.result!.matches.single.publishedCalories, 590);
    });

    test('a source the search never returned is flagged, not trusted',
        () async {
      final s =
          ScriptedClient([(_) => fixture200('anthropic_uncited_source.json')]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.isDone, isTrue);
      final c = checkSource(
          sourceUrl: o.result!.sourceUrl,
          citedUrls: o.citedUrls,
          evidence: o.evidence,
          chainDomains: mcdDomains,
          figures: o.result!.matches.single.allFigures);
      expect(c.official, isTrue, reason: 'right domain…');
      expect(c.cited, isFalse, reason: '…but a made-up page');
      expect(c.passes, isFalse);
    });

    test('an answer without citations is not grounded', () async {
      final s =
          ScriptedClient([(_) => fixture200('anthropic_no_citations.json')]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.isDone, isTrue);
      expect(o.evidence, isEmpty);
      final c = checkSource(
          sourceUrl: o.result!.sourceUrl,
          citedUrls: o.citedUrls,
          evidence: o.evidence,
          chainDomains: mcdDomains,
          figures: o.result!.matches.single.allFigures);
      expect(c.cited, isTrue);
      expect(c.reason, 'figure_not_grounded');
    });

    test('a third-party database page is cited but not official', () async {
      final s =
          ScriptedClient([(_) => fixture200('anthropic_third_party.json')]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.result!.sourceType, 'third_party_db');
      final c = checkSource(
          sourceUrl: o.result!.sourceUrl,
          citedUrls: o.citedUrls,
          evidence: o.evidence,
          chainDomains: mcdDomains,
          figures: o.result!.matches.single.allFigures);
      expect(c.cited, isTrue);
      expect(c.official, isFalse);
      expect(c.groundedFigures, [563]);
    });

    test('refusal, max_tokens, malformed answers', () async {
      Future<LookupOutcome> run(Map<String, dynamic> body) => _client(
              ScriptedClient([(_) => json200(body)]))
          .submit(bigMacRequest);
      expect((await run(fixture('anthropic_refusal.json'))).failure!.code,
          LookupFailureCode.refused);
      final cut = fixture('anthropic_found.json')..['stop_reason'] = 'max_tokens';
      expect((await run(cut)).failure!.code, LookupFailureCode.truncated);
      final prose = fixture('anthropic_found.json')
        ..['content'] = [
          {'type': 'text', 'text': 'The Big Mac has 590 calories.'}
        ];
      final o = await run(prose);
      expect(o.failure!.code, LookupFailureCode.malformedReply);
      expect(o.failure!.transient, isFalse);
      expect((await run({'id': 'x'})).failure!.code,
          LookupFailureCode.malformedReply);
      final odd = fixture('anthropic_found.json')..['stop_reason'] = 'tool_use';
      expect((await run(odd)).failure!.code, LookupFailureCode.malformedReply);
    });
  });

  group('transport', () {
    test('HTTP errors classify like the analyzers', () async {
      final rows = <(int, String, LookupOutcomeKind, LookupFailureCode)>[
        (401, '{"type":"error","error":{"type":"authentication_error"}}',
            LookupOutcomeKind.failed, LookupFailureCode.auth),
        (429, '{"type":"error","error":{"type":"rate_limit_error"}}',
            LookupOutcomeKind.rateLimited, LookupFailureCode.rateLimited),
        (529, '{"type":"error","error":{"type":"overloaded_error"}}',
            LookupOutcomeKind.failed, LookupFailureCode.server),
        (400,
            '{"type":"error","error":{"type":"invalid_request_error",'
                '"message":"Your credit balance is too low"}}',
            LookupOutcomeKind.failed, LookupFailureCode.billing),
        (404, '{"type":"error","error":{"type":"not_found_error"}}',
            LookupOutcomeKind.failed, LookupFailureCode.modelNotFound),
        (302, '', LookupOutcomeKind.offline, LookupFailureCode.captivePortal),
      ];
      for (final (status, body, kind, code) in rows) {
        final s = ScriptedClient([(_) => http.Response(body, status)]);
        final o = await _client(s).submit(bigMacRequest);
        expect(o.kind, kind, reason: '$status');
        expect(o.failure!.code, code, reason: '$status');
        expect(s.requests, hasLength(1), reason: 'never retried in place');
      }
    });

    test('a non-JSON 200 is a portal page', () async {
      final s = ScriptedClient([(_) => http.Response('<html>login</html>', 200)]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.offline);
      expect(o.failure!.code, LookupFailureCode.captivePortal);
    });

    test('transport error → offline, with no URL or key in the message',
        () async {
      final s = ScriptedClient([
        (_) => throw http.ClientException(
            'Connection refused', Uri.parse('https://api.anthropic.com/v1'))
      ]);
      final o = await _client(s).submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.offline);
      expect(o.failure!.code, LookupFailureCode.network);
      expect(o.failure!.message.contains('anthropic.com'), isFalse);
      expect(o.failure!.message.contains('test-key'), isFalse);
    });

    test('a stalled provider hits the per-call deadline', () async {
      final never = Completer<http.Response>();
      final s = ScriptedClient([(_) => never.future]);
      final o = await _client(s, perCall: const Duration(milliseconds: 50))
          .submit(bigMacRequest);
      expect(o.kind, LookupOutcomeKind.failed);
      expect(o.failure!.code, LookupFailureCode.timeout);
      expect(o.failure!.transient, isTrue);
    });

    test('cancel while in flight discards the lookup', () async {
      final gate = Completer<http.Response>();
      final s = ScriptedClient([(_) => gate.future]);
      final token = LookupCancelToken();
      final pending = _client(s).submit(bigMacRequest, cancel: token);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();
      final o = await pending;
      expect(o.failure!.code, LookupFailureCode.cancelled);
      expect(o.result, isNull);
      gate.complete(fixture200('anthropic_found.json'));
    });

    test('cancel after the reply arrived still discards it', () async {
      final token = LookupCancelToken();
      final s = ScriptedClient([
        (_) {
          token.cancel(); // Off tapped while the body was being read
          return fixture200('anthropic_found.json');
        }
      ]);
      final o = await _client(s).submit(bigMacRequest, cancel: token);
      expect(o.result, isNull);
      expect(o.failure!.code, LookupFailureCode.cancelled);
    });

    test('no key, or nothing to look up → zero calls', () async {
      final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
      final a = await _client(s, key: '  ').submit(bigMacRequest);
      expect(a.failure!.code, LookupFailureCode.noKey);
      final b = await _client(s).submit(const LookupRequest(items: []));
      expect(b.failure!.code, LookupFailureCode.badRequest);
      final token = LookupCancelToken()..cancel();
      final c = await _client(s).submit(bigMacRequest, cancel: token);
      expect(c.failure!.code, LookupFailureCode.cancelled);
      expect(s.requests, isEmpty);
    });

    test('support and poll', () async {
      final c = _client(ScriptedClient([(_) => json200({})]));
      expect(c.lookupSupport().supported, isTrue);
      expect(c.lookupSupport().recipient, LookupRecipient.anthropic);
      expect(c.lookupSupport().locationAllowed, isTrue);
      expect((await c.poll('job')).kind, LookupOutcomeKind.unsupported);
    });
  });
}
