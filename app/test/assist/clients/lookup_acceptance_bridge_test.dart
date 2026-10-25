// The bridge from a direct client to lane B's acceptance: a client's
// outcome goes into decideAssist as is (LookupOutcome.toAssistLookup), with
// a request composed from the meal by lane B's composer. A clean, cited,
// official, grounded answer for a printed-brand Big Mac applies; the same
// answer grounded only by the model's own span, or from a search that never
// returned the claimed page, does not.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/services/assist/clients/anthropic_lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final DateTime _now = DateTime(2026, 10, 23, 14, 0);

Map<String, dynamic> _bigMacMeal() => {
      'is_food': true,
      'food_items': [
        {
          'name': 'Big Mac',
          'estimated_calories': 540,
          'protein_g': 24,
          'carbs_g': 44,
          'fat_g': 30,
          'brand': "McDonald's",
          'qty': 1,
          'unit': 'sandwich',
        }
      ],
      'total_calories': 540,
      'total_protein_g': 24,
      'total_carbs_g': 44,
      'total_fat_g': 30,
      'meal_description': "A Big Mac in its McDonald's box",
      'estimate_confidence': 'low',
      'restaurant_context': 'restaurant',
      'portion_state': 'whole',
      'order_merchant': '',
    };

Meal _meal(Map<String, dynamic> analysis) => Meal(
      id: 7,
      date: '2026-10-23',
      time: '12:30 PM',
      timestamp: '2026-10-23T12:30:00',
      source: MealSource.appWatch,
      analysis: analysis,
    );

Future<(LookupOutcome, LookupRequest)> _lookup(Map<String, dynamic> body,
    {Map<String, dynamic>? analysis}) async {
  final a = analysis ?? _bigMacMeal();
  final request = LookupRequest.compose(
      {'items': a['food_items'], 'chains': ['mcdonalds'], 'country': 'US'});
  final s = ScriptedClient([(_) => json200(body)]);
  final o = await AnthropicLookupClient(apiKey: () => 'test-key', client: s.client)
      .submit(request, chainDomains: request.chainDomains);
  return (o, request);
}

AssistDecision _decide(LookupOutcome o, LookupRequest request,
        {Map<String, dynamic>? analysis}) =>
    decideAssist(
      _meal(analysis ?? _bigMacMeal()),
      o.toAssistLookup()!,
      AssistContext(
        now: _now,
        trigger: AssistTrigger.autoLowConfidence,
        country: 'US',
        requestChainKeys: request.chainKeys,
        requestItems: request.items,
      ),
    );

void main() {
  test('toAssistLookup carries the raw answer, the recipient and the search',
      () async {
    final (o, _) = await _lookup(fixture('anthropic_found.json'));
    expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
    final lookup = o.toAssistLookup()!;
    expect(lookup.result, same(o.result!.json));
    expect(lookup.provider, 'anthropic');
    expect(lookup.citedUrls, o.citedUrls);
    expect(lookup.evidence, hasLength(o.evidence.length));
    expect(lookup.evidence.first.url, o.evidence.first.url);
    expect(lookup.evidence.first.text, o.evidence.first.text);
    expect(lookup.evidence.first.verbatim, isTrue);
    expect(lookup.evidence.first.pageAge, 'October 2, 2026');
    expect(
        const LookupOutcome(
                kind: LookupOutcomeKind.failed,
                provider: LookupRecipient.anthropic)
            .toAssistLookup(),
        isNull);
  });

  test('a clean Anthropic answer for a printed-brand Big Mac applies',
      () async {
    final (o, request) = await _lookup(fixture('anthropic_found.json'));
    final d = _decide(o, request);
    expect(d.outcome, AssistOutcome.apply, reason: d.reason);
    expect(d.chainKey, 'mcdonalds');
    expect(d.evidence, AssistEvidenceKind.itemBrand);
    expect(d.source!.cited && d.source!.official, isTrue);
    expect(d.grounded, isTrue);
    expect(d.items.single.proposed.calories, 590);
    expect(d.provider, 'anthropic');
  });

  test('the same answer grounded only by the model\'s own text is no APPLY',
      () async {
    final body = fixture('anthropic_found.json');
    // Strip every citation: the answer still names 590, but no text the
    // search extracted from the page backs it.
    for (final b in body['content'] as List) {
      if (b is Map && b['type'] == 'text') b.remove('citations');
    }
    final (o, request) = await _lookup(body);
    expect(o.evidence, isEmpty);
    expect(_decide(o, request).outcome, isNot(AssistOutcome.apply));
  });

  test('a claimed page the search never returned is no APPLY', () async {
    final (o, request) =
        await _lookup(fixture('anthropic_uncited_source.json'));
    expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
    expect(_decide(o, request).outcome, isNot(AssistOutcome.apply));
  });

  test('a meal edited after the request was sent is rejected, not applied',
      () async {
    final (o, request) = await _lookup(fixture('anthropic_found.json'));
    final edited = _bigMacMeal();
    ((edited['food_items'] as List).single as Map)['name'] = 'Quarter Pounder';
    expect(_decide(o, request, analysis: edited).outcome,
        AssistOutcome.reject);
  });
}
