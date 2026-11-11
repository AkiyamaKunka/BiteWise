// Usual foods, end to end: time.
//
// Stories about the clock, through the app's real parts (harness.dart):
//   1. A late eater's week: meals just before and after midnight, the app
//      left open past midnight (Today and the editor), "Around this time"
//      wrapping midnight to the minute, and "Log it again?" across it.
//   2. Ninety days back, to the day, on both sides of a clock change: what
//      is still learned from and listed on day 89, and no longer on day 90
//      or 91; the 30-day edge of "Around this time".
//   3. A meal dated tomorrow, and numbers set while the phone's clock was
//      wrong.
//
// Every date is a local calendar date, so the stories hold in any zone.
// Run them in three (the repo's clock recipe):
//   TZ=UTC flutter test test/e2e/usual_time_e2e_test.dart
//   TZ=America/Chicago flutter test test/e2e/usual_time_e2e_test.dart
//   TZ=Asia/Shanghai flutter test test/e2e/usual_time_e2e_test.dart
// America/Chicago is the one with the clock changes of story 2 (1 November
// 2026 and 14 March 2027): there a window worked out with 24-hour days
// instead of calendar days is a day off, and the story fails.
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Finder _card(int id) => find.byKey(ValueKey('meal$id'));
Finder _chip(int id) =>
    find.descendant(of: _card(id), matching: find.byKey(const Key('usualChip')));
Finder _row(String food) =>
    find.byKey(ValueKey('usualRow:${usualNameKey(food)}'));

/// The model's reply for one [food].
Map<String, dynamic> _one(String food, num kcal) =>
    aiSays([foodItem(food, kcal)], description: food);

/// At [when], a photo of [food] lands (the model says [kcal]).
Future<int> _photo(WidgetTester tester, Phone phone, DateTime when,
    String food, num kcal) async {
  phone.now = when;
  final id = await phone.photo(_one(food, kcal));
  await tester.pumpAndSettle();
  return id;
}

/// At [when], the app is opened, a photo of [food] lands (the model says
/// [ai] kcal) and the owner sets [mine] in the editor.
Future<int> _teach(WidgetTester tester, Phone phone, DateTime when,
    String food, num ai, num mine) async {
  await dismissSnackBar(tester);
  phone.now = when;
  await reopen(tester);
  final id = await phone.photo(_one(food, ai));
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: _card(id), matching: find.text(food)));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('itemCal0')), '$mine');
  await tester.pump();
  await tester.tap(find.byKey(const Key('saveMealButton')));
  await tester.pumpAndSettle();
  expect(find.byType(MealEditorScreen), findsNothing);
  return id;
}

/// The app is opened at [when].
Future<void> _open(WidgetTester tester, Phone phone, DateTime when) async {
  await dismissSnackBar(tester);
  phone.now = when;
  await reopen(tester);
}

void main() {
  useInProcessSqlite();

  testWidgets('a late eater: meals on both sides of midnight, the app left '
      'open past it, "Around this time" across it, "Log it again?" across '
      'it', (tester) async {
    final l = copyFor(const Locale('en'));
    final phone = await Phone.boot(DateTime(2026, 10, 10, 23, 30));
    addTearDown(phone.shutDown);
    await pumpApp(tester, phone);

    // The owner's ramen is 620, set on the 10th.
    await _teach(tester, phone, DateTime(2026, 10, 10, 23, 30), 'Ramen', 500, 620);
    // Other things eaten on the 18th and the 19th, each at its own clock
    // (minutes from 00:15: tea 120, toast 121, milk 120, egg 121).
    for (final day in [18, 19]) {
      await _photo(tester, phone, DateTime(2026, 10, day, 2, 15), 'Milk', 120);
      await _photo(tester, phone, DateTime(2026, 10, day, 2, 16), 'Egg', 80);
      await _photo(tester, phone, DateTime(2026, 10, day, 12, 30), 'Sandwich', 400);
      await _photo(tester, phone, DateTime(2026, 10, day, 22, 14), 'Toast', 150);
      await _photo(tester, phone, DateTime(2026, 10, day, 22, 15), 'Tea', 30);
    }

    // ── 20 October, 23:50. Ramen. It is today's meal for ten minutes. ──
    await _open(tester, phone, DateTime(2026, 10, 20, 23, 50));
    final late = await phone.photo(_one('Ramen', 480));
    await tester.pumpAndSettle();
    expect((await phone.row(late))['date'], '2026-10-20');
    expect((await phone.row(late))['time'], '11:50 PM');
    expect(
        find.descendant(
            of: _chip(late),
            matching: find.text(l.usualItemLine('Ramen', '480', '620'))),
        findsOneWidget);
    final lateRaw = await phone.raw(late);

    // 00:05. The app was left open; the chip is still on screen. Use now
    // writes nothing (the meal is yesterday's and gets no offer), says
    // nothing, and Today turns to the new day.
    phone.now = DateTime(2026, 10, 21, 0, 5);
    expect(_chip(late), findsOneWidget, reason: 'nothing reloaded Today');
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect(await phone.raw(late), lateRaw);
    expect(await phone.corrected(late), isFalse);
    expect(find.byType(SnackBar), findsNothing);
    expect(_card(late), findsNothing);
    expect(find.text(l.todayEmptyTitle), findsOneWidget);
    expect(await phone.usual.offerFor((await phone.dao.mealSnapshot(late))!.meal),
        isNull);

    // 00:10. A second bowl. This one is the new day's first meal.
    final early = await _photo(
        tester, phone, DateTime(2026, 10, 21, 0, 10), 'Ramen', 480);
    expect((await phone.row(early))['date'], '2026-10-21');
    expect((await phone.row(early))['time'], '12:10 AM');
    expect(_chip(early), findsOneWidget);
    expect(todayEaten(tester), '480',
        reason: "yesterday's bowl is not in today's total");
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect(find.text(l.usualUsedSnack('480', '620')), findsOneWidget);
    expect((await phone.item(early))['estimated_calories'], 620);

    // ── 21 October, 23:55. Ramen again; the owner opens it. The editor is
    // left open past midnight: Use my numbers then writes nothing, and the
    // card goes without a word. ──
    await _open(tester, phone, DateTime(2026, 10, 21, 23, 55));
    final third = await phone.photo(_one('Ramen', 470));
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: _card(third), matching: find.text('Ramen')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualOfferCard')), findsOneWidget);
    expect(find.text(l.usualCardFrom('Ramen', '2026-10-21')), findsOneWidget,
        reason: 'the numbers come from the bowl used after midnight');
    final thirdRaw = await phone.raw(third);
    phone.now = DateTime(2026, 10, 22, 0, 5);
    await tester.tap(find.byKey(const Key('usualUseMine')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualOfferCard')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(await phone.raw(third), thirdRaw);
    expect(await phone.corrected(third), isFalse);
    await goBack(tester);

    // ── 22 October, 00:15. My usual foods, read at a quarter past
    // midnight. "Around this time" reaches back over midnight to 22:15
    // and forward to 02:15, to the minute. ──
    phone.now = DateTime(2026, 10, 22, 0, 15);
    await pushFromLog(
        tester, UsualFoodsScreen(usual: phone.usual, now: phone.clock));
    final moreAt = tester.getTopLeft(find.text(l.usualMoreHeader)).dy;
    expect(tester.getTopLeft(find.text(l.usualNowHeader)).dy, lessThan(moreAt));
    double top(String food) => tester.getTopLeft(_row(food)).dy;
    for (final food in ['Ramen', 'Tea', 'Milk']) {
      expect(top(food), lessThan(moreAt), reason: '$food is around this time');
    }
    for (final food in ['Toast', 'Egg', 'Sandwich']) {
      expect(top(food), greaterThan(moreAt), reason: '$food is not');
    }
    // Ramen: four bowls on three days (the 10th, the 20th and the 21st,
    // twice), the last one yesterday.
    expect(
        find.descendant(
            of: _row('Ramen'),
            matching: find.text(l.usualRowStats(
                3, shownDay(l, '2026-10-21', phone.now)))),
        findsOneWidget);
    expect(find.text(l.usualLoggedToday('12:15 AM')), findsNothing);

    // A tap on Ramen: it was logged 20 minutes ago, on yesterday's date.
    // The app still asks.
    final count = await phone.mealCount();
    await tester.tap(_row('Ramen'));
    await tester.pumpAndSettle();
    expect(find.text(l.usualAgainTitle), findsOneWidget);
    expect(find.text(l.usualAgainBody('Ramen', '11:55 PM')), findsOneWidget);
    await tester.tap(find.byKey(const Key('usualAgainConfirm')));
    await tester.pumpAndSettle();
    expect(await phone.mealCount(), count + 1);
    final again = await phone.row(await phone.lastMealId());
    expect(again['date'], '2026-10-22');
    expect(again['time'], '12:15 AM');
    expect(again['source'], 'app_repeat');
    // The owner's 620, though the bowl it was copied from says 470.
    expect((await phone.item(await phone.lastMealId()))['estimated_calories'],
        620);
    await dismissSnackBar(tester);

    // Milk at 00:15: nothing like it in the last three hours, no question.
    await tester.tap(_row('Milk'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('usualAgainDialog')), findsNothing);
    expect(await phone.mealCount(), count + 2);
  });

  testWidgets('ninety days back, to the day, across a clock change: day 89 '
      'still teaches and counts, day 90 and day 91 do not; day 29 is around '
      'this time, day 30 is not', (tester) async {
    final l = copyFor(const Locale('en'));
    final phone = await Phone.boot(DateTime(2026, 8, 3, 8, 0));
    addTearDown(phone.shutDown);
    await pumpApp(tester, phone);

    // Read on Monday 2 November 2026 at 23:30, the day after US clocks
    // went back: day 89 before it is 5 August.
    await _teach(tester, phone, DateTime(2026, 8, 3, 8, 0), 'Yogurt', 150, 190);
    await _teach(tester, phone, DateTime(2026, 8, 4, 8, 0), 'Granola', 200, 260);
    await _photo(tester, phone, DateTime(2026, 8, 4, 9, 0), 'Apple', 90);
    await _teach(tester, phone, DateTime(2026, 8, 5, 8, 0), 'Oatmeal', 300, 350);
    await _photo(tester, phone, DateTime(2026, 8, 5, 9, 0), 'Banana', 110);
    await _photo(tester, phone, DateTime(2026, 10, 3, 23, 30), 'Cocoa', 180);
    await _photo(tester, phone, DateTime(2026, 10, 4, 23, 30), 'Tea', 30);
    await _open(tester, phone, DateTime(2026, 11, 1, 9, 0));
    for (final (food, kcal) in [('Apple', 90), ('Banana', 110)]) {
      await _photo(tester, phone, DateTime(2026, 11, 1, 9, 0), food, kcal);
    }
    for (final (food, kcal) in [('Cocoa', 180), ('Tea', 30)]) {
      await _photo(tester, phone, DateTime(2026, 11, 1, 23, 30), food, kcal);
    }

    await _open(tester, phone, DateTime(2026, 11, 2, 23, 30));
    expect(usualWindowStart(phone.now), '2026-08-05');
    final oatmeal = await _photo(tester, phone, phone.now, 'Oatmeal', 300);
    final granola = await _photo(tester, phone, phone.now, 'Granola', 200);
    final yogurt = await _photo(tester, phone, phone.now, 'Yogurt', 150);
    expect(
        find.descendant(
            of: _chip(oatmeal),
            matching: find.text(l.usualItemLine('Oatmeal', '300', '350'))),
        findsOneWidget,
        reason: 'set on day 89');
    expect(_chip(granola), findsNothing, reason: 'set on day 90');
    expect(_chip(yogurt), findsNothing, reason: 'set on day 91');

    // My usual foods the same night.
    await pushFromLog(
        tester, UsualFoodsScreen(usual: phone.usual, now: phone.clock));
    // Banana: 5 August and 1 November, two days of the last 90. Apple:
    // 4 August fell out, one day is not usual.
    expect(
        find.descendant(
            of: _row('Banana'),
            matching: find.text(l.usualRowStats(
                2, shownDay(l, '2026-11-01', phone.now)))),
        findsOneWidget);
    expect(_row('Apple'), findsNothing);
    // Tea at 23:30 on 4 October (day 29) and last night: around this
    // time. Cocoa on 3 October (day 30) and last night: listed, but one
    // night of the last 30 is not "around this time".
    final moreAt = tester.getTopLeft(find.text(l.usualMoreHeader)).dy;
    expect(tester.getTopLeft(_row('Tea')).dy, lessThan(moreAt));
    expect(tester.getTopLeft(_row('Cocoa')).dy, greaterThan(moreAt));
    await goBack(tester);

    // And the other way round. Read on Saturday 20 March 2027 at 00:30,
    // the week after US clocks went forward: day 89 before it is
    // 21 December, and a day of 24 hours too many would let the 20th in.
    await _teach(tester, phone, DateTime(2026, 12, 20, 12, 0), 'Soup', 250, 320);
    await _teach(tester, phone, DateTime(2026, 12, 21, 12, 0), 'Stew', 400, 480);
    await _open(tester, phone, DateTime(2027, 3, 20, 0, 30));
    expect(usualWindowStart(phone.now), '2026-12-21');
    final stew = await _photo(tester, phone, phone.now, 'Stew', 400);
    final soup = await _photo(tester, phone, phone.now, 'Soup', 250);
    expect(
        find.descendant(
            of: _chip(stew),
            matching: find.text(l.usualItemLine('Stew', '400', '480'))),
        findsOneWidget,
        reason: 'set on day 89');
    expect(_chip(soup), findsNothing, reason: 'set on day 90');
  });

  testWidgets('a meal dated tomorrow teaches nothing until tomorrow, and '
      'numbers set while the clock ran two days ahead count once the real '
      'day catches up', (tester) async {
    final l = copyFor(const Locale('en'));
    final phone = await Phone.boot(DateTime(2026, 10, 14, 20, 0));
    addTearDown(phone.shutDown);
    await pumpApp(tester, phone);

    // The owner types in tomorrow's planned lunch tonight, dated the 15th
    // (the editor's date picker allows tomorrow).
    await pushFromLog(
        tester,
        MealEditorScreen(
            dao: phone.dao, now: phone.clock, initialDate: '2026-10-15'));
    await tester.enterText(find.byKey(const Key('editorCalories')), '250');
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('itemName0')), 'Trail mix');
    await tester.pump();
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    final planned = await phone.lastMealId();
    expect((await phone.row(planned))['date'], '2026-10-15');
    expect((await phone.item(planned))['user'], isNotNull);
    expect(find.byKey(ValueKey('meal$planned')), findsNothing,
        reason: 'not one of today\'s meals');

    // Tonight a photo of trail mix gets no offer: the 250 is on a day
    // that has not come.
    final tonight = await _photo(
        tester, phone, DateTime(2026, 10, 14, 20, 30), 'Trail mix', 180);
    expect(_chip(tonight), findsNothing);
    expect((await phone.usual.index()).records, isEmpty);
    expect((await phone.usual.frequentMeals()).isEmpty, isTrue);

    // Tomorrow it does, and the two days make it a usual food.
    await _open(tester, phone, DateTime(2026, 10, 15, 13, 0));
    final next = await _photo(
        tester, phone, DateTime(2026, 10, 15, 13, 0), 'Trail mix', 180);
    expect(
        find.descendant(
            of: _chip(next),
            matching: find.text(l.usualItemLine('Trail mix', '180', '250'))),
        findsOneWidget);
    final list = await phone.usual.frequentMeals();
    expect([...list.around, ...list.more].map((m) => m.key),
        [usualNameKey('Trail mix')]);

    // A muffin photo on the 15th. Then the phone's clock jumps two days
    // ahead (a bad time sync), and the owner fixes that muffin while it
    // does: the mark on it says the 17th, 19:00.
    final muffin = await _photo(
        tester, phone, DateTime(2026, 10, 15, 16, 0), 'Muffin', 300);
    phone.now = DateTime(2026, 10, 17, 19, 0);
    await pushFromLog(
        tester,
        MealEditorScreen(
            dao: phone.dao,
            meal: (await phone.dao.mealSnapshot(muffin))!.meal,
            now: phone.clock));
    await tester.enterText(find.byKey(const Key('itemCal0')), '420');
    await tester.pump();
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    expect(((await phone.item(muffin))['user'] as Map)['at'],
        usualStamp(DateTime(2026, 10, 17, 19, 0)));
    // The clock is corrected, back to the 15th. The mark is from more
    // than a day in the future: it vouches for nothing yet.
    await _open(tester, phone, DateTime(2026, 10, 15, 17, 0));
    final early = await _photo(
        tester, phone, DateTime(2026, 10, 15, 17, 0), 'Muffin', 310);
    expect(_chip(early), findsNothing);
    await _open(tester, phone, DateTime(2026, 10, 16, 18, 59));
    final almost = await _photo(
        tester, phone, DateTime(2026, 10, 16, 18, 59), 'Muffin', 310);
    expect(_chip(almost), findsNothing);
    // From the 16th, 19:00 on it is within a day of now, and counts.
    final later = await _photo(
        tester, phone, DateTime(2026, 10, 16, 19, 0), 'Muffin', 310);
    expect(
        find.descendant(
            of: _chip(later),
            matching: find.text(l.usualItemLine('Muffin', '310', '420'))),
        findsOneWidget);
  });
}
