/// RC 1.6.0: the meal editor and hand-typed meals from before 1.6.0.
///
/// A meal typed by hand in 1.5.0 has no `user` marks; 1.6.0 learns its
/// numbers through _recordOf's path (b): app_manual, NOT corrected, no
/// `user` map. The editor's Save always sets corrected = 1 and writes a
/// mark only on rows whose numbers changed. So the first time the owner
/// opens such a meal and saves it with its numbers as they are (to fix
/// its time, its date, its description, or nothing at all), the meal
/// stops being theirs: the offer on today's photo is gone, although every
/// number on that meal is still the one they typed. The save now writes
/// the mark on those unchanged rows, at the meal's own timestamp.
library;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../e2e/harness.dart';

void main() {
  useInProcessSqlite();

  for (final edit in ['nothing', 'the description']) {
    testWidgets('a hand-typed meal from 1.5.0 saved again with the same '
        'numbers (changing $edit) still teaches them', (tester) async {
      final phone = await Phone.boot(DateTime(2026, 11, 10, 8, 0));
      addTearDown(phone.shutDown);
      // Typed by hand on 1.5.0 two days ago: no marks, not corrected.
      final typedId = await phone.dao.saveMeal(
        Meal(
          id: 0,
          date: '2026-11-08',
          time: '08:00 AM',
          timestamp: '2026-11-08T08:00:00.000',
          source: MealSource.appManual,
          analysis: {
            'is_food': true,
            'meal_description': 'Oatmeal',
            'total_calories': 350,
            'total_protein_g': 12,
            'total_carbs_g': 55,
            'total_fat_g': 8,
            'food_items': [foodItem('Oatmeal', 350, p: 12, c: 55, f: 8)],
          },
        ),
      );
      await pumpApp(tester, phone);
      final id = await phone.photo(aiSays([foodItem('Oatmeal', 300)]));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('usualChip')),
        findsOneWidget,
        reason: 'the typed 350 is offered on today\'s photo',
      );

      // The owner opens the typed meal (from History) and saves it as it is.
      final typed = (await phone.dao.mealSnapshot(typedId))!.meal;
      await pushFromLog(
        tester,
        MealEditorScreen(dao: phone.dao, meal: typed, now: phone.clock),
      );
      if (edit == 'the description') {
        await tester.enterText(
          find.byKey(const Key('editorDescription')),
          'Oats with milk',
        );
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsNothing);
      expect((await phone.item(typedId))['estimated_calories'], 350);
      expect(await phone.corrected(typedId), isTrue);
      expect(
        (await phone.item(typedId))['user'],
        {
          'set': true,
          'at': usualStamp(DateTime.parse('2026-11-08T08:00:00.000')),
          'n': [350, 12, 55, 8],
          'qty': 1,
        },
        reason: 'the numbers it was typed with, at the moment it was typed',
      );

      expect(
        find.byKey(const Key('usualChip')),
        findsOneWidget,
        reason:
            'nothing on the typed meal changed, yet its 350 is no '
            'longer the owner\'s usual number for $id',
      );
    });
  }
}
