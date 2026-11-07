// The usual-foods choices store (usual-foods spec §5, T45): one small
// preferences value of short codes and meal ids — never a food name.
import 'dart:convert';

import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/services/usual/usual_choices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  var clock = DateTime.utc(2026, 11, 7, 12);
  Future<(UsualChoices, SharedPreferences)> store(
      [Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    final prefs = await SharedPreferences.getInstance();
    return (UsualChoices(prefs, clock: () => clock), prefs);
  }

  setUp(() => clock = DateTime.utc(2026, 11, 7, 12));

  test('a missing or corrupt value reads as empty', () async {
    for (final raw in [
      null,
      'not json',
      '[]',
      '{"v":2,"hidden":[{"h":"0123456789abcdef","at":"2026-11-01"}]}',
      '{"v":1,"hidden":"x","declined":7}',
      '{"v":1,"hidden":[{"h":"Oatmeal","at":"2026-11-01T00:00:00Z"},'
          '{"h":"0123456789abcdef","at":"soon"}],'
          '"declined":[{"m":"1","h":"0123456789abcdef","at":"2026-11-01"},'
          '{"m":0,"h":"0123456789abcdef","at":"2026-11-01"}]}',
    ]) {
      final (c, _) = await store(raw == null ? {} : {usualChoicesPrefsKey: raw});
      final v = c.view();
      expect(v.hidden, isEmpty, reason: raw);
      expect(v.declined, isEmpty, reason: raw);
    }
  });

  test('hide, unhide and decline round-trip through the one value', () async {
    final (c, prefs) = await store();
    final oats = usualHideId('oatmeal');
    final latte = usualHideId('latte');
    await c.hide(oats);
    await c.decline(42, [latte, oats]);
    expect(c.view().isHidden(oats), isTrue);
    expect(c.view().mealDeclined(42, now: clock), isTrue);
    expect(c.view().declined, hasLength(2));
    // A fresh store over the same preferences reads the same.
    final again = UsualChoices(prefs, clock: () => clock).view();
    expect(again.hidden, {oats});
    expect({for (final d in again.declined) (d.mealId, d.hideId)},
        {(42, latte), (42, oats)});
    await c.unhide(oats);
    expect(c.view().isHidden(oats), isFalse);
    await c.decline(42, [latte]);
    expect(c.view().declined, hasLength(2), reason: 'no duplicate decline');
  });

  test('only 16-hex ids and meal ids are stored, never a food name',
      () async {
    final (c, prefs) = await store();
    await c.hide('Oatmeal with blueberries');
    await c.decline(3, ['Latte', 'oatmeal']);
    expect(c.view().hidden, isEmpty);
    expect(c.view().declined, isEmpty);
    await c.hide(usualHideId('blueberry oatmeal'));
    await c.decline(3, [usualHideId('latte')]);
    final raw = prefs.getString(usualChoicesPrefsKey)!;
    expect(raw.toLowerCase(), isNot(contains('oat')));
    expect(raw.toLowerCase(), isNot(contains('latte')));
    final doc = jsonDecode(raw) as Map;
    expect(doc.keys.toSet(), {'v', 'hidden', 'declined'});
    expect((doc['hidden'] as List).single.keys.toSet(), {'h', 'at'});
    expect((doc['declined'] as List).single.keys.toSet(), {'m', 'h', 'at'});
    expect(raw, matches(RegExp(r'^[{}\[\]":,0-9a-zTZ.\-]+$')),
        reason: 'hex ids, ids, ISO stamps and the four key names only');
  });

  test('declines older than 90 days are dropped and ignored', () async {
    final (c, _) = await store();
    final h = usualHideId('oatmeal');
    clock = DateTime.utc(2026, 7, 1);
    await c.decline(1, [h]);
    clock = DateTime.utc(2026, 7, 2);
    await c.decline(2, [h]);
    clock = DateTime.utc(2026, 11, 7);
    final since = DateTime.utc(2026, 6, 1);
    expect(c.view().declined, hasLength(2), reason: 'not yet rewritten');
    expect(c.view().muted('oatmeal', since: since, now: clock), isFalse,
        reason: 'the view ignores them already');
    await c.decline(3, [usualHideId('latte')]);
    expect([for (final d in c.view().declined) d.mealId], [3]);
  });

  test('at most 200 of each are kept, newest first', () async {
    final (c, _) = await store();
    for (var i = 0; i < 205; i++) {
      clock = DateTime.utc(2026, 11, 1).add(Duration(minutes: i));
      await c.hide(usualHideId('food $i'));
      await c.decline(i + 1, [usualHideId('food $i')]);
    }
    final v = c.view();
    expect(v.hidden, hasLength(kUsualChoicesCap));
    expect(v.hidden.contains(usualHideId('food 204')), isTrue);
    expect(v.hidden.contains(usualHideId('food 4')), isFalse);
    expect(v.declined, hasLength(kUsualChoicesCap));
    expect(v.declined.first.mealId, 205);
    expect(v.declined.last.mealId, 6);
  });

  test('writes are serialized: quick taps keep every entry', () async {
    final (c, _) = await store();
    await Future.wait([
      for (var i = 0; i < 10; i++) c.hide(usualHideId('food $i')),
    ]);
    expect(c.view().hidden, hasLength(10));
  });

  test('muting needs 2 declines on different meals after the record', () {
    final h = usualHideId('oatmeal');
    final now = DateTime.utc(2026, 11, 7);
    final rec = DateTime.utc(2026, 11, 3);
    UsualDecline d(int m, int day) =>
        UsualDecline(mealId: m, hideId: h, at: DateTime.utc(2026, 11, day));
    bool muted(List<UsualDecline> ds) =>
        UsualChoicesView(declined: ds).muted('oatmeal', since: rec, now: now);
    expect(muted([d(1, 4), d(2, 5)]), isTrue);
    expect(muted([d(1, 4), d(1, 5)]), isFalse, reason: 'the same meal twice');
    expect(muted([d(1, 2), d(2, 5)]), isFalse, reason: 'one before the record');
    expect(
        UsualChoicesView(declined: [d(1, 4), d(2, 5)])
            .muted('latte', since: rec, now: now),
        isFalse);
  });
}
