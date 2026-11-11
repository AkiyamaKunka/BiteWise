// RC 1.6.0 (gate): the Undo of a usual-numbers Use, tapped after a
// restaurant lookup was applied to the same meal.
//
// A photo meal of two foods. Use writes the owner's usual numbers on the
// oatmeal (item 0). In the editor a lookup then finds McDonald's published
// numbers for the Big Mac (item 1) and the owner takes them: the assist
// block stamps the items and the meal totals it wrote. The Use's Undo is
// still on the snackbar (a screen reader holds it; without one it is up
// for 8 s). Undoing it moved the totals under the lookup's stamp, so the
// lookup could no longer be taken back ("Use AI estimate" gone) and the
// Big Mac kept `published: true` for good, though nobody touched it. The
// Undo now writes nothing and says the meal changed since.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart'
    show assistStampValid;
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  useInProcessSqlite();

  testWidgets('Use, then a lookup applied in the editor, then the Use\'s '
      'Undo: nothing is undone, it says so, and the lookup can still be '
      'taken back', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final phone = await Phone.boot(DateTime(2026, 11, 9, 8, 0));
    addTearDown(phone.shutDown);

    // Yesterday: the owner set 350 on an oatmeal photo.
    await phone.dao.saveMeal(Meal(
      id: 0,
      date: '2026-11-09',
      time: '08:00 AM',
      timestamp: '2026-11-09T08:00:00.000',
      source: MealSource.appPhoto,
      imageHash: 'b' * 32,
      corrected: true,
      analysis: aiSays([
        {
          ...foodItem('Oatmeal', 350, p: 12, c: 55, f: 8),
          'user': {
            'set': true,
            'at': '2026-11-09T08:05:00.000Z',
            'n': [350, 12, 55, 8],
            'qty': 1,
          },
        },
      ]),
    ));
    phone.now = DateTime(2026, 11, 10, 12, 0);
    // Lookups on, "When unsure": a meal eaten at home triggers none, so
    // the usual-numbers chip shows.
    await phone.turnLookupsOn('auto');
    phone.lookups.onSubmit = (request) async {
      final found = bigMacFound();
      ((found['matches'] as List).first as Map)['item_index'] = 1;
      return planAnswer(found);
    };
    await pumpApp(tester, phone);

    final id = await phone.photo(aiSays([
      foodItem('Oatmeal', 300),
      {
        ...foodItem('Big Mac', 540, p: 24, c: 44, f: 30),
        'brand': "McDonald's",
        'qty': 1,
        'unit': 'sandwich',
      },
    ], description: 'Oatmeal and a Big Mac', context: 'home'));
    await tester.pumpAndSettle();

    // Use on the chip: oatmeal 300 → 350.
    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect((await phone.item(id, 0))['estimated_calories'], 350);
    expect(find.byKey(const Key('usualUsedSnack')), findsOneWidget);

    // The editor: Look up restaurant nutrition, then Use published numbers.
    await tester.tap(find.descendant(
        of: find.byKey(ValueKey('meal$id')),
        matching: find.text('Oatmeal and a Big Mac')));
    await tester.pumpAndSettle();
    expect(find.byType(MealEditorScreen), findsOneWidget);
    await tester.tap(find.byKey(const Key('assistLookUp')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('assistUsePublished')));
    await tester.tap(find.byKey(const Key('assistUsePublished')));
    await tester.pumpAndSettle();
    if (find.byKey(const Key('assistAcceptConfirmOk')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('assistAcceptConfirmOk')));
      await tester.pumpAndSettle();
    }
    expect((await phone.item(id, 1))['estimated_calories'], 590);
    final applied = await phone.analysis(id);
    expect(assistStampValid(applied), isTrue);
    expect(find.byKey(const Key('assistUseEstimate')), findsOneWidget);

    // The Use's Undo is still up (a screen reader holds it).
    expect(find.byKey(const Key('usualUsedSnack')), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const Key('usualUsedSnack')),
        matching: find.text('Undo')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('usualUndoStale')), findsOneWidget,
        reason: 'the Undo says the meal changed since');
    final after = await phone.analysis(id);
    expect(after, applied, reason: 'nothing was written');
    expect(assistStampValid(after), isTrue,
        reason: 'the lookup can still be taken back');
    expect(find.byKey(const Key('assistUseEstimate')), findsOneWidget);
  });
}
