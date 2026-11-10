/// The owner's server re-caps a lookup answer before the app sees it
/// (lookup_contract.sanitize_lookup). That must never change what lane B's
/// acceptance decides: shared/vectors/lookup_sanitizer.json pairs each
/// model answer with the server's version of it (generated from the Python
/// sanitizer), and decideAssist must reach the same outcome and reason on
/// both — with verbatim page text as evidence (where APPLY lives) and with
/// the server's search-summary evidence (verbatim false).
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _load() {
  var dir = Directory.current.absolute;
  while (true) {
    final file = File('${dir.path}/shared/vectors/lookup_sanitizer.json');
    if (file.existsSync()) {
      return (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, dynamic>();
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('shared/vectors not found above ${Directory.current}');
    }
    dir = parent;
  }
}

/// Every calorie figure the RAW answer states, as one page would print
/// them: the same evidence for both answers, so only the answers differ.
String _figuresText(Object? answer) {
  final figures = <int>{};
  void add(Object? v) {
    if (v is num && v.isFinite && v == v.roundToDouble()) {
      figures.add(v.toInt());
    }
  }

  final matches = answer is Map ? answer['matches'] : null;
  for (final m in matches is List ? matches : const []) {
    if (m is! Map) continue;
    for (final key in const ['options', 'components']) {
      final list = m[key];
      for (final o in list is List ? list : const []) {
        if (o is! Map) continue;
        add(o['calories']);
        final range = o['calories_range'];
        if (range is List) range.forEach(add);
      }
    }
  }
  return 'Nutrition facts: ${figures.map((n) => '$n Cal').join('; ')}';
}

void main() {
  final doc = _load();
  final now = DateTime.parse(doc['now'] as String);
  final mealTimes = (doc['meal'] as Map).cast<String, dynamic>();
  final cited = (doc['cited'] as List).cast<String>();

  for (final raw in (doc['cases'] as List).cast<Map>()) {
    final c = raw.cast<String, dynamic>();
    final id = '${c['id']}';
    final meal = Meal(
      id: 7,
      date: mealTimes['date'] as String,
      time: mealTimes['time'] as String,
      timestamp: mealTimes['timestamp'] as String,
      source: MealSource.appWatch,
      analysis: (c['analysis'] as Map).cast<String, dynamic>(),
    );
    final request = (c['request'] as Map).cast<String, dynamic>();
    final ctx = AssistContext(
      now: now,
      trigger: AssistTrigger.autoLowConfidence,
      country: 'US',
      requestChainKeys: [
        for (final chain in request['chains'] as List)
          (chain as Map)['key'] as String,
      ],
      requestItems: (request['items'] as List).cast<Object?>(),
    );
    final text = _figuresText(c['raw']);

    AssistDecision decide(Object? answer, {required bool verbatim}) =>
        decideAssist(
          meal,
          AssistLookup(
            result: answer,
            provider: 'claude_plan',
            citedUrls: cited,
            evidence: [
              AssistEvidence(url: cited.first, text: text, verbatim: verbatim),
            ],
          ),
          ctx,
        );

    test('$id: the server answer decides as the raw answer does', () {
      expect(c['sanitized'], isA<Map>(), reason: '[$id] sanitized');
      final expected = (c['raw_verbatim'] as List).cast<String>();
      final rawVerbatim = decide(c['raw'], verbatim: true);
      expect([rawVerbatim.outcome.name, rawVerbatim.reason], expected,
          reason: '[$id] lane B on the raw answer');
      for (final verbatim in const [true, false]) {
        final a = decide(c['raw'], verbatim: verbatim);
        final b = decide(c['sanitized'], verbatim: verbatim);
        expect([b.outcome.name, b.reason], [a.outcome.name, a.reason],
            reason: '[$id] verbatim=$verbatim');
        expect(b.status, a.status, reason: '[$id] status');
        expect([for (final i in b.items) i.itemIndex],
            [for (final i in a.items) i.itemIndex],
            reason: '[$id] covered items');
      }
    });
  }
}
