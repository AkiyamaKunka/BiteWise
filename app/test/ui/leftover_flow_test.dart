// The leftover deduction FLOW (user feature 2026-08-04): pick the meal,
// pick the photo, confirm — and the exact incident that motivated the
// feature (the watcher already logged the leftover photo as a new meal)
// must repair itself in the same confirmation.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/server_transport.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/analyzer/gemini_analyzer.dart';
import 'package:calorie_tracker/services/photo/photo_hash.dart';
import 'package:calorie_tracker/services/photo/system_photo_picker.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/meal_in_use.dart';
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:calorie_tracker/ui/services.dart'
    show RecentAsset, UiServices;
import 'package:calorie_tracker/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'add_flow_system_picker_test.dart' show FakeSystemPicker;
import 'fakes.dart';

final _photoBytes = Uint8List.fromList([9, 9, 9, 9]);
final _photoMd5 = originalBytesMd5(_photoBytes);

/// Gemini's answer once the free tier's daily requests are used up.
const _dailyQuotaBody =
    '{"error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "message": '
    '"Quota exceeded for quota metric generate_content_free_tier_requests '
    'limit GenerateRequestsPerDayPerProjectPerModel-FreeTier"}}';

class _MemoryKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// The screen's settings, with the quota pause read from [store]: the
/// AppSettings the analyzer arms it on, as the app's own adapter does.
class _PauseFromStore extends FakeSettings {
  _PauseFromStore(this.store);
  final AppSettings store;

  @override
  bool get isQuotaPaused => store.isQuotaPaused;
}

/// A photo the library cannot hand over (too large, or removed meanwhile).
class _UnreadablePicker extends FakePicker {
  @override
  Future<IntakePhoto?> loadOriginal(RecentAsset asset) async {
    loadedOriginals.add(asset.id);
    return null;
  }
}

/// A grid source that counts listings: in production the listing itself
/// asks for library access (di.dart _ShareIntakePicker.recentAssets).
class _ListingPicker extends FakePicker {
  int listings = 0;
  @override
  Future<List<RecentAsset>> recentAssets({int limit = 30}) {
    listings++;
    return super.recentAssets(limit: limit);
  }
}

/// A database whose reads or writes throw (a row an old import stored
/// untyped makes every read of its range throw; disk errors do the same).
class _FailingDao extends FakeDao {
  /// How many meal reads throw before reads work again.
  int failReads = 0;
  int reads = 0;
  bool failDelete = false;

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) async {
    reads++;
    if (failReads > 0) {
      failReads--;
      throw StateError('database is locked');
    }
    return super.mealsBetween(startDate, endDate);
  }

  @override
  Future<void> deleteMeal(int mealId) async {
    if (failDelete) throw StateError('disk I/O error');
    return super.deleteMeal(mealId);
  }
}

/// The model call held open until [gate] completes: the estimate in
/// flight, the analyzing overlay up.
class _HeldAnalyzer extends FakeAnalyzer {
  final gate = Completer<Map<String, dynamic>?>();
  int calls = 0;

  @override
  Future<Map<String, dynamic>?> leftoverIntent(
      Uint8List originalBytes, String originalCompact) {
    calls++;
    lastLeftoverCompact = originalCompact;
    return gate.future;
  }
}

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

  Future<void> pump(WidgetTester tester, {UiServices? services}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: LeftoverScreen(
            services: services ??
                makeServices(dao: dao, analyzer: analyzer, picker: picker))));
    await tester.pumpAndSettle();
  }

  Future<void> runToConfirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('leftoverMeal-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leftoverPhoto-lp1')));
    await tester.pumpAndSettle();
  }

  // Review 1.7.0 (high): the photo step was a fixed Column (the chosen
  // meal, the heading, then an Expanded grid). At accessibility text sizes
  // the first two took all the height, the grid got none and no photo cell
  // was built, so the flow could not be finished.
  for (final (size, scale) in const [
    (Size(320, 568), 53 / 17), // AX5 on an SE (1st gen)
    (Size(375, 667), 2.35), // AX3 on an SE
  ]) {
    testWidgets(
        'at ${scale.toStringAsFixed(2)}x on ${size.width.toInt()} pt the '
        'photo step scrolls to its photos and one can be picked',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      dao.put(_meal(1, '12:30', 900));
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: LeftoverScreen(
            services:
                makeServices(dao: dao, analyzer: analyzer, picker: picker)),
      ));
      await tester.pumpAndSettle();
      final meal = find.byKey(const Key('leftoverMeal-1'));
      await tester.scrollUntilVisible(meal, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(meal);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final photo = find.byKey(const Key('leftoverPhoto-lp1'));
      await tester.scrollUntilVisible(photo, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(photo);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(analyzer.lastLeftoverCompact, isNotNull,
          reason: 'the picked photo went on to the leftover check');
    });
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

  // An unsure automatic leftover verdict leaves the photo 'failed' and
  // tells the user to use Leftovers (B4). Doing so must settle the row,
  // or Photo Coverage keeps listing it as failed and Retry all sends it
  // to the AI again (run-7 review ai-2).
  testWidgets('a photo left failed by an unsure leftover verdict is '
      'settled by the deduction', (tester) async {
    dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
    dao.ledger[_photoMd5] = IngestionStatus.failed;
    await pump(tester);
    await runToConfirm(tester);
    await tester.tap(find.byKey(const Key('leftoverConfirm')));
    await tester.pumpAndSettle();
    expect(dao.meals.single.analysis['total_calories'], 665);
    expect(dao.ledger[_photoMd5], IngestionStatus.skipped);
  });

  testWidgets("a live 'processing' reservation is never stomped",
      (tester) async {
    dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
    dao.ledger[_photoMd5] = IngestionStatus.processing;
    await pump(tester);
    await runToConfirm(tester);
    await tester.tap(find.byKey(const Key('leftoverConfirm')));
    await tester.pumpAndSettle();
    expect(dao.meals.single.analysis['total_calories'], 665);
    expect(dao.ledger[_photoMd5], IngestionStatus.processing);
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

  // The meal-picker rows were bare InkWells: VoiceOver read each as text
  // with a tap action, never as a button (the A11 class), and with a single
  // meal the section header was read as part of the row (review 1.7.1).
  group('screen reader: the meal-picker rows', () {
    testWidgets('each row is a button of its own that picks its meal',
        (tester) async {
      final handle = tester.ensureSemantics();
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      dao.put(_meal(2, '08:10', 420, hash: 'h2', desc: 'Breakfast bowl'));
      await pump(tester);
      for (final (id, name, other) in const [
        (1, 'Cafeteria tray', 'Breakfast bowl'),
        (2, 'Breakfast bowl', 'Cafeteria tray'),
      ]) {
        final row = tester
            .getSemantics(find.byKey(Key('leftoverMeal-$id')))
            .getSemanticsData();
        expect(row.flagsCollection.isButton, isTrue, reason: name);
        expect(row.hasAction(SemanticsAction.tap), isTrue, reason: name);
        expect(row.label, contains(name));
        expect(row.label, contains('kcal'), reason: 'the detail line too');
        expect(row.label, isNot(contains(other)));
      }
      tester.semantics.tap(find.semantics.byLabel(RegExp('^Breakfast bowl')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('leftoverChosenMeal')), findsOneWidget);
      expect(find.text('Breakfast bowl'), findsOneWidget,
          reason: 'the double-tapped row is the meal picked');
      handle.dispose();
    });

    testWidgets('with one meal, the header is not read as part of the row',
        (tester) async {
      final handle = tester.ensureSemantics();
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      await pump(tester);
      final row = tester
          .getSemantics(find.byKey(const Key('leftoverMeal-1')))
          .getSemanticsData();
      expect(row.flagsCollection.isButton, isTrue);
      expect(row.label, contains('Cafeteria tray'));
      expect(row.label, isNot(contains('Which meal was this?')));
      final header = tester
          .getSemantics(find.text('Which meal was this?'))
          .getSemanticsData();
      expect(header.flagsCollection.isHeader, isTrue);
      expect(header.flagsCollection.isButton, isFalse);
      handle.dispose();
    });
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

  // The duplicate line was drawn in the info indigo, which is 4.05:1 on
  // the dark dialog (#2C2C2E), short of the 4.5:1 body text needs; the
  // tokens keep that indigo off raised surfaces (review 1.7.1).
  group('the duplicate line is readable on the dialog', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
    }

    for (final (name, brightness, highContrast) in const [
      ('light', Brightness.light, false),
      ('dark', Brightness.dark, false),
      ('light Increase Contrast', Brightness.light, true),
      ('dark Increase Contrast', Brightness.dark, true),
    ]) {
      testWidgets('$name: 4.5:1 or better', (tester) async {
        dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
        dao.put(_meal(2, '13:44', 690,
            hash: _photoMd5, desc: 'Chinese cafeteria meal (mostly eaten)'));
        dao.ledger[_photoMd5] = IngestionStatus.saved;
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
            theme: AppTheme.build(brightness, highContrast: highContrast),
            home: LeftoverScreen(
                services: makeServices(
                    dao: dao, analyzer: analyzer, picker: picker))));
        await tester.pumpAndSettle();
        await runToConfirm(tester);

        final line = find.byKey(const Key('leftoverDupLine'));
        final fg = tester
            .widget<RichText>(
                find.descendant(of: line, matching: find.byType(RichText)))
            .text
            .style!
            .color!;
        final bg = tester
            .widget<Material>(find
                .descendant(
                    of: find.byType(AlertDialog),
                    matching: find.byType(Material))
                .first)
            .color!;
        expect(bg, AppColors.forBrightness(brightness,
                highContrast: highContrast)
            .elevated, reason: 'measured on the dialog surface');
        expect(contrast(fg, bg), greaterThanOrEqualTo(4.5),
            reason: 'fg $fg on $bg');
      });
    }
  });

  // Write safety (design R6a): the deduction is re-based on the meal as
  // stored when the user confirms, and written compare-and-set.
  group('a meal that changed before the confirm', () {
    /// A restaurant lookup that lands meanwhile: published numbers for the
    /// pork, totals moved by the same delta (no corrected flag).
    Future<void> landLookup(int id) async {
      final snap = (await dao.mealSnapshot(id))!;
      final a = snap.meal.analysis;
      final items = [
        for (final it in a['food_items'] as List) Map<String, dynamic>.from(it),
      ];
      items[1]['estimated_calories'] = 865;
      items[1]['published'] = true;
      expect(
          await dao.applyAssist(id, expectedRaw: snap.rawAnalysis, analysis: {
            ...a,
            'food_items': items,
            'total_calories': 1165,
            'assist': {'v': 2, 'status': 'applied', 'chain_key': 'chipotle'},
          }),
          isTrue);
    }

    testWidgets('deducts from the post-lookup total, with the same fractions',
        (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      await pump(tester);
      await runToConfirm(tester);
      await landLookup(1); // while the confirm dialog is up
      await tester.tap(find.byKey(const Key('leftoverConfirm')));
      await tester.pumpAndSettle();

      final m = dao.byId(1);
      expect(m.analysis['total_calories'], 865,
          reason: 'rice left (1.0), the published pork eaten (0.0 left)');
      expect(m.analysis['leftover']['original']['total_calories'], 1165,
          reason: 'the base is the meal as it was when confirmed');
      expect(m.corrected, isTrue);
      expect(dao.ledger[_photoMd5], IngestionStatus.skipped);
    });

    testWidgets('a write between the re-read and the write gets one '
        're-based retry', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      await pump(tester);
      await runToConfirm(tester);
      var landed = false;
      dao.beforeCompareAndSet = (id) async {
        if (landed) return;
        landed = true;
        await landLookup(id);
      };
      await tester.tap(find.byKey(const Key('leftoverConfirm')));
      await tester.pumpAndSettle();
      expect(dao.compareMisses, 1);
      expect(dao.byId(1).analysis['total_calories'], 865);
      expect(dao.ledger[_photoMd5], IngestionStatus.skipped);
    });

    testWidgets('a second miss deducts nothing and says why', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      await pump(tester);
      await runToConfirm(tester);
      var bump = 0;
      dao.beforeCompareAndSet = (id) async {
        // Something keeps rewriting the meal.
        final snap = (await dao.mealSnapshot(id))!;
        await dao.applyAssist(id,
            expectedRaw: snap.rawAnalysis,
            analysis: {...snap.meal.analysis, 'rewrites': ++bump});
      };
      await tester.tap(find.byKey(const Key('leftoverConfirm')));
      await tester.pumpAndSettle();
      expect(dao.compareMisses, 2);
      expect(
          find.text('That meal changed while the leftovers were being '
              'estimated, so nothing was deducted. Try again.'),
          findsOneWidget);
      expect(dao.byId(1).analysis['total_calories'], 965);
      expect(dao.byId(1).analysis.containsKey('leftover'), isFalse);
      expect(dao.ledger.containsKey(_photoMd5), isFalse,
          reason: 'the photo is not settled for a deduction that never landed');
    });

    testWidgets('a meal deleted before the confirm: the old error, nothing '
        'written', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      await pump(tester);
      await runToConfirm(tester);
      await dao.deleteMeal(1);
      await tester.tap(find.byKey(const Key('leftoverConfirm')));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't estimate the leftovers from that photo."),
          findsOneWidget);
      expect(dao.updates, isEmpty);
      expect(dao.ledger.containsKey(_photoMd5), isFalse);
    });
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
    expect(find.text("Chopstats isn't allowed to see your photos."),
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

  // With no key (or during the quota pause) every estimate fails, and the
  // screen said "Couldn't estimate the leftovers from that photo." — the
  // user went on trying other photos (run 7, B7). It now names the cause
  // before any photo is read.
  group('nothing can be analyzed right now', () {
    Future<void> tapPhoto(WidgetTester tester, FakeSettings settings,
        {Locale? locale}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      dao.put(_meal(1, '13:34', 965));
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
                  settings: settings))));
      await tester.pumpAndSettle();
      await runToConfirm(tester);
    }

    void expectNothingSent() {
      expect(picker.loadedOriginals, isEmpty, reason: 'no photo is read');
      expect(analyzer.lastLeftoverCompact, isNull, reason: 'no AI call');
      expect(dao.updates, isEmpty);
      expect(find.byKey(const Key('leftoverResultLine')), findsNothing);
    }

    testWidgets('no key: says so, reads nothing', (tester) async {
      final en = AppLocalizationsEn();
      await tapPhoto(tester, FakeSettings(apiKey: ''));
      expect(find.text(en.errNoApiKey), findsOneWidget);
      expect(find.text(en.leftoverFailed), findsNothing);
      expectNothingSent();
    });

    testWidgets('own server without address or key names those',
        (tester) async {
      final settings = FakeSettings(apiKey: '')..provider = 'server';
      await tapPhoto(tester, settings);
      expect(find.text(AppLocalizationsEn().errNoServerKey), findsOneWidget);
      expectNothingSent();
    });

    // Review of the privacy lane, finding 2: an own server address the app
    // sends nothing to (not https://) said "couldn't estimate" — before the
    // consent question and the photo read, it now says why.
    for (final (locale, l) in [
      (const Locale('en'), AppLocalizationsEn() as AppLocalizations),
      (const Locale('zh'), AppLocalizationsZh() as AppLocalizations),
    ]) {
      testWidgets('own server not at https:// (${locale.languageCode}): '
          'names it, asks nothing, reads nothing', (tester) async {
        debugRequireHttpsServerOverride = true;
        addTearDown(() => debugRequireHttpsServerOverride = null);
        final settings = FakeSettings(keys: {'server': 'up'})
          ..provider = 'server'
          ..serverBaseUrl = 'http://10.0.0.5'
          ..aiConsent = {};
        await tapPhoto(tester, settings, locale: locale);
        expect(find.text(l.errServerNeedsHttps), findsOneWidget);
        expect(find.text(l.leftoverFailed), findsNothing);
        expect(find.byKey(const Key('aiConsentDialog')), findsNothing);
        expectNothingSent();
      });
    }

    testWidgets('the quota pause: its own line, no "kept and retried"',
        (tester) async {
      final en = AppLocalizationsEn();
      await tapPhoto(tester, FakeSettings()..isQuotaPaused = true);
      expect(find.text(en.leftoverQuotaPaused), findsOneWidget);
      expect(en.leftoverQuotaPaused, isNot(contains('retried')));
      expectNothingSent();
    });

    testWidgets('zh: in Chinese', (tester) async {
      final zh = AppLocalizationsZh();
      await tapPhoto(tester, FakeSettings(apiKey: ''),
          locale: const Locale('zh'));
      expect(find.text(zh.errNoApiKey), findsOneWidget);
      expectNothingSent();
      expect(zh.leftoverQuotaPaused, isNot(contains('自动重试')));
    });

    testWidgets('a working key still goes through', (tester) async {
      await tapPhoto(tester, FakeSettings());
      expect(picker.loadedOriginals, ['lp1']);
      expect(find.byKey(const Key('leftoverResultLine')), findsOneWidget);
    });
  });

  // Every failure said "Couldn't estimate the leftovers from that photo.",
  // and the user went on trying other photos (review 171, C23). The
  // analyzer hands back no reason, but two causes the screen can see.
  group('a failed estimate names the cause the screen can see', () {
    testWidgets("Gemini's daily quota, hit by this very call: the pause on "
        'the first tap', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: _MemoryKeys());
      await store.setGeminiApiKey('test-key');
      var calls = 0;
      final gemini = GeminiAnalyzer(store,
          client: MockClient((_) async {
            calls++;
            return http.Response(_dailyQuotaBody, 429);
          }),
          sleep: (_) async {},
          normalizer: (b) async => b);
      dao.put(_meal(1, '13:34', 965));
      await pump(tester,
          services: UiServices(
              dao: dao,
              analyzer: gemini,
              executor: FakeExecutor(),
              settings: _PauseFromStore(store),
              picker: picker,
              requestPhotoPermission: () async => true));
      await runToConfirm(tester);

      final en = AppLocalizationsEn();
      expect(calls, 1);
      expect(store.isQuotaPaused, isTrue, reason: 'the call armed the pause');
      expect(find.text(en.leftoverQuotaPaused), findsOneWidget);
      expect(find.text(en.leftoverFailed), findsNothing);
      expect(dao.updates, isEmpty);
    });

    testWidgets('a photo that cannot be read says so, as the add flow does',
        (tester) async {
      picker = _UnreadablePicker()
        ..photos = [IntakePhoto(_photoBytes, 'lp1', 'IMG_L.jpg')];
      dao.put(_meal(1, '13:34', 965));
      await pump(tester);
      await runToConfirm(tester);

      final en = AppLocalizationsEn();
      expect(picker.loadedOriginals, ['lp1']);
      expect(find.text(en.addPhotoUnreadable), findsOneWidget);
      expect(find.text(en.leftoverFailed), findsNothing);
      expect(analyzer.lastLeftoverCompact, isNull, reason: 'nothing was sent');
      expect(dao.updates, isEmpty);
    });
  });

  // A read or a write that threw left the screen with no way on: a failed
  // read of the meals was a spinner for good, and a write that failed
  // after the estimate said nothing, its error uncaught (review 171, C26).
  group('a failing database', () {
    testWidgets('a failed meals read shows the error and Retry, and Retry '
        'loads them', (tester) async {
      final failing = _FailingDao()..failReads = 1;
      failing.put(_meal(1, '13:34', 965));
      dao = failing;
      await pump(tester);

      final en = AppLocalizationsEn();
      expect(find.text(en.leftoverLoadFailed), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('leftoverMeal-1')), findsNothing);
      await tester.tap(find.byKey(const Key('leftoverRetry')));
      await tester.pumpAndSettle();
      expect(failing.reads, 2);
      expect(find.text(en.leftoverLoadFailed), findsNothing);
      expect(find.byKey(const Key('leftoverMeal-1')), findsOneWidget);
    });

    testWidgets('a write that fails after the deduction says so, and picking '
        'the photo again finishes it without deducting twice',
        (tester) async {
      final failing = _FailingDao()..failDelete = true;
      failing.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      failing.put(_meal(2, '13:44', 690,
          hash: _photoMd5, desc: 'Chinese cafeteria meal (mostly eaten)'));
      failing.ledger[_photoMd5] = IngestionStatus.saved;
      dao = failing;
      await pump(tester);
      await runToConfirm(tester);
      await tester.tap(find.byKey(const Key('leftoverConfirm')));
      await tester.pumpAndSettle();

      final en = AppLocalizationsEn();
      expect(find.text(en.leftoverSaveFailed), findsOneWidget);
      expect(find.text(en.leftoverApplied), findsNothing);
      expect(failing.byId(1).analysis['total_calories'], 665,
          reason: 'the deduction itself had landed');
      expect(failing.meals.where((m) => m.id == 2), hasLength(1),
          reason: 'the duplicate could not be removed');
      expect(find.byKey(const Key('leftoverPhoto-lp1')), findsOneWidget,
          reason: 'the screen stays for another try');

      failing.failDelete = false;
      await tester.tap(find.byKey(const Key('leftoverPhoto-lp1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('leftoverDupLine')), findsOneWidget);
      await tester.tap(find.byKey(const Key('leftoverConfirm')));
      await tester.pumpAndSettle();
      expect(failing.byId(1).analysis['total_calories'], 665);
      expect(failing.meals.where((m) => m.id == 2), isEmpty);
    });
  });

  // The analyzing overlay was a plain Text over the photo step: silent to
  // a screen reader, and its scrim stopped a finger but not VoiceOver.
  // 'Change' under it let go of the meal's hold mid-estimate and brought
  // back the meal picker; a meal picked there showed as chosen while the
  // confirm deducted the first one (review 171, C30).
  group('while a photo is analyzed', () {
    late MealInUseRegistry registry;
    late _HeldAnalyzer held;

    /// Meal 2 picked, its leftover photo tapped, the model call in flight.
    Future<void> startEstimate(WidgetTester tester) async {
      registry = MealInUseRegistry();
      held = _HeldAnalyzer();
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      dao.put(_meal(2, '12:30', 965, hash: 'h2', desc: 'Beef noodles'));
      await pump(tester,
          services: makeServices(
              dao: dao, analyzer: held, picker: picker, mealInUse: registry));
      await tester.tap(find.byKey(const Key('leftoverMeal-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('leftoverPhoto-lp1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(held.calls, 1, reason: 'the model call is in flight');
      expect(registry.isInUse(2), isTrue);
    }

    /// The estimate comes back for meal 2; its confirm, then Cancel.
    Future<void> finishEstimate(WidgetTester tester) async {
      held.gate.complete(analyzer.nextLeftover);
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Beef noodles')),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }

    testWidgets('a screen reader hears it: the label is a live region',
        (tester) async {
      final handle = tester.ensureSemantics();
      final en = AppLocalizationsEn();
      await startEstimate(tester);
      expect(tester.getSemantics(find.text(en.analyzing)),
          isSemantics(label: en.analyzing, isLiveRegion: true));
      await finishEstimate(tester);
      handle.dispose();
    });

    testWidgets('a screen reader cannot reach the step under it, and gets '
        'it back after', (tester) async {
      final handle = tester.ensureSemantics();
      final en = AppLocalizationsEn();
      await startEstimate(tester);
      expect(find.semantics.byLabel(en.leftoverChangeMeal), findsNothing);
      expect(find.semantics.byLabel(RegExp('^Photo 1 of 1')), findsNothing);
      await finishEstimate(tester);
      expect(find.semantics.byLabel(en.leftoverChangeMeal), findsOne);
      expect(find.semantics.byLabel(RegExp('^Photo 1 of 1')), findsOne);
      handle.dispose();
    },
        variant: TargetPlatformVariant(
            {TargetPlatform.iOS, TargetPlatform.android}));

    testWidgets('Change does nothing until the estimate is done, however it '
        'is pressed', (tester) async {
      await startEstimate(tester);
      // A hardware keyboard or Switch Control presses the button itself,
      // with no hit test for the scrim to stop.
      tester
          .widget<TextButton>(find.byKey(const Key('leftoverChangeMeal')))
          .onPressed!();
      await tester.pump();
      expect(find.byKey(const Key('leftoverChosenMeal')), findsOneWidget);
      expect(registry.isInUse(2), isTrue, reason: 'the meal is still held');
      await finishEstimate(tester);

      await tester.tap(find.byKey(const Key('leftoverChangeMeal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('leftoverMeal-1')), findsOneWidget,
          reason: 'once it is done, Change works again');
      expect(registry.isInUse(2), isFalse);
    });
  });

  // Google Play's photo policy (2026-11): the Play build declares no photo
  // permission at all, so on Android the photo step is the system Photo
  // Picker — after the AI consent, never a library request, never the
  // "isn't allowed" dead end. With full access the grid stays, plus a row
  // that opens the picker.
  group('Android: the system Photo Picker', () {
    late _ListingPicker listing;
    late int permissionRequests;

    setUp(() {
      listing = _ListingPicker()
        ..photos = [IntakePhoto(_photoBytes, 'lp1', 'IMG_L.jpg')];
      permissionRequests = 0;
    });

    SystemPick picked() => SystemPick(SystemPickStatus.ok, photos: [
          IntakePhoto(_photoBytes, '', 'PXL_20261113_124500000.jpg',
              deliberate: true)
        ]);

    Future<void> pumpPicker(WidgetTester tester, FakeSystemPicker system,
        {FakeSettings? settings}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: LeftoverScreen(
              systemPicker: system,
              services: UiServices(
                dao: dao,
                analyzer: analyzer,
                executor: FakeExecutor(),
                settings: settings ?? FakeSettings(),
                picker: listing,
                requestPhotoPermission: () async {
                  permissionRequests++;
                  return false; // the Play build: nothing to grant
                },
                openSystemSettings: () async {},
              ))));
      await tester.pumpAndSettle();
    }

    Future<void> chooseMeal(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('leftoverMeal-1')));
      await tester.pumpAndSettle();
    }

    void expectNoLibraryAsked() {
      expect(permissionRequests, 0, reason: 'services.requestPhotoPermission');
      expect(listing.listings, 0,
          reason: 'the grid listing asks for access in production');
      expect(find.byKey(const Key('leftoverPhotoPermissionDenied')),
          findsNothing);
    }

    testWidgets('with no photo permission at all the deduction works end to '
        'end: the meal opens the picker, and the picked photo is ledgered',
        (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final system = FakeSystemPicker(replies: [picked()]);
      await pumpPicker(tester, system);
      await chooseMeal(tester);

      expect(system.picks, [1], reason: 'one photo, at once');
      expectNoLibraryAsked();
      expect(find.byKey(const Key('leftoverResultLine')), findsOneWidget);
      await tester.tap(find.byKey(const Key('leftoverConfirm')));
      await tester.pumpAndSettle();
      expect(dao.meals.singleWhere((m) => m.id == 1).analysis['total_calories'],
          665);
      expect(dao.ledger[_photoMd5], IngestionStatus.skipped,
          reason: 'the picked photo is known by its md5 like a grid photo: '
              'the watcher must never log it as food');
    });

    testWidgets('the AI consent comes before the picker; Not now opens '
        'nothing, and the button asks again', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final settings = FakeSettings()..aiConsent = {};
      final system = FakeSystemPicker(replies: [picked()]);
      await pumpPicker(tester, system, settings: settings);
      await chooseMeal(tester);
      expect(find.byKey(const Key('aiConsentDialog')), findsOneWidget);
      expect(system.picks, isEmpty);
      await tester.tap(find.byKey(const Key('aiConsentNotNow')));
      await tester.pumpAndSettle();
      expect(system.picks, isEmpty);
      expect(analyzer.lastLeftoverCompact, isNull);

      await tester.tap(find.byKey(const Key('leftoverChooseAllPhotos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('aiConsentAllow')));
      await tester.pumpAndSettle();
      expect(system.picks, [1]);
      expect(analyzer.lastLeftoverCompact, isNotNull);
      expectNoLibraryAsked();
    });

    testWidgets('without a key nothing is picked: it says why', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final system = FakeSystemPicker(replies: [picked()]);
      await pumpPicker(tester, system, settings: FakeSettings(apiKey: ''));
      await chooseMeal(tester);
      expect(system.picks, isEmpty);
      expect(find.text(AppLocalizationsEn().errNoApiKey), findsOneWidget);
    });

    testWidgets('a cancelled pick keeps the photo step; the button and a '
        'newly chosen meal open the picker again', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final system = FakeSystemPicker(); // every pick cancelled
      await pumpPicker(tester, system);
      await chooseMeal(tester);
      expect(system.picks, [1]);
      expect(find.byKey(const Key('leftoverChosenMeal')), findsOneWidget);
      expect(find.byKey(const Key('leftoverPickerNote')), findsOneWidget);

      await tester.tap(find.byKey(const Key('leftoverChooseAllPhotos')));
      await tester.pumpAndSettle();
      expect(system.picks, [1, 1]);

      await tester.tap(find.byKey(const Key('leftoverChangeMeal')));
      await tester.pumpAndSettle();
      await chooseMeal(tester);
      expect(system.picks, [1, 1, 1]);
      expect(analyzer.lastLeftoverCompact, isNull);
      expectNoLibraryAsked();
    });

    testWidgets('an unreadable pick says so; a picker that cannot open says '
        'that, never "isn\'t allowed"', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final system = FakeSystemPicker(replies: [
        const SystemPick(SystemPickStatus.ok, tooBig: 1),
        const SystemPick(SystemPickStatus.unavailable),
      ]);
      await pumpPicker(tester, system);
      await chooseMeal(tester);
      expect(find.text(AppLocalizationsEn().addPhotoUnreadable),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('leftoverChooseAllPhotos')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('leftoverPickerUnavailable')),
          findsOneWidget);
      expect(analyzer.lastLeftoverCompact, isNull);
      expectNoLibraryAsked();
    });

    testWidgets('with full access: the grid as before, plus the row',
        (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final system = FakeSystemPicker(broad: true, replies: [picked()]);
      await pumpPicker(tester, system);
      await chooseMeal(tester);
      expect(system.picks, isEmpty, reason: 'the grid first');
      expect(permissionRequests, 0, reason: 'full access is read, not asked');
      expect(find.byKey(const Key('leftoverPhoto-lp1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('leftoverChooseAllPhotos')));
      await tester.pumpAndSettle();
      expect(system.picks, [1]);
      expect(listing.loadedOriginals, isEmpty,
          reason: 'the picked photo, not a grid photo');
      expect(find.byKey(const Key('leftoverResultLine')), findsOneWidget);
    });

    testWidgets('at AX5 on a 320 pt phone the picker step fits and its '
        'button is reachable', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final system = FakeSystemPicker();
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(53 / 17)),
          child: child!,
        ),
        home: LeftoverScreen(
            systemPicker: system,
            services: UiServices(
              dao: dao,
              analyzer: analyzer,
              executor: FakeExecutor(),
              settings: FakeSettings(),
              picker: listing,
              requestPhotoPermission: () async => false,
            )),
      ));
      await tester.pumpAndSettle();
      final meal = find.byKey(const Key('leftoverMeal-1'));
      await tester.scrollUntilVisible(meal, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(meal);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(system.picks, [1]);
      final button = find.byKey(const Key('leftoverChooseAllPhotos'));
      await tester.scrollUntilVisible(button, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(system.picks, [1, 1]);
    });

    testWidgets('with full access, a picker that cannot open from the row '
        'says so; the grid stays', (tester) async {
      dao.put(_meal(1, '13:34', 965, hash: 'orig-hash'));
      final system = FakeSystemPicker(
          broad: true,
          replies: [const SystemPick(SystemPickStatus.unavailable)]);
      await pumpPicker(tester, system);
      await chooseMeal(tester);
      await tester.tap(find.byKey(const Key('leftoverChooseAllPhotos')));
      await tester.pumpAndSettle();
      expect(find.text(AppLocalizationsEn().addPickerUnavailable),
          findsOneWidget);
      expect(find.byKey(const Key('leftoverPhoto-lp1')), findsOneWidget);
    });
  });
}
