// The leftover deduction FLOW (user feature 2026-08-04): pick the meal,
// pick the photo, confirm — and the exact incident that motivated the
// feature (the watcher already logged the leftover photo as a new meal)
// must repair itself in the same confirmation.
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final _photoBytes = Uint8List.fromList([9, 9, 9, 9]);
final _photoMd5 = originalBytesMd5(_photoBytes);

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

Meal _meal(int id, String time, num kcal,
        {String hash = '', String desc = 'Cafeteria tray'}) =>
    Meal(
      id: id,
      date: _today(),
      time: time,
      timestamp: '${_today()}T$time:00',
      source: 'app_watch',
      imageHash: hash,
      analysis: {
        'is_food': true,
        'meal_description': desc,
        'total_calories': kcal,
        'total_protein_g': 40,
        'total_carbs_g': 90,
        'total_fat_g': 40,
        'food_items': [
          {'name': 'Rice (~200 g)', 'estimated_calories': 300},
          {'name': 'Pork (~150 g)', 'estimated_calories': kcal - 300},
        ],
      },
    );

void main() {
  late FakeDao dao;
  late FakeAnalyzer analyzer;
  late FakePicker picker;

  setUp(() {
    dao = FakeDao();
    analyzer = FakeAnalyzer()
      ..nextLeftover = {
        'same_meal': true,
        'confidence': 0.9,
        'leftover_fraction': 0.4,
        'items': [
          {'name': 'Rice (~200 g)', 'left_fraction': 1.0},
          {'name': 'Pork (~150 g)', 'left_fraction': 0.0},
        ],
        'note': 'rice untouched',
      };
    picker = FakePicker()
      ..photos = [IntakePhoto(_photoBytes, 'lp1', 'IMG_L.jpg')];
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: LeftoverScreen(
            services: makeServices(
                dao: dao, analyzer: analyzer, picker: picker))));
    await tester.pumpAndSettle();
  }

  Future<void> runToConfirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('leftoverMeal-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leftoverPhoto-lp1')));
    await tester.pumpAndSettle();
  }

  testWidgets('deducts the uneaten rice and marks the photo ledger',
      (tester) async {
    dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
    await pump(tester);
    await runToConfirm(tester);
    // eaten = pork 665 only → total 665 of 965.
    expect(find.byKey(const Key('leftoverResultLine')), findsOneWidget);
    await tester.tap(find.byKey(const Key('leftoverConfirm')));
    await tester.pumpAndSettle();
    final updated = dao.meals.singleWhere((m) => m.id == 1);
    expect(updated.analysis['total_calories'], 665);
    expect(updated.analysis['leftover']['original']['total_calories'], 965);
    expect(dao.ledger[_photoMd5], IngestionStatus.skipped,
        reason: 'the watcher must never log the leftover photo as food');
  });

  // The photo picker was a grid of unlabeled 'image's to VoiceOver/
  // TalkBack — the leftover flow could not be finished without sight
  // (a11y find 2026-10-08).
  testWidgets('screen reader: each photo cell names its position and shot '
      'time, and that node is the one a double-tap picks', (tester) async {
    final handle = tester.ensureSemantics();
    dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
    await pump(tester);
    await tester.tap(find.byKey(const Key('leftoverMeal-1')));
    await tester.pumpAndSettle();

    // FakePicker dates an undated photo 2026-07-31 00:00.
    final cell = find.semantics.byLabel('Photo 1 of 1, Friday, Jul 31 12:00 AM');
    expect(cell, findsOne);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    tester.semantics.tap(cell);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('leftoverResultLine')), findsOneWidget,
        reason: 'the labeled node carries the tap');
    handle.dispose();
  });

  testWidgets("yesterday's incident: the watcher-logged duplicate is "
      'removed in the same confirmation', (tester) async {
    dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
    dao.put(_meal(2, '13:44', 690,
        hash: _photoMd5, desc: 'Chinese cafeteria meal (mostly eaten)'));
    dao.ledger[_photoMd5] = IngestionStatus.saved;
    await pump(tester);
    await runToConfirm(tester);
    expect(find.byKey(const Key('leftoverDupLine')), findsOneWidget,
        reason: 'the user is told the duplicate goes away too');
    await tester.tap(find.byKey(const Key('leftoverConfirm')));
    await tester.pumpAndSettle();
    expect(dao.meals.where((m) => m.id == 2), isEmpty,
        reason: 'the 690 kcal double-count is gone');
    expect(dao.meals.singleWhere((m) => m.id == 1).analysis['total_calories'],
        665);
  });

  testWidgets('a different-meal verdict warns and cancel changes nothing',
      (tester) async {
    analyzer.nextLeftover = {
      'same_meal': false,
      'leftover_fraction': 0.5,
      'note': 'this looks like a different dish',
    };
    dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
    await pump(tester);
    await runToConfirm(tester);
    expect(find.byKey(const Key('leftoverUseAnyway')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(dao.meals.single.analysis['total_calories'], 965);
    expect(dao.updates, isEmpty);
  });

  testWidgets('no usable model reply is an error, not a mutation',
      (tester) async {
    analyzer.nextLeftover = null;
    dao.put(_meal(1, '13:34', 965));
    await pump(tester);
    await runToConfirm(tester);
    expect(find.text("Couldn't estimate the leftovers from that photo."),
        findsOneWidget);
    expect(dao.updates, isEmpty);
  });

  // Photo access declined (or iOS no longer re-prompting): the picker said
  // 'No recent photos found.' with nothing to tap — indistinguishable from
  // an empty camera roll and a dead end. It must name the real problem
  // and offer the system-settings way back, like AddPhotoScreen does
  // (loop find 2026-10-07).
  Future<void> pumpDenied(WidgetTester tester,
      {Locale? locale, Future<void> Function()? openSystemSettings}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates:
            locale == null ? null : AppLocalizations.localizationsDelegates,
        supportedLocales: locale == null
            ? const [Locale('en', 'US')]
            : AppLocalizations.supportedLocales,
        home: LeftoverScreen(
            services: makeServices(
                dao: dao,
                analyzer: analyzer,
                picker: picker,
                grantPhotoPermission: false,
                openSystemSettings: openSystemSettings))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leftoverMeal-1')));
    await tester.pumpAndSettle();
  }

  testWidgets('denied photo access says so and opens system settings',
      (tester) async {
    var opened = 0;
    dao.put(_meal(1, '13:34', 965));
    await pumpDenied(tester, openSystemSettings: () async => opened++);
    expect(find.byKey(const Key('leftoverPhotoPermissionDenied')),
        findsOneWidget);
    expect(find.text("Bitewise isn't allowed to see your photos."),
        findsOneWidget);
    expect(find.text('No recent photos found.'), findsNothing,
        reason: 'a denial is not an empty camera roll');
    await tester.tap(find.byKey(const Key('leftoverOpenSystemSettings')));
    await tester.pump();
    expect(opened, 1);
    expect(dao.updates, isEmpty);
  });

  testWidgets('denied photo access without a settings hook shows no button',
      (tester) async {
    dao.put(_meal(1, '13:34', 965));
    await pumpDenied(tester);
    expect(find.byKey(const Key('leftoverPhotoPermissionDenied')),
        findsOneWidget);
    expect(find.byKey(const Key('leftoverOpenSystemSettings')), findsNothing);
  });

  testWidgets('zh: the denial and its settings button are Chinese',
      (tester) async {
    final zh = AppLocalizationsZh();
    dao.put(_meal(1, '13:34', 965));
    await pumpDenied(tester,
        locale: const Locale('zh'), openSystemSettings: () async {});
    expect(find.text(zh.photoPermissionDenied), findsOneWidget);
    expect(find.text(zh.openSystemSettings), findsOneWidget);
    expect(find.text(zh.addNoPhotos), findsNothing);
  });
}
