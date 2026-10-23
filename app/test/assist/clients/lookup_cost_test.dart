// Cost caps: the per-lookup ceiling (checked before EVERY request), the
// daily budget (count and dollars), and spend recording even on failure.
import 'package:calorie_tracker/services/assist/clients/anthropic_lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

class _RecordingBudget implements LookupBudget {
  final List<double> starts = [];
  final List<LookupCost> spends = [];
  bool allow = true;
  @override
  bool tryStartLookup(double worstCaseUsd) {
    starts.add(worstCaseUsd);
    return allow;
  }

  @override
  void recordSpend(LookupCost cost) => spends.add(cost);
}

AnthropicLookupClient _anthropic(ScriptedClient s,
        {LookupCostPolicy policy = const LookupCostPolicy(),
        LookupBudget? budget}) =>
    AnthropicLookupClient(
        apiKey: () => 'test-key',
        client: s.client,
        policy: policy,
        budget: budget);

void main() {
  test('price helpers', () {
    expect(haikuUsd(100000, 0), closeTo(0.01, 1e-12));
    expect(haikuUsd(0, 1000000), closeTo(0.50, 1e-12));
    // Past 100K prompt tokens the long-context rate applies ($0.50/M).
    expect(haikuUsd(200000, 0), closeTo(0.10, 1e-12));
    expect(haikuUsd(200000, 1000), closeTo(0.10 + 0.0025, 1e-12));
    expect(kAnthropicSearchUsd, 0.01);
    expect(kOpenRouterExaRequestUsd, 0.007);
  });

  test('LookupCost adds up; reported only when someone reported', () {
    const a = LookupCost(searches: 1, inputTokens: 10, estimatedUsd: 0.01);
    const b = LookupCost(searches: 2, outputTokens: 5, estimatedUsd: 0.02);
    final s = a + b;
    expect(s.searches, 3);
    expect(s.inputTokens, 10);
    expect(s.outputTokens, 5);
    expect(s.reportedUsd, isNull);
    expect(s.usd, closeTo(0.03, 1e-12));
    final r = a + const LookupCost(reportedUsd: 0.005);
    expect(r.reportedUsd, 0.005);
  });

  test('Anthropic worst case for the design defaults is ~2.3¢', () {
    final c = _anthropic(ScriptedClient([(_) => json200({})]));
    expect(c.worstCaseFirstRequestUsd(),
        closeTo(0.02 + 23000 * 0.10 / 1e6 + 1500 * 0.50 / 1e6, 1e-12));
    expect(c.worstCaseFirstRequestUsd(), lessThan(0.05));
  });

  test('a cap below the first request\'s worst case: zero calls', () async {
    final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
    final budget = _RecordingBudget();
    final o = await _anthropic(s,
            policy: const LookupCostPolicy(maxUsdPerLookup: 0.01),
            budget: budget)
        .submit(bigMacRequest);
    expect(o.kind, LookupOutcomeKind.failed);
    expect(o.failure!.code, LookupFailureCode.costCap);
    expect(o.failure!.transient, isFalse);
    expect(s.requests, isEmpty);
    expect(budget.starts, isEmpty, reason: 'not counted against the day');
  });

  test('a pause_turn continuation that could break the cap is not sent',
      () async {
    final s = ScriptedClient([
      (_) => fixture200('anthropic_pause_1.json'),
      (_) => fixture200('anthropic_pause_2.json'),
    ]);
    final budget = _RecordingBudget();
    // First request worst case 2.305¢ fits; after it spent ~1.07¢, the
    // continuation's worst case (~1.32¢) would reach ~2.4¢ > 2.35¢.
    final o = await _anthropic(s,
            policy: const LookupCostPolicy(maxUsdPerLookup: 0.0235),
            budget: budget)
        .submit(bigMacRequest);
    expect(s.requests, hasLength(1));
    expect(o.failure!.code, LookupFailureCode.costCap);
    expect(o.cost.httpCalls, 1);
    expect(budget.spends.single.usd, closeTo(o.cost.usd, 1e-12));
    expect(o.cost.usd, greaterThan(0.01));
  });

  test('every lookup stays under the per-lookup cap', () async {
    // Three pauses: the loop must stop on cap or limit, never overspend.
    for (final cap in [0.024, 0.03, 0.04, 0.05]) {
      final s = ScriptedClient([(_) => fixture200('anthropic_pause_1.json')]);
      final o = await _anthropic(s,
              policy: LookupCostPolicy(maxUsdPerLookup: cap))
          .submit(bigMacRequest);
      expect(o.cost.usd, lessThanOrEqualTo(cap), reason: 'cap $cap');
      expect(o.isDone, isFalse);
    }
  });

  test('spend is recorded for a failed lookup too', () async {
    final s = ScriptedClient([
      (_) => fixture200('anthropic_pause_1.json'),
      (_) => http.Response('{"type":"error","error":{}}', 500),
    ]);
    final budget = _RecordingBudget();
    final o = await _anthropic(s, budget: budget).submit(bigMacRequest);
    expect(o.failure!.code, LookupFailureCode.server);
    expect(budget.starts, hasLength(1));
    expect(budget.spends.single.httpCalls, 2);
    expect(budget.spends.single.searches, 1);
    expect(budget.spends.single.usd, greaterThan(0.01));
  });

  group('DailyLookupBudget', () {
    test('count cap → rateLimited with zero calls', () async {
      final budget = DailyLookupBudget(maxLookupsPerDay: 2, maxUsdPerDay: 10);
      final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
      final c = _anthropic(s, budget: budget);
      expect((await c.submit(bigMacRequest)).isDone, isTrue);
      expect((await c.submit(bigMacRequest)).isDone, isTrue);
      final third = await c.submit(bigMacRequest);
      expect(third.kind, LookupOutcomeKind.rateLimited);
      expect(third.failure!.code, LookupFailureCode.dailyCap);
      expect(third.failure!.transient, isTrue);
      expect(s.requests, hasLength(2));
      expect(budget.lookupsToday, 2);
      expect(budget.usdToday, greaterThan(0.02));
    });

    test('dollar cap counts what was spent plus the next worst case',
        () async {
      final budget =
          DailyLookupBudget(maxLookupsPerDay: 20, maxUsdPerDay: 0.03);
      final s = ScriptedClient([(_) => fixture200('anthropic_found.json')]);
      final c = _anthropic(s, budget: budget);
      expect((await c.submit(bigMacRequest)).isDone, isTrue); // ~1.12¢ spent
      final second = await c.submit(bigMacRequest); // +2.3¢ worst > 3¢
      expect(second.failure!.code, LookupFailureCode.dailyCap);
      expect(s.requests, hasLength(1));
    });

    test('the ledger resets at local midnight', () {
      var now = DateTime(2026, 10, 23, 23, 59);
      final b = DailyLookupBudget(
          maxLookupsPerDay: 1, maxUsdPerDay: 1, clock: () => now);
      expect(b.tryStartLookup(0.02), isTrue);
      b.recordSpend(const LookupCost(estimatedUsd: 0.02));
      expect(b.tryStartLookup(0.02), isFalse);
      now = DateTime(2026, 10, 24, 0, 1);
      expect(b.usdToday, 0);
      expect(b.tryStartLookup(0.02), isTrue);
    });

    test('the default is the design\'s 20 a day', () {
      final b = DailyLookupBudget();
      for (var i = 0; i < 20; i++) {
        expect(b.tryStartLookup(0.0), isTrue);
      }
      expect(b.tryStartLookup(0.0), isFalse);
    });
  });
}
