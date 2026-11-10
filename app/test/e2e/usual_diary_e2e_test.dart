// Usual foods, end to end: two weeks of the owner's diary.
//
// One story per language, told across days with the phone's clock moved
// by hand, through the app's real parts (see harness.dart for the wiring
// and for the few seams that are faked): photos land through the real
// pipeline, the owner taps the real Today, editor, Log sheet and My usual
// foods screens, and every step checks both what the owner SEES (the
// generated l10n getters' text) and what is STORED (the meals rows, read
// with SQL, and the choices preference).
//
// The owner's setup: photo logging, their own server on Claude Plan,
// restaurant lookups off (the lookup stories are in
// saved_answer_e2e_test.dart).
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The oatmeal as the photo model names it, and as the screens show it.
typedef _Words = ({
  Locale locale,
  String aiName,
  String shown,
  String description,
});

const List<_Words> _languages = [
  (
    locale: Locale('en'),
    aiName: 'Oatmeal (~250 g)',
    shown: 'Oatmeal',
    description: 'Bowl of oatmeal',
  ),
  (
    locale: Locale('zh'),
    aiName: '燕麦粥（约250克）',
    shown: '燕麦粥',
    // Full-width punctuation, as a Chinese reply writes it.
    description: '一碗燕麦粥，加了牛奶',
  ),
];

void main() {
  useInProcessSqlite();

  test('the copy the stories read from the getters is the copy the owner '
      'was promised', () {
    final en = copyFor(const Locale('en'));
    final zh = copyFor(const Locale('zh'));
    expect(en.usualItemLine('Oatmeal', '310', '350'),
        'Oatmeal: AI 310 → your usual 350 kcal');
    expect(zh.usualItemLine('燕麦粥', '310', '350'),
        '燕麦粥：AI 310 → 你平时的 350 千卡');
    expect(en.usualChipUse, 'Use');
    expect(zh.usualChipUse, '采用');
    expect(en.usualUsedSnack('310', '350'),
        'Used your usual numbers: 310 → 350 kcal');
    expect(zh.usualUsedSnack('310', '350'), '已采用你平时的数值：310 → 350 千卡');
    expect(en.assistUndo, 'Undo');
    expect(zh.assistUndo, '撤销');
    expect(en.usualCardTitle, 'Your usual numbers');
    expect(zh.usualCardTitle, '你平时的数值');
    expect(en.usualCardFrom('Oatmeal', '2026-10-19'),
        'From your Oatmeal on 2026-10-19.');
    expect(zh.usualCardFrom('燕麦粥', '2026-10-19'),
        '来自你 2026-10-19 记录的「燕麦粥」。');
    expect(en.usualKeepAi, 'Keep AI estimate');
    expect(zh.usualKeepAi, '保留 AI 估算');
    expect(en.addUsual, 'My usual foods');
    expect(zh.addUsual, '我常吃的');
    expect(en.usualNowHeader, 'Around this time');
    expect(zh.usualNowHeader, '这个时间常吃的');
    expect(en.usualLoggedSnack('Bowl of oatmeal', '360'),
        'Logged Bowl of oatmeal · 360 kcal');
    expect(zh.usualLoggedSnack('一碗燕麦粥', '360'), '已记录「一碗燕麦粥」· 360 千卡');
    expect(en.usualAgainTitle, 'Log it again?');
    expect(zh.usualAgainTitle, '再记一次？');
    expect(en.usualAgainBody('Bowl of oatmeal', '07:45 AM'),
        'You logged Bowl of oatmeal at 07:45 AM.');
    expect(zh.usualAgainBody('一碗燕麦粥', '07:45'), '你 07:45 已经记过「一碗燕麦粥」。');
    expect(en.usualAgainConfirm, 'Log again');
    expect(zh.usualAgainConfirm, '再记一次');
  });

  for (final w in _languages) {
    testWidgets('${w.locale}: two weeks of oatmeal — fix it once, Use and '
        'Undo, Keep AI estimate twice mutes it, new numbers bring the offer '
        'back, and My usual foods logs it again with no AI', (tester) async {
      final l = copyFor(w.locale);
      final phone = await Phone.boot(DateTime(2026, 10, 19, 7, 40));
      addTearDown(phone.shutDown);
      final key = usualNameKey(w.aiName)!;

      Map<String, dynamic> oatmeal(num kcal, {num carbs = 45}) => aiSays(
            [foodItem(w.aiName, kcal, p: 10, c: carbs, f: 8)],
            description: w.description,
          );
      Future<int> photoLands(num kcal, {num carbs = 45}) async {
        final id = await phone.photo(oatmeal(kcal, carbs: carbs));
        await tester.pumpAndSettle();
        return id;
      }

      Future<void> newDay(DateTime at) async {
        await dismissSnackBar(tester);
        phone.now = at;
        await reopen(tester);
      }

      Finder card(int id) => find.byKey(ValueKey('meal$id'));
      Finder chipOf(int id) => find.descendant(
          of: card(id), matching: find.byKey(const Key('usualChip')));
      Finder inChip(int id, String text) =>
          find.descendant(of: chipOf(id), matching: find.text(text));
      Future<void> openEditor(int id) async {
        await tester.tap(find.descendant(
            of: card(id), matching: find.text(w.description)));
        await tester.pumpAndSettle();
        expect(find.byType(MealEditorScreen), findsOneWidget);
      }

      Future<void> back() async {
        await goBack(tester);
        expect(find.byType(MealEditorScreen), findsNothing);
      }

      String todayTotal() =>
          tester.widget<Text>(find.byKey(const Key('todayTotalKcal'))).data!;

      await pumpApp(tester, phone, locale: w.locale);
      expect(find.text(l.todayEmptyTitle), findsOneWidget);

      // ── Day 1, Monday 07:40. The watcher saves the oatmeal photo; the
      // model says 300 kcal, fairly sure. Nothing is learned yet. ──
      final day1 = await photoLands(300);
      expect(phone.ai.photoCalls, 1);
      expect(card(day1), findsOneWidget);
      expect(find.byKey(const Key('usualChip')), findsNothing);
      expect(todayTotal(), l.kcalAmount('300'));
      expect((await phone.row(day1))['source'], MealSource.appWatch);
      expect(await phone.corrected(day1), isFalse);
      expect((await phone.item(day1)).containsKey('user'), isFalse);

      // The owner opens it, corrects 300 to 350 and saves.
      await openEditor(day1);
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      await tester.enterText(find.byKey(const Key('itemCal0')), '350');
      await tester.pump();
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsNothing);
      expect(todayTotal(), l.kcalAmount('350'));
      final fixedAt = usualStamp(phone.now);
      expect(await phone.item(day1), {
        'name': w.aiName,
        'estimated_calories': 350,
        'protein_g': 10,
        'carbs_g': 45,
        'fat_g': 8,
        'user': {
          'set': true,
          'at': fixedAt,
          'n': [350, 10, 45, 8],
          'qty': 1,
        },
      });
      expect((await phone.analysis(day1))['total_calories'], 350);
      expect(await phone.corrected(day1), isTrue);
      // A meal never offers its own numbers back to itself.
      expect(find.byKey(const Key('usualChip')), findsNothing);

      // ── Day 2, Tuesday 07:42. The same breakfast; the model says 310
      // and 46 g carbs. Today offers the owner's numbers on the card. ──
      await newDay(DateTime(2026, 10, 20, 7, 42));
      expect(find.text(l.todayEmptyTitle), findsOneWidget);
      final day2 = await photoLands(310, carbs: 46);
      expect(chipOf(day2), findsOneWidget);
      expect(inChip(day2, l.usualItemLine(w.shown, '310', '350')),
          findsOneWidget);
      expect(inChip(day2, l.usualChipUse), findsOneWidget);
      expect(find.bySemanticsLabel(l.usualChipUseLabel(w.shown)),
          findsOneWidget);
      expect(find.byKey(const Key('usualChipReview')), findsNothing);
      // Nothing changes without the tap.
      final asLogged = await phone.raw(day2);
      expect(await phone.corrected(day2), isFalse);
      expect(todayTotal(), l.kcalAmount('310'));

      await tester.tap(find.byKey(const Key('usualChipUse')));
      await tester.pumpAndSettle();
      expect(find.text(l.usualUsedSnack('310', '350')), findsOneWidget);
      expect(find.text(l.assistUndo), findsOneWidget);
      expect(todayTotal(), l.kcalAmount('350'));
      expect(chipOf(day2), findsNothing);
      final used = await phone.analysis(day2);
      expect((used['food_items'] as List).single, {
        'name': w.aiName,
        'estimated_calories': 350,
        'protein_g': 10,
        'carbs_g': 45,
        'fat_g': 8,
        'user': {
          'set': true,
          'at': usualStamp(phone.now),
          'n': [350, 10, 45, 8],
          'qty': 1,
        },
      });
      expect(used['total_calories'], 350);
      expect(used['total_carbs_g'], 45);
      expect(used['meal_description'], w.description);
      expect(await phone.corrected(day2), isTrue);

      // Undo: the analysis is back as the pipeline stored it, byte for
      // byte. The meal stays "corrected", so it is not offered again.
      await tester.tap(find.text(l.assistUndo));
      await tester.pumpAndSettle();
      expect(await phone.raw(day2), asLogged);
      expect(await phone.corrected(day2), isTrue);
      expect(todayTotal(), l.kcalAmount('310'));
      expect(chipOf(day2), findsNothing);
      expect(find.text(l.usualUndoStale), findsNothing);

      // ── Day 3, Wednesday 07:39. The chip again; this time the owner
      // opens the meal instead, and keeps the AI estimate. ──
      await newDay(DateTime(2026, 10, 21, 7, 39));
      final day3 = await photoLands(305);
      // Tuesday's Use was undone, so Monday's numbers are still the usual.
      expect(inChip(day3, l.usualItemLine(w.shown, '305', '350')),
          findsOneWidget);
      await openEditor(day3);
      final offerCard = find.byKey(const Key('usualOfferCard'));
      expect(offerCard, findsOneWidget);
      expect(
          find.descendant(of: offerCard, matching: find.text(l.usualCardTitle)),
          findsOneWidget);
      expect(
          tester.widget<Text>(find.byKey(const Key('usualOfferItem0'))).data,
          l.usualItemLine(w.shown, '305', '350'));
      expect(find.text(l.usualCardFrom(w.shown, '2026-10-19')),
          findsOneWidget);
      expect(find.text(l.usualUseMine), findsOneWidget);
      final day3Raw = await phone.raw(day3);
      await tester.tap(find.byKey(const Key('usualKeepAi')));
      await tester.pumpAndSettle();
      expect(offerCard, findsNothing);
      expect(await phone.raw(day3), day3Raw, reason: 'the meal is not written');
      expect(await phone.corrected(day3), isFalse);
      // The decline is stored as a meal id and a short code, never a name.
      final declined = phone.storedChoices()['declined'] as List;
      expect(declined, hasLength(1));
      expect((declined.single as Map)['m'], day3);
      expect((declined.single as Map)['h'], usualHideId(key));
      expect(phone.prefs.getString('usual_foods.choices_v1'),
          isNot(contains(w.shown)));
      await back();
      expect(chipOf(day3), findsNothing, reason: 'declined on this meal');

      // ── Day 4, Thursday 07:41. One decline mutes nothing: the offer is
      // there again. The owner keeps the AI estimate a second time. ──
      await newDay(DateTime(2026, 10, 22, 7, 41));
      final day4 = await photoLands(300);
      expect(inChip(day4, l.usualItemLine(w.shown, '300', '350')),
          findsOneWidget);
      await openEditor(day4);
      await tester.tap(find.byKey(const Key('usualKeepAi')));
      await tester.pumpAndSettle();
      await back();
      expect((phone.storedChoices()['declined'] as List), hasLength(2));

      // 15:05, oatmeal again: declined on two meals, the food is muted.
      phone.now = DateTime(2026, 10, 22, 15, 5);
      final day4b = await photoLands(290);
      expect(card(day4b), findsOneWidget);
      expect(find.byKey(const Key('usualChip')), findsNothing);
      await openEditor(day4b);
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      await back();
      expect(await phone.corrected(day4b), isFalse);

      // ── Day 5, Friday 07:40. Still muted. The owner sets new numbers
      // in the editor: 360. ──
      await newDay(DateTime(2026, 10, 23, 7, 40));
      final day5 = await photoLands(305);
      expect(find.byKey(const Key('usualChip')), findsNothing);
      await openEditor(day5);
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      await tester.enterText(find.byKey(const Key('itemCal0')), '360');
      await tester.pump();
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect((await phone.item(day5))['user'], {
        'set': true,
        'at': usualStamp(phone.now),
        'n': [360, 10, 45, 8],
        'qty': 1,
      });

      // ── Day 6, Saturday 07:44. New numbers lifted the mute: the offer
      // is back, with the new number. The owner taps Use. ──
      await newDay(DateTime(2026, 10, 24, 7, 44));
      final day6 = await photoLands(300);
      expect(inChip(day6, l.usualItemLine(w.shown, '300', '360')),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('usualChipUse')));
      await tester.pumpAndSettle();
      expect(find.text(l.usualUsedSnack('300', '360')), findsOneWidget);
      final usedAt = usualStamp(phone.now);
      expect((await phone.item(day6))['user'], {
        'set': true,
        'at': usedAt,
        'n': [360, 10, 45, 8],
        'qty': 1,
      });

      // ── Day 7, Sunday 07:45. No photo. Log › My usual foods. ──
      await newDay(DateTime(2026, 10, 25, 7, 45));
      expect(find.text(l.todayEmptyTitle), findsOneWidget);
      expect(phone.ai.photoCalls, 7);
      await tester.tap(find.byKey(const Key('addMealFab')));
      await tester.pumpAndSettle();
      final sheetRow = find.byKey(const Key('addUsual'));
      expect(find.descendant(of: sheetRow, matching: find.text(l.addUsual)),
          findsOneWidget);
      expect(
          find.descendant(of: sheetRow, matching: find.text(l.addManualNote)),
          findsOneWidget);
      await tester.tap(sheetRow);
      await tester.pumpAndSettle();
      expect(find.byType(UsualFoodsScreen), findsOneWidget);
      // Logged on six days, always around this time; the numbers are the
      // owner's latest (Saturday's Use), not any AI estimate.
      final row = find.byKey(ValueKey('usualRow:$key'));
      expect(row, findsOneWidget);
      expect(find.text(l.usualNowHeader), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(w.description)),
          findsOneWidget);
      expect(
          find.descendant(
              of: row,
              matching: find.text('${l.kcalAmount('360')} · '
                  '${l.macroProteinShort}: 10g · '
                  '${l.macroCarbsShort}: 45g · '
                  '${l.macroFatShort}: 8g')),
          findsOneWidget);
      // (The Log sheet's screen labels days with the device clock; no
      // story day is ever the device's today, so the label is the same.)
      expect(
          find.descendant(
              of: row,
              matching: find.text(l.usualRowStats(
                  6, shownDay(l, '2026-10-24', phone.now)))),
          findsOneWidget);
      expect(find.text(l.usualScreenHint), findsOneWidget);

      // One tap logs it: one more row, no model call.
      final before = await phone.mealCount();
      final callsBefore = phone.ai.calls;
      final ledgerBefore =
          (await phone.db.query('photo_ingestions')).length;
      expect(before, 7);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualAgainDialog')), findsNothing);
      expect(await phone.mealCount(), before + 1);
      expect(phone.ai.calls, callsBefore, reason: 'zero AI calls');
      expect(phone.lookups.submits, isEmpty);
      expect((await phone.db.query('photo_ingestions')).length, ledgerBefore,
          reason: 'no photo, no ledger row');
      final logged = await phone.lastMealId();
      final stored = await phone.row(logged);
      expect(stored['source'], 'app_repeat');
      expect(stored['date'], '2026-10-25');
      expect(stored['time'], '07:45 AM');
      expect(stored['corrected'], 0);
      expect(stored['image_hash'] ?? '', '');
      expect(stored['file_id'] ?? '', '');
      final again = await phone.analysis(logged);
      expect(again.keys.toSet(), {
        'is_food',
        'meal_description',
        'food_items',
        'total_calories',
        'total_protein_g',
        'total_carbs_g',
        'total_fat_g',
        'logged_again',
      });
      expect(again['logged_again'], usualStamp(phone.now));
      expect(again['total_calories'], 360);
      // The owner's numbers, with the mark of the day they were set.
      expect((again['food_items'] as List).single, {
        'name': w.aiName,
        'estimated_calories': 360,
        'protein_g': 10,
        'carbs_g': 45,
        'fat_g': 8,
        'user': {
          'set': true,
          'at': usedAt,
          'n': [360, 10, 45, 8],
          'qty': 1,
        },
      });
      expect(find.text(l.usualLoggedSnack(w.description, '360')),
          findsOneWidget);
      expect(find.byKey(const Key('usualLoggedCheck')), findsOneWidget);

      // Undo takes that one row away again.
      await tester.tap(find.text(l.assistUndo));
      await tester.pumpAndSettle();
      expect(await phone.mealCount(), before);
      expect(await phone.db.query('meals', where: 'id = ?', whereArgs: [logged]),
          isEmpty);
      expect(find.byKey(const Key('usualLoggedCheck')), findsNothing);

      // Logged for real this time.
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(await phone.mealCount(), before + 1);
      await dismissSnackBar(tester);

      // 08:30, a tap on the same row: it was logged 45 minutes ago, so
      // the app asks first. Cancel writes nothing.
      phone.now = DateTime(2026, 10, 25, 8, 30);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('usualAgainDialog'));
      expect(dialog, findsOneWidget);
      expect(
          find.descendant(of: dialog, matching: find.text(l.usualAgainTitle)),
          findsOneWidget);
      expect(
          find.text(l.usualAgainBody(
              w.description, shownClock(l, '07:45 AM'))),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('usualAgainCancel')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(await phone.mealCount(), before + 1);
      expect(find.byKey(const Key('usualLoggedSnack')), findsNothing);

      // Log again writes exactly one.
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('usualAgainConfirm')));
      await tester.pumpAndSettle();
      expect(await phone.mealCount(), before + 2);
      expect((await phone.row(await phone.lastMealId()))['time'], '08:30 AM');
      expect(phone.ai.calls, callsBefore);

      // Back on Today: both are in the day's total, and neither gets an
      // offer (they are not photos).
      await dismissSnackBar(tester);
      await goBack(tester);
      expect(todayTotal(), l.kcalAmount('720'));
      expect(find.byKey(const Key('usualChip')), findsNothing);
    });
  }
}
