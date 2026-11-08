// The usual-foods service (usual-foods spec §3.5-§3.7, §4.3, §5): Use and
// its undo through the compare-and-set, Keep AI estimate and muting, the
// memoized index, logging again and its undo, the fresh "Log it again?"
// read, and usualLookupTakesIt (T31-T33, T41, the B part of T47).
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart'
    show usualHideId, usualStamp, UsualDecline;
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart'
    show AssistMode, AssistSettingsView;
import 'package:calorie_tracker/services/nl/executor.dart';
import 'package:calorie_tracker/services/usual/usual_foods.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../nl/fakes.dart' show FakeAnalyzer, testSettings;
import '../support/fake_meals_dao.dart';

class _Dao extends BaseFakeDao {
  final List<(String, String)> betweenCalls = [];

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) {
    betweenCalls.add((startDate, endDate));
    return super.mealsBetween(startDate, endDate);
  }
}

const String today = '2026-11-07';

Map<String, dynamic> item(String name, num kcal,
        {num p = 10, num c = 54, num f = 6, Map<String, dynamic>? user}) =>
    {
      'name': name,
      'estimated_calories': kcal,
      'protein_g': p,
      'carbs_g': c,
      'fat_g': f,
      'user': ?user,
    };

Map<String, dynamic> mark(List<num> n,
        {String at = '2026-11-03T08:00:00.000Z'}) =>
    {'set': true, 'at': at, 'n': n, 'qty': 1};

Map<String, dynamic> analysisOf(List<Map<String, dynamic>> items,
    {String desc = 'Breakfast'}) {
  num sum = 0;
  for (final i in items) {
    sum += i['estimated_calories'] as num;
  }
  return {
    'is_food': true,
    'meal_description': desc,
    'total_calories': sum,
    'total_protein_g': 10,
    'total_carbs_g': 54,
    'total_fat_g': 6,
    'estimate_confidence': 'medium',
    'restaurant_context': 'home',
    'food_items': items,
  };
}

void main() {
  late _Dao dao;
  late ValueNotifier<int> signal;
  late UsualChoices choices;
  late DateTime clock;
  late bool takes;
  late UsualFoods usual;

  setUp(() async {
    dao = _Dao();
    signal = ValueNotifier<int>(0);
    clock = DateTime(2026, 11, 7, 12, 30);
    takes = false;
    SharedPreferences.setMockInitialValues({});
    choices = UsualChoices(await SharedPreferences.getInstance(),
        clock: () => clock);
    usual = UsualFoods(
      dao: dao,
      choices: choices,
      mealsChanged: signal,
      onMealsChanged: () => signal.value++,
      lookupTakesIt: (_) => takes,
      clock: () => clock,
    );
  });

  int seed(List<Map<String, dynamic>> items,
          {String date = today,
          String time = '07:40 AM',
          String source = MealSource.appWatch,
          bool corrected = false,
          String desc = 'Breakfast'}) =>
      dao.put(Meal(
        id: 0,
        date: date,
        time: time,
        timestamp: '${date}T08:00:00.000',
        source: source,
        corrected: corrected,
        analysis: analysisOf(items, desc: desc),
      ));

  /// The user's oatmeal (350) from Nov 3, and today's photo (AI 300).
  int learnedAndPhoto() {
    seed([item('Oatmeal (~250 g)', 350, p: 12, c: 50, f: 14,
        user: mark([350, 12, 50, 14]))],
        date: '2026-11-03', source: MealSource.appPhoto, corrected: true);
    return seed([item('Oatmeal (~260 g)', 300)]);
  }

  group('offersFor and the memo', () {
    test('no candidate meal: no index is built', () async {
      final id = seed([item('Oatmeal', 300)], source: MealSource.appManual);
      expect(await usual.offersFor([dao.byId(id)]), isEmpty);
      expect(dao.betweenCalls, isEmpty);
    });

    test('a photo meal gets the offer, read once per signal', () async {
      final id = learnedAndPhoto();
      final offers = await usual.offersFor([dao.byId(id)]);
      expect(offers[id]!.items.single.mine.kcal, 350);
      expect(dao.betweenCalls, [('2026-08-10', today)]);
      await usual.offersFor([dao.byId(id)]);
      expect(dao.betweenCalls, hasLength(1), reason: 'memoized');
      signal.value++;
      await usual.offerFor(dao.byId(id));
      expect(dao.betweenCalls, hasLength(2), reason: 'a new signal');
      usual.invalidate();
      await usual.offerFor(dao.byId(id));
      expect(dao.betweenCalls, hasLength(3), reason: 'a new epoch');
      clock = DateTime(2026, 11, 8, 0, 1);
      await usual.index();
      expect(dao.betweenCalls, hasLength(4), reason: 'a new day');
    });

    test('a meal the lookup takes gets no offer', () async {
      final id = learnedAndPhoto();
      takes = true;
      expect(await usual.offersFor([dao.byId(id)]), isEmpty);
    });

    test('a lookupTakesIt that throws reads as taken', () async {
      final id = learnedAndPhoto();
      final throwing = UsualFoods(
          dao: dao,
          choices: choices,
          mealsChanged: signal,
          onMealsChanged: () {},
          lookupTakesIt: (_) => throw StateError('no support'),
          clock: () => clock);
      expect(await throwing.offersFor([dao.byId(id)]), isEmpty);
    });
  });

  group('accept (T31)', () {
    test('writes through updateMealAnalysisIfUnchanged and sets corrected',
        () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      final before = signal.value;
      final r = await usual.accept(id, shown: shown);
      expect(r.status, UsualAcceptStatus.written);
      expect((r.mealId, r.beforeKcal, r.afterKcal), (id, 300, 350));
      expect(dao.assistWrites, isEmpty, reason: 'never through applyAssist');
      expect(dao.updates, hasLength(1));
      final m = dao.byId(id);
      expect(m.corrected, isTrue);
      final it = (m.analysis['food_items'] as List).single as Map;
      expect(it['estimated_calories'], 350);
      expect((it['user'] as Map)['set'], isTrue);
      expect(m.analysis['total_calories'], 350);
      expect(signal.value, before + 1);
      // A corrected meal is never offered again.
      expect(await usual.offerFor(dao.byId(id)), isNull);
    });

    test('nothing is written when the shown AI numbers changed', () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      final i = dao.meals.indexWhere((m) => m.id == id);
      final m = dao.meals[i];
      dao.meals[i] = Meal(
          id: m.id,
          date: m.date,
          time: m.time,
          timestamp: m.timestamp,
          source: m.source,
          analysis: analysisOf([item('Oatmeal (~260 g)', 290)]));
      final r = await usual.accept(id, shown: shown);
      expect(r.status, UsualAcceptStatus.conflict);
      expect(dao.updates, isEmpty);
    });

    test('nothing is written when the editor\'s raw text changed', () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      final raw = (await dao.mealSnapshot(id))!.rawAnalysis;
      final stale = await usual.accept(id, shown: shown, expectedRaw: '$raw ');
      expect(stale.status, UsualAcceptStatus.conflict);
      expect(dao.updates, isEmpty);
      final fresh = await usual.accept(id, shown: shown, expectedRaw: raw);
      expect(fresh.status, UsualAcceptStatus.written);
    });

    test('a writer between the read and the write wins', () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      dao.beforeCompareAndSet = (mealId) async {
        await dao.updateMealAnalysis(
            mealId, analysisOf([item('Oatmeal (~260 g)', 320)]));
      };
      final r = await usual.accept(id, shown: shown);
      expect(r.status, UsualAcceptStatus.conflict);
      expect(dao.byId(id).analysis['total_calories'], 320);
    });

    test('a second concurrent call returns busy and writes nothing', () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      final first = usual.accept(id, shown: shown);
      final second = await usual.accept(id, shown: shown);
      expect(second.status, UsualAcceptStatus.busy);
      expect((await first).status, UsualAcceptStatus.written);
      expect(dao.updates, hasLength(1));
    });

    test('Use of a kcal-only offer does not make the AI macros yours',
        () async {
      // A hand-typed latte, kcal only (macros left blank): a kcal-only
      // record.
      final typed = seed([item('Oat milk latte', 190, p: 0, c: 0, f: 0)],
          date: '2026-11-03', source: MealSource.appManual);
      // Photo A: AI 120 kcal, 4/15/5. Use.
      final a = seed([item('Oat milk latte', 120, p: 4, c: 15, f: 5)],
          time: '08:00 AM');
      final offerA = (await usual.offerFor(dao.byId(a)))!;
      expect(offerA.items.single.kcalOnly, isTrue);
      expect((await usual.accept(a, shown: offerA)).status,
          UsualAcceptStatus.written);
      // Photo B: AI 185 kcal, 7/22/7. Against the kcal-only record the kcal
      // differs by 5 (< 20) and macros are ignored: no offer.
      final b = seed([item('Oat milk latte', 185, p: 7, c: 22, f: 7)],
          time: '03:00 PM');
      final rec = (await usual.index()).records['latte milk oat']!;
      expect((rec.mealId, rec.kcalOnly), (typed, true),
          reason: 'still the hand-typed record, not photo A\'s AI macros '
              '(${rec.numbers})');
      expect(await usual.offerFor(dao.byId(b)), isNull);
    });

    test('the user\'s later numbers win over an earlier Use through an alias',
        () async {
      Map<String, dynamic> renamed(List<num> n, String at) =>
          item('Overnight oats', n[0], p: n[1], c: n[2], f: n[3], user: {
            ...mark(n, at: at),
            'ai_name': 'Oatmeal (~250 g)',
          });
      // The same rename on 2 meals: a confirmed alias.
      seed([renamed([350, 12, 50, 14], '2026-11-01T08:00:00.000Z')],
          date: '2026-11-01', source: MealSource.appPhoto, corrected: true);
      seed([renamed([350, 12, 50, 14], '2026-11-02T08:00:00.000Z')],
          date: '2026-11-02', source: MealSource.appPhoto, corrected: true);
      // This morning's photo is offered through the alias; Use.
      final p1 = seed([item('Oatmeal (~260 g)', 300)], time: '07:00 AM');
      final o1 = (await usual.offerFor(dao.byId(p1)))!;
      expect(o1.items.single.viaAlias, isTrue);
      expect((await usual.accept(p1, shown: o1)).status,
          UsualAcceptStatus.written);
      // An hour later the user sets new numbers for their overnight oats.
      clock = DateTime(2026, 11, 7, 13, 30);
      seed([renamed([420, 14, 60, 16], usualStamp(clock))],
          time: '01:30 PM', source: MealSource.appPhoto, corrected: true);
      signal.value++;
      final p2 = seed([item('Oatmeal (~260 g)', 300)], time: '03:00 PM');
      final o2 = (await usual.offerFor(dao.byId(p2)))!;
      expect((o2.items.single.mine.kcal, o2.items.single.learnedName),
          (420, 'Overnight oats'),
          reason: 'the morning Use\'s copy must not hide the newer numbers');
    });

    test('a deleted meal is gone', () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      await dao.deleteMeal(id);
      expect((await usual.accept(id, shown: shown)).status,
          UsualAcceptStatus.gone);
    });
  });

  group('undoAccept (T32)', () {
    test('restores while unchanged and records no decline', () async {
      final id = learnedAndPhoto();
      final original = dao.byId(id).analysis;
      final shown = (await usual.offerFor(dao.byId(id)))!;
      final r = await usual.accept(id, shown: shown);
      final before = signal.value;
      expect(await usual.undoAccept(r), isTrue);
      expect(dao.byId(id).analysis, original);
      expect(dao.byId(id).corrected, isTrue, reason: 'as the leftover undo');
      expect(signal.value, before + 1);
      expect(choices.view().declined, isEmpty);
    });

    test('writes nothing once the meal changed', () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      final r = await usual.accept(id, shown: shown);
      final edited = Map<String, dynamic>.from(dao.byId(id).analysis)
        ..['food_items'] = [item('Oatmeal (~260 g)', 360)];
      await dao.updateMealAnalysis(id, edited);
      final writes = dao.updates.length;
      expect(await usual.undoAccept(r), isFalse);
      expect(dao.updates, hasLength(writes));
      expect(dao.byId(id).analysis, edited);
    });

    test('a result that wrote nothing has nothing to undo', () async {
      final id = learnedAndPhoto();
      final shown = (await usual.offerFor(dao.byId(id)))!;
      await dao.deleteMeal(id);
      final r = await usual.accept(id, shown: shown);
      expect(await usual.undoAccept(r), isFalse);
    });
  });

  group('Keep AI estimate and muting (T33)', () {
    test('a decline hides that meal\'s offer and writes nothing', () async {
      final id = learnedAndPhoto();
      final offer = (await usual.offerFor(dao.byId(id)))!;
      await usual.decline(offer);
      expect(await usual.offerFor(dao.byId(id)), isNull);
      expect(dao.updates, isEmpty);
      expect(choices.view().declined.single.hideId, usualHideId('oatmeal'));
    });

    test('2 declines on different meals mute the food; new numbers lift it',
        () async {
      seed([item('Oatmeal (~250 g)', 350, p: 12, c: 50, f: 14,
          user: mark([350, 12, 50, 14]))],
          date: '2026-11-03', source: MealSource.appPhoto, corrected: true);
      final a = seed([item('Oatmeal (~260 g)', 300)], time: '07:00 AM');
      final b = seed([item('Oatmeal (~260 g)', 300)], time: '08:00 AM');
      final c = seed([item('Oatmeal (~260 g)', 300)], time: '09:00 AM');
      await usual.decline((await usual.offerFor(dao.byId(a)))!);
      expect(await usual.offerFor(dao.byId(c)), isNotNull,
          reason: 'one decline does not mute');
      await usual.decline((await usual.offerFor(dao.byId(b)))!);
      expect(await usual.offerFor(dao.byId(c)), isNull, reason: 'muted');
      // The user sets new numbers for the food after the declines.
      seed([item('Oatmeal', 380, p: 12, c: 50, f: 14,
          user: mark([380, 12, 50, 14], at: '2026-11-07T19:00:00.000Z'))],
          date: today, time: '11:00 AM', source: MealSource.appManual);
      signal.value++;
      final lifted = await usual.offerFor(dao.byId(c));
      expect(lifted!.items.single.mine.kcal, 380);
    });

    test('declines older than 90 days are ignored', () async {
      final id = learnedAndPhoto();
      final h = usualHideId('oatmeal');
      final old = UsualChoicesView(declined: [
        UsualDecline(mealId: 50, hideId: h, at: DateTime(2026, 11, 4)),
        UsualDecline(mealId: 51, hideId: h, at: DateTime(2026, 11, 5)),
      ]);
      expect(
          old.muted('oatmeal',
              since: DateTime.utc(2026, 11, 3), now: DateTime(2026, 11, 7)),
          isTrue);
      expect(
          old.muted('oatmeal',
              since: DateTime.utc(2026, 11, 3), now: DateTime(2027, 2, 10)),
          isFalse);
      expect(await usual.offerFor(dao.byId(id)), isNotNull);
    });
  });

  group('a fix by chat teaches nothing (spec §3.1, P10)', () {
    /// Applies a chat correction of meal [id] to [analysis], as the Fix
    /// screen does: the executor stores the text model's analysis.
    Future<void> chatFix(int id, Map<String, dynamic> analysis) async {
      final exec = createExecutor(dao, FakeAnalyzer(), await testSettings())
          as DefaultNlExecutor;
      final recent = await dao.recentMeals();
      await exec.executeParsed({
        'intent': 'correction',
        'meal_index': recent.indexWhere((m) => m.id == id),
        'analysis': analysis,
      }, 'it was a bigger bowl', recent);
    }

    test('the model\'s numbers on a hand-typed meal are neither learned nor '
        'offered', () async {
      final typed = seed([item('Oatmeal', 350, p: 12, c: 50, f: 14)],
          date: '2026-11-03', source: MealSource.appManual);
      await chatFix(
          typed,
          analysisOf([
            item('Oatmeal', 520, p: 18, c: 80, f: 16),
            item('Banana', 105, p: 1, c: 27, f: 0),
          ]));
      final fixed = dao.byId(typed);
      expect((fixed.source, fixed.corrected), (MealSource.appManual, true),
          reason: 'the fix keeps the source');
      final index = await usual.index();
      expect((index.records['oatmeal'], index.records['banana']),
          (null, null));
      final photo = seed([item('Oatmeal (~260 g)', 300)]);
      expect(await usual.offerFor(dao.byId(photo)), isNull);
    });

    test('a re-log of the fixed meal never stamps the model\'s numbers as '
        'yours', () async {
      seed([item('Oatmeal', 350, p: 12, c: 50, f: 14)],
          date: '2026-11-03', source: MealSource.appManual);
      final typed = seed([item('Oatmeal', 350, p: 12, c: 50, f: 14)],
          date: '2026-11-04', source: MealSource.appManual);
      await chatFix(
          typed, analysisOf([item('Oatmeal', 520, p: 18, c: 80, f: 16)]));
      final row = (await usual.frequentMeals()).more.single;
      expect(row.template.id, typed);
      final done = (await usual.logAgain(row))!;
      final it =
          (dao.byId(done.mealId).analysis['food_items'] as List).single as Map;
      // The numbers the user typed on Nov 3 replace the template's; the
      // chat model's 520 is no record, so no mark vouches for it.
      expect(it['estimated_calories'], 350, reason: 'the re-log wrote $it');
      expect((it['user'] as Map)['n'], [350, 12, 50, 14]);
    });
  });

  group('My usual foods (T41)', () {
    UsualMeal row(Map<String, dynamic> analysis) => UsualMeal(
        key: 'k',
        title: usualMealTitle(analysis),
        template: Meal(
            id: 99,
            date: '2026-11-05',
            time: '08:00 AM',
            timestamp: '2026-11-05T08:00:00.000',
            source: MealSource.appManual,
            analysis: analysis),
        days90: 2,
        days30: 2,
        aroundDays: 0,
        lastDate: '2026-11-05',
        lastTime: '08:00 AM',
        loggedTodayTime: null,
        numbers: (kcal: 0, p: 0, c: 0, f: 0));

    test('frequentMeals lists a meal logged on 2 days; hide and unhide',
        () async {
      seed([item('Oat milk latte', 190, p: 6, c: 24, f: 7)],
          date: '2026-11-05', time: '03:10 PM', desc: 'Oat milk latte');
      seed([item('Oat milk latte', 190, p: 6, c: 24, f: 7)],
          date: '2026-11-06', time: '03:05 PM', desc: 'Oat milk latte');
      final list = await usual.frequentMeals();
      final m = [...list.around, ...list.more].single;
      expect(m.title, 'Oat milk latte');
      expect(m.numbers, (kcal: 190, p: 6, c: 24, f: 7));
      await usual.hide(m);
      final hidden = await usual.frequentMeals();
      expect(hidden.isEmpty, isTrue);
      expect(hidden.hiddenCount, 1);
      expect([for (final h in await usual.hiddenMeals()) h.title],
          ['Oat milk latte']);
      await usual.unhide(m);
      expect((await usual.frequentMeals()).hiddenCount, 0);
    });

    test('logAgain saves one app_repeat meal now, with no photo and no '
        'ledger row, and signals', () async {
      seed([item('Oat milk latte', 190, p: 6, c: 24, f: 7)],
          date: '2026-11-05', desc: 'Oat milk latte');
      seed([item('Oat milk latte', 190, p: 6, c: 24, f: 7)],
          date: '2026-11-06', desc: 'Oat milk latte');
      final m = (await usual.frequentMeals()).more.single;
      clock = DateTime(2026, 11, 7, 15, 10, 4, 321);
      final before = signal.value;
      final r = (await usual.logAgain(m))!;
      expect(dao.saved, hasLength(1));
      final saved = dao.byId(r.mealId);
      expect(saved.source, MealSource.appRepeat);
      expect(saved.date, today);
      expect(saved.time, '03:10 PM');
      expect(saved.timestamp, clock.toIso8601String());
      expect(saved.imageHash, '');
      expect(saved.fileId, '');
      expect(saved.corrected, isFalse);
      expect(dao.ledger, isEmpty);
      expect(saved.analysis['logged_again'], isNotNull);
      expect(signal.value, before + 1);
      expect((r.title, r.kcal), ('Oat milk latte', 190));
      expect(r.rawAnalysis, (await dao.mealSnapshot(r.mealId))!.rawAnalysis);
    });

    test('a second log while one runs writes nothing', () async {
      seed([item('Latte', 190)], date: '2026-11-05', desc: 'Latte');
      seed([item('Latte', 190)], date: '2026-11-06', desc: 'Latte');
      final m = (await usual.frequentMeals()).more.single;
      final first = usual.logAgain(m);
      expect(await usual.logAgain(m), isNull);
      expect(await first, isNotNull);
      expect(dao.saved, hasLength(1));
    });

    test('undoLog deletes only while unchanged', () async {
      seed([item('Latte', 190)], date: '2026-11-05', desc: 'Latte');
      seed([item('Latte', 190)], date: '2026-11-06', desc: 'Latte');
      final m = (await usual.frequentMeals()).more.single;
      final r = (await usual.logAgain(m))!;
      expect(await usual.undoLog(r), isTrue);
      expect(dao.deletedIds, [r.mealId]);

      final r2 = (await usual.logAgain(m))!;
      await dao.updateMealAnalysis(r2.mealId, analysisOf([item('Latte', 250)]));
      expect(await usual.undoLog(r2), isFalse);
      expect(dao.deletedIds, [r.mealId]);
    });

    test('loggedRecently reads the meals fresh: a seeded meal with no signal '
        'is found', () async {
      final latte = row(analysisOf([item('Latte', 190)]));
      await usual.index(); // a memo exists
      expect(await usual.loggedRecently(latte), isNull);
      seed([item('Iced latte', 150)], time: '11:30 AM'); // no signal bump
      final found = await usual.loggedRecently(latte);
      expect(found?.time, '11:30 AM');
    });

    test('it finds a reworded pair', () async {
      final oats = row(analysisOf([item('Blueberry oatmeal', 320)]));
      seed([item('Steel-cut oats with berries (~250 g)', 300)],
          time: '10:00 AM');
      expect(await usual.loggedRecently(oats), isNotNull);
      final soup = row(analysisOf([item('Tomato soup', 200)]));
      expect(await usual.loggedRecently(soup), isNull);
    });

    test('it finds a 23:30 meal at 01:00, and nothing at 3 h 1 min', () async {
      final tea = row(analysisOf([item('Chamomile tea', 5)]));
      seed([item('Chamomile tea', 5)], date: '2026-11-06', time: '11:30 PM');
      clock = DateTime(2026, 11, 7, 1, 0);
      expect(await usual.loggedRecently(tea), isNotNull);
      clock = DateTime(2026, 11, 7, 2, 30);
      expect(await usual.loggedRecently(tea), isNotNull, reason: '3 h');
      clock = DateTime(2026, 11, 7, 2, 31);
      expect(await usual.loggedRecently(tea), isNull);
    });

    test('a non-food meal does not count', () async {
      final tea = row(analysisOf([item('Chamomile tea', 5)]));
      final id = seed([item('Chamomile tea', 5)], time: '12:00 PM');
      await dao.updateMealAnalysis(
          id, {...dao.byId(id).analysis, 'is_food': false});
      expect(await usual.loggedRecently(tea), isNull);
    });
  });

  group('usualLookupTakesIt (T47, B part)', () {
    const support = LookupSupport(
        supported: true,
        recipient: LookupRecipient.claudePlan,
        locationAllowed: true,
        recipientHostTag: 'abcd1234');
    final consented = DateTime(2026, 11, 1);
    AssistSettingsView view(AssistMode mode, {String? recipient}) =>
        AssistSettingsView(
            mode: mode,
            consentAt: consented,
            consentRecipient: recipient ?? support.recipientStamp);
    Map<String, dynamic> a(String context,
            {String confidence = 'medium', String? brand}) =>
        {
          'is_food': true,
          'restaurant_context': context,
          'estimate_confidence': confidence,
          'food_items': [
            {'name': 'Latte', 'estimated_calories': 190, 'brand': ?brand},
          ],
        };
    bool takesIt(Map<String, dynamic> analysis, AssistSettingsView v,
            [LookupSupport s = support]) =>
        usualLookupTakesIt(analysis, settings: v, support: s);

    test('Off never takes a meal', () {
      expect(takesIt(a('restaurant'), view(AssistMode.off)), isFalse);
    });
    test('an unsupported provider never takes a meal', () {
      expect(
          takesIt(a('restaurant'), view(AssistMode.always),
              const LookupSupport.unsupported('no_search_tool')),
          isFalse);
    });
    test('a paused consent (another recipient) never takes a meal', () {
      expect(
          takesIt(a('restaurant'),
              view(AssistMode.always, recipient: 'claude_plan:ffffffff')),
          isFalse);
      expect(
          takesIt(a('restaurant'),
              const AssistSettingsView(mode: AssistMode.always)),
          isFalse,
          reason: 'never consented');
    });
    test('Always takes a restaurant meal', () {
      expect(takesIt(a('restaurant'), view(AssistMode.always)), isTrue);
      expect(takesIt(a('takeout'), view(AssistMode.always)), isTrue);
    });
    test('Always takes a home meal with a chain-brand item', () {
      expect(takesIt(a('home', brand: 'Starbucks'), view(AssistMode.always)),
          isTrue);
    });
    test('Always leaves a plain home meal', () {
      expect(takesIt(a('home'), view(AssistMode.always)), isFalse);
    });
    test('When unsure leaves a high-confidence restaurant meal', () {
      expect(
          takesIt(a('restaurant', confidence: 'high'), view(AssistMode.auto)),
          isFalse);
      expect(
          takesIt(a('restaurant', confidence: 'low'), view(AssistMode.auto)),
          isTrue);
    });
  });
}
