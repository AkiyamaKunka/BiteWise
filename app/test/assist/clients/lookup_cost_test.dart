// Cost caps: the per-lookup ceiling (checked before EVERY request), the
// daily budget (count and dollars), and spend recording even on failure.
import 'dart:async';

import 'package:calorie_tracker/services/assist/clients/anthropic_lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/http_lookup_client.dart';
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

  test('usage counts: numbers and numeric strings; junk is unknown', () {
    expect(countOf(2), 2);
    expect(countOf(0), 0);
    expect(countOf(2.0), 2);
    expect(countOf(1.2), 2, reason: 'a fraction rounds up');
    expect(countOf('2'), 2);
    expect(countOf(' 7 '), 7);
    expect(countOf('1e3'), 1000);
    expect(countOf(1e300), kMaxReportedCount, reason: 'no overflow');
    for (final junk in <Object?>[
      null, -1, '-1', '', 'x', 'NaN', double.nan, double.infinity, true,
      <Object?>[], <String, Object?>{},
    ]) {
      expect(countOf(junk), isNull, reason: '$junk');
    }
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
        closeTo(0.02 + 24000 * 0.10 / 1e6 + 1500 * 0.50 / 1e6, 1e-12));
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

  group('a request sent without a reply is charged its worst case', () {
    // It may have run, and been billed for, its searches: the daily dollar
    // ledger must see that, or retries of a transient failure spend
    // unseen.
    final worst = _anthropic(ScriptedClient([(_) => json200({})]))
        .worstCaseFirstRequestUsd();

    test('deadline hit', () async {
      final budget = _RecordingBudget();
      final never = Completer<http.Response>();
      final s = ScriptedClient([(_) => never.future]);
      final o = await AnthropicLookupClient(
              apiKey: () => 'test-key',
              client: s.client,
              budget: budget,
              perCallDeadline: const Duration(milliseconds: 30))
          .submit(bigMacRequest);
      expect(o.failure!.code, LookupFailureCode.timeout);
      expect(budget.spends.single.usd, greaterThan(0));
      expect(budget.spends.single.usd, closeTo(worst, 1e-12));
      expect(o.cost.usd, closeTo(worst, 1e-12));
    });

    test('cancelled in flight', () async {
      final budget = _RecordingBudget();
      final gate = Completer<http.Response>();
      final s = ScriptedClient([(_) => gate.future]);
      final token = LookupCancelToken();
      final pending =
          _anthropic(s, budget: budget).submit(bigMacRequest, cancel: token);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();
      final o = await pending;
      expect(o.failure!.code, LookupFailureCode.cancelled);
      expect(budget.spends.single.usd, closeTo(worst, 1e-12));
      gate.complete(fixture200('anthropic_found.json'));
    });

    test('connection dropped', () async {
      final budget = _RecordingBudget();
      final s = ScriptedClient([
        (_) => throw http.ClientException('Connection reset by peer')
      ]);
      final o = await _anthropic(s, budget: budget).submit(bigMacRequest);
      expect(o.failure!.code, LookupFailureCode.network);
      expect(budget.spends.single.usd, closeTo(worst, 1e-12));
    });

    test('a non-JSON reply', () async {
      final budget = _RecordingBudget();
      final s = ScriptedClient([(_) => http.Response('<html>', 200)]);
      final o = await _anthropic(s, budget: budget).submit(bigMacRequest);
      expect(o.failure!.code, LookupFailureCode.captivePortal);
      expect(budget.spends.single.usd, closeTo(worst, 1e-12));
    });

    test('a continuation that times out adds ITS worst case to the real '
        'spend of the first request', () async {
      final budget = _RecordingBudget();
      final never = Completer<http.Response>();
      final s = ScriptedClient([
        (_) => fixture200('anthropic_pause_1.json'),
        (_) => never.future,
      ]);
      final c = AnthropicLookupClient(
          apiKey: () => 'test-key',
          client: s.client,
          budget: budget,
          perCallDeadline: const Duration(milliseconds: 30));
      final o = await c.submit(bigMacRequest);
      expect(o.failure!.code, LookupFailureCode.timeout);
      final first = 0.01 + haikuUsd(7012, 96);
      final second =
          c.worstCaseRequestUsd(continuation: 1, searchesSoFar: 1, maxUses: 1);
      expect(budget.spends.single.usd, closeTo(first + second, 1e-12));
    });

    test('an HTTP error answer is not charged', () async {
      final budget = _RecordingBudget();
      final s = ScriptedClient(
          [(_) => http.Response('{"type":"error","error":{}}', 500)]);
      await _anthropic(s, budget: budget).submit(bigMacRequest);
      expect(budget.spends.single.usd, 0);
      expect(budget.spends.single.httpCalls, 1);
    });

    test('the daily dollar cap sees timed-out lookups', () async {
      final budget = DailyLookupBudget(maxLookupsPerDay: 20, maxUsdPerDay: 0.05);
      final s = ScriptedClient([(_) => Completer<http.Response>().future]);
      final c = AnthropicLookupClient(
          apiKey: () => 'test-key',
          client: s.client,
          budget: budget,
          perCallDeadline: const Duration(milliseconds: 10));
      expect((await c.submit(bigMacRequest)).failure!.code,
          LookupFailureCode.timeout);
      expect((await c.submit(bigMacRequest)).failure!.code,
          LookupFailureCode.timeout);
      // 2 × 2.3¢ charged; a third worst case would pass 5¢.
      final third = await c.submit(bigMacRequest);
      expect(third.failure!.code, LookupFailureCode.dailyCap);
      expect(s.requests, hasLength(2));
    });
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
