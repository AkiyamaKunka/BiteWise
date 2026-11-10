// Usual foods, end to end: every way a number becomes "yours", and every
// way it does not.
//
// One story across four days. Each way of putting a number on a food is
// taken once through the app's real parts (harness.dart), and the proof is
// what the next photo of that food shows on Today: an offer of the
// owner's number, or none.
//
//   teaches                              teaches nothing
//   ─────────────────────────────────    ─────────────────────────────────
//   a number changed in the editor       a rename alone (and it is an alias
//   a number changed in the describe       only once two meals repeat it)
//     preview                            an unedited describe-preview row
//   a meal typed in by hand              a correction on the Fix screen
//   Use                                  a model reply that claims a mark
//                                        a name given to the model's totals
//                                        Use on a kcal-only record
//                                        a re-log of a meal that was never
//                                          the owner's
//
// Then the whole log is exported and imported onto a second, empty phone:
// the marks and the re-logs arrive, and nothing is trusted there that was
// not trusted here.
import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/data/meals_dao_impl.dart';
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:calorie_tracker/ui/screens/fix_meal_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  useInProcessSqlite();

  testWidgets('four days: what teaches a usual number and what does not, '
      'and the same after export and import onto an empty phone',
      (tester) async {
    final l = copyFor(const Locale('en'));
    final phone = await Phone.boot(DateTime(2026, 10, 5, 8, 0));
    addTearDown(phone.shutDown);

    Future<int> photoLands(Map<String, dynamic> reply) async {
      final id = await phone.photo(reply);
      await tester.pumpAndSettle();
      return id;
    }

    Future<void> at(DateTime when, {bool newDay = false}) async {
      await dismissSnackBar(tester);
      phone.now = when;
      if (newDay) await reopen(tester);
    }

    Finder card(int id) => find.byKey(ValueKey('meal$id'));
    Finder chipOf(int id) => find.descendant(
        of: card(id), matching: find.byKey(const Key('usualChip')));
    String chipLine(int id) => tester
        .widget<Text>(find.descendant(
            of: chipOf(id), matching: find.byKey(const Key('usualChipText'))))
        .data!;
    Future<void> openEditor(int id, String title) async {
      await tester.tap(
          find.descendant(of: card(id), matching: find.text(title)));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsOneWidget);
    }

    Future<void> save() async {
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsNothing);
    }

    /// The Fix screen, from the Log sheet: [sentence] is sent and the
    /// model answers [reply].
    Future<void> fixByChat(String sentence, Map<String, dynamic> reply) async {
      await dismissSnackBar(tester);
      phone.ai.nextText = reply;
      await tester.tap(find.byKey(const Key('addMealFab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('addFixMeal')));
      await tester.pumpAndSettle();
      expect(find.byType(FixMealScreen), findsOneWidget);
      await tester.enterText(find.byKey(const Key('fixMealField')), sentence);
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      // A long reply is a dialog, a short one a snackbar.
      if (find.byType(AlertDialog).evaluate().isNotEmpty) {
        await tester.tap(find.text(l.okButton));
        await tester.pumpAndSettle();
      }
      await dismissSnackBar(tester);
      await goBack(tester);
      expect(find.byType(FixMealScreen), findsNothing);
    }

    /// The editor on a stored meal of another day (as Day detail opens
    /// it), to delete it.
    Future<void> deleteMeal(int id) async {
      final meal = (await phone.dao.mealSnapshot(id))!.meal;
      await pushFromLog(tester,
          MealEditorScreen(dao: phone.dao, meal: meal, now: phone.clock));
      await tester.tap(find.byKey(const Key('deleteMealButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDeleteMeal')));
      await tester.pumpAndSettle();
      expect(await phone.db.query('meals', where: 'id = ?', whereArgs: [id]),
          isEmpty);
    }

    await pumpApp(tester, phone);

    // ═══ Day 1, Monday 5 October ═══════════════════════════════════════

    // 08:00 A breakfast photo: three foods.
    final breakfast = await photoLands(aiSays([
      foodItem('Greek yogurt', 150, p: 15, c: 8, f: 4),
      foodItem('Latte', 150, p: 8, c: 12, f: 6),
      foodItem('Toast', 120, p: 4, c: 22, f: 2),
    ], description: 'Breakfast'));
    await openEditor(breakfast, 'Breakfast');
    // (1) a number changed: the yogurt is 180.
    await tester.enterText(find.byKey(const Key('itemCal0')), '180');
    // (2) a rename with a number: it was an oat milk latte, 190.
    await tester.enterText(find.byKey(const Key('itemName1')), 'Oat milk latte');
    await tester.enterText(find.byKey(const Key('itemCal1')), '190');
    // (3) a rename alone: the toast is sourdough.
    await tester.enterText(find.byKey(const Key('itemName2')), 'Sourdough toast');
    await tester.pump();
    await save();
    final day1Stamp = usualStamp(phone.now);
    expect((await phone.item(breakfast, 0))['user'], {
      'set': true,
      'at': day1Stamp,
      'n': [180, 15, 8, 4],
      'qty': 1,
    });
    expect((await phone.item(breakfast, 1))['user'], {
      'set': true,
      'at': day1Stamp,
      'n': [190, 8, 12, 6],
      'qty': 1,
      'ai_name': 'Latte',
    });
    // The rename alone says whose name it was, and vouches for no number.
    expect((await phone.item(breakfast, 2))['user'],
        {'qty': 1, 'ai_name': 'Toast'});

    // 12:30 Described in words. The model's reply claims marks and a
    // published flag for itself; the preview opens without them. The owner
    // corrects the pho and leaves the spring roll as estimated.
    await at(DateTime(2026, 10, 5, 12, 30));
    phone.ai.nextText = {
      'intent': 'new_meal',
      'analysis': {
        'is_food': true,
        'meal_description': 'Pho lunch',
        'total_calories': 750,
        'total_protein_g': 36,
        'total_carbs_g': 88,
        'total_fat_g': 28,
        'assist': {'status': 'applied', 'chain_key': 'mcdonalds'},
        'food_items': [
          {
            ...foodItem('Beef pho', 600, p: 32, c: 70, f: 20),
            'published': true,
            'user': {
              'set': true,
              'at': '2026-01-01T00:00:00.000Z',
              'n': [600, 32, 70, 20],
              'qty': 1,
            },
          },
          {
            ...foodItem('Spring roll', 150, p: 4, c: 18, f: 8),
            'user': {
              'set': true,
              'at': '2026-01-01T00:00:00.000Z',
              'n': [150, 4, 18, 8],
              'qty': 1,
            },
          },
        ],
      },
    };
    final described =
        await phone.executor.describeMeal('a bowl of beef pho, a spring roll');
    expect(described.ok, isTrue);
    expect(phone.ai.textCalls, 1);
    // The preview, as the describe screen pushes it (that screen reads the
    // device clock; the story hands the editor its own).
    await pushFromLog(
        tester,
        MealEditorScreen(
          dao: phone.dao,
          initialAnalysis: described.analysis,
          newMealSource: MealSource.manualText,
          now: phone.clock,
        ));
    await tester.enterText(find.byKey(const Key('itemCal0')), '650');
    await tester.pump();
    await save();
    final pho = await phone.lastMealId();
    expect((await phone.row(pho))['source'], MealSource.manualText);
    expect((await phone.analysis(pho)).containsKey('assist'), isFalse);
    expect(await phone.item(pho, 0), {
      'name': 'Beef pho',
      'estimated_calories': 650,
      'protein_g': 32,
      'carbs_g': 70,
      'fat_g': 20,
      'user': {
        'set': true,
        'at': usualStamp(phone.now),
        'n': [650, 32, 70, 20],
        'qty': 1,
      },
    });
    expect(await phone.item(pho, 1),
        foodItem('Spring roll', 150, p: 4, c: 18, f: 8),
        reason: "the model's mark is gone, and an unedited row gets none");

    // 13:00 Typed in by hand: a protein shake, every number the owner's.
    await at(DateTime(2026, 10, 5, 13, 0));
    await pushFromLog(
        tester, MealEditorScreen(dao: phone.dao, now: phone.clock));
    await tester.enterText(find.byKey(const Key('editorCalories')), '220');
    await tester.enterText(find.byKey(const Key('editorProtein')), '30');
    await tester.enterText(find.byKey(const Key('editorCarbs')), '10');
    await tester.enterText(find.byKey(const Key('editorFat')), '5');
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('itemName0')), 'Protein shake');
    await tester.pump();
    await save();
    final shake = await phone.lastMealId();
    expect((await phone.row(shake))['source'], MealSource.appManual);
    expect((await phone.row(shake))['corrected'], 0);
    expect((await phone.item(shake))['user'], {
      'set': true,
      'at': usualStamp(phone.now),
      'n': [220, 30, 10, 5],
      'qty': 1,
    });

    // 13:10 Typed in by hand with the calories only: a cold brew, 80.
    await at(DateTime(2026, 10, 5, 13, 10));
    await pushFromLog(
        tester, MealEditorScreen(dao: phone.dao, now: phone.clock));
    await tester.enterText(find.byKey(const Key('editorCalories')), '80');
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('itemName0')), 'Cold brew');
    await tester.pump();
    await save();
    final brew = await phone.lastMealId();
    expect((await phone.item(brew))['user'], {
      'set': true,
      'at': usualStamp(phone.now),
      'n': [80, 0, 0, 0],
      'qty': 1,
    });

    // 19:00 A dinner photo, fixed on the Fix screen. The model rewrites the
    // meal, and even claims a mark; nothing of it is the owner's.
    await at(DateTime(2026, 10, 5, 19, 0));
    final salad = await photoLands(aiSays(
        [foodItem('Chicken salad', 400, p: 35, c: 12, f: 22)],
        description: 'Chicken salad'));
    await fixByChat('the chicken salad was 550', {
      'intent': 'correction',
      'meal_index': await phone.chatIndexOf(salad),
      'reason': 'as you said',
      'analysis': {
        'is_food': true,
        'meal_description': 'Chicken salad',
        'total_calories': 550,
        'total_protein_g': 40,
        'total_carbs_g': 15,
        'total_fat_g': 34,
        'food_items': [
          {
            ...foodItem('Chicken salad', 550, p: 40, c: 15, f: 34),
            'user': {
              'set': true,
              'at': '2026-10-05T23:00:00.000Z',
              'n': [550, 40, 15, 34],
              'qty': 1,
            },
          },
        ],
      },
    });
    expect(phone.ai.textCalls, 2);
    expect(await phone.corrected(salad), isTrue);
    expect(await phone.item(salad),
        foodItem('Chicken salad', 550, p: 40, c: 15, f: 34));

    // 19:30 A bagel photo whose reply claims the owner set its numbers,
    // that a chain published them, and a lookup block. All three go before
    // the meal is stored. The owner then only fixes the description.
    await at(DateTime(2026, 10, 5, 19, 30));
    final bagel = await photoLands({
      ...aiSays([
        {
          ...foodItem('Bagel', 300, p: 10, c: 56, f: 4),
          'published': true,
          'user': {
            'set': true,
            'at': '2026-01-01T00:00:00.000Z',
            'n': [300, 10, 56, 4],
            'qty': 1,
          },
        },
      ], description: 'Bagel'),
      'assist': {'status': 'applied', 'chain_key': 'mcdonalds'},
    });
    expect(await phone.item(bagel), foodItem('Bagel', 300, p: 10, c: 56, f: 4));
    expect((await phone.analysis(bagel)).containsKey('assist'), isFalse);
    await openEditor(bagel, 'Bagel');
    await tester.enterText(
        find.byKey(const Key('editorDescription')), 'Bagel, plain');
    await tester.pump();
    await save();
    expect(await phone.corrected(bagel), isTrue);
    expect(await phone.item(bagel), foodItem('Bagel', 300, p: 10, c: 56, f: 4));

    // 20:00 A smoothie photo the model gives only totals for. The owner
    // adds a row to give it a name. The row starts with the model's
    // totals, and naming it sets no number.
    await at(DateTime(2026, 10, 5, 20, 0));
    final smoothie = await photoLands({
      ...aiSays(const [], description: 'A smoothie'),
      'total_calories': 280,
      'total_protein_g': 6,
      'total_carbs_g': 52,
      'total_fat_g': 4,
    });
    await openEditor(smoothie, 'A smoothie');
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('itemName0')), 'Berry smoothie');
    await tester.pump();
    await save();
    expect(await phone.item(smoothie),
        foodItem('Berry smoothie', 280, p: 6, c: 52, f: 4));
    expect(await phone.corrected(smoothie), isTrue);

    // ═══ Day 2, Tuesday 6 October ══════════════════════════════════════

    // 08:00 Breakfast again, as the model names things.
    await at(DateTime(2026, 10, 6, 8, 0), newDay: true);
    final breakfast2 = await photoLands(aiSays([
      foodItem('Greek yogurt', 140, p: 15, c: 8, f: 4),
      foodItem('Latte', 150, p: 8, c: 12, f: 6),
      foodItem('Sourdough toast', 200, p: 6, c: 36, f: 3),
      foodItem('Toast', 200, p: 6, c: 36, f: 3),
    ], description: 'Breakfast'));
    // One food is offered: the yogurt (a number changed in the editor).
    // Not the latte (one rename is no alias yet), not the toast under
    // either name (a rename alone taught no number).
    expect(chipLine(breakfast2), l.usualItemLine('Greek yogurt', '140', '180'));
    expect(find.byKey(const Key('usualChipReview')), findsNothing);
    await openEditor(breakfast2, 'Breakfast');
    expect(find.byKey(const Key('usualOfferItem0')), findsOneWidget);
    for (final i in [1, 2, 3]) {
      expect(find.byKey(Key('usualOfferItem$i')), findsNothing);
    }
    // The owner renames the latte the same way a second time.
    await tester.enterText(find.byKey(const Key('itemName1')), 'Oat milk latte');
    await tester.enterText(find.byKey(const Key('itemCal1')), '190');
    await tester.pump();
    // The card's buttons wait for the save.
    expect(find.text(l.assistEditFirst), findsWidgets);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('usualUseMine')))
            .onPressed,
        isNull);
    await save();

    // 12:00 Pho and a spring roll. The pho the owner corrected in the
    // preview is offered; the spring roll the model estimated is not.
    await at(DateTime(2026, 10, 6, 12, 0));
    final pho2 = await photoLands(aiSays([
      foodItem('Beef pho', 560, p: 30, c: 60, f: 15),
      foodItem('Spring roll', 200, p: 5, c: 24, f: 10),
    ], description: 'Pho again'));
    expect(chipLine(pho2), l.usualItemLine('Beef pho', '560', '650'));

    // 13:00 The shake typed by hand is offered on its photo.
    await at(DateTime(2026, 10, 6, 13, 0));
    final shake2 = await photoLands(aiSays(
        [foodItem('Protein shake', 160, p: 25, c: 8, f: 3)],
        description: 'Shake'));
    expect(chipLine(shake2), l.usualItemLine('Protein shake', '160', '220'));

    // 14:00 The cold brew: only its calories were ever typed. Use changes
    // the calories, keeps the model's macros, and vouches for nothing.
    await at(DateTime(2026, 10, 6, 14, 0));
    final brew2 = await photoLands(aiSays(
        [foodItem('Cold brew', 45, p: 1, c: 8, f: 1)],
        description: 'Iced coffee'));
    expect(chipLine(brew2), l.usualItemLine('Cold brew', '45', '80'));
    await tester.tap(find.descendant(
        of: chipOf(brew2), matching: find.byKey(const Key('usualChipUse'))));
    await tester.pumpAndSettle();
    expect(find.text(l.usualUsedSnack('45', '80')), findsOneWidget);
    expect(await phone.item(brew2), foodItem('Cold brew', 80, p: 1, c: 8, f: 1),
        reason: 'no mark: the macros are not the owner\'s');
    expect(await phone.corrected(brew2), isTrue);

    // 19:00 Chicken salad again: the Fix screen taught nothing.
    await at(DateTime(2026, 10, 6, 19, 0));
    final salad2 = await photoLands(aiSays(
        [foodItem('Chicken salad', 400, p: 35, c: 12, f: 22)],
        description: 'Chicken salad'));
    expect(chipOf(salad2), findsNothing);

    // 19:30 A bagel again: the mark the model claimed taught nothing,
    // though the owner later edited that meal.
    await at(DateTime(2026, 10, 6, 19, 30));
    final bagel2 = await photoLands(aiSays(
        [foodItem('Bagel', 250, p: 9, c: 48, f: 3)],
        description: 'Bagel'));
    expect(chipOf(bagel2), findsNothing);
    // 20:00 A smoothie again: the row the owner only named taught nothing.
    await at(DateTime(2026, 10, 6, 20, 0));
    final smoothie2 = await photoLands(aiSays(
        [foodItem('Berry smoothie', 200, p: 4, c: 40, f: 2)],
        description: 'A smoothie'));
    expect(chipOf(smoothie2), findsNothing);
    // Of the day's offers, two are still on Today.
    expect(find.byKey(const Key('usualChip')), findsNWidgets(2),
        reason: 'pho and shake (the cold brew was used, breakfast saved)');

    // ═══ Day 3, Wednesday 7 October ════════════════════════════════════

    // 08:00 Latte and yogurt. The latte is now offered under the owner's
    // name for it (the same rename on two meals); two foods mean Review.
    await at(DateTime(2026, 10, 7, 8, 0), newDay: true);
    final breakfast3 = await photoLands(aiSays([
      foodItem('Latte', 150, p: 8, c: 12, f: 6),
      foodItem('Greek yogurt', 140, p: 15, c: 8, f: 4),
    ], description: 'Coffee and yogurt'));
    expect(chipLine(breakfast3), l.usualChipMany(2));
    expect(find.byKey(const Key('usualChipUse')), findsNothing);
    await tester.tap(find.byKey(const Key('usualChipReview')));
    await tester.pumpAndSettle();
    expect(find.byType(MealEditorScreen), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('usualOfferItem0'))).data,
        l.usualItemLine('Latte', '150', '190'));
    expect(find.text(l.usualCardFrom('Oat milk latte', '2026-10-06')),
        findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('usualOfferItem1'))).data,
        l.usualItemLine('Greek yogurt', '140', '180'));
    expect(find.text(l.usualCardFrom('Greek yogurt', '2026-10-05')),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('usualUseMine')));
    await tester.pumpAndSettle();
    expect(find.text(l.usualUsedSnack('290', '370')), findsOneWidget);
    final day3Stamp = usualStamp(phone.now);
    expect(await phone.item(breakfast3, 0), {
      ...foodItem('Latte', 190, p: 8, c: 12, f: 6),
      'user': {
        'set': true,
        'at': day3Stamp,
        'n': [190, 8, 12, 6],
        'qty': 1,
      },
    });
    expect((await phone.item(breakfast3, 1))['user'], {
      'set': true,
      'at': day3Stamp,
      'n': [180, 15, 8, 4],
      'qty': 1,
    });
    expect((await phone.analysis(breakfast3))['total_calories'], 370);
    await dismissSnackBar(tester);
    await goBack(tester);

    // The owner fixes Monday's hand-typed shake by chat: 300. It is now
    // the chat model's rewrite, and teaches nothing.
    await at(DateTime(2026, 10, 7, 12, 0));
    await fixByChat('the protein shake on monday was 300', {
      'intent': 'correction',
      'meal_index': await phone.chatIndexOf(shake),
      'analysis': {
        'is_food': true,
        'meal_description': 'Protein shake',
        'total_calories': 300,
        'total_protein_g': 35,
        'total_carbs_g': 20,
        'total_fat_g': 8,
        'food_items': [foodItem('Protein shake', 300, p: 35, c: 20, f: 8)],
      },
    });
    expect((await phone.row(shake))['source'], MealSource.appManual);
    expect(await phone.corrected(shake), isTrue);
    await at(DateTime(2026, 10, 7, 13, 0));
    final shake3 = await photoLands(aiSays(
        [foodItem('Protein shake', 160, p: 25, c: 8, f: 3)],
        description: 'Shake'));
    expect(chipOf(shake3), findsNothing,
        reason: 'neither the typed 220 nor the chat\'s 300');

    // Monday's hand-typed cold brew is deleted. Tuesday's Use of it left
    // no mark, so nothing is known about cold brew any more.
    await deleteMeal(brew);
    await at(DateTime(2026, 10, 7, 14, 0));
    final brew3 = await photoLands(aiSays(
        [foodItem('Cold brew', 45, p: 1, c: 8, f: 1)],
        description: 'Iced coffee'));
    expect(chipOf(brew3), findsNothing);

    // Monday's breakfast is deleted too: the yogurt's 180 now lives only
    // in this morning's Use.
    await deleteMeal(breakfast);

    // An older build's photos arrive by import: a granola bar on two days
    // whose rows carry a mark no owner set (stored before model marks were
    // stripped), never edited since.
    final old = await openEmptyDatabase();
    addTearDown(old.close);
    for (final date in ['2026-10-06', '2026-10-07']) {
      await SqfliteMealsDao(old).saveMeal(Meal(
        id: 0,
        date: date,
        time: '04:00 PM',
        timestamp: '${date}T16:00:00.000',
        source: MealSource.appWatch,
        imageHash: 'old-$date',
        fileId: 'old-asset-$date',
        analysis: aiSays([
          {
            ...foodItem('Granola bar', 200, p: 4, c: 28, f: 8),
            'user': {
              'set': true,
              'at': '${date}T21:00:00.000Z',
              'n': [200, 4, 28, 8],
              'qty': 1,
            },
          },
        ], description: 'Granola bar'),
      ));
    }
    final imported =
        await phone.dao.importJson(await SqfliteMealsDao(old).exportJson());
    expect(imported.added['meals'], 2);
    signalMealsChanged();
    await tester.pumpAndSettle();

    // ═══ Day 4, Thursday 8 October ═════════════════════════════════════

    // 08:00 Yogurt: offered from Wednesday's Use, the only place left.
    await at(DateTime(2026, 10, 8, 8, 0), newDay: true);
    final yogurt4 = await photoLands(aiSays(
        [foodItem('Greek yogurt', 140, p: 15, c: 8, f: 4)],
        description: 'Yogurt'));
    expect(chipLine(yogurt4), l.usualItemLine('Greek yogurt', '140', '180'));
    await openEditor(yogurt4, 'Yogurt');
    expect(find.text(l.usualCardFrom('Greek yogurt', '2026-10-07')),
        findsOneWidget);
    await goBack(tester);

    // 09:00 My usual foods lists the granola bar (two days). One tap logs
    // it with the numbers it had, and without the mark: the template was
    // never the owner's.
    await at(DateTime(2026, 10, 8, 9, 0));
    await tester.tap(find.byKey(const Key('addMealFab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addUsual')));
    await tester.pumpAndSettle();
    expect(find.byType(UsualFoodsScreen), findsOneWidget);
    final callsBefore = phone.ai.calls;
    await tester.tap(
        find.byKey(ValueKey('usualRow:${usualNameKey('Granola bar')}')));
    await tester.pumpAndSettle();
    expect(find.text(l.usualLoggedSnack('Granola bar', '200')), findsOneWidget);
    expect(phone.ai.calls, callsBefore);
    final bar = await phone.lastMealId();
    expect((await phone.row(bar))['source'], MealSource.appRepeat);
    expect(await phone.item(bar), foodItem('Granola bar', 200, p: 4, c: 28, f: 8));
    await dismissSnackBar(tester);
    await goBack(tester);

    // 16:00 A granola bar photo: no offer. Not from the imported marks,
    // and not from the re-log, whose source alone would be trusted.
    await at(DateTime(2026, 10, 8, 16, 0));
    final bar4 = await photoLands(aiSays(
        [foodItem('Granola bar', 150, p: 3, c: 22, f: 6)],
        description: 'Granola bar'));
    expect(chipOf(bar4), findsNothing);
    expect(find.byKey(const Key('usualChip')), findsOneWidget,
        reason: 'the yogurt, and only the yogurt');

    // What the phone has learned, in all: four foods.
    final learned = await phone.usual.index();
    expect(learned.records.keys.toSet(), {
      usualNameKey('Greek yogurt'),
      usualNameKey('Oat milk latte'),
      usualNameKey('Latte'),
      usualNameKey('Beef pho'),
    });
    // With Monday's breakfast deleted the latte's rename stands on one
    // meal again, so it is no alias any more; Wednesday's Use left the
    // owner's number under the model's own name for it.
    expect(learned.aliases, isEmpty);

    // ═══ A new phone ═══════════════════════════════════════════════════

    // Export, then import onto an empty database.
    final export = await phone.dao.exportJson();
    final rowsHere = await phone.db
        .query('meals', columns: ['date', 'time', 'source', 'corrected', 'analysis'],
            orderBy: 'date, time, analysis');
    await dismissSnackBar(tester);
    final second = await Phone.boot(phone.now);
    addTearDown(second.shutDown);
    final summary = await second.dao.importJson(export);
    expect(summary.added['meals'], rowsHere.length);
    final rowsThere = await second.db
        .query('meals', columns: ['date', 'time', 'source', 'corrected', 'analysis'],
            orderBy: 'date, time, analysis');
    // Every meal arrived as stored, marks and re-log stamps included, and
    // none became "corrected" on the way.
    expect(jsonEncode(rowsThere), jsonEncode(rowsHere));
    expect(
        rowsThere.where((r) => r['source'] == MealSource.appRepeat), hasLength(1));
    final there = await second.usual.index();
    expect(there.records.keys.toSet(), learned.records.keys.toSet());
    expect({
      for (final r in there.records.values) r.key: (r.numbers, r.atRaw),
    }, {
      for (final r in learned.records.values) r.key: (r.numbers, r.atRaw),
    });
    expect(there.aliases, learned.aliases);

    // The second phone, the same afternoon: the yogurt is offered there
    // too, the granola bar and the bagel still are not.
    await pumpApp(tester, second);
    second.now = DateTime(2026, 10, 8, 17, 0);
    final yogurtThere = await second.photo(aiSays(
        [foodItem('Greek yogurt', 140, p: 15, c: 8, f: 4)],
        description: 'Yogurt'));
    final barThere = await second.photo(aiSays(
        [foodItem('Granola bar', 150, p: 3, c: 22, f: 6)],
        description: 'Granola bar'));
    final bagelThere = await second.photo(aiSays(
        [foodItem('Bagel', 250, p: 9, c: 48, f: 3)],
        description: 'Bagel'));
    await tester.pumpAndSettle();
    expect(chipLine(yogurtThere),
        l.usualItemLine('Greek yogurt', '140', '180'));
    expect(chipOf(barThere), findsNothing);
    expect(chipOf(bagelThere), findsNothing);
  });
}
