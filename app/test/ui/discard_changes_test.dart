// Android push (ui lane, 2026-11-13): a back gesture used to close Edit
// meal and the Body log sheet and drop what had been typed, with no
// question (UX run screenshots 30, 33, 68). Back now asks 'Discard
// changes?' while something is unsaved, and only then: a clean screen
// leaves at once, so iOS keeps its swipe-back there. Save and Delete pop
// as before. System back is driven through the binding, as Android's back
// gesture and button arrive.
import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:calorie_tracker/ui/screens/fix_meal_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/settings/profile_page.dart';
import 'package:calorie_tracker/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Meal _meal() => Meal(
      id: 1,
      date: '2026-07-24',
      time: '01:30 PM',
      timestamp: '2026-07-24T13:30:00.000',
      source: 'app_photo',
      imageHash: 'h1',
      analysis: const {
        'is_food': true,
        'meal_description': 'Chicken salad',
        'total_calories': 450,
        'total_protein_g': 50,
        'total_carbs_g': 12,
        'total_fat_g': 22,
      },
    );

DateTime _clock() => DateTime(2026, 7, 24, 19, 5);

const _open = Key('openScreen');
const _dialog = Key('discardChangesDialog');
const _keep = Key('discardChangesKeep');
const _discard = Key('discardChangesDiscard');

/// [screen] pushed over a home page, so a pop has somewhere to go.
Future<void> _push(WidgetTester tester, Widget screen,
    {ThemeData? theme}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            key: _open,
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => screen)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(_open));
  await tester.pumpAndSettle();
}

/// Android's back gesture or button.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  group('Edit meal', () {
    testWidgets('back with an edit asks; Keep Editing stays with the typing',
        (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await tester.enterText(
          find.byKey(const Key('editorDescription')), 'Chicken salad, no dressing');
      await tester.pump();

      await _systemBack(tester);
      expect(find.byKey(_dialog), findsOneWidget);
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.byKey(_keep));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(MealEditorScreen), findsOneWidget);
      expect(find.text('Chicken salad, no dressing'), findsOneWidget);
      expect(dao.meals.first.analysis['meal_description'], 'Chicken salad',
          reason: 'nothing is saved by asking');
    });

    testWidgets('Discard leaves without saving', (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await tester.enterText(find.byKey(const Key('editorCalories')), '600');
      await tester.pump();

      await _systemBack(tester);
      await tester.tap(find.byKey(_discard));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsNothing);
      expect(find.byKey(_open), findsOneWidget);
      expect(dao.meals.first.analysis['total_calories'], 450);
    });

    testWidgets('the app bar back button asks too', (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await tester.enterText(find.byKey(const Key('editorFat')), '30');
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
    });

    testWidgets('an untouched meal leaves at once', (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(MealEditorScreen), findsNothing);
    });

    testWidgets('typing undone is no change: back leaves at once',
        (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await tester.enterText(find.byKey(const Key('editorCalories')), '451');
      await tester.pump();
      await tester.enterText(find.byKey(const Key('editorCalories')), '450');
      await tester.pump();
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(MealEditorScreen), findsNothing);
    });

    testWidgets('manual entry: typed numbers ask, an empty form does not',
        (tester) async {
      final dao = FakeDao();
      await _push(tester, MealEditorScreen(dao: dao, now: _clock));
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(MealEditorScreen), findsNothing);

      await tester.tap(find.byKey(_open));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('editorCalories')), '320');
      await tester.pump();
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.byKey(_discard));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsNothing);
      expect(dao.meals, isEmpty);
    });

    testWidgets('a picked date counts as a change', (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await tester.tap(find.byKey(const Key('editorDateButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('23'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsOneWidget);
    });

    testWidgets('Save with an edit still closes the editor, no question',
        (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await tester.enterText(find.byKey(const Key('editorCalories')), '520');
      await tester.pump();
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(MealEditorScreen), findsNothing);
      expect(dao.meals.first.analysis['total_calories'], 520);
    });

    testWidgets('Delete still closes the editor, no question',
        (tester) async {
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock));
      await tester.enterText(find.byKey(const Key('editorCalories')), '520');
      await tester.pump();
      await tester.tap(find.byKey(const Key('deleteMealButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDeleteMeal')));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(MealEditorScreen), findsNothing);
      expect(dao.meals, isEmpty);
    });

    // PopScope(canPop: false) switches the iOS edge swipe off. It is held
    // only while something is unsaved, so a clean editor still swipes back.
    testWidgets('iOS: a clean editor still swipes back; an edited one asks '
        'from the back button', (tester) async {
      final ios = ThemeData(platform: TargetPlatform.iOS);
      final dao = FakeDao()..seed(_meal());
      await _push(tester,
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: _clock),
          theme: ios);
      await tester.dragFrom(const Offset(4, 600), const Offset(900, 0));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsNothing,
          reason: 'the swipe-back works on a clean editor');

      await tester.tap(find.byKey(_open));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('editorCalories')), '520');
      await tester.pump();
      await tester.dragFrom(const Offset(4, 600), const Offset(900, 0));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsOneWidget,
          reason: 'a swipe never drops an edit');
      expect(find.byKey(_dialog), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
    });
  });

  group('Fix meals', () {
    testWidgets('a typed request asks; an empty field leaves at once',
        (tester) async {
      final executor = FakeExecutor();
      await _push(tester,
          FixMealScreen(executor: executor, settings: FakeSettings()));
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(FixMealScreen), findsNothing);

      await tester.tap(find.byKey(_open));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'the latte was oat milk');
      await tester.pump();
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.byKey(_keep));
      await tester.pumpAndSettle();
      expect(find.text('the latte was oat milk'), findsOneWidget);

      await _systemBack(tester);
      await tester.tap(find.byKey(_discard));
      await tester.pumpAndSettle();
      expect(find.byType(FixMealScreen), findsNothing);
      expect(executor.handledTexts, isEmpty, reason: 'nothing was sent');
    });

    // The request is on its way: nothing typed is lost by leaving, and the
    // answer can take a server's 20 s. Back leaves, as before the guard.
    testWidgets('while a request is sending, back leaves at once',
        (tester) async {
      final reply = Completer<List<NlReply>>();
      final executor = _SlowExecutor(reply.future);
      await _push(tester,
          FixMealScreen(executor: executor, settings: FakeSettings()));
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'the latte was oat milk');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pump();
      expect(executor.handledTexts, ['the latte was oat milk']);
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(FixMealScreen), findsNothing);
      reply.complete(const [NlReply('✏️ Corrected.', applied: true)]);
      await tester.pumpAndSettle();
    });

    testWidgets('an applied request clears the field: back leaves at once',
        (tester) async {
      final executor = FakeExecutor()
        ..nextReplies = const [NlReply('✏️ Corrected.', applied: true)];
      await _push(tester,
          FixMealScreen(executor: executor, settings: FakeSettings()));
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'the latte was oat milk');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      expect(executor.handledTexts, ['the latte was oat milk']);
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(FixMealScreen), findsNothing);
    });
  });

  group('Body log sheet', () {
    final clock = DateTime(2026, 8, 2, 10);

    Future<T> openSheet<T extends FakeDao>(WidgetTester tester,
        {T? dao}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      dao ??= FakeDao() as T;
      // The app's theme: its sheets show a drag handle.
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.build(Brightness.light, cjk: false),
          home: BodyScreen(dao: dao, clock: () => clock)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('logBodyButton')));
      await tester.pumpAndSettle();
      return dao;
    }

    testWidgets('back with a typed weight asks; Keep keeps it, Discard drops '
        'it', (tester) async {
      final dao = await openSheet(tester);
      await tester.enterText(find.byKey(const Key('bodyWeightField')), '72.5');
      await tester.pump();

      await _systemBack(tester);
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.byKey(_keep));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodySheetSave')), findsOneWidget,
          reason: 'the sheet is still open');
      expect(find.text('72.5'), findsOneWidget);

      await _systemBack(tester);
      await tester.tap(find.byKey(_discard));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodySheetSave')), findsNothing);
      expect(dao.weightsByDate, isEmpty);
    });

    testWidgets('a tap outside the sheet asks too', (tester) async {
      await openSheet(tester);
      await tester.enterText(find.byKey(const Key('bodyWaistField')), '83');
      await tester.pump();
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.byKey(_keep));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodySheetSave')), findsOneWidget);
    });

    // Review 2026-11-13 (HIGH): Material's handle and drag-to-dismiss pop
    // the sheet with Navigator.pop, past the question: 72.5 typed, a fling
    // down, and the sheet was gone with nothing saved.
    Future<void> flingHandle(WidgetTester tester) async {
      final handle = tester.getRect(find.byKey(const Key('sheetDragHandle')));
      await tester.flingFrom(handle.center, const Offset(0, 600), 3000);
      await tester.pumpAndSettle();
    }

    testWidgets('a fling down on the handle asks too', (tester) async {
      final dao = await openSheet(tester);
      await tester.enterText(find.byKey(const Key('bodyWeightField')), '72.5');
      await tester.pump();
      await flingHandle(tester);
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.byKey(_keep));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodySheetSave')), findsOneWidget);
      expect(find.text('72.5'), findsOneWidget);

      await flingHandle(tester);
      await tester.tap(find.byKey(_discard));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodySheetSave')), findsNothing);
      expect(dao.weightsByDate, isEmpty);
    });

    testWidgets('a clean sheet: a fling down on the handle closes it',
        (tester) async {
      await openSheet(tester);
      await flingHandle(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byKey(const Key('bodySheetSave')), findsNothing);
    });

    testWidgets('a short nudge on the handle does nothing', (tester) async {
      await openSheet(tester);
      final handle = tester.getRect(find.byKey(const Key('sheetDragHandle')));
      await tester.dragFrom(handle.center, const Offset(0, 8));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodySheetSave')), findsOneWidget);
    });

    testWidgets("the handle's screen-reader Dismiss asks too", (tester) async {
      final handle = tester.ensureSemantics();
      await openSheet(tester);
      final dismiss = find.semantics.byPredicate((n) =>
          n.label == 'Dismiss' &&
          n.getSemanticsData().hasAction(SemanticsAction.tap));
      expect(dismiss, findsOne);
      await tester.enterText(find.byKey(const Key('bodyHipField')), '95');
      await tester.pump();
      tester.semantics.tap(dismiss);
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      await tester.tap(find.byKey(_discard));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodySheetSave')), findsNothing);

      // Clean: it just closes.
      await tester.tap(find.byKey(const Key('logBodyButton')));
      await tester.pumpAndSettle();
      tester.semantics.tap(dismiss);
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byKey(const Key('bodySheetSave')), findsNothing);
      handle.dispose();
    });

    testWidgets('an untouched sheet closes at once', (tester) async {
      await openSheet(tester);
      await _systemBack(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byKey(const Key('bodySheetSave')), findsNothing);
    });

    testWidgets('Save with a typed weight closes it, no question',
        (tester) async {
      final dao = await openSheet(tester);
      await tester.enterText(find.byKey(const Key('bodyWeightField')), '72.5');
      await tester.tap(find.byKey(const Key('bodySheetSave')));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byKey(const Key('bodySheetSave')), findsNothing);
      expect(dao.weightsByDate['2026-08-02']?.kg, 72.5);
    });
  });

  // The dietary profile is saved as it is typed (settings.update on every
  // change), so there is nothing to discard and back never asks.
  testWidgets('Dietary profile: saved as typed, so back leaves at once',
      (tester) async {
    final settings = FakeSettings();
    await _push(tester, ProfileSettingsPage(settings: settings));
    await tester.enterText(
        find.byKey(const Key('dietaryProfileField')), 'vegetarian');
    await tester.pump();
    await _systemBack(tester);
    expect(find.byKey(_dialog), findsNothing);
    expect(find.byType(ProfileSettingsPage), findsNothing);
    expect(settings.dietaryProfile, 'vegetarian');
  });
}

class _SlowExecutor extends FakeExecutor {
  _SlowExecutor(this._reply);
  final Future<List<NlReply>> _reply;

  @override
  Future<List<NlReply>> handleText(String userText) {
    handledTexts.add(userText);
    return _reply;
  }
}
