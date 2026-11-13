// The Body tab (2026-08-02): weight history + waist/chest/hip. These pin
// the page's contract: latest values with honest deltas, a chart only when
// there is a trend to draw, prefilled edit (so the full-row upsert can't
// eat data), validation on the SHARED weight bounds, and delete confirm.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/data/db.dart' show openAppDatabase;
import 'package:calorie_tracker/data/meals_dao_impl.dart' show SqfliteMealsDao;
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:calorie_tracker/ui/screens/log_body_sheet.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:calorie_tracker/ui/widgets/weight_trend_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show
        createDatabaseFactoryFfi,
        databaseFactoryOrNull,
        inMemoryDatabasePath,
        sqfliteFfiInit;

import 'fakes.dart';

void main() {
  final clock = DateTime(2026, 8, 2, 10);

  Future<FakeDao> pump(WidgetTester tester,
      {Map<String, double>? weights,
      List<BodyMeasurements> measurements = const []}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    weights?.forEach((date, kg) =>
        dao.weightsByDate[date] = WeightEntry(date, kg, source: 'manual'));
    for (final m in measurements) {
      dao.measurementsByDate[m.date] = m;
    }
    // UniqueKey: a second pump in the same test must get a FRESH State
    // (same-type widgets at the same position reuse state, skipping
    // initState and therefore the new dao's load).
    await tester.pumpWidget(MaterialApp(
        home: BodyScreen(key: UniqueKey(), dao: dao, clock: () => clock)));
    await tester.pumpAndSettle();
    return dao;
  }

  testWidgets('empty state invites logging and names no chat', (tester) async {
    // The chat bar went on 2026-07-31; the hint still sent new users to it
    // (U24). Both languages.
    for (final lang in const ['en', 'zh']) {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BodyScreen(dao: FakeDao(), clock: () => clock),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodyEmpty')), findsOneWidget);
      expect(find.byKey(const Key('logBodyButton')), findsOneWidget);
      final texts = tester
          .widgetList<Text>(find.descendant(
              of: find.byKey(const Key('bodyEmpty')),
              matching: find.byType(Text)))
          .map((t) => t.data!)
          .join(' ');
      expect(texts, isNot(matches(RegExp(r'\bchat\b', caseSensitive: false))),
          reason: lang);
      expect(texts, isNot(contains('对话')), reason: lang);
      expect(texts, isNot(contains('聊天')), reason: lang);
    }
  });

  testWidgets('no Log button until the page has loaded', (tester) async {
    // The sheet prefills from the loaded day; one opened before the load
    // would save today's measurements as a whole row with the untouched
    // ones blank.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: BodyScreen(dao: FakeDao(), clock: () => clock)));
    expect(find.byKey(const Key('logBodyButton')), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('logBodyButton')), findsOneWidget);
  });

  testWidgets('latest weight is the headline; delta is against the previous '
      'entry', (tester) async {
    await pump(tester, weights: {'2026-07-28': 82.4, '2026-08-02': 81.6});
    expect(find.byKey(const Key('bodyWeightHeadline')), findsOneWidget);
    expect(find.text('81.6'), findsOneWidget);
    final delta = tester
        .widget<Text>(find.descendant(
            of: find.byKey(const Key('bodyWeightDelta')),
            matching: find.byType(Text)))
        .data!;
    expect(delta, contains('0.8'));
    expect(delta, contains('▼'), reason: '81.6 < 82.4 — direction in text');
  });

  testWidgets('one weigh-in renders no chart; two render the trend',
      (tester) async {
    await pump(tester, weights: {'2026-08-02': 81.6});
    expect(find.byKey(const Key('weightTrendChart')), findsNothing,
        reason: 'a single point is not a trend');
    await pump(tester, weights: {'2026-07-28': 82.4, '2026-08-02': 81.6});
    expect(find.byKey(const Key('weightTrendChart')), findsOneWidget);
  });

  testWidgets('measurements card shows per-metric latest even when days are '
      'sparse', (tester) async {
    await pump(tester, measurements: [
      const BodyMeasurements('2026-07-30', waistCm: 84, chestCm: 100),
      const BodyMeasurements('2026-08-02', waistCm: 83.5), // chest not taken
    ]);
    expect(find.text('83.5 cm'), findsOneWidget);
    expect(find.text('100 cm'), findsOneWidget,
        reason: 'a day without chest must not blank the chest series');
  });

  testWidgets('logging weight through the sheet saves with source manual '
      'and refreshes the page', (tester) async {
    final dao = await pump(tester);
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.6');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();

    expect(dao.weightsByDate['2026-08-02']?.kg, 81.6);
    expect(dao.weightsByDate['2026-08-02']?.source, 'manual');
    expect(find.text('81.6'), findsOneWidget, reason: 'page reloaded');
    expect(find.byKey(const Key('bodyEmpty')), findsNothing);
  });

  testWidgets('a weight outside the SHARED parity bounds is refused with '
      'the bounds named', (tester) async {
    final dao = await pump(tester);
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '500');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bodySheetError')), findsOneWidget);
    expect(find.textContaining('300'), findsOneWidget,
        reason: 'the message names the real bound (shared weightMaxKg)');
    expect(dao.weightsByDate, isEmpty);
  });

  testWidgets('an empty sheet save is refused', (tester) async {
    final dao = await pump(tester);
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bodySheetError')), findsOneWidget);
    expect(dao.weightsByDate, isEmpty);
    expect(dao.measurementsByDate, isEmpty);
  });

  testWidgets('editing a day PREFILLS, so an untouched field survives the '
      'full-row upsert', (tester) async {
    final dao = await pump(tester, measurements: [
      const BodyMeasurements('2026-08-02', waistCm: 84, chestCm: 100),
    ]);
    await tester.tap(find.byKey(const Key('bodyDay2026-08-02')));
    await tester.pumpAndSettle();
    // Change only the waist; chest must carry through via the prefill.
    await tester.enterText(find.byKey(const Key('bodyWaistField')), '83.5');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();

    final saved = dao.measurementsByDate['2026-08-02']!;
    expect(saved.waistCm, 83.5);
    expect(saved.chestCm, 100, reason: 'prefill preserved the untouched field');
  });

  testWidgets('clearing a prefilled weight on edit deletes that weigh-in',
      (tester) async {
    final dao = await pump(tester,
        weights: {'2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-08-02', waistCm: 84)]);
    await tester.tap(find.byKey(const Key('bodyDay2026-08-02')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isEmpty,
        reason: 'a cleared field really clears');
    expect(dao.measurementsByDate['2026-08-02']?.waistCm, 84);
  });

  testWidgets('SWIPE to delete asks first, then removes both tables for '
      'the day', (tester) async {
    // The trailing delete button became swipe-to-delete (Apple idiom,
    // polish loop cycle 1) — the confirm dialog still gates it.
    final dao = await pump(tester,
        weights: {'2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-08-02', waistCm: 84)]);
    await tester.drag(
        find.byKey(const Key('bodyDay2026-08-02')), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isNotEmpty, reason: 'nothing until confirmed');
    await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isEmpty);
    expect(dao.measurementsByDate, isEmpty);
    expect(find.byKey(const Key('bodyEmpty')), findsOneWidget);
  });

  testWidgets('history rows list newest first with the values inline',
      (tester) async {
    await pump(tester,
        weights: {'2026-07-28': 82.4, '2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-08-02', waistCm: 84)]);
    // Rows are grouped cells now, ordered by their bodyDay keys.
    expect(
        tester
            .getTopLeft(find.byKey(const Key('bodyDay2026-08-02')))
            .dy,
        lessThan(tester
            .getTopLeft(find.byKey(const Key('bodyDay2026-07-28')))
            .dy),
        reason: 'newest first');
    // A no-break space keeps the short label with its number.
    expect(find.textContaining('W\u00A084'), findsOneWidget);
  });

  testWidgets('history row girth labels follow the app language (zh 腰/胸/臀)',
      (tester) async {
    // The row joined literal 'W'/'C'/'H' initials in every language, so
    // the zh history read 'W 84  ·  C 100  ·  H 98'.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    dao.measurementsByDate['2026-08-02'] = const BodyMeasurements(
        '2026-08-02',
        waistCm: 84,
        chestCm: 100,
        hipCm: 98);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BodyScreen(dao: dao, clock: () => clock),
    ));
    await tester.pumpAndSettle();
    expect(find.text('腰\u00A084  ·  胸\u00A0100  ·  臀\u00A098'), findsOneWidget);
    expect(find.textContaining('W\u00A084'), findsNothing);
  });

  testWidgets('dates read short everywhere: card, rows, footnote, sheet and '
      'confirm (no ISO dates on screen)', (tester) async {
    await pump(tester,
        weights: {'2026-07-28': 82.4, '2026-08-02': 81.6},
        measurements: [
          const BodyMeasurements('2026-07-28',
              waistCm: 84, chestCm: 100, hipCm: 98),
        ]);
    expect(find.textContaining(RegExp(r'\d{4}-\d{2}-\d{2}')), findsNothing,
        reason: 'storage keeps ISO; the screen does not');
    expect(tester.widget<Text>(find.byKey(const Key('bodyWeightDate'))).data,
        'on Aug 2');
    expect(find.text('Aug 2'), findsOneWidget, reason: 'history row title');
    expect(find.text('Jul 28'), findsOneWidget);
    // All three girths share their date: one footnote, no per-row dates.
    expect(
        tester
            .widget<Text>(find.byKey(const Key('bodyMeasurementsAsOf')))
            .data,
        'as of Jul 28');
    expect(find.text('on Jul 28'), findsNothing);

    // Today has data, so the Log button EDITS it — the title says so.
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    expect(find.text('Edit Aug 2'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
    await tester.pumpAndSettle();

    await tester.drag(
        find.byKey(const Key('bodyDay2026-07-28')), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete Jul 28?'), findsOneWidget);
  });

  testWidgets('a day without data opens as a new log', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
    expect(find.text('Log body · Aug 2'), findsOneWidget);
    expect(find.byKey(const Key('bodySheetDelete')), findsNothing,
        reason: 'nothing to delete on a new day');
  });

  testWidgets('girths taken on different days keep a date on each row',
      (tester) async {
    await pump(tester, measurements: [
      const BodyMeasurements('2026-07-30', waistCm: 84, chestCm: 100),
      const BodyMeasurements('2026-08-02', waistCm: 83.5),
    ]);
    expect(find.byKey(const Key('bodyMeasurementsAsOf')), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('bodyWaistRow')),
            matching: find.text('on Aug 2')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('bodyChestRow')),
            matching: find.text('on Jul 30')),
        findsOneWidget);
    expect(
        tester.widget<Text>(find.byKey(const Key('bodyHipLatest'))).data, '—');
  });

  testWidgets('the swipe background is the danger fill under a white glyph',
      (tester) async {
    await pump(tester, weights: {'2026-08-02': 81.6});
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('bodyDay2026-08-02'))));
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    final bg = tester
        .widget<ColoredBox>(find.byKey(const Key('bodyDeleteBackground')));
    expect(bg.color, AppColors.light.dangerFill);
    final glyph = tester.widget<Icon>(find.descendant(
        of: find.byKey(const Key('bodyDeleteBackground')),
        matching: find.byType(Icon)));
    expect(glyph.color, const Color(0xFFFFFFFF));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the delete confirm uses the destructive button style',
      (tester) async {
    await pump(tester, weights: {'2026-08-02': 81.6});
    await tester.drag(
        find.byKey(const Key('bodyDay2026-08-02')), const Offset(-500, 0));
    await tester.pumpAndSettle();
    final style = tester
        .widget<FilledButton>(find.byKey(const Key('confirmDeleteBodyDay')))
        .style!;
    expect(style.backgroundColor!.resolve({}), AppColors.light.fill);
    expect(style.foregroundColor!.resolve({}), AppColors.light.danger);
  });

  testWidgets('VoiceOver: a Body day is a button with a named Delete action '
      'that asks first (A11)', (tester) async {
    final handle = tester.ensureSemantics();
    final dao = await pump(tester, weights: {'2026-08-02': 81.6});
    final row = find.byKey(const Key('bodyDay2026-08-02'));
    expect(
        tester.getSemantics(row),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          customActions: [const CustomSemanticsAction(label: 'Delete')],
        ));
    final node = tester.getSemantics(row);
    node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
            const CustomSemanticsAction(label: 'Delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirmDeleteBodyDay')), findsOneWidget);
    expect(dao.weightsByDate, isNotEmpty, reason: 'nothing until confirmed');
    await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isEmpty);
    handle.dispose();
  });

  testWidgets('editing a day offers Delete in the sheet: it asks, removes '
      'the day and closes the sheet', (tester) async {
    final dao = await pump(tester,
        weights: {'2026-07-28': 82.4, '2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-07-28', waistCm: 84)]);
    await tester.tap(find.byKey(const Key('bodyDay2026-07-28')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bodySheetDelete')));
    await tester.pumpAndSettle();
    expect(find.text('Removes the weight and measurements recorded for '
        'this day.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate.keys, ['2026-08-02']);
    expect(dao.measurementsByDate, isEmpty);
    expect(find.byType(LogBodySheet), findsNothing, reason: 'sheet closed');
    expect(find.byKey(const Key('bodyDay2026-07-28')), findsNothing);
  });

  testWidgets('cancelling the sheet Delete keeps the day and the sheet',
      (tester) async {
    final dao = await pump(tester, weights: {'2026-08-02': 81.6});
    await tester.tap(find.byKey(const Key('bodyDay2026-08-02')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bodySheetDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate, isNotEmpty);
    expect(find.byType(LogBodySheet), findsOneWidget);
  });

  testWidgets('editing an OLDER weigh-in redraws the chart (B11)',
      (tester) async {
    // shouldRepaint compared only the count and the last point, so this
    // edit left the old line on screen while the row showed the new value.
    await pump(tester, weights: {
      '2026-07-20': 83.0,
      '2026-07-23': 82.6,
      '2026-07-26': 82.2,
      '2026-07-29': 81.9,
      '2026-08-02': 81.6,
    });
    WeightTrendPainter painter() => tester
        .widget<CustomPaint>(find.byKey(const Key('weightTrendChart')))
        .painter! as WeightTrendPainter;
    final before = painter();
    await tester.tap(find.byKey(const Key('bodyDay2026-07-20')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '95');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    final after = painter();
    expect(after.entries.first.kg, 95);
    expect(after.shouldRepaint(before), isTrue);
  });

  testWidgets('a year of weigh-ins: one row per date, newest first, and an '
      'older day edits and deletes only itself (P2)', (tester) async {
    final weights = <String, double>{};
    final measurements = <BodyMeasurements>[];
    for (var i = 0; i < 365; i++) {
      // UTC: a local-time subtraction crosses DST and repeats a date.
      final d = DateTime.utc(2026, 8, 2).subtract(Duration(days: i));
      final iso = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      weights[iso] = 80 + (i % 10) / 10;
      if (i % 7 == 0) {
        measurements.add(BodyMeasurements(iso, waistCm: 84 + i % 3, hipCm: 97));
      }
    }
    final dao = await pump(tester,
        weights: weights, measurements: measurements.reversed.toList());
    final rows = find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('bodyDay'));
    expect(rows, findsNWidgets(365));
    expect(tester.widget(rows.first).key, const Key('bodyDay2026-08-02'));
    expect(tester.widget(rows.at(1)).key, const Key('bodyDay2026-08-01'));

    final row = find.byKey(const Key('bodyDay2026-07-26')); // i = 7
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    String field(String key) => tester
        .widget<TextField>(find.byKey(Key(key)))
        .controller!
        .text;
    expect(field('bodyWeightField'), '80.7');
    expect(field('bodyWaistField'), '85');
    expect(field('bodyHipField'), '97');
    await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
    await tester.pumpAndSettle();

    await tester.drag(row, const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate.containsKey('2026-07-26'), isFalse);
    expect(dao.measurementsByDate.containsKey('2026-07-26'), isFalse);
    expect(dao.weightsByDate, hasLength(364));
    expect(dao.measurementsByDate, hasLength(measurements.length - 1));
    expect(rows, findsNWidgets(364));
  });

  // Review 1.7.1: the page and its sheet had no failure path. A failed
  // read left a spinner for good, with no Log button and no way to try
  // again (Today and History show an error with Retry); a failed save left
  // the sheet on 'Saving…' with Save and Delete disabled and nothing said.
  group('when the database fails', () {
    Future<_FlakyBodyDao> pumpFlaky(WidgetTester tester,
        {bool failReads = false,
        Locale? locale,
        bool withMeasurements = false}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final dao = _FlakyBodyDao()..failReads = failReads;
      dao.weightsByDate['2026-07-28'] =
          const WeightEntry('2026-07-28', 82.4, source: 'manual');
      if (withMeasurements) {
        dao.measurementsByDate['2026-07-28'] =
            const BodyMeasurements('2026-07-28', waistCm: 84);
      }
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BodyScreen(dao: dao, clock: () => clock),
      ));
      await tester.pumpAndSettle();
      return dao;
    }

    testWidgets('a failed read says so, and Retry loads the page',
        (tester) async {
      final dao = await pumpFlaky(tester, failReads: true);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('bodyLoadError')), findsOneWidget);
      expect(find.text("Couldn't load your weight and measurements."),
          findsOneWidget);
      expect(find.textContaining('database is locked'), findsNothing,
          reason: 'the raw error belongs in the log');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'not a spinner for good');
      expect(find.byKey(const Key('logBodyButton')), findsNothing,
          reason: 'the sheet prefills from data the page does not have');

      dao.failReads = false;
      await tester.tap(find.byKey(const Key('bodyRetry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bodyLoadError')), findsNothing);
      expect(find.text('82.4'), findsOneWidget);
      expect(find.byKey(const Key('logBodyButton')), findsOneWidget);
    });

    testWidgets('a read that fails after a good one shows the error, not '
        'the old page', (tester) async {
      final dao = await pumpFlaky(tester);
      expect(find.text('82.4'), findsOneWidget);
      dao.failReads = true;
      await tester
          .state<BodyScreenState>(find.byType(BodyScreen))
          .reload();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('bodyLoadError')), findsOneWidget);
      expect(find.byKey(const Key('logBodyButton')), findsNothing);
    });

    testWidgets('zh: the error sentence is Chinese', (tester) async {
      await pumpFlaky(tester, failReads: true, locale: const Locale('zh'));
      expect(find.text('无法加载体重和围度记录。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('a failed save keeps the sheet and what was typed, says '
        'so, and Save works again', (tester) async {
      final dao = await pumpFlaky(tester);
      await tester.tap(find.byKey(const Key('logBodyButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.6');
      dao.failWrites = true;
      await tester.tap(find.byKey(const Key('bodySheetSave')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LogBodySheet), findsOneWidget,
          reason: 'the sheet stays open');
      expect(find.text("Couldn't save. Try again."), findsOneWidget);
      expect(find.textContaining('disk I/O'), findsNothing);
      final save =
          tester.widget<FilledButton>(find.byKey(const Key('bodySheetSave')));
      expect(save.onPressed, isNotNull, reason: 'not stuck on Saving…');
      expect((save.child! as Text).data, 'Save');
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('bodyWeightField')))
              .controller!
              .text,
          '81.6');

      dao.failWrites = false;
      await tester.tap(find.byKey(const Key('bodySheetSave')));
      await tester.pumpAndSettle();
      expect(find.byType(LogBodySheet), findsNothing);
      expect(dao.weightsByDate['2026-08-02']?.kg, 81.6);
      expect(find.text('81.6'), findsOneWidget, reason: 'page reloaded');
    });

    // Review 1.7.1, second pass: a save that failed part-way (the weight
    // written, the measurements not) kept the sheet open, as it should,
    // but closed then with a swipe or a tap outside, it left the page on
    // the old weight until its next reload.
    for (final (what, typed, headline) in const [
      ('a new weight', '81.6', '81.6'),
      // Today's weigh-in gone: the page falls back to Jul 28's.
      ('a cleared weight', '', '82.4'),
    ]) {
      testWidgets('$what written, the measurements not, then the sheet '
          'dismissed: the page shows what was written', (tester) async {
        final dao = await pumpFlaky(tester);
        dao.weightsByDate['2026-08-02'] =
            const WeightEntry('2026-08-02', 83.2, source: 'manual');
        await tester.state<BodyScreenState>(find.byType(BodyScreen)).reload();
        await tester.pumpAndSettle();
        String shown() => tester
            .widget<Text>(find.byKey(const Key('bodyWeightHeadline')))
            .data!;
        expect(shown(), '83.2');

        await tester.tap(find.byKey(const Key('logBodyButton')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('bodyWeightField')), typed);
        await tester.enterText(find.byKey(const Key('bodyWaistField')), '90');
        dao.failMeasurementWrites = true;
        await tester.tap(find.byKey(const Key('bodySheetSave')));
        await tester.pumpAndSettle();
        expect(find.text("Couldn't save. Try again."), findsOneWidget);
        expect(dao.weightsByDate['2026-08-02']?.kg,
            typed.isEmpty ? isNull : 81.6,
            reason: 'the weight went through');
        expect(dao.measurementsByDate, isEmpty);

        await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
        await tester.pumpAndSettle();
        expect(find.byType(LogBodySheet), findsNothing);
        expect(shown(), headline, reason: 'the page reloaded');
        expect(find.byKey(const Key('bodyDay2026-08-02')),
            typed.isEmpty ? findsNothing : findsOneWidget);
      });
    }

    testWidgets('zh: the save failure is Chinese', (tester) async {
      final dao = await pumpFlaky(tester, locale: const Locale('zh'));
      await tester.tap(find.byKey(const Key('logBodyButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.6');
      dao.failWrites = true;
      await tester.tap(find.byKey(const Key('bodySheetSave')));
      await tester.pumpAndSettle();
      expect(find.text('没能保存，请再试一次。'), findsOneWidget);
    });

    // sqflite's error text carries the statement AND its arguments
    // ("sql 'INSERT INTO body_weight …' args [local, 2026-08-02, 81.6,
    // manual, …]", on iOS and Android alike), and debugPrint is not
    // compiled out of a release build. The save path logged '$e', so a
    // failed save wrote the typed weight or girths to the phone's log
    // (review 1.7.1, second pass). These fail a real write in the real DAO
    // (SQLite in this isolate, as test/e2e/harness.dart runs it, so its
    // futures finish in fake time) and read every line the save logs.
    const typed = [
      ('bodyWeightField', '81.6'),
      ('bodyWaistField', '91.5'),
      ('bodyChestField', '103.5'),
      ('bodyHipField', '99.5'),
    ];
    for (final table in const ['body_weight', 'body_measurements']) {
      testWidgets('a failed $table write keeps what was typed out of the log',
          (tester) async {
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        sqfliteFfiInit();
        databaseFactoryOrNull = createDatabaseFactoryFfi(noIsolate: true);
        final db = await openAppDatabase(path: inMemoryDatabasePath);
        try {
          final dao = SqfliteMealsDao(db, clock: () => clock);
          // SQLite refuses the insert inside the statement, as a locked or
          // full database does, so sqflite's own error comes back.
          await db.execute('CREATE TRIGGER refuse_insert BEFORE INSERT ON '
              "$table BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END");

          // The premise, so this cannot pass for nothing: the error's own
          // text holds the values that were written.
          var raw = '';
          try {
            if (table == 'body_weight') {
              await dao.saveBodyWeight('2026-08-02', 81.6, source: 'manual');
            } else {
              await dao.saveBodyMeasurements('2026-08-02',
                  waistCm: 91.5, chestCm: 103.5, hipCm: 99.5);
            }
          } catch (e) {
            raw = '$e';
          }
          final written = table == 'body_weight'
              ? const ['81.6']
              : const ['91.5', '103.5', '99.5'];
          for (final v in written) {
            expect(raw, contains(v),
                reason: "sqflite's error text carries the arguments: $raw");
          }

          final logged = <String>[];
          final debugPrintBefore = debugPrint;
          debugPrint = (String? message, {int? wrapWidth}) {
            if (message != null) logged.add(message);
          };
          try {
            await tester.pumpWidget(MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: BodyScreen(dao: dao, clock: () => clock),
            ));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('logBodyButton')));
            await tester.pumpAndSettle();
            for (final (key, text) in typed) {
              await tester.enterText(find.byKey(Key(key)), text);
            }
            await tester.tap(find.byKey(const Key('bodySheetSave')));
            await tester.pumpAndSettle();
          } finally {
            debugPrint = debugPrintBefore;
          }
          expect(find.text("Couldn't save. Try again."), findsOneWidget);
          final log = logged.join('\n');
          expect(log, contains('Body: save failed'),
              reason: 'the failure itself is still logged');
          for (final (_, text) in typed) {
            expect(log, isNot(contains(text)),
                reason: 'a typed value reached the log: $log');
          }
          expect(log, isNot(contains('INSERT')),
              reason: 'nor the statement: $log');
        } finally {
          await db.close();
        }
      });
    }

    // Review 1.7.1, second pass: a failed DELETE had no failure path
    // either. From a history row's swipe or its VoiceOver Delete the error
    // went uncaught and the row slid back with nothing said; from the
    // sheet's Delete, the same, with the sheet left as it was.
    const deleteFailed = "Couldn't delete. Try again.";

    Future<void> swipeDelete(WidgetTester tester, String date) async {
      await tester.drag(
          find.byKey(Key('bodyDay$date')), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
      await tester.pumpAndSettle();
    }

    testWidgets('a failed delete from a swipe keeps the day and says so',
        (tester) async {
      final dao = await pumpFlaky(tester);
      dao.failWeightDeletes = true;
      await swipeDelete(tester, '2026-07-28');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('bodyDay2026-07-28')), findsOneWidget,
          reason: 'the row is back in place');
      expect(find.text(deleteFailed), findsOneWidget);
      expect(find.textContaining('disk I/O'), findsNothing,
          reason: 'the raw error belongs in the log');
      expect(dao.weightsByDate.keys, ['2026-07-28']);

      dao.failWeightDeletes = false;
      await swipeDelete(tester, '2026-07-28');
      expect(dao.weightsByDate, isEmpty);
      expect(find.byKey(const Key('bodyEmpty')), findsOneWidget);
    });

    testWidgets('a failed delete from the VoiceOver action says so too',
        (tester) async {
      final handle = tester.ensureSemantics();
      final dao = await pumpFlaky(tester);
      dao.failWeightDeletes = true;
      final node =
          tester.getSemantics(find.byKey(const Key('bodyDay2026-07-28')));
      node.owner!.performAction(
          node.id,
          SemanticsAction.customAction,
          CustomSemanticsAction.getIdentifier(
              const CustomSemanticsAction(label: 'Delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(deleteFailed), findsOneWidget);
      expect(find.byKey(const Key('bodyDay2026-07-28')), findsOneWidget);
      expect(dao.weightsByDate.keys, ['2026-07-28']);
      handle.dispose();
    });

    testWidgets('a failed delete from the sheet keeps the sheet open, says '
        'so in it, and Delete works again', (tester) async {
      final dao = await pumpFlaky(tester);
      await tester.tap(find.byKey(const Key('bodyDay2026-07-28')));
      await tester.pumpAndSettle();
      dao.failWeightDeletes = true;
      await tester.tap(find.byKey(const Key('bodySheetDelete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LogBodySheet), findsOneWidget,
          reason: 'the sheet stays open');
      expect(tester.widget<Text>(find.byKey(const Key('bodySheetError'))).data,
          deleteFailed);
      expect(find.byType(SnackBar), findsNothing,
          reason: 'said in the sheet, not under it');
      expect(find.textContaining('disk I/O'), findsNothing);
      expect(dao.weightsByDate.keys, ['2026-07-28']);

      dao.failWeightDeletes = false;
      await tester.tap(find.byKey(const Key('bodySheetDelete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
      await tester.pumpAndSettle();
      expect(find.byType(LogBodySheet), findsNothing);
      expect(dao.weightsByDate, isEmpty);
      expect(find.byKey(const Key('bodyEmpty')), findsOneWidget);
    });

    testWidgets('a delete that fails part-way shows what is left',
        (tester) async {
      final dao = await pumpFlaky(tester, withMeasurements: true);
      expect(find.byKey(const Key('bodyWeightCard')), findsOneWidget);
      dao.failMeasurementDeletes = true;
      await swipeDelete(tester, '2026-07-28');
      expect(tester.takeException(), isNull);
      expect(find.text(deleteFailed), findsOneWidget);
      expect(dao.weightsByDate, isEmpty, reason: 'the weight went first');
      expect(find.byKey(const Key('bodyWeightCard')), findsNothing,
          reason: 'the page shows it gone');
      expect(find.byKey(const Key('bodyMeasurementsCard')), findsOneWidget);
      expect(find.byKey(const Key('bodyDay2026-07-28')), findsOneWidget);
    });

    testWidgets('zh: the delete failure is Chinese', (tester) async {
      final dao = await pumpFlaky(tester, locale: const Locale('zh'));
      dao.failWeightDeletes = true;
      await swipeDelete(tester, '2026-07-28');
      expect(find.text('没能删除，请再试一次。'), findsOneWidget);
    });

    // sqflite's text for a failed delete carries the statement and its
    // arguments too (the day). As the save path, the delete logs only the
    // error's type.
    testWidgets('a failed delete logs its type, never the statement or the '
        'day', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      sqfliteFfiInit();
      databaseFactoryOrNull = createDatabaseFactoryFfi(noIsolate: true);
      final db = await openAppDatabase(path: inMemoryDatabasePath);
      try {
        final dao = SqfliteMealsDao(db, clock: () => clock);
        await dao.saveBodyWeight('2026-08-02', 81.6, source: 'manual');
        await db.execute('CREATE TRIGGER refuse_delete BEFORE DELETE ON '
            "body_weight BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END");

        // The premise: the error's own text holds the statement and day.
        var raw = '';
        try {
          await dao.deleteBodyWeight('2026-08-02');
        } catch (e) {
          raw = '$e';
        }
        expect(raw, contains('DELETE'), reason: raw);
        expect(raw, contains('2026-08-02'), reason: raw);

        final logged = <String>[];
        final debugPrintBefore = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logged.add(message);
        };
        try {
          await tester.pumpWidget(MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BodyScreen(dao: dao, clock: () => clock),
          ));
          await tester.pumpAndSettle();
          await swipeDelete(tester, '2026-08-02');
        } finally {
          debugPrint = debugPrintBefore;
        }
        expect(tester.takeException(), isNull);
        expect(find.text(deleteFailed), findsOneWidget);
        expect(find.byKey(const Key('bodyDay2026-08-02')), findsOneWidget);
        final log = logged.join('\n');
        expect(log, contains('Body: delete failed'),
            reason: 'the failure itself is still logged');
        expect(log, isNot(contains('DELETE')), reason: log);
        expect(log, isNot(contains('2026-08-02')), reason: log);
      } finally {
        await db.close();
      }
    });
  });

  // ── Measurements rows at accessibility text sizes (2026-10-07) ────────
  // The row was label (fixed 64 px) + value + 'on {date}' + Spacer + delta,
  // none of which could shrink: at 1.64× (AX1) and 2× it overflowed the
  // card, clipping the ▲/▼ delta, and 'Waist' broke mid-word in its box.
  // Whether text fits depends on the glyphs (the test font is a full em
  // per glyph, far wider than the phone's), so this loads the iPhone's own
  // system fonts — macOS only, skipped elsewhere, as row_fit_layout_test.
  const sfPath = '/System/Library/Fonts/SFNS.ttf';
  const cjkPath = '/System/Library/Fonts/Hiragino Sans GB.ttc';
  final haveIphoneFonts =
      File(sfPath).existsSync() && File(cjkPath).existsSync();

  Future<void> loadFont(String family, String path) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(
          ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }

  group('measurements rows fit at large text sizes (SF + Hiragino)', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadFont('BodySF', sfPath);
      await loadFont('BodyHiragino', cjkPath);
    });

    for (final lang in const ['en', 'zh']) {
      for (final width in const [375.0, 390.0]) {
        // 1.0 keeps the one-line rows; AX1 (1.64) and up stack the label
        // over value, date and delta (A5: AX4/AX5 clipped the deltas).
        for (final scale in const [1.0, 1.64, 2.0, 2.76, 3.12]) {
          for (final sharedDate in const [true, false]) {
            testWidgets(
                '$lang at ${scale}x on a $width pt phone'
                '${sharedDate ? '' : ', a date per row'}', (tester) async {
              tester.view.physicalSize = Size(width, 2400);
              tester.view.devicePixelRatio = 1.0;
              addTearDown(tester.view.reset);
              tester.platformDispatcher.textScaleFactorTestValue = scale;
              addTearDown(
                  tester.platformDispatcher.clearTextScaleFactorTestValue);
              final dao = FakeDao();
              for (final m in [
                const BodyMeasurements('2026-07-30',
                    waistCm: 84, chestCm: 100, hipCm: 98),
                BodyMeasurements('2026-08-02',
                    waistCm: 83.5,
                    chestCm: 101.5,
                    hipCm: sharedDate ? 97.5 : null),
                if (!sharedDate)
                  const BodyMeasurements('2026-08-01', hipCm: 97.5),
              ]) {
                dao.measurementsByDate[m.date] = m;
              }
              await tester.pumpWidget(MaterialApp(
                locale: Locale(lang),
                theme: ThemeData(
                    fontFamily: 'BodySF',
                    fontFamilyFallback: const ['BodyHiragino']),
                localizationsDelegates:
                    AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: BodyScreen(dao: dao, clock: () => clock),
              ));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull,
                  reason: 'the old row overflowed the card at this size');

              final cardRect = tester
                  .getRect(find.byKey(const Key('bodyMeasurementsCard')));
              for (final (key, value, delta) in const [
                ('bodyWaist', '83.5 cm', '▼ 0.5'),
                ('bodyChest', '101.5 cm', '▲ +1.5'),
                ('bodyHip', '97.5 cm', '▼ 0.5'),
              ]) {
                final valueFinder = find.byKey(Key('${key}Latest'));
                expect(tester.widget<Text>(valueFinder).data, value);
                final row = find.byKey(Key('${key}Row'));
                final deltaFinder =
                    find.descendant(of: row, matching: find.text(delta));
                expect(deltaFinder, findsOneWidget,
                    reason: '$key keeps its direction glyph');
                for (final f in [valueFinder, deltaFinder]) {
                  final r = tester.getRect(f);
                  expect(r.right, lessThanOrEqualTo(cardRect.right),
                      reason: '$key: value and delta stay inside the card');
                  expect(r.left, greaterThanOrEqualTo(cardRect.left));
                }
                // Only a one-line row's date may give way; the label,
                // value and delta read in full.
                for (final p in tester.renderObjectList<RenderParagraph>(
                    find.descendant(of: row, matching: find.byType(RichText)))) {
                  final text = p.text.toPlainText();
                  if (scale == 1.0 && text.startsWith('on ')) continue;
                  expect(p.didExceedMaxLines, isFalse,
                      reason: '"$text" must not be cut');
                  expect(
                      p.size.width,
                      greaterThanOrEqualTo(
                          p.getMaxIntrinsicWidth(double.infinity) - 0.5),
                      reason: '"$text" must not wrap mid-word');
                }
              }
            });
          }
        }
      }
    }
  }, skip: haveIphoneFonts ? false : 'needs the macOS system fonts');
}

/// A DAO whose body reads or writes can be made to fail, as a locked or
/// full database does.
class _FlakyBodyDao extends FakeDao {
  bool failReads = false;
  bool failWrites = false;
  bool failMeasurementWrites = false;
  bool failWeightDeletes = false;
  bool failMeasurementDeletes = false;

  @override
  Future<List<WeightEntry>> listBodyWeights(
      String startDate, String endDate) async {
    if (failReads) throw StateError('database is locked');
    return super.listBodyWeights(startDate, endDate);
  }

  @override
  Future<void> saveBodyWeight(String date, double kg,
      {String source = 'nl'}) async {
    if (failWrites) throw StateError('disk I/O error');
    return super.saveBodyWeight(date, kg, source: source);
  }

  @override
  Future<void> saveBodyMeasurements(String date,
      {double? waistCm, double? chestCm, double? hipCm}) async {
    if (failMeasurementWrites) throw StateError('disk I/O error');
    return super.saveBodyMeasurements(date,
        waistCm: waistCm, chestCm: chestCm, hipCm: hipCm);
  }

  @override
  Future<void> deleteBodyWeight(String date) async {
    if (failWeightDeletes) throw StateError('disk I/O error');
    return super.deleteBodyWeight(date);
  }

  @override
  Future<void> deleteBodyMeasurements(String date) async {
    if (failMeasurementDeletes) throw StateError('disk I/O error');
    return super.deleteBodyMeasurements(date);
  }
}
