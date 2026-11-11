/// RC 1.6.0: the Undo snackbar and the meal editor.
///
/// Use on Today's chip shows "Used your usual numbers … Undo" on the app's
/// own messenger, so it stays up over the editor. The owner opens the meal
/// to look at what changed and taps Undo there (inside the 8 s, no screen
/// reader needed). The stored meal went back to the AI numbers, but the
/// editor open on it was never told (the snackbar's onUndone reloaded
/// Today only, the editor did not listen to the meals signal): the form
/// kept showing 350, and its next Save was refused with "This meal was
/// just updated — please review." The same for a Use made in the editor
/// when that editor was closed and the meal reopened.
library;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../e2e/harness.dart';

/// Yesterday the owner set oatmeal to 350; today a photo of oatmeal reads
/// 300, and Today offers 350 on it. The photo meal's id.
Future<int> _offeredOatmeal(WidgetTester tester, Phone phone) async {
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
  phone.now = DateTime(2026, 11, 10, 8, 0);
  await pumpApp(tester, phone);
  final id = await phone.photo(aiSays([foodItem('Oatmeal', 300)]));
  await tester.pumpAndSettle();
  return id;
}

Future<void> _openFromToday(WidgetTester tester, int id) async {
  await tester.tap(find.descendant(
      of: find.byKey(ValueKey('meal$id')), matching: find.text('Oatmeal')));
  await tester.pumpAndSettle();
  expect(find.byType(MealEditorScreen), findsOneWidget);
}

Future<void> _tapSnackUndo(WidgetTester tester) async {
  await tester.tap(find.descendant(
      of: find.byKey(const Key('usualUsedSnack')),
      matching: find.text('Undo')));
  await tester.pumpAndSettle();
}

String _kcalShown(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('itemCal0'))).controller!.text;

bool _conflictShown() =>
    find.byKey(const Key('editorSaveConflict')).evaluate().isNotEmpty;

void main() {
  useInProcessSqlite();

  testWidgets('Use on the chip, open the meal, Undo on the snackbar: the '
      'editor shows the meal as stored, and Save is not refused',
      (tester) async {
    final phone = await Phone.boot(DateTime(2026, 11, 9, 8, 0));
    addTearDown(phone.shutDown);
    final id = await _offeredOatmeal(tester, phone);

    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    expect((await phone.item(id))['estimated_calories'], 350);

    await _openFromToday(tester, id);
    expect(_kcalShown(tester), '350');
    expect(find.byKey(const Key('usualUsedSnack')), findsOneWidget);
    await _tapSnackUndo(tester);
    expect((await phone.item(id))['estimated_calories'], 300,
        reason: 'Undo wrote');
    expect(_kcalShown(tester), '300',
        reason: 'the form shows what Undo put back');

    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    expect(_conflictShown(), isFalse,
        reason: 'nothing was typed: Save writes the meal as it shows it');
    expect(find.byType(MealEditorScreen), findsNothing);
    expect((await phone.item(id))['estimated_calories'], 300);
  });

  testWidgets('typed over before the Undo: Save still gets the conflict '
      'dialog and writes nothing', (tester) async {
    final phone = await Phone.boot(DateTime(2026, 11, 9, 8, 0));
    addTearDown(phone.shutDown);
    final id = await _offeredOatmeal(tester, phone);

    await tester.tap(find.byKey(const Key('usualChipUse')));
    await tester.pumpAndSettle();
    await _openFromToday(tester, id);
    await tester.enterText(find.byKey(const Key('itemCal0')), '360');
    await tester.pump();
    await _tapSnackUndo(tester);
    expect(_kcalShown(tester), '360', reason: 'the typing is not thrown away');

    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    expect(_conflictShown(), isTrue);
    expect((await phone.item(id))['estimated_calories'], 300,
        reason: 'the older copy is never written over the Undo');
    await tester.tap(find.byKey(const Key('editorSaveConflictOk')));
    await tester.pumpAndSettle();
    expect(_kcalShown(tester), '300');
  });

  testWidgets('Use in the editor, editor closed and the meal reopened, Undo '
      'on the snackbar: the reopened editor shows the meal as stored',
      (tester) async {
    final phone = await Phone.boot(DateTime(2026, 11, 9, 8, 0));
    addTearDown(phone.shutDown);
    final id = await _offeredOatmeal(tester, phone);

    await _openFromToday(tester, id);
    await tester.tap(find.byKey(const Key('usualUseMine')));
    await tester.pumpAndSettle();
    expect((await phone.item(id))['estimated_calories'], 350);
    expect(_kcalShown(tester), '350');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _openFromToday(tester, id);
    expect(_kcalShown(tester), '350');

    await _tapSnackUndo(tester);
    expect((await phone.item(id))['estimated_calories'], 300);
    expect(_kcalShown(tester), '300');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    expect(_conflictShown(), isFalse);
  });
}
