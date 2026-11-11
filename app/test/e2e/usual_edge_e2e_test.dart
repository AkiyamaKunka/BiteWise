// Usual foods, end to end: the rough edges.
//
// Through the app's real parts (harness.dart):
//   1. A long-time owner: 2,000 meals from a fixed-seed generator. What
//      the app learns and lists is checked against a plain recount of the
//      same meals, by size and content (no timing: a loaded machine is not
//      a slow phone).
//   2. Rows no build of this app wrote: analysis text that is not JSON, the
//      wrong types everywhere, a mark of nonsense. The good meals around
//      them are still offered and listed, and nothing throws.
//   3. A corrupt choices preference.
//   4. A meal deleted while its chip shows, and two Uses racing.
//   5. The largest text size on the narrowest phone, in both languages:
//      the My usual foods rows and the "Log it again?" dialog.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/meal_edit_logic.dart' show formatClock;
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Finder _card(int id) => find.byKey(ValueKey('meal$id'));
Finder _chip(int id) =>
    find.descendant(of: _card(id), matching: find.byKey(const Key('usualChip')));
Finder _row(String food) =>
    find.byKey(ValueKey('usualRow:${usualNameKey(food)}'));
Finder get _rows => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && k.value.startsWith('usualRow:');
    });

Map<String, dynamic> _one(String food, num kcal, {num p = 10, num c = 50, num f = 6}) =>
    aiSays([foodItem(food, kcal, p: p, c: c, f: f)], description: food);

/// A meal of [food] saved through the DAO at [when] (dated and stamped
/// with it), as [source]; with [mine] the row carries the owner's mark
/// for those kcal, set at [when], and the meal is corrected.
Future<int> _seed(Phone phone, DateTime when, String food, num kcal,
    {String source = MealSource.appWatch, bool mine = false}) async {
  final item = foodItem(food, kcal);
  if (mine) {
    item['user'] = {
      'set': true,
      'at': usualStamp(when),
      'n': [kcal, 10, 50, 6],
      'qty': 1,
    };
  }
  final id = await phone.dao.saveMeal(Meal(
    id: 0,
    date: isoDate(when),
    time: formatClock(when),
    timestamp: when.toIso8601String(),
    source: source,
    imageHash: source == MealSource.appWatch
        ? 'seed-${when.microsecondsSinceEpoch}-${food.hashCode}'
        : '',
    analysis: aiSays([item], description: food),
  ));
  if (mine) {
    await phone.db.update('meals', {'corrected': 1},
        where: 'id = ?', whereArgs: [id]);
  }
  return id;
}

/// Rows the app wrote. total_changes() also counts what triggers write, and
/// since schema v4 (1.7.0 iCloud Backup) every write to a backed-up table
/// bumps one data_changes counter by exactly one; subtracting the counters
/// leaves the app's own writes.
Future<int> _changes(Phone phone) async => (await phone.db.rawQuery(
        'SELECT total_changes() - '
        '(SELECT records + thumbs FROM data_changes WHERE id = 1) AS n'))
    .single['n'] as int;

// The iPhone's own fonts: whether text fits depends on the glyphs (the
// test font is a full em per glyph). macOS only, as large_text_overflow_
// test does.
const _sfPath = '/System/Library/Fonts/SFNS.ttf';
const _cjkPath = '/System/Library/Fonts/Hiragino Sans GB.ttc';
final bool _haveIphoneFonts =
    File(_sfPath).existsSync() && File(_cjkPath).existsSync();

Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

void main() {
  useInProcessSqlite();

  testWidgets('a long-time owner: 2,000 meals, and what the app learns and '
      'lists from them equals a plain recount', (tester) async {
    final l = copyFor(const Locale('en'));
    final now = DateTime(2026, 10, 30, 12, 0);
    final phone = await Phone.boot(now);
    addTearDown(phone.shutDown);

    // 60 foods; 2,000 single-food meals over the last 400 days, about a
    // quarter of them inside the 90-day window. One in six was fixed by
    // the owner.
    const how = ['Grilled', 'Baked', 'Spicy', 'Sweet', 'Smoked', 'Fried'];
    const what = [
      'chicken', 'tofu', 'salmon', 'rice', 'noodles',
      'beans', 'lentils', 'pasta', 'potato', 'squash',
    ];
    final foods = [for (final h in how) for (final w in what) '$h $w'];
    final rng = Random(20261030);
    const sources = [
      MealSource.appWatch, MealSource.appWatch, MealSource.appWatch,
      MealSource.appPhoto, MealSource.manualText, MealSource.appRepeat,
    ];
    final windowStart = usualWindowStart(now);
    final start30 = usualWindowStart(now, days: 30);
    // The recount, kept beside the generator.
    final days90 = <String, Set<String>>{};
    final days30 = <String, Set<String>>{};
    final mineLatest = <String, ({DateTime at, num kcal})>{};
    for (var i = 0; i < 2000; i++) {
      final food = foods[rng.nextInt(foods.length)];
      // Never today (day 0), so Today starts empty.
      final when = DateTime(now.year, now.month, now.day - 1 - rng.nextInt(400),
          6 + rng.nextInt(16), rng.nextInt(60), 0, i);
      final kcal = 100 + rng.nextInt(80) * 10;
      final mine = rng.nextInt(6) == 0;
      final source = sources[rng.nextInt(sources.length)];
      await _seed(phone, when, food, kcal,
          source: mine ? MealSource.appWatch : source, mine: mine);
      final date = isoDate(when);
      if (date.compareTo(windowStart) < 0) continue;
      final key = usualNameKey(food)!;
      days90.putIfAbsent(key, () => {}).add(date);
      if (date.compareTo(start30) >= 0) {
        days30.putIfAbsent(key, () => {}).add(date);
      }
      final held = mineLatest[key];
      if (mine && (held == null || when.isAfter(held.at))) {
        mineLatest[key] = (at: when, kcal: kcal);
      }
    }
    expect(await phone.mealCount(), 2000);
    final inWindow = (await phone.db.rawQuery(
            'SELECT COUNT(*) AS n FROM meals WHERE date >= ?', [windowStart]))
        .single['n'] as int;
    expect(inWindow, inInclusiveRange(350, 550));

    // What the app learned: the latest numbers the owner set per food.
    final index = await phone.usual.index();
    expect(index.groups.length, days90.length);
    expect(index.groups.values.fold<int>(0, (n, g) => n + g.meals.length),
        inWindow, reason: 'every meal of the window is in exactly one group');
    expect(index.records.keys.toSet(), mineLatest.keys.toSet());
    for (final e in mineLatest.entries) {
      expect(index.records[e.key]!.numbers.kcal, e.value.kcal, reason: e.key);
      expect(index.records[e.key]!.atRaw, usualStamp(e.value.at));
    }
    // What it lists: at most 20, each with the recount's day counts, and
    // no food left out that was logged on more of the last 30 days than
    // the last one listed under More.
    final list = await phone.usual.frequentMeals();
    final listable = days90.values.where((d) => d.length >= 2).length;
    expect(listable, greaterThan(20));
    final listed = [...list.around, ...list.more];
    expect(listed, hasLength(20));
    for (final m in listed) {
      expect(m.days90, days90[m.key]!.length, reason: m.key);
      expect(m.days30, days30[m.key]?.length ?? 0, reason: m.key);
    }
    if (list.more.isNotEmpty) {
      final floor = list.more.last.days30;
      final shown = {for (final m in listed) m.key};
      for (final e in days90.entries) {
        if (shown.contains(e.key) || e.value.length < 2) continue;
        // Around-this-time rows are ranked apart; an unlisted food can
        // only be one that More ranks no higher than its last row.
        expect(days30[e.key]?.length ?? 0, lessThanOrEqualTo(floor),
            reason: e.key);
      }
    }

    // On screen: Today offers the owner's number on a photo of one of
    // those foods, and My usual foods shows the 20 rows.
    final food = foods.firstWhere((f) {
      final r = mineLatest[usualNameKey(f)];
      return r != null && r.kcal >= 300;
    });
    final mine = mineLatest[usualNameKey(food)]!.kcal;
    await pumpApp(tester, phone);
    final id = await phone.photo(_one(food, mine - 150));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: _chip(id),
            matching:
                find.text(l.usualItemLine(food, '${mine - 150}', '$mine'))),
        findsOneWidget);
    await pushFromLog(
        tester, UsualFoodsScreen(usual: phone.usual, now: phone.clock));
    await tester.pumpAndSettle();
    expect(_rows, findsNWidgets(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows no build of this app wrote: text that is not JSON, '
      'wrong types everywhere, marks of nonsense. The meals around them '
      'are still offered and listed, and nothing throws', (tester) async {
    final l = copyFor(const Locale('en'));
    final now = DateTime(2026, 10, 30, 12, 0);
    final phone = await Phone.boot(now);
    addTearDown(phone.shutDown);
    DateTime day(int back, [int hour = 8]) =>
        DateTime(now.year, now.month, now.day - back, hour);

    // The good meals: oatmeal the owner set to 350 three days ago, and a
    // granola bar on two days.
    await _seed(phone, day(3), 'Oatmeal', 350, mine: true);
    await _seed(phone, day(2), 'Granola bar', 200);
    await _seed(phone, day(1), 'Granola bar', 200);

    // The bad ones, on those same days and today.
    const junkItems = <Object?>[
      42,
      null,
      'a string',
      ['a', 'list'],
      {'name': 7, 'estimated_calories': 'abc'},
      {'name': ['Oatmeal'], 'estimated_calories': true},
      {'name': null},
      {},
      {'name': 'Oatmeal', 'estimated_calories': '999', 'user': 'yes'},
      {
        'name': 'Oatmeal',
        'estimated_calories': 999,
        'protein_g': 'lots',
        'qty': 'two',
        'unit': 5,
        'brand': {'x': 1},
        'published': 'true',
        'user': {'set': true, 'at': 5, 'n': 'no', 'qty': 'one', 'ai_name': 99},
      },
      {
        'name': 'Oatmeal',
        'estimated_calories': 999,
        'user': {'set': true, 'at': '2026-10-01T00:00:00.000Z', 'n': [999, 1, 2]},
      },
      {
        'name': 'Oatmeal',
        'estimated_calories': 999,
        'user': {
          'set': 'true',
          'at': 'never',
          'n': [999, '1', null, {}],
        },
      },
      // The right length, the wrong things in it.
      {
        ...{'name': 'Oatmeal', 'estimated_calories': 999},
        'protein_g': 10,
        'carbs_g': 50,
        'fat_g': 6,
        'user': {
          'set': true,
          'at': '2026-10-29T00:00:00.000Z',
          'n': [999, '10', null, {}],
          'qty': 1,
        },
      },
      // One number short.
      {
        ...{'name': 'Oatmeal', 'estimated_calories': 999},
        'protein_g': 10,
        'carbs_g': 50,
        'fat_g': 6,
        'user': {
          'set': true,
          'at': '2026-10-29T00:00:00.000Z',
          'n': [999, 10, 50],
          'qty': 1,
        },
      },
      {
        'name': 'Oatmeal',
        'estimated_calories': -50,
        'protein_g': -1,
        'user': {'set': true, 'at': '2026-10-01T00:00:00.000Z', 'n': [-50, -1, 0, 0]},
      },
    ];
    final shapes = <Map<String, dynamic>>[
      {'is_food': true, 'food_items': junkItems, 'total_calories': {'a': 1}},
      {'is_food': 'yes', 'food_items': 'oops', 'meal_description': 12},
      {'is_food': true, 'food_items': {'0': foodItem('Oatmeal', 999)}},
      {
        'is_food': true,
        'meal_description': ['Oatmeal'],
        'total_calories': 'many',
        'estimate_confidence': 5,
        'portion_state': [],
        'restaurant_context': {'at': 'home'},
        'order_merchant': 7,
        'leftover': 'none',
        'assist': 'applied',
        'logged_again': {'when': 1},
        'food_items': [
          {...foodItem('Oatmeal', 999), 'user': []},
        ],
      },
      {
        'is_food': true,
        'food_items': [
          for (var i = 0; i < 300; i++) foodItem('Oatmeal ${'x' * 40}$i', 5),
        ],
      },
      {
        'is_food': true,
        'meal_description': 'Z' * 5000,
        'food_items': [foodItem('O' * 5000, 999)],
      },
      {'is_food': 1},
      <String, dynamic>{},
    ];
    var n = 0;
    final junkToday = <int>[];
    for (final back in [0, 1, 2, 3]) {
      for (final shape in shapes) {
        // Photo meals and described meals (half of each corrected below):
        // on both, only a valid mark makes a number the owner's. (A meal
        // typed in by hand is the owner's as it stands, whatever else the
        // row says, so none of the junk is one.)
        for (final source in [MealSource.appWatch, MealSource.manualText]) {
          n++;
          // After 13:00, so today's real photo (noon) is Today's first
          // card.
          final when = day(back, 13).add(Duration(minutes: n));
          final id = await phone.dao.saveMeal(Meal(
            id: 0,
            date: isoDate(when),
            time: formatClock(when),
            timestamp: when.toIso8601String(),
            source: source,
            imageHash: source == MealSource.appWatch ? 'junk-$n' : '',
            analysis: shape,
          ));
          if (n % 4 < 2) {
            await phone.db.update('meals', {'corrected': 1},
                where: 'id = ?', whereArgs: [id]);
          }
          if (back == 0) junkToday.add(id);
        }
      }
    }
    // A plate of 41 foods and one of 40, each on two days: the editor
    // holds 40, so only the second can be logged again.
    for (final (count, hour) in [(41, 18), (40, 19)]) {
      for (final back in [1, 2]) {
        final when = day(back, hour);
        await phone.dao.saveMeal(Meal(
          id: 0,
          date: isoDate(when),
          time: formatClock(when),
          timestamp: when.toIso8601String(),
          source: MealSource.appWatch,
          imageHash: 'plate-$count-$back',
          analysis: aiSays([
            for (var i = 1; i <= count; i++) foodItem('Dumpling $i', 40),
          ], description: '$count dumplings'),
        ));
      }
    }

    // And rows whose columns themselves are wrong: analysis text that is
    // not JSON, or not an object; an impossible date; no clock; no source.
    final texts = ['not json at all', '[1, 2, 3]', '"a string"', 'null', '42',
        '{"is_food": true, "food_items": [{"name": "Oatmeal"', ''];
    for (var i = 0; i < texts.length; i++) {
      for (final date in [isoDate(now), isoDate(day(1)), '2026-02-30', '']) {
        await phone.db.insert('meals', {
          'chat_id': 0,
          'date': date,
          'time': i.isEven ? 'noonish' : '25:99 XM',
          'timestamp': i.isEven ? 'whenever' : '',
          'source': i.isEven ? null : MealSource.appWatch,
          'image_hash': null,
          'file_id': null,
          'analysis': texts[i],
          'corrected': i.isEven ? 0 : 1,
        });
      }
    }
    // The chat id every DAO read filters on, whatever it is.
    final chat = (await phone.row(junkToday.first))['chat_id'];
    await phone.db.update('meals', {'chat_id': chat}, where: 'chat_id = 0');

    // Today opens; a real oatmeal photo lands and gets its offer.
    await pumpApp(tester, phone);
    expect(tester.takeException(), isNull);
    final real = await phone.photo(_one('Oatmeal', 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
        find.descendant(
            of: _chip(real),
            matching: find.text(l.usualItemLine('Oatmeal', '300', '350'))),
        findsOneWidget);
    // No junk row of today is offered anything, and none taught anything:
    // the only number known is the owner's 350.
    expect(find.byKey(const Key('usualChip')), findsOneWidget);
    final today = await phone.dao.mealsBetween(isoDate(now), isoDate(now));
    expect(today.length, greaterThan(16));
    expect((await phone.usual.offersFor(today)).keys, [real]);
    final index = await phone.usual.index();
    expect(index.records.keys, [usualNameKey('Oatmeal')]);
    expect(index.records.values.single.numbers.kcal, 350);

    // Use still works among them.
    await tester.tap(find.descendant(
        of: _chip(real), matching: find.byKey(const Key('usualChipUse'))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((await phone.item(real))['estimated_calories'], 350);
    await dismissSnackBar(tester);

    // The editor opens on a junk row of today (its card is on Today).
    final shown = junkToday.firstWhere((id) => _card(id).evaluate().isNotEmpty);
    await tester.ensureVisible(_card(shown));
    await tester.tap(_card(shown), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (find.byType(MealEditorScreen).evaluate().isNotEmpty) {
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      await goBack(tester);
    }

    // My usual foods lists the real foods and logs one.
    await pushFromLog(
        tester, UsualFoodsScreen(usual: phone.usual, now: phone.clock));
    expect(tester.takeException(), isNull);
    expect(_row('Granola bar'), findsOneWidget);
    final count = await phone.mealCount();
    await tester.tap(_row('Granola bar'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(await phone.mealCount(), count + 1);
    expect(find.text(l.usualLoggedSnack('Granola bar', '200')), findsOneWidget);
    // Every row on the list can be logged again without a throw, and what
    // each log writes is a clean meal: finite numbers within the editor's
    // bounds, at most 40 foods, names at most 300 characters.
    final list = await phone.usual.frequentMeals();
    // The real foods, and the one oversized meal that is a food meal all
    // the same (a 5,000-character name: its title is cut to 80, and a log
    // of it writes the name cut to 300). Never the 41-food plate.
    expect([...list.around, ...list.more].map((m) => m.title).toSet(),
        {'Oatmeal', 'Granola bar', '40 dumplings', 'Z' * 80});
    for (final m in [...list.around, ...list.more]) {
      final a = usualLogAnalysis(m, await phone.usual.index(), now: phone.now);
      expect(jsonEncode(a), isNotEmpty);
      final items = a['food_items'] as List;
      expect(items.length, lessThanOrEqualTo(40));
      for (final it in items.cast<Map>()) {
        expect((it['name'] as String).runes.length, lessThanOrEqualTo(300));
        for (final k in ['estimated_calories', 'protein_g', 'carbs_g', 'fat_g']) {
          expect(it[k], isA<num>());
          expect((it[k] as num).isFinite, isTrue);
          expect(it[k] as num, inInclusiveRange(0, 20000));
        }
      }
      expect(a['total_calories'], isA<num>());
    }
  });

  // What a hidden oatmeal and two declines of it would look like, to show
  // that a value this build does not understand is not half-read.
  final oatmealId = usualHideId('oatmeal');
  final entries = '"hidden":[{"h":"$oatmealId","at":"2026-10-29T10:00:00.000Z"}],'
      '"declined":[{"m":901,"h":"$oatmealId","at":"2026-10-29T10:00:00.000Z"},'
      '{"m":902,"h":"$oatmealId","at":"2026-10-29T11:00:00.000Z"}]';
  for (final (name, value) in [
    ('cut off in the middle', '{"v":1,${entries.substring(0, entries.length - 9)}'),
    ('the wrong types', '{"v":1,"hidden":"all","declined":[{"m":"1"},7,null,'
        '{"m":3,"h":"zz","at":"never"},{"m":-4,"h":"$oatmealId","at":5},'
        '{"m":901,"h":"$oatmealId","at":"never"},'
        '{"m":"902","h":"$oatmealId","at":"2026-10-29T11:00:00.000Z"}]}'),
    ('another version', '{"v":2,$entries}'),
    ('not an object', '[{"v":1,$entries}]'),
  ]) {
    testWidgets('a corrupt choices preference ($name) reads as no choices, '
        'and the next choice writes a clean one', (tester) async {
      final l = copyFor(const Locale('en'));
      final now = DateTime(2026, 10, 30, 12, 0);
      final phone = await Phone.boot(now,
          preferences: {'usual_foods.choices_v1': value});
      addTearDown(phone.shutDown);
      await _seed(phone, DateTime(2026, 10, 28, 8), 'Oatmeal', 350, mine: true);
      await _seed(phone, DateTime(2026, 10, 29, 8), 'Oatmeal', 300);
      await pumpApp(tester, phone);
      final id = await phone.photo(_one('Oatmeal', 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_chip(id), findsOneWidget);

      // Keep AI estimate in the editor.
      await tester.tap(
          find.descendant(of: _card(id), matching: find.text('Oatmeal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('usualKeepAi')));
      await tester.pumpAndSettle();
      await goBack(tester);
      expect(_chip(id), findsNothing);
      expect(phone.storedChoices(), {
        'v': 1,
        'hidden': <Object>[],
        'declined': [
          {'m': id, 'h': usualHideId('oatmeal'), 'at': usualStamp(now)},
        ],
      });

      // Hide in My usual foods.
      await pushFromLog(
          tester, UsualFoodsScreen(usual: phone.usual, now: phone.clock));
      expect(_row('Oatmeal'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('usualHide')));
      await tester.pumpAndSettle();
      expect(_row('Oatmeal'), findsNothing);
      expect(find.text(l.usualHiddenSnack), findsOneWidget);
      expect(find.text(l.usualHiddenRow(1)), findsOneWidget);
      expect((phone.storedChoices()['hidden'] as List).single,
          {'h': usualHideId('oatmeal'), 'at': usualStamp(now)});

      // Hidden foods (1) › Show again brings it back.
      await dismissSnackBar(tester);
      await tester.tap(find.byKey(const Key('usualHiddenRow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualHiddenSheet')), findsOneWidget);
      expect(find.text(l.usualUnhide), findsOneWidget);
      await tester.tap(find.byKey(const Key('usualUnhide')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualHiddenSheet')), findsNothing);
      expect(_row('Oatmeal'), findsOneWidget);
      expect(find.byKey(const Key('usualHiddenRow')), findsNothing);
      expect(phone.storedChoices()['hidden'], isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a meal deleted while its chip shows: Use says the meal '
      'changed and writes nothing. Two Uses at once: one writes',
      (tester) async {
    final l = copyFor(const Locale('en'));
    final now = DateTime(2026, 10, 30, 12, 0);
    final phone = await Phone.boot(now);
    addTearDown(phone.shutDown);
    await _seed(phone, DateTime(2026, 10, 28, 8), 'Oatmeal', 350, mine: true);
    await pumpApp(tester, phone);
    final gone = await phone.photo(_one('Oatmeal', 300));
    final twice = await phone.photo(_one('Oatmeal', 290));
    final service = await phone.photo(_one('Oatmeal', 280));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualChip')), findsNWidgets(3));
    Finder useOf(int id) => find.descendant(
        of: _chip(id), matching: find.byKey(const Key('usualChipUse')));

    // The first meal is deleted behind Today's back (a write that sent no
    // signal: another engine's, say).
    await phone.dao.deleteMeal(gone);
    expect(_chip(gone), findsOneWidget, reason: 'Today has not reloaded');
    var changes = await _changes(phone);
    await tester.tap(useOf(gone));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualConflict')), findsOneWidget);
    expect(find.text(l.editorSaveConflict), findsOneWidget);
    expect(find.byKey(const Key('usualUsedSnack')), findsNothing);
    expect(await _changes(phone), changes, reason: 'nothing written');
    expect(_card(gone), findsNothing, reason: 'Today reloaded');
    expect(await phone.mealCount(), 3);
    await dismissSnackBar(tester);

    // Two taps on Use before the first has finished.
    changes = await _changes(phone);
    await tester.tap(useOf(twice));
    await tester.tap(useOf(twice), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(await _changes(phone), changes + 1, reason: 'one write');
    expect(find.byKey(const Key('usualUsedSnack')), findsOneWidget);
    expect(find.byKey(const Key('usualConflict')), findsNothing);
    expect((await phone.item(twice))['estimated_calories'], 350);
    expect(await phone.corrected(twice), isTrue);
    await dismissSnackBar(tester);

    // The same race one layer down: two callers of the service at once.
    final meal = (await phone.dao.mealSnapshot(service))!.meal;
    final offer = (await phone.usual.offerFor(meal))!;
    changes = await _changes(phone);
    final both = await Future.wait([
      phone.usual.accept(service, shown: offer),
      phone.usual.accept(service, shown: offer),
    ]);
    expect(both.map((r) => r.status).toSet(),
        {UsualAcceptStatus.written, UsualAcceptStatus.busy});
    expect(await _changes(phone), changes + 1);
    // A Use of numbers that are no longer the owner's latest: between the
    // offer and the tap the owner set 400 on another meal. Nothing is
    // written; the next offer says 400.
    final stale = await phone.photo(_one('Oatmeal', 275));
    final staleMeal = (await phone.dao.mealSnapshot(stale))!.meal;
    final staleOffer = (await phone.usual.offerFor(staleMeal))!;
    expect(staleOffer.items.single.mine.kcal, 350);
    phone.now = now.add(const Duration(minutes: 5));
    await _seed(phone, phone.now, 'Oatmeal', 400, mine: true);
    signalMealsChanged();
    changes = await _changes(phone);
    final outdated = await phone.usual.accept(stale, shown: staleOffer);
    expect(outdated.status, UsualAcceptStatus.conflict);
    expect(await _changes(phone), changes);
    expect((await phone.usual.offerFor(staleMeal))!.items.single.mine.kcal, 400);
    // And a Use that lost to another writer: the meal changed between the
    // offer and the tap.
    final late = await phone.photo(_one('Oatmeal', 270));
    final lateMeal = (await phone.dao.mealSnapshot(late))!.meal;
    final lateOffer = (await phone.usual.offerFor(lateMeal))!;
    await phone.dao.updateMealAnalysis(late, _one('Oatmeal', 500));
    changes = await _changes(phone);
    final lost = await phone.usual.accept(late, shown: lateOffer);
    expect(lost.status, UsualAcceptStatus.conflict);
    expect(await _changes(phone), changes);
    expect((await phone.item(late))['estimated_calories'], 500);
    await tester.pumpAndSettle();
  });

  group('the largest text (3.1×) on a 320 pt phone', () {
    setUpAll(() async {
      if (!_haveIphoneFonts) return;
      TestWidgetsFlutterBinding.ensureInitialized();
      await _loadFont('AxSF', _sfPath);
      await _loadFont('AxHiragino', _cjkPath);
    });

    for (final locale in const [Locale('en'), Locale('zh')]) {
      testWidgets('$locale: a My usual foods row reads in full, and "Log it '
          'again?" shows its whole question and both buttons',
          (tester) async {
        final l = copyFor(locale);
        final zh = locale.languageCode == 'zh';
        final food = zh
            ? '蓝莓核桃燕麦粥配希腊酸奶和蜂蜜'
            : 'Steel-cut oatmeal with blueberries and walnuts';
        final now = DateTime(2026, 10, 30, 12, 0);
        final phone = await Phone.boot(now);
        addTearDown(phone.shutDown);
        await _seed(phone, DateTime(2026, 10, 28, 12), food, 1320);
        await _seed(phone, DateTime(2026, 10, 29, 12), food, 1320);
        // Logged an hour ago too, so a tap asks first.
        await _seed(phone, DateTime(2026, 10, 30, 11), food, 1320);
        await pumpApp(tester, phone,
            locale: locale,
            size: const Size(320, 640),
            textScale: 3.1,
            theme: ThemeData(
                fontFamily: 'AxSF', fontFamilyFallback: const ['AxHiragino']),
            home: UsualFoodsScreen(usual: phone.usual, now: phone.clock));
        expect(tester.takeException(), isNull);

        void expectInFull(Finder within) {
          final paragraphs = tester.renderObjectList<RenderParagraph>(
              find.descendant(of: within, matching: find.byType(RichText)));
          expect(paragraphs, isNotEmpty);
          for (final p in paragraphs) {
            expect(p.didExceedMaxLines, isFalse,
                reason: '"${p.text.toPlainText()}" is cut');
            // Every line of it is laid out: a paragraph squeezed into less
            // height than its text needs is cut off at the bottom.
            expect(p.size.height,
                greaterThanOrEqualTo(p.getMaxIntrinsicHeight(p.size.width) - 0.5),
                reason: '"${p.text.toPlainText()}" loses its last lines');
            final box = p.localToGlobal(Offset.zero) & p.size;
            expect(box.left, greaterThanOrEqualTo(0));
            expect(box.right, lessThanOrEqualTo(320),
                reason: '"${p.text.toPlainText()}" runs off the screen');
          }
        }

        final row = _row(food);
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(food)),
            findsOneWidget);
        expect(
            find.descendant(
                of: row,
                matching: find.text(
                    l.usualLoggedToday(shownClock(l, '11:00 AM')))),
            findsOneWidget);
        expectInFull(row);
        expect(
            tester
                .getRect(find.descendant(
                    of: row, matching: find.byIcon(Icons.more_horiz)))
                .right,
            lessThanOrEqualTo(320));

        // The dialog.
        final count = await phone.mealCount();
        await tester.tap(find.descendant(of: row, matching: find.text(food)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final dialog = find.byKey(const Key('usualAgainDialog'));
        expect(dialog, findsOneWidget);
        final frame = tester.getRect(dialog);
        expect(frame.left, greaterThanOrEqualTo(0));
        expect(frame.right, lessThanOrEqualTo(320));
        expect(frame.top, greaterThanOrEqualTo(0));
        expect(frame.bottom, lessThanOrEqualTo(640));
        expect(find.text(l.usualAgainTitle), findsOneWidget);
        expect(
            find.text(l.usualAgainBody(food, shownClock(l, '11:00 AM'))),
            findsOneWidget);
        expectInFull(dialog);
        // Both buttons are inside the dialog, whole, and not on top of
        // each other.
        final cancel = tester.getRect(find.byKey(const Key('usualAgainCancel')));
        final confirm =
            tester.getRect(find.byKey(const Key('usualAgainConfirm')));
        for (final b in [cancel, confirm]) {
          expect(b.left, greaterThanOrEqualTo(frame.left));
          expect(b.right, lessThanOrEqualTo(frame.right));
          expect(b.top, greaterThanOrEqualTo(frame.top));
          expect(b.bottom, lessThanOrEqualTo(frame.bottom));
        }
        expect(cancel.overlaps(confirm), isFalse);
        // The question itself can be read to its end: it scrolls when it
        // is taller than what the buttons leave.
        await tester.ensureVisible(find.text(
            l.usualAgainBody(food, shownClock(l, '11:00 AM'))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Cancel writes nothing; Log again writes one.
        await tester.tap(find.byKey(const Key('usualAgainCancel')));
        await tester.pumpAndSettle();
        expect(await phone.mealCount(), count);
        await tester.tap(find.descendant(of: row, matching: find.text(food)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('usualAgainConfirm')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(await phone.mealCount(), count + 1);
        expect(find.text(l.usualLoggedSnack(food, '1,320')), findsOneWidget);
      }, skip: !_haveIphoneFonts);
    }
  });
}
