// Vendor shapes drift. Every fixture, mutated at random (a value replaced
// by the wrong type, a key dropped), must come back as an outcome — never
// an exception — and a "done" outcome must still hold a valid result.
import 'dart:convert';
import 'dart:math';

import 'package:calorie_tracker/services/assist/clients/anthropic_lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/http_lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/openrouter_lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/responses_lookup_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// All (container, key-or-index) slots of a JSON tree.
void _slots(Object? node, List<(Object, Object)> out) {
  if (node is Map) {
    for (final k in node.keys.toList()) {
      out.add((node, k));
      _slots(node[k], out);
    }
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      out.add((node, i));
      _slots(node[i], out);
    }
  }
}

final List<Object?> _junk = [
  null,
  0,
  -1,
  1e300,
  true,
  '',
  'x',
  '{"status": "found"}',
  <Object?>[],
  <String, Object?>{},
  [1, 'a', null],
  {'type': 'text'},
];

Map<String, dynamic> _mutate(Map<String, dynamic> fixture, Random r) {
  final copy = jsonDecode(jsonEncode(fixture)) as Map<String, dynamic>;
  final slots = <(Object, Object)>[];
  _slots(copy, slots);
  for (var n = 0; n < 1 + r.nextInt(3) && slots.isNotEmpty; n++) {
    final (container, key) = slots[r.nextInt(slots.length)];
    final junk = _junk[r.nextInt(_junk.length)];
    if (container is Map) {
      if (r.nextInt(4) == 0) {
        container.remove(key);
      } else {
        container[key] = junk;
      }
    } else if (container is List && key is int && key < container.length) {
      container[key] = junk;
    }
  }
  return copy;
}

void main() {
  final cases = <String, HttpLookupClient Function(ScriptedClient)>{
    'anthropic_found.json': (s) =>
        AnthropicLookupClient(apiKey: () => 'k', client: s.client),
    'anthropic_max_uses.json': (s) =>
        AnthropicLookupClient(apiKey: () => 'k', client: s.client),
    'openrouter_found.json': (s) => OpenRouterLookupClient(
        apiKey: () => 'k', modelOf: () => 'm', client: s.client),
    'openai_found.json': (s) =>
        OpenAiLookupClient(apiKey: () => 'k', client: s.client),
    'xai_found.json': (s) => XaiLookupClient(
        apiKey: () => 'k',
        modelOf: () => 'grok-4.7',
        client: s.client,
        policy: const LookupCostPolicy(maxUsdPerLookup: 1)),
  };

  for (final e in cases.entries) {
    test('${e.key}: 300 mutations, no throw, done ⇒ valid result', () async {
      final r = Random(e.key.hashCode);
      final base = fixture(e.key);
      var done = 0;
      for (var i = 0; i < 300; i++) {
        final s = ScriptedClient([(_) => json200(_mutate(base, r))]);
        final o = await e.value(s).submit(bigMacRequest);
        expect(
            o.kind,
            isIn([
              LookupOutcomeKind.done,
              LookupOutcomeKind.failed,
              LookupOutcomeKind.offline,
              LookupOutcomeKind.rateLimited,
            ]));
        if (o.kind == LookupOutcomeKind.done) {
          done++;
          expect(o.result, isNotNull);
          expect(kLookupStatuses, contains(o.result!.status));
          for (final m in o.result!.matches) {
            expect(m.itemIndex, inInclusiveRange(0, 0));
          }
        } else {
          expect(o.failure, isNotNull);
          // The parsers check every shape themselves; the skeleton's
          // catch-all is a backstop that no mutation should reach.
          expect(o.failure!.message, isNot(startsWith('unexpected reply')),
              reason: 'mutation $i');
        }
      }
      // Most single mutations miss the parts that matter.
      expect(done, greaterThan(0));
    });
  }
}
