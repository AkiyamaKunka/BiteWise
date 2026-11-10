// Editor + day-detail flows: edit an existing meal, add one by hand, delete
// with confirmation. These pin the wiring the pure-logic tests can't see —
// which DAO call each button makes, and that the day list reflects it.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/usual_foods_logic.dart'
    show usualStamp;
import 'package:calorie_tracker/core/restaurant_assist_logic.dart'
    show
        AssistDecision,
        AssistReason,
        acceptAssistSuggestion,
        recordAssistDecision;
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart'
    show LookupRecipient, LookupSupport;
import 'package:calorie_tracker/services/assist/meal_assist.dart'
    show AssistRun, AssistSkip, AssistUserAction;
import 'package:calorie_tracker/services/usual/usual_foods.dart'
    show UsualChoices, UsualFoods, UsualOffer;
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/assist_fixtures.dart';
import 'fakes.dart';

Meal meal({
  int id = 1,
  String date = '2026-07-24',
  String time = '01:30 PM',
  Map<String, dynamic>? analysis,
}) =>
    Meal(
      id: id,
      date: date,
      time: time,
      timestamp: '2026-07-24T13:30:00.000',
      source: 'app_photo',
      imageHash: 'h$id',
      analysis: analysis ??
          {
            'is_food': true,
            'meal_description': 'Chicken salad',
            'total_calories': 450,
            'total_protein_g': 50,
            'total_carbs_g': 12,
            'total_fat_g': 22,
          },
    );

Widget host(Widget child) => MaterialApp(home: child);

/// The editor is a long form; the default 800x600 test surface pushes the
/// item controls below the fold, where taps silently miss.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  DateTime clock() => DateTime(2026, 7, 24, 19, 5);

  testWidgets('editing totals saves through updateMealFields, keeping the id',
      (tester) async {
    final dao = FakeDao()..seed(meal());
    await tester.pumpWidget(host(
        MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock)));

    await tester.enterText(find.byKey(const Key('editorCalories')), '520');
    await tester.enterText(find.byKey(const Key('editorProtein')), '55');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();

    expect(dao.fieldUpdates, hasLength(1));
    final (id, analysis, date, time) = dao.fieldUpdates.single;
    expect(id, 1);
    expect(analysis!['total_calories'], 520);
    expect(analysis['total_protein_g'], 55);
    expect(analysis['total_carbs_g'], 12); // untouched field survives
    expect(analysis['meal_description'], 'Chicken salad');
    expect(date, '2026-07-24');
    expect(time, '01:30 PM');
    expect(dao.saved, isEmpty); // an edit must never insert a second row
  });

  testWidgets('invalid input blocks the save and lists every problem',
      (tester) async {
    final dao = FakeDao()..seed(meal());
    await tester.pumpWidget(host(
        MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock)));

    await tester.enterText(find.byKey(const Key('editorCalories')), 'abc');
    await tester.enterText(find.byKey(const Key('editorFat')), '-3');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pump();

    expect(find.byKey(const Key('editorErrors')), findsOneWidget);
    expect(find.textContaining('Calories must be a number'), findsOneWidget);
    expect(find.textContaining('Fat cannot be negative'), findsOneWidget);
    expect(dao.fieldUpdates, isEmpty);
  });

  testWidgets('adding a meal by hand inserts with source app_manual',
      (tester) async {
    final dao = FakeDao();
    await tester.pumpWidget(host(MealEditorScreen(
        dao: dao, initialDate: '2026-07-20', now: clock)));

    await tester.enterText(
        find.byKey(const Key('editorDescription')), 'Bowl of congee');
    await tester.enterText(find.byKey(const Key('editorCalories')), '320');
    await tester.enterText(find.byKey(const Key('editorCarbs')), '60');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();

    expect(dao.saved, hasLength(1));
    final saved = dao.saved.single;
    expect(saved.source, 'app_manual');
    expect(saved.date, '2026-07-20'); // the day the user came from
    expect(saved.imageHash, ''); // no photo → no ledger identity
    expect(saved.analysis['is_food'], isTrue);
    expect(saved.analysis['total_calories'], 320);
    expect(saved.analysis['meal_description'], 'Bowl of congee');
  });

  testWidgets('logging a photo by hand dates it by the clock where it was '
      'TAKEN, like the automatic pipeline (travel, 2026-10-08)',
      (tester) async {
    // iPhone: capturedAt is the asset's createDateTime — an instant shown in
    // the CURRENT zone. 12:30 CDT on Oct 8 = 17:30Z reads Oct 9 01:30 AM in
    // Shanghai; the EXIF wall clock + offset name the same instant.
    final shot = img.Image(width: 1, height: 1);
    shot.exif.exifIfd['DateTimeOriginal'] = '2026:10:08 12:30:00';
    shot.exif.exifIfd['OffsetTimeOriginal'] = '-05:00';
    final dao = FakeDao();
    await tester.pumpWidget(host(MealEditorScreen(
        dao: dao,
        fromPhoto: IntakePhoto(
            Uint8List.fromList(img.encodeJpg(shot)), 'asset-9', 'IMG_9.HEIC',
            capturedAt: DateTime.fromMillisecondsSinceEpoch(
                DateTime.utc(2026, 10, 8, 17, 30).millisecondsSinceEpoch),
            deliberate: true),
        now: clock)));

    await tester.enterText(
        find.byKey(const Key('editorDescription')), 'Noodles');
    await tester.enterText(find.byKey(const Key('editorCalories')), '600');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();

    final saved = dao.saved.single;
    expect(saved.date, '2026-10-08');
    expect(saved.time, '12:30 PM');
  });

  testWidgets('a hand-typed photo save that lands on a meal already logged '
      'for that photo says so and does not pretend it saved', (tester) async {
    // The add flow's 手动记录 after a refusal, while the background scan (or
    // an import) logged the same photo: the DAO backstop returns the
    // existing meal and writes nothing. The editor must not close as a
    // plain success with the typed numbers silently gone.
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final dao = FakeDao()
      ..seed(Meal(
        id: 7,
        date: '2026-07-24',
        time: '12:00 PM',
        timestamp: '2026-07-24T12:00:00.000',
        source: 'app_watch',
        imageHash: md5.convert(bytes).toString(),
        analysis: const {'is_food': true, 'total_calories': 500},
      ));
    var thumbs = 0;
    Object? popped;
    await tester.pumpWidget(host(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                    builder: (_) => MealEditorScreen(
                        dao: dao,
                        fromPhoto: IntakePhoto(bytes, 'asset-7', 'IMG_7.JPG',
                            deliberate: true),
                        makeThumb: (_) async {
                          thumbs++;
                          return Uint8List.fromList([9]);
                        },
                        now: clock)));
          },
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('editorDescription')), 'Noodles');
    await tester.enterText(find.byKey(const Key('editorCalories')), '321');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();

    expect(
        find.text('This photo was already logged — your numbers were not '
            'saved; open that meal from Today to edit it.'),
        findsOneWidget,
        reason: 'the snackbar survives the pop back to the page below');
    expect(popped, isTrue,
        reason: 'back to Today, where the logged meal is shown');
    expect(dao.saved, isEmpty);
    expect(dao.meals.single.analysis['total_calories'], 500);
    expect(thumbs, 0, reason: 'nothing of this save is written');
  });

  testWidgets('delete asks first, and cancelling changes nothing',
      (tester) async {
    final dao = FakeDao()..seed(meal());
    await tester.pumpWidget(host(
        MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock)));

    await tester.tap(find.byKey(const Key('deleteMealButton')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this meal?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(dao.meals, hasLength(1));

    await tester.tap(find.byKey(const Key('deleteMealButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmDeleteMeal')));
    await tester.pumpAndSettle();
    expect(dao.meals, isEmpty);
  });

  testWidgets('item rows can be added, filled, summed into totals, removed',
      (tester) async {
    useTallSurface(tester);
    final dao = FakeDao();
    await tester.pumpWidget(host(MealEditorScreen(dao: dao, now: clock)));

    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('itemName0')), 'Rice');
    await tester.enterText(find.byKey(const Key('itemCal0')), '200');
    await tester.enterText(find.byKey(const Key('itemCarb0')), '44');

    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('itemName1')), 'Egg');
    await tester.enterText(find.byKey(const Key('itemCal1')), '80');
    await tester.enterText(find.byKey(const Key('itemPro1')), '7');

    // Totals are DERIVED from the items now (user decision 2026-08-06):
    // no button to press — typing the rows already moved them.
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('editorCalories')))
            .controller!
            .text,
        '280');
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('editorProtein')))
            .controller!
            .text,
        '7');

    // Removing the first row must not corrupt the second one's values —
    // AND must move the totals (user-reported 2026-08-06: deleting an
    // item left the meal's calories untouched).
    await tester.tap(find.byKey(const Key('removeItem0')));
    await tester.pump();
    expect(
        tester.widget<TextField>(find.byKey(const Key('itemName0'))).controller!.text,
        'Egg');
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('editorCalories')))
            .controller!
            .text,
        '80',
        reason: 'the deleted 200 kcal row must leave the total');
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('editorCarbs')))
            .controller!
            .text,
        '0',
        reason: "the deleted row's carbs go with it");

    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    final items = dao.saved.single.analysis['food_items'] as List;
    expect(items, hasLength(1));
    expect((items.single as Map)['name'], 'Egg');
  });

  testWidgets('adding the first item row keeps the hand-typed totals',
      (tester) async {
    // Found 2026-10-07: 添加食物 on a meal with no rows re-derived the totals
    // from the one empty row and zeroed what the user had just typed.
    useTallSurface(tester);
    final dao = FakeDao();
    await tester.pumpWidget(host(MealEditorScreen(dao: dao, now: clock)));
    String text(String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

    await tester.enterText(find.byKey(const Key('editorCalories')), '450');
    await tester.enterText(find.byKey(const Key('editorProtein')), '50');
    await tester.enterText(find.byKey(const Key('editorCarbs')), '12');
    await tester.enterText(find.byKey(const Key('editorFat')), '22');

    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    expect(text('editorCalories'), '450');
    expect(text('editorProtein'), '50');
    expect(text('editorCarbs'), '12');
    expect(text('editorFat'), '22');
    // The row now carries the numbers, so the totals legitimately follow it.
    expect(text('itemCal0'), '450');
    expect(text('itemPro0'), '50');
    expect(text('itemCarb0'), '12');
    expect(text('itemFat0'), '22');
    expect(find.byKey(const Key('totalsDerivedHint')), findsOneWidget);

    // Itemizing from here is the usual flow: edit the row, totals follow.
    await tester.enterText(find.byKey(const Key('itemName0')), 'Chicken');
    await tester.enterText(find.byKey(const Key('itemCal0')), '300');
    await tester.pump();
    expect(text('editorCalories'), '300');

    // A second row starts blank — seeding it too would double the totals.
    await tester.tap(find.byKey(const Key('addItemRow')));
    await tester.pump();
    expect(text('itemCal1'), '');
    expect(text('editorCalories'), '300');

    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    final saved = dao.saved.single.analysis;
    expect(saved['total_calories'], 300);
    expect(saved['total_protein_g'], 50);
    final items = saved['food_items'] as List;
    expect(items, hasLength(1), reason: 'the blank second row is dropped');
    expect((items.single as Map)['estimated_calories'], 300);
  });

  testWidgets('day detail lists the day, opens the editor, and reloads',
      (tester) async {
    final dao = FakeDao()
      ..seed(meal(id: 1))
      ..seed(meal(
          id: 2,
          time: '07:15 PM',
          analysis: {
            'is_food': true,
            'meal_description': 'Noodles',
            'total_calories': 700,
          }));
    await tester.pumpWidget(host(
        DayDetailScreen(dao: dao, date: '2026-07-24', now: clock)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dayTotalKcal')), findsOneWidget);
    expect(find.text('~1,150 kcal'), findsOneWidget); // 450 + 700
    expect(find.text('2 meals'), findsOneWidget);
    expect(find.text('Noodles'), findsOneWidget);

    await tester.tap(find.byKey(const Key('mealRow2')));
    await tester.pumpAndSettle();
    expect(find.text('Edit meal'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('editorCalories')), '650');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();

    // Back on the day, totals reflect the edit (450 + 650).
    expect(find.text('~1,100 kcal'), findsOneWidget);
  });

  // Write safety (design R6a): the save is a compare-and-set against the
  // analysis text the form was loaded from.
  group('a meal that changed while the editor was open', () {
    /// A write that lands while the editor is open: a restaurant lookup
    /// applying published numbers (never marks the meal corrected).
    Future<void> landLookup(FakeDao dao, int id, num kcal) async {
      final snap = (await dao.mealSnapshot(id))!;
      expect(
          await dao.applyAssist(id,
              expectedRaw: snap.rawAnalysis,
              analysis: {...snap.meal.analysis, 'total_calories': kcal}),
          isTrue);
    }

    testWidgets('is never overwritten: the save says so, then shows the '
        'meal as it is now', (tester) async {
      final dao = FakeDao()..seed(meal());
      await tester.pumpWidget(host(
          MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock)));
      await tester.pump();

      await landLookup(dao, 1, 610);
      await tester.enterText(find.byKey(const Key('editorCalories')), '520');
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('editorSaveConflict')), findsOneWidget);
      expect(find.text('This meal was just updated — please review.'),
          findsOneWidget);
      expect(dao.fieldUpdates, isEmpty, reason: 'the older copy is not saved');
      expect(dao.byId(1).analysis['total_calories'], 610);
      expect(dao.byId(1).corrected, isFalse);

      await tester.tap(find.byKey(const Key('editorSaveConflictOk')));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsOneWidget,
          reason: 'the editor stays open for a review');
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('editorCalories')))
              .controller!
              .text,
          '610');

      // Edited again on the fresh form, the save lands.
      await tester.enterText(find.byKey(const Key('editorCalories')), '600');
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(dao.fieldUpdates, hasLength(1));
      expect(dao.byId(1).analysis['total_calories'], 600);
      expect(dao.byId(1).corrected, isTrue);
    });

    testWidgets('an older copy from the list is replaced before anything is '
        'typed', (tester) async {
      final dao = FakeDao()..seed(meal());
      final listCopy = dao.meals.first; // what the day list loaded
      await landLookup(dao, 1, 610); // landed before the tap
      await tester.pumpWidget(
          host(MealEditorScreen(dao: dao, meal: listCopy, now: clock)));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('editorCalories')))
              .controller!
              .text,
          '610');

      await tester.enterText(find.byKey(const Key('editorProtein')), '60');
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorSaveConflict')), findsNothing);
      expect(dao.byId(1).analysis['total_calories'], 610);
      expect(dao.byId(1).analysis['total_protein_g'], 60);
    });

    testWidgets('typing over an older copy before the re-read lands is a '
        'conflict, never a silent reload', (tester) async {
      final dao = _SlowSnapshotDao()..seed(meal());
      final listCopy = dao.meals.first;
      await landLookup(dao, 1, 610);
      dao.gate = Completer<void>();
      await tester.pumpWidget(
          host(MealEditorScreen(dao: dao, meal: listCopy, now: clock)));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('editorCalories')), '520');
      dao.gate!.complete();
      await tester.pump();
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('editorCalories')))
              .controller!
              .text,
          '520',
          reason: "the user's typing is not wiped under them");

      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorSaveConflict')), findsOneWidget);
      expect(dao.fieldUpdates, isEmpty);
      expect(dao.byId(1).analysis['total_calories'], 610);
    });

    testWidgets('a meal deleted meanwhile closes the editor after the '
        'notice, writing nothing', (tester) async {
      final dao = FakeDao()..seed(meal());
      await tester.pumpWidget(host(Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MealEditorScreen(
                  dao: dao, meal: dao.meals.first, now: clock))),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await dao.deleteMeal(1);
      await tester.enterText(find.byKey(const Key('editorCalories')), '520');
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorSaveConflict')), findsOneWidget);
      await tester.tap(find.byKey(const Key('editorSaveConflictOk')));
      await tester.pumpAndSettle();
      expect(find.byType(MealEditorScreen), findsNothing);
      expect(dao.meals, isEmpty);
      expect(dao.fieldUpdates, isEmpty);
    });
  });

  testWidgets("a describe preview's assist block and published flags are "
      'not saved (design R6a)', (tester) async {
    useTallSurface(tester);
    final dao = FakeDao();
    await tester.pumpWidget(host(MealEditorScreen(
      dao: dao,
      now: clock,
      newMealSource: MealSource.manualText,
      initialAnalysis: const {
        'is_food': true,
        'meal_description': 'Burrito bowl',
        'total_calories': 1050,
        'assist': {'v': 2, 'status': 'applied', 'chain_key': 'chipotle'},
        'food_items': [
          {'name': 'Burrito bowl', 'estimated_calories': 1050, 'published': true},
        ],
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    final saved = dao.saved.single.analysis;
    expect(saved.containsKey('assist'), isFalse);
    expect((saved['food_items'] as List).single.containsKey('published'),
        isFalse);
  });

  testWidgets("a describe preview's user marks are dropped when it opens; "
      'a number the user changes there is saved as theirs (usual foods T26)',
      (tester) async {
    useTallSurface(tester);
    final dao = FakeDao();
    final forged = {
      'set': true,
      'at': '2026-01-01T00:00:00.000Z',
      'n': [1050, 40, 120, 30],
      'qty': 1,
    };
    await tester.pumpWidget(host(MealEditorScreen(
      dao: dao,
      now: clock,
      newMealSource: MealSource.manualText,
      initialAnalysis: {
        'is_food': true,
        'meal_description': 'Burrito bowl and chips',
        'total_calories': 1250,
        'total_protein_g': 43,
        'total_carbs_g': 145,
        'total_fat_g': 40,
        'assist': {'v': 2, 'status': 'applied', 'chain_key': 'chipotle'},
        'food_items': [
          {
            'name': 'Burrito bowl',
            'estimated_calories': 1050,
            'protein_g': 40,
            'carbs_g': 120,
            'fat_g': 30,
            'published': true,
            'user': forged,
          },
          {
            'name': 'Chips',
            'estimated_calories': 200,
            'protein_g': 3,
            'carbs_g': 25,
            'fat_g': 10,
            'user': {...forged, 'n': [200, 3, 25, 10]},
          },
        ],
      },
    )));
    await tester.pumpAndSettle();
    // Shown as the model wrote the numbers.
    expect(
      tester.widget<TextField>(find.byKey(const Key('itemCal0'))).controller!
          .text,
      '1050',
    );
    await tester.enterText(find.byKey(const Key('itemCal1')), '250');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();

    final saved = dao.saved.single.analysis;
    expect(saved.containsKey('assist'), isFalse);
    final items = [
      for (final e in saved['food_items'] as List) e as Map<String, dynamic>,
    ];
    // Untouched: no mark (the model's was not the user's), no flag.
    expect(items[0].containsKey('user'), isFalse);
    expect(items[0].containsKey('published'), isFalse);
    expect(items[0]['estimated_calories'], 1050);
    // Changed here: the user's numbers, stamped with the editor's clock.
    final user = items[1]['user'] as Map;
    expect(user['set'], isTrue);
    expect(user['n'], [250, 3, 25, 10]);
    expect(user['at'], usualStamp(clock()));
    expect(user['qty'], 1);
    expect(saved['total_calories'], 1300);
  });

  testWidgets('a hand-typed meal\'s rows are saved as the user\'s numbers, '
      'and an edit of a stored meal stamps the editor\'s clock', (tester) async {
    useTallSurface(tester);
    final dao = FakeDao()
      ..seed(meal(analysis: {
        'is_food': true,
        'meal_description': 'Oatmeal',
        'total_calories': 300,
        'total_protein_g': 10,
        'total_carbs_g': 50,
        'total_fat_g': 6,
        'food_items': [
          {
            'name': 'Oatmeal (~250 g)',
            'estimated_calories': 300,
            'protein_g': 10,
            'carbs_g': 50,
            'fat_g': 6,
          },
        ],
      }));
    await tester.pumpWidget(host(
        MealEditorScreen(dao: dao, meal: dao.meals.first, now: clock)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('itemCal0')), '350');
    await tester.tap(find.byKey(const Key('saveMealButton')));
    await tester.pumpAndSettle();
    final (_, analysis, _, _) = dao.fieldUpdates.single;
    final user = (analysis!['food_items'] as List).single['user'] as Map;
    expect(user['set'], isTrue);
    expect(user['n'], [350, 10, 50, 6]);
    expect(user['at'], usualStamp(clock()));
  });

  group('your usual numbers (usual foods T36)', () {
    /// The user's own oatmeal and latte, typed by hand on 2026-07-22, and
    /// today's photo of both (AI 300 and 150).
    Future<(FakeDao, UsualFoods)> open(WidgetTester tester,
        {bool withUsual = true}) async {
      useTallSurface(tester);
      final dao = FakeDao()
        ..seed(foodMeal(
          id: 2,
          date: '2026-07-22',
          source: MealSource.appManual,
          items: [
            foodItem('Oatmeal (~250 g)', 350, p: 12, c: 50, f: 14),
            foodItem('Oat milk latte', 190, p: 4, c: 24, f: 8),
          ],
        ))
        ..seed(foodMeal(
          id: 1,
          date: '2026-07-24',
          description: 'Oatmeal and a latte',
          items: [
            foodItem('Oatmeal (~260 g)', 300, p: 10, c: 45, f: 8),
            foodItem('Oat milk latte', 150, p: 3, c: 18, f: 6),
          ],
        ));
      final usual = await makeUsualFoods(dao, clock: clock);
      await tester.pumpWidget(KeyedSubtree(
        key: UniqueKey(),
        child: host(MealEditorScreen(
          dao: dao,
          meal: dao.byId(1),
          now: clock,
          usual: withUsual ? usual : null,
        )),
      ));
      await tester.pumpAndSettle();
      return (dao, usual);
    }

    String fieldText(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

    testWidgets('the card names each food, the AI number and yours, and '
        'where yours came from; no checkboxes', (tester) async {
      await open(tester);
      final card = find.byKey(const Key('usualOfferCard'));
      expect(card, findsOneWidget);
      for (final line in [
        'Your usual numbers',
        'Oatmeal: AI 300 → your usual 350 kcal',
        'From your Oatmeal on 2026-07-22.',
        'Oat milk latte: AI 150 → your usual 190 kcal',
        'From your Oat milk latte on 2026-07-22.',
      ]) {
        expect(find.descendant(of: card, matching: find.text(line)),
            findsOneWidget, reason: line);
      }
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      // Above the description, under where the source card goes.
      expect(tester.getRect(card).bottom,
          lessThan(tester.getRect(find.byKey(const Key('editorDescription'))).top));

      // Not offered without the service (Day detail, History: D31).
      await open(tester, withUsual: false);
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
    });

    testWidgets('Use my numbers writes every offered food, shows the meal '
        "totals and the stored meal, and Undo puts the AI's back",
        (tester) async {
      final (dao, _) = await open(tester);
      final stored = dao.rawOf(dao.byId(1));
      await tester.tap(find.byKey(const Key('usualUseMine')));
      await tester.pumpAndSettle();
      final m = dao.byId(1);
      expect(m.corrected, isTrue);
      final items = m.analysis['food_items'] as List;
      expect(
        [for (final i in items) i['estimated_calories']],
        [350, 190],
      );
      expect(items[0]['protein_g'], 12);
      expect(items[1]['fat_g'], 8);
      expect((items[0]['user'] as Map)['set'], isTrue);
      expect(m.analysis['total_calories'], 540);
      expect(dao.rawOf(m), isNot(stored));
      expect(find.text('Used your usual numbers: 450 → 540 kcal'),
          findsOneWidget);
      // The form shows the stored meal (the basis was read again) and the
      // offer is gone: the meal is the user's now.
      expect(fieldText(tester, 'editorCalories'), '540');
      expect(fieldText(tester, 'itemCal0'), '350');
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(
        [
          for (final i in dao.byId(1).analysis['food_items'] as List)
            i['estimated_calories'],
        ],
        [300, 150],
      );
      expect(fieldText(tester, 'editorCalories'), '450');

      // Saving now writes against the newer row: no conflict.
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorSaveConflict')), findsNothing);
    });

    testWidgets('a meal changed under the card: Use writes nothing and says '
        'so', (tester) async {
      final (dao, _) = await open(tester);
      // Another writer (a chat fix) lands between the read and the write.
      dao.beforeCompareAndSet = (id) async {
        await dao.updateMealAnalysisIfUnchanged(id,
            expectedRaw: dao.rawOf(dao.byId(id)),
            analysis: editedFirstItem(dao.byId(id).analysis, 320));
      };
      await tester.tap(find.byKey(const Key('usualUseMine')));
      await tester.pumpAndSettle();
      expect(find.text('This meal was just updated — please review.'),
          findsOneWidget);
      expect(
        (dao.byId(1).analysis['food_items'] as List)[0]['estimated_calories'],
        320,
      );
      expect(fieldText(tester, 'itemCal0'), '320');
    });

    testWidgets('a food offered for its macros alone: the card names the '
        'macros, and the snackbar does not read the same kcal twice',
        (tester) async {
      useTallSurface(tester);
      final dao = FakeDao()
        ..seed(foodMeal(
          id: 2,
          date: '2026-07-22',
          source: MealSource.appManual,
          items: [foodItem('Oatmeal (~250 g)', 350, p: 25, c: 40, f: 10)],
        ))
        ..seed(foodMeal(
          id: 1,
          date: '2026-07-24',
          items: [foodItem('Oatmeal (~260 g)', 350, p: 10, c: 50, f: 14)],
        ));
      final usual = await makeUsualFoods(dao, clock: clock);
      await tester.pumpWidget(host(MealEditorScreen(
          dao: dao, meal: dao.byId(1), now: clock, usual: usual)));
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('usualOfferCard'));
      expect(
        find.descendant(
            of: card,
            matching: find.text('Oatmeal: AI P 10g · C 50g · F 14g → your '
                'usual P 25g · C 40g · F 10g')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('usualUseMine')));
      await tester.pumpAndSettle();
      expect(find.text('Used your usual numbers.'), findsOneWidget);
      expect(
          (dao.byId(1).analysis['food_items'] as List)[0]['protein_g'], 25);
    });

    testWidgets('past midnight, Use my numbers drops the card quietly: no '
        'message, nothing written', (tester) async {
      useTallSurface(tester);
      var now = DateTime(2026, 7, 24, 23, 50);
      final dao = FakeDao()
        ..seed(foodMeal(
          id: 2,
          date: '2026-07-22',
          source: MealSource.appManual,
          items: [foodItem('Oatmeal (~250 g)', 350, p: 12, c: 50, f: 14)],
        ))
        ..seed(foodMeal(
          id: 1,
          date: '2026-07-24',
          items: [foodItem('Oatmeal (~260 g)', 300, p: 10, c: 45, f: 8)],
        ));
      final usual = await makeUsualFoods(dao, clock: () => now);
      await tester.pumpWidget(host(MealEditorScreen(
          dao: dao, meal: dao.byId(1), now: () => now, usual: usual)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualOfferCard')), findsOneWidget);
      // The editor stays open past midnight.
      now = DateTime(2026, 7, 25, 0, 5);
      await tester.tap(find.byKey(const Key('usualUseMine')));
      await tester.pumpAndSettle();
      expect(find.text('This meal was just updated — please review.'),
          findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      expect(dao.updates, isEmpty);
      expect(dao.byId(1).corrected, isFalse);
    });

    testWidgets('Use writes against the stored text the form shows: a meal '
        'changed since, even where the offer did not, writes nothing',
        (tester) async {
      final (dao, _) = await open(tester);
      // Another writer renamed the meal after the form read it; the offered
      // foods and their numbers are the same.
      final at = dao.meals.indexWhere((m) => m.id == 1);
      dao.meals[at] = foodMeal(
        id: 1,
        date: '2026-07-24',
        description: 'Breakfast',
        items: [
          foodItem('Oatmeal (~260 g)', 300, p: 10, c: 45, f: 8),
          foodItem('Oat milk latte', 150, p: 3, c: 18, f: 6),
        ],
      );
      await tester.tap(find.byKey(const Key('usualUseMine')));
      await tester.pumpAndSettle();
      expect(find.text('This meal was just updated — please review.'),
          findsOneWidget);
      expect(dao.updates, isEmpty);
      expect(dao.byId(1).corrected, isFalse);
      expect(fieldText(tester, 'editorDescription'), 'Breakfast');
    });

    testWidgets('a tap that lands before the form shows its typing writes '
        'nothing and says to save first', (tester) async {
      final (dao, _) = await open(tester);
      // The button as it was drawn, before the typing rebuilt it.
      final use = tester
          .widget<FilledButton>(find.byKey(const Key('usualUseMine')))
          .onPressed!;
      await tester.enterText(
          find.byKey(const Key('editorDescription')), 'Big breakfast');
      use();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistEditFirstSnack')), findsOneWidget);
      expect(dao.updates, isEmpty);
      expect(dao.byId(1).corrected, isFalse);
    });

    testWidgets('Keep AI estimate: an offer still on its way does not bring '
        'the card back', (tester) async {
      useTallSurface(tester);
      final dao = FakeDao()
        ..seed(foodMeal(
          id: 2,
          date: '2026-07-22',
          source: MealSource.appManual,
          items: [foodItem('Oatmeal (~250 g)', 350, p: 12, c: 50, f: 14)],
        ))
        ..seed(foodMeal(
          id: 1,
          date: '2026-07-24',
          items: [foodItem('Oatmeal (~260 g)', 300, p: 10, c: 45, f: 8)],
        ));
      SharedPreferences.setMockInitialValues({});
      final usual = _HeldOfferUsual(
          dao, UsualChoices(await SharedPreferences.getInstance(), clock: clock));
      // A lookup the meal changed under: the editor reads the meal again
      // and works the offer out again (held here).
      final assist = FakeAssist(dao)
        ..onLookup = (_, _, _) async => const AssistRun(AssistSkip.casMiss);
      await tester.pumpWidget(host(MealEditorScreen(
        dao: dao,
        meal: dao.byId(1),
        now: clock,
        usual: usual,
        assist: assist.controls(),
        settings: FakeSettings()
          ..restaurantAssist = 'auto'
          ..restaurantAssistConsentAt = DateTime(2026, 7, 20, 8)
          ..restaurantAssistConsentRecipient = 'anthropic',
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualOfferCard')), findsOneWidget);
      usual.hold = true;
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(usual.held, hasLength(1));
      expect(find.byKey(const Key('usualOfferCard')), findsOneWidget);

      await tester.tap(find.byKey(const Key('usualKeepAi')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      usual.held.single.complete(usual.last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      expect(dao.updates, isEmpty);
    });

    testWidgets('Keep AI estimate writes nothing and the card goes',
        (tester) async {
      final (dao, usual) = await open(tester);
      final stored = dao.rawOf(dao.byId(1));
      await tester.tap(find.byKey(const Key('usualKeepAi')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      expect(dao.updates, isEmpty);
      expect(dao.rawOf(dao.byId(1)), stored);
      expect(dao.byId(1).corrected, isFalse);
      expect(await usual.offerFor(dao.byId(1)), isNull,
          reason: 'turned down for this meal');
    });

    testWidgets('unsaved typing: both buttons wait and the card says why',
        (tester) async {
      final (dao, _) = await open(tester);
      await tester.enterText(
          find.byKey(const Key('editorDescription')), 'Big breakfast');
      await tester.pump();
      final card = find.byKey(const Key('usualOfferCard'));
      expect(
        find.descendant(
            of: card,
            matching: find.text('Save your changes first to use these buttons.')),
        findsOneWidget,
      );
      expect(
          tester.widget<FilledButton>(find.byKey(const Key('usualUseMine')))
              .onPressed,
          isNull);
      expect(
          tester.widget<OutlinedButton>(find.byKey(const Key('usualKeepAi')))
              .onPressed,
          isNull);
      await tester.tap(find.byKey(const Key('usualUseMine')));
      await tester.pumpAndSettle();
      expect(dao.updates, isEmpty);
      // Typing it back: the buttons are live again.
      await tester.enterText(
          find.byKey(const Key('editorDescription')), 'Oatmeal and a latte');
      await tester.pump();
      expect(
          tester.widget<FilledButton>(find.byKey(const Key('usualUseMine')))
              .onPressed,
          isNotNull);
    });
  });

  testWidgets('empty day offers the add path', (tester) async {
    final dao = FakeDao();
    await tester.pumpWidget(host(
        DayDetailScreen(dao: dao, date: '2026-07-19', now: clock)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dayEmpty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('addMealToDay')));
    await tester.pumpAndSettle();
    expect(find.text('Add meal'), findsOneWidget);
    // The new meal defaults to the day being viewed, not today.
    expect(find.widgetWithText(OutlinedButton, '2026-07-19'), findsOneWidget);
  });

  testWidgets('the date picker ends TOMORROW by the calendar, also in the '
      'hour next to midnight around a DST change', (tester) async {
    // The last date was now + 24 h. At 00:30 on the day DST ends (a 25-hour
    // day) that is 23:30 the SAME day, so tomorrow could not be picked; at
    // 23:30 on the eve of its start it is the day AFTER tomorrow. Teeth
    // under a US zone; in UTC (CI) these are ordinary days.
    useTallSurface(tester);
    for (final (now, last) in [
      (DateTime(2026, 7, 24, 19, 5), DateTime(2026, 7, 25)),
      (DateTime(2026, 11, 1, 0, 30), DateTime(2026, 11, 2)),
      (DateTime(2027, 3, 13, 23, 30), DateTime(2027, 3, 14)),
    ]) {
      final dao = FakeDao()..seed(meal());
      await tester.pumpWidget(host(MealEditorScreen(
          key: UniqueKey(), dao: dao, meal: dao.meals.first, now: () => now)));
      await tester.tap(find.byKey(const Key('editorDateButton')));
      await tester.pumpAndSettle();
      final picker =
          tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
      expect(picker.lastDate, last, reason: 'opened at $now');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });

  group('the restaurant source card (design R7b)', () {
    FakeSettings assistSettings({String mode = 'auto', bool consent = true}) =>
        FakeSettings()
          ..restaurantAssist = mode
          ..restaurantAssistConsentAt = consent
              ? DateTime(2026, 10, 24, 8)
              : null
          ..restaurantAssistConsentRecipient = consent ? 'anthropic' : null;

    Future<(FakeDao, FakeAssist)> open(
      WidgetTester tester,
      Map<String, dynamic> analysis, {
      FakeSettings? settings,
      Future<bool> Function(Uri url)? openUrl,
      void Function(FakeAssist a)? setUp,
    }) async {
      useTallSurface(tester);
      final dao = FakeDao()..seed(assistMeal(analysis));
      final assist = FakeAssist(dao);
      setUp?.call(assist);
      // A new app each time: a reused State would keep the old meal, and a
      // reused messenger the old snackbars.
      await tester.pumpWidget(
        KeyedSubtree(
          key: UniqueKey(),
          child: host(
            MealEditorScreen(
              dao: dao,
              meal: dao.meals.first,
              now: clock,
              assist: assist.controls(),
              settings: settings ?? assistSettings(),
              openUrl: openUrl,
              assistPollInterval: const Duration(seconds: 1),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (dao, assist);
    }

    String fieldText(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

    testWidgets('applied: Use AI estimate writes the revert against the '
        'stored text, and the form shows the AI estimate', (tester) async {
      final (dao, assist) = await open(tester, appliedBigMac());
      expect(find.byKey(const Key('assistSourceCard')), findsOneWidget);
      expect(find.text('Source: mcdonalds.com'), findsOneWidget);
      expect(fieldText(tester, 'editorCalories'), '590');
      expect(assist.seen, [1], reason: 'opening the meal clears its dot');

      final stored = dao.rawOf(dao.meals.first);
      await tester.tap(find.byKey(const Key('assistUseEstimate')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.useEstimate);
      expect(assist.acts.single.expectedRaw, stored);
      expect(dao.meals.first.analysis['total_calories'], 540);
      expect(dao.meals.first.corrected, isTrue);
      expect(fieldText(tester, 'editorCalories'), '540');
      expect(find.byKey(const Key('assistSourceCard')), findsNothing);
      // Nothing stands any more: the lookup is offered instead.
      expect(find.byKey(const Key('assistLookUp')), findsOneWidget);

      // The form now saves against the newer row, no conflict.
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorSaveConflict')), findsNothing);
    });

    testWidgets('a meal changed meanwhile: the answer says so and shows the '
        'newer meal', (tester) async {
      final (dao, assist) = await open(tester, appliedBigMac());
      dao.meals[0] = assistMeal(
        editedFirstItem(appliedBigMac(), 700)..['total_calories'] = 700,
      );
      await tester.tap(find.byKey(const Key('assistUseEstimate')));
      await tester.pumpAndSettle();
      expect(
        find.text('This meal was just updated — please review.'),
        findsOneWidget,
      );
      expect(fieldText(tester, 'editorCalories'), '700');
      expect(
        find.byKey(const Key('assistUseEstimate')),
        findsNothing,
        reason: 'the newer meal has stale stamps',
      );
      expect(find.byKey(const Key('assistStale')), findsOneWidget);
      expect(dao.meals.first.analysis['total_calories'], 700);
    });

    testWidgets('unsaved typing: the answers wait for a save', (tester) async {
      final (dao, assist) = await open(tester, appliedBigMac());
      await tester.enterText(
        find.byKey(const Key('editorDescription')),
        'Two Big Macs',
      );
      await tester.tap(find.byKey(const Key('assistUseEstimate')));
      await tester.pumpAndSettle();
      expect(assist.acts, isEmpty);
      expect(
        find.text('Save your changes first to use these buttons.'),
        findsWidgets,
      );
      expect(dao.meals.first.analysis['total_calories'], 590);
    });

    testWidgets('Wrong restaurant: reverted, then our chain table, then a '
        'lookup of the chain picked (no location)', (tester) async {
      final (dao, assist) = await open(tester, appliedBigMac());
      await tester.tap(find.byKey(const Key('assistWrongRestaurant')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.wrongRestaurant);
      expect(dao.meals.first.analysis['total_calories'], 540);
      expect(find.text('Which restaurant?'), findsOneWidget);
      expect(find.byKey(const Key('chainPick-mcdonalds')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('chainPickerSearch')),
        'burger king',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chainPick-burger_king')));
      await tester.pumpAndSettle();
      expect(assist.lookups.single.chainKey, 'burger_king');
      expect(assist.lookups.single.useLocation, isFalse);
    });

    testWidgets('Not from a restaurant and Correct say what was kept', (
      tester,
    ) async {
      var (_, assist) = await open(tester, suggestedBigMac());
      expect(find.byKey(const Key('assistCorrect')), findsNothing);
      await tester.tap(find.byKey(const Key('assistNotRestaurant')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.notFromRestaurant);
      expect(find.text('Got it: not from a restaurant.'), findsOneWidget);
      expect(find.byKey(const Key('assistSourceCard')), findsNothing);

      (_, assist) = await open(tester, appliedBigMacAtSpot());
      await tester.tap(find.byKey(const Key('assistCorrect')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.correct);
      expect(
        find.text("Thanks. Chopstats will remember McDonald's here."),
        findsOneWidget,
      );

      // Where the spot cannot be learned, Correct is not offered.
      (_, assist) = await open(
        tester,
        appliedBigMacAtSpot(),
        setUp: (a) => a.canLearn = false,
      );
      expect(find.byKey(const Key('assistCorrect')), findsNothing);

      // Nor where a printed brand named the chain (review 2026-10-25): the
      // numbers fit, but they say nothing about the spot.
      (_, assist) = await open(tester, appliedBigMac());
      expect(find.byKey(const Key('assistUseEstimate')), findsOneWidget);
      expect(find.byKey(const Key('assistCorrect')), findsNothing);
    });

    testWidgets('Use published numbers on a first visit says the spot is '
        'remembered', (tester) async {
      final (dao, assist) = await open(tester, suggestedBigMacAtSpot());
      await tester.tap(find.byKey(const Key('assistUsePublished')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.acceptSuggestion);
      expect(dao.meals.first.analysis['total_calories'], 590);
      expect(
        find.text("Thanks. Chopstats will remember McDonald's here."),
        findsOneWidget,
      );
    });

    // Review 2026-10-25 (device): after an accept the form showed 910 kcal
    // over the OLD macros, and Save wrote them (the items said otherwise).
    testWidgets('after an accept or Use AI estimate the macro totals are '
        'the stored ones, and Save keeps them', (tester) async {
      final (dao, _) = await open(tester, suggestedBigMac());
      expect(fieldText(tester, 'editorProtein'), '24');
      await tester.tap(find.byKey(const Key('assistUsePublished')));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'editorCalories'), '590');
      expect(fieldText(tester, 'editorProtein'), '25');
      expect(fieldText(tester, 'editorCarbs'), '46');
      expect(fieldText(tester, 'editorFat'), '34');

      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      final saved = dao.meals.first.analysis;
      expect(saved['total_calories'], 590);
      expect(saved['total_protein_g'], 25);
      expect(saved['total_carbs_g'], 46);
      expect(saved['total_fat_g'], 34);

      final (dao2, _) = await open(tester, appliedBigMac());
      await tester.tap(find.byKey(const Key('assistUseEstimate')));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'editorCalories'), '540');
      expect(fieldText(tester, 'editorProtein'), '24');
      expect(fieldText(tester, 'editorCarbs'), '44');
      expect(fieldText(tester, 'editorFat'), '30');
      await tester.tap(find.byKey(const Key('saveMealButton')));
      await tester.pumpAndSettle();
      expect(dao2.meals.first.analysis['total_protein_g'], 24);
      expect(dao2.meals.first.analysis['total_fat_g'], 30);
    });

    testWidgets('a shared plate: Use published numbers says why and the new '
        'total, and asks first', (tester) async {
      final (dao, assist) = await open(tester, suggestedSharedBigMac());
      expect(
        find.text(
          'The photo looked shared or partly eaten — the published number '
          'is one whole serving.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('assistUsePublished')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistAcceptConfirm')), findsOneWidget);
      expect(find.text("This meal's total will be 590 kcal."), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(assist.acts, isEmpty);
      expect(dao.meals.first.analysis['total_calories'], 540);

      await tester.tap(find.byKey(const Key('assistUsePublished')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('assistAcceptConfirmOk')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.acceptSuggestion);
      expect(dao.meals.first.analysis['total_calories'], 590);
    });

    testWidgets('an unclear size lists every published size and asks first; '
        'a plain suggestion does not ask', (tester) async {
      var (_, assist) = await open(tester, suggestedFriesSizes());
      expect(
        find.text(
          'Published sizes: Small 230 kcal · Medium 320 kcal · Large 480 kcal',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('assistUsePublished')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistAcceptConfirm')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(assist.acts, isEmpty);

      (_, assist) = await open(tester, suggestedBigMac());
      await tester.tap(find.byKey(const Key('assistUsePublished')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistAcceptConfirm')), findsNothing);
      expect(assist.acts.single.action, AssistUserAction.acceptSuggestion);
    });

    testWidgets('Wrong restaurant with the owner\'s server on http: no chain '
        'picker (a pick could not be sent there)', (tester) async {
      final (_, assist) = await open(
        tester,
        appliedBigMac(),
        setUp: (a) => a.support = const LookupSupport(
          supported: true,
          recipient: LookupRecipient.claudePlan,
          locationAllowed: false,
          recipientHostTag: 'abcd1234',
        ),
      );
      await tester.tap(find.byKey(const Key('assistWrongRestaurant')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.wrongRestaurant);
      expect(find.text('Which restaurant?'), findsNothing);
      expect(assist.lookups, isEmpty);
    });

    testWidgets('Look up while this meal\'s automatic lookup still runs: '
        'asked again, not silently dropped', (tester) async {
      var calls = 0;
      late FakeDao store;
      await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) {
          store = a.dao as FakeDao;
          a.onLookup = (id, useLocation, chainKey) async {
            calls++;
            if (calls == 1) return const AssistRun(AssistSkip.working);
            final m = store.meals.first;
            await store.updateMealAnalysisIfUnchanged(
              id,
              expectedRaw: store.rawOf(m),
              analysis: suggestedBigMac(),
            );
            return const AssistRun(AssistReason.notGrounded, wrote: true);
          };
        },
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byKey(const Key('assistUsePublished')), findsOneWidget);
    });

    testWidgets('Look up: the app leaving the foreground stops the polling '
        '(the sweep collects the job later)', (tester) async {
      final (_, assist) = await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) =>
            a.onLookup = (_, _, _) async => const AssistRun(AssistSkip.pending),
      );
      void go(List<AppLifecycleState> states) {
        for (final state in states) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }

      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pump();
      expect(assist.lookups, hasLength(1));
      go(const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(assist.lookups, hasLength(1), reason: 'no poll in the background');
      expect(find.byKey(const Key('assistLookingUp')), findsNothing);
      go(const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pumpAndSettle();
      expect(
        find.text('Still looking. Open this meal again in a minute.'),
        findsOneWidget,
      );
    });

    testWidgets('a picked chain the owner\'s http server could not be sent '
        'says why', (tester) async {
      await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) => a.onLookup = (_, _, _) async =>
            const AssistRun(AssistSkip.pickNeedsHttps),
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Looking up a restaurant you pick needs https on your server.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Look up: asked again while the server runs it; the '
        'suggestion lands; Use published numbers applies it', (tester) async {
      late FakeDao store;
      var calls = 0;
      final (dao, assist) = await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) {
          store = a.dao as FakeDao;
          a.onLookup = (id, useLocation, chainKey) async {
            calls++;
            if (calls < 3) return const AssistRun(AssistSkip.pending);
            final m = store.meals.first;
            await store.updateMealAnalysisIfUnchanged(
              id,
              expectedRaw: store.rawOf(m),
              analysis: suggestedBigMac(),
            );
            return const AssistRun(AssistReason.notGrounded, wrote: true);
          };
        },
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pump();
      expect(find.byKey(const Key('assistLookingUp')), findsOneWidget);
      expect(find.text('Looking up restaurant nutrition…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(
        assist.lookups.first.useLocation,
        isFalse,
        reason: "'Use photo location' is off in these settings",
      );
      expect(find.byKey(const Key('assistUsePublished')), findsOneWidget);
      expect(find.text('Not confirmed on the source page'), findsOneWidget);

      await tester.tap(find.byKey(const Key('assistUsePublished')));
      await tester.pumpAndSettle();
      expect(assist.acts.single.action, AssistUserAction.acceptSuggestion);
      expect(dao.meals.first.analysis['total_calories'], 590);
      expect(fieldText(tester, 'editorCalories'), '590');
      expect(find.byKey(const Key('assistUseEstimate')), findsOneWidget);
    });

    testWidgets('Look up: still running after four minutes, or nothing to '
        'ask about, says so', (tester) async {
      var (_, assist) = await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) =>
            a.onLookup = (_, _, _) async => const AssistRun(AssistSkip.pending),
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pump();
      // kAssistPollWindow (4 minutes) at the 1 s interval open() sets.
      var waited = 0;
      while (find.byKey(const Key('assistLookingUp')).evaluate().isNotEmpty &&
          waited < 400) {
        await tester.pump(const Duration(seconds: 1));
        waited++;
      }
      await tester.pump();
      expect(
        waited,
        inInclusiveRange(239, 242),
        reason: 'asked for four minutes, then given up',
      );
      expect(
        find.text('Still looking. Open this meal again in a minute.'),
        findsOneWidget,
      );
      expect(assist.lookups.length, 241);
      await tester.pumpAndSettle();

      (_, assist) = await open(tester, bigMacAnalysis(brand: ''));
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'No restaurant chain Chopstats knows was found for this meal.',
        ),
        findsOneWidget,
      );

      (_, assist) = await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) =>
            a.onLookup = (_, _, _) async =>
                const AssistRun(AssistSkip.dailyCap),
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Today's restaurant lookups are used up. Try again tomorrow.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('Look up without a consent for this recipient asks first; '
        'Cancel looks nothing up', (tester) async {
      final (_, assist) = await open(
        tester,
        bigMacAnalysis(),
        settings: assistSettings(consent: false),
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('restaurantConsentSheet')), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantConsentDecline')));
      await tester.pumpAndSettle();
      expect(assist.lookups, isEmpty);
    });

    testWidgets('the source opens as its normalized https address', (
      tester,
    ) async {
      final opened = <Uri>[];
      await open(
        tester,
        appliedBigMac(),
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      );
      await tester.tap(find.byKey(const Key('assistSourceLink')));
      await tester.pumpAndSettle();
      expect(opened, [
        Uri.parse('https://mcdonalds.com/us/en-us/product/big-mac.html'),
      ]);
    });

    testWidgets('Off: no lookup offered; applied numbers can still be undone', (
      tester,
    ) async {
      await open(
        tester,
        bigMacAnalysis(),
        settings: assistSettings(mode: 'off'),
      );
      expect(find.byKey(const Key('editorAssistCard')), findsNothing);
      await open(
        tester,
        appliedBigMac(),
        settings: assistSettings(mode: 'off'),
        setUp: (a) => a.canLearn = false,
      );
      expect(find.byKey(const Key('assistUseEstimate')), findsOneWidget);
      expect(find.byKey(const Key('assistCorrect')), findsNothing);
    });

    testWidgets('an unsupported provider offers no lookup; a text meal none '
        'either', (tester) async {
      await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) => a.support = const LookupSupport.unsupported('gemini'),
      );
      expect(find.byKey(const Key('assistLookUp')), findsNothing);
      useTallSurface(tester);
      final dao = FakeDao()
        ..seed(
          Meal(
            id: 1,
            date: '2026-10-24',
            time: '12:30 PM',
            timestamp: '2026-10-24T12:30:00.000',
            source: MealSource.manualText,
            analysis: bigMacAnalysis(),
          ),
        );
      await tester.pumpWidget(
        host(
          MealEditorScreen(
            key: UniqueKey(),
            dao: dao,
            meal: dao.meals.first,
            now: clock,
            assist: FakeAssist(dao).controls(),
            settings: assistSettings(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistLookUp')), findsNothing);

      // Logged again from My usual foods (usual foods T44): not a photo
      // meal, so never looked up.
      final repeat = FakeDao()
        ..seed(
          Meal(
            id: 1,
            date: '2026-10-24',
            time: '12:30 PM',
            timestamp: '2026-10-24T12:30:00.000',
            source: MealSource.appRepeat,
            analysis: bigMacAnalysis(),
          ),
        );
      await tester.pumpWidget(
        host(
          MealEditorScreen(
            key: UniqueKey(),
            dao: repeat,
            meal: repeat.meals.first,
            now: clock,
            assist: FakeAssist(repeat).controls(),
            settings: assistSettings(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistLookUp')), findsNothing);
      expect(find.byKey(const Key('editorAssistCard')), findsNothing);
    });

    // ── Saved lookup answers (usual foods §2.4, T23) ──

    testWidgets('Search again asks the provider on every poll of its press',
        (tester) async {
      var calls = 0;
      final (dao, assist) = await open(
        tester,
        acceptedSavedBigMac(),
        setUp: (a) => a.onLookup = (_, _, _) async {
          calls++;
          if (calls < 3) return const AssistRun(AssistSkip.pending);
          return AssistRun(
            AssistReason.notGrounded,
            decision: planBigMacDecision(),
          );
        },
      );
      expect(
        find.text('via Claude (server) · saved answer from 2026-03-02'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('assistSearchAgain')), findsOneWidget);
      await tester.tap(find.byKey(const Key('assistSearchAgain')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(assist.lookups, hasLength(3));
      expect(
        assist.lookups.map((l) => l.fresh),
        everyElement(isTrue),
        reason: 'a pending fresh search is never answered by the saved one',
      );
      expect(dao.meals.first.analysis['total_calories'], 590);
    });

    testWidgets('a saved answer found says so (never "used"), and the next '
        'press asks the provider, whatever the button', (tester) async {
      late FakeDao store;
      var calls = 0;
      final (dao, assist) = await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) {
          store = a.dao as FakeDao;
          a.onLookup = (id, _, _) async {
            calls++;
            if (calls == 1) {
              // A Claude Plan answer saved on 2026-03-02: a suggestion.
              final d = planBigMacDecision().withFetchedOn('2026-03-02');
              final m = store.meals.first;
              await store.updateMealAnalysisIfUnchanged(
                id,
                expectedRaw: store.rawOf(m),
                analysis: recordAssistDecision(m.analysis, d)!,
              );
              return AssistRun(
                AssistReason.notGrounded,
                decision: d,
                wrote: true,
                fromCache: true,
              );
            }
            return const AssistRun(AssistSkip.noBrand);
          };
        },
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(assist.lookups.single.fresh, isFalse);
      final notice = find.byKey(const Key('assistFoundSavedSnack'));
      expect(notice, findsOneWidget);
      expect(
        find.text(
          'Found a saved answer from 2026-03-02. Tap Search again for a new '
          'search.',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: notice, matching: find.textContaining('Used')),
        findsNothing,
      );
      // The saved suggestion: Search again, not Look up.
      expect(find.byKey(const Key('assistUsePublished')), findsOneWidget);
      expect(find.byKey(const Key('assistSearchAgain')), findsOneWidget);
      expect(find.byKey(const Key('assistLookUp')), findsNothing);
      expect(dao.meals.first.analysis['total_calories'], 540);

      // Wrong restaurant, then a chain picked: the press right after the
      // saved answer asks the provider.
      await tester.tap(find.byKey(const Key('assistWrongRestaurant')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('chainPickerSearch')),
        'burger king',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chainPick-burger_king')));
      await tester.pumpAndSettle();
      expect(assist.lookups, hasLength(2));
      expect(assist.lookups.last.chainKey, 'burger_king');
      expect(assist.lookups.last.fresh, isTrue);

      // That one came from the provider: the next plain Look up may use a
      // saved answer again.
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(assist.lookups, hasLength(3));
      expect(assist.lookups.last.fresh, isFalse);
    });

    testWidgets('a saved answer the provider then confirms: the press after '
        'a saved answer that wrote nothing is fresh too', (tester) async {
      var calls = 0;
      final (_, assist) = await open(
        tester,
        bigMacAnalysis(),
        setUp: (a) => a.onLookup = (_, _, _) async {
          calls++;
          // First a saved answer that could not be used, then the
          // provider.
          return calls == 1
              ? AssistRun(
                  AssistReason.notGrounded,
                  decision: planBigMacDecision(),
                  fromCache: true,
                )
              : const AssistRun(AssistSkip.noBrand);
        },
      );
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistFoundSavedSnack')), findsNothing);
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(assist.lookups.map((l) => l.fresh), [false, true]);
    });

    testWidgets('a fresh search over published numbers in use that writes '
        'nothing says what it found', (tester) async {
      Future<void> searchAgain(AssistRun answer, String says) async {
        final (dao, assist) = await open(
          tester,
          acceptedSavedBigMac(),
          settings: assistSettings(),
          setUp: (a) => a.onLookup = (_, _, _) async => answer,
        );
        await tester.tap(find.byKey(const Key('assistSearchAgain')));
        await tester.pumpAndSettle();
        expect(assist.lookups.single.fresh, isTrue);
        expect(find.text(says), findsOneWidget, reason: says);
        expect(
          find.text('No published nutrition found — AI estimate kept'),
          findsNothing,
        );
        expect(dao.meals.first.analysis['total_calories'], 590);
        expect(dao.compareMisses, 0);
      }

      const nothing = 'The new search found nothing better. These numbers stay.';
      // No decision at all.
      await searchAgain(const AssistRun(AssistSkip.noBrand), nothing);
      // A search that found no published nutrition.
      final none = decideFixture(
        bigMacAnalysis(),
        {...bigMacFound(), 'status': 'not_published', 'matches': <Object>[]},
        verbatim: false,
        provider: 'claude_plan',
      );
      await searchAgain(
        AssistRun(AssistReason.notPublished, decision: none),
        nothing,
      );
      // The same published numbers (a Claude Plan suggestion of them).
      await searchAgain(
        AssistRun(AssistReason.notGrounded, decision: planBigMacDecision()),
        'The new search found the same numbers.',
      );
      // Other numbers: how to use them.
      await searchAgain(
        AssistRun(
          AssistReason.notGrounded,
          decision: planBigMacDecision(kcal: 610),
        ),
        'The new search found 610 kcal for these items. To use it, tap Use '
        'AI estimate, then look up again.',
      );
      // A search that could not run says why, not "nothing better".
      await searchAgain(
        const AssistRun(AssistSkip.dailyCap),
        "Today's restaurant lookups are used up. Try again tomorrow.",
      );
    });

    testWidgets('a fresh search over a saved suggestion that writes nothing '
        'says the suggestion stays, never "AI estimate kept"',
        (tester) async {
      Future<void> searchAgain(AssistRun answer, String says) async {
        final (dao, assist) = await open(
          tester,
          savedSuggestionBigMac(),
          settings: assistSettings(),
          setUp: (a) => a.onLookup = (_, _, _) async => answer,
        );
        final stored = dao.rawOf(dao.meals.first);
        expect(find.byKey(const Key('assistUsePublished')), findsOneWidget);
        await tester.tap(find.byKey(const Key('assistSearchAgain')));
        await tester.pumpAndSettle();
        expect(assist.lookups.single.fresh, isTrue);
        expect(find.text(says), findsOneWidget, reason: says);
        expect(
          find.text('No published nutrition found — AI estimate kept'),
          findsNothing,
        );
        // The suggestion is still there to take.
        expect(dao.rawOf(dao.meals.first), stored);
        expect(find.byKey(const Key('assistUsePublished')), findsOneWidget);
        expect(dao.meals.first.analysis['total_calories'], 540);
      }

      const nothing = 'The new search found nothing better. These numbers stay.';
      // The provider found no published nutrition (the engine writes
      // nothing over a standing suggestion).
      final none = decideFixture(
        bigMacAnalysis(),
        {...bigMacFound(), 'status': 'not_published', 'matches': <Object>[]},
        verbatim: false,
        provider: 'claude_plan',
      );
      await searchAgain(
        AssistRun(AssistReason.notPublished, decision: none),
        nothing,
      );
      // No decision at all.
      await searchAgain(const AssistRun(AssistSkip.noBrand), nothing);
      // A search that could not run says why.
      await searchAgain(
        const AssistRun(AssistSkip.dailyCap),
        "Today's restaurant lookups are used up. Try again tomorrow.",
      );
    });
  });
}

/// A Claude Plan suggestion decided on a lookup answer saved on
/// [fetchedOn], not taken yet: Use published numbers and Search again on
/// the card.
Map<String, dynamic> savedSuggestionBigMac({String fetchedOn = '2026-03-02'}) {
  final d = planBigMacDecision().withFetchedOn(fetchedOn);
  final suggested = recordAssistDecision(bigMacAnalysis(), d)!;
  assert((suggested['assist'] as Map)['status'] == 'suggested');
  return suggested;
}

/// The owner's server (Claude Plan) answering McDonald's Big Mac at
/// [kcal]: never grounded, so a suggestion at most.
AssistDecision planBigMacDecision({int kcal = 590}) {
  final found = bigMacFound();
  final match = Map<String, dynamic>.from(
    (found['matches'] as List).single as Map,
  );
  final option = Map<String, dynamic>.from(
    (match['options'] as List).single as Map,
  )..['calories'] = kcal;
  match['options'] = [option];
  found['matches'] = [match];
  return decideFixture(
    bigMacAnalysis(),
    found,
    verbatim: false,
    provider: 'claude_plan',
  );
}

/// A Claude Plan suggestion decided on a lookup answer saved on
/// [fetchedOn], which the user then accepted: published numbers in use,
/// with Search again on the card.
Map<String, dynamic> acceptedSavedBigMac({String fetchedOn = '2026-03-02'}) {
  final a = bigMacAnalysis();
  final d = planBigMacDecision().withFetchedOn(fetchedOn);
  final accepted = acceptAssistSuggestion(
    recordAssistDecision(a, d)!,
    now: assistFixtureNow,
  )!;
  assert((accepted['assist'] as Map)['fetched_on'] == fetchedOn);
  return accepted;
}

/// UsualFoods whose offerFor is held, once [hold] is set, until the test
/// completes [held]; [last] is the last offer worked out before.
class _HeldOfferUsual extends UsualFoods {
  _HeldOfferUsual(BaseFakeDao dao, UsualChoices choices)
      : super(
          dao: dao,
          choices: choices,
          mealsChanged: ValueNotifier<int>(0),
          onMealsChanged: () {},
          lookupTakesIt: (_) => false,
          clock: () => DateTime(2026, 7, 24, 19, 5),
        );

  bool hold = false;
  UsualOffer? last;
  final List<Completer<UsualOffer?>> held = [];

  @override
  Future<UsualOffer?> offerFor(Meal meal) async {
    if (!hold) return last = await super.offerFor(meal);
    final c = Completer<UsualOffer?>();
    held.add(c);
    return c.future;
  }
}

/// mealSnapshot waits for [gate] while it is set: the editor's open-time
/// re-read still in flight.
class _SlowSnapshotDao extends FakeDao {
  Completer<void>? gate;

  @override
  Future<MealSnapshot?> mealSnapshot(int mealId) async {
    final g = gate;
    if (g != null) await g.future;
    return super.mealSnapshot(mealId);
  }
}
