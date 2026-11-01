// U18: a weigh-in or measurement can be logged for a past day. The Log
// sheet has a date row (today by default); picking a day rebuilds the
// sheet for THAT day — prefilled when it has data, so the full-row
// measurements upsert and "cleared means delete" act on the right day —
// and saving writes there. No future days; what the user typed is never
// dropped silently.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:calorie_tracker/ui/screens/log_body_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  final clock = DateTime(2026, 8, 2, 10);

  Future<FakeDao> pump(WidgetTester tester,
      {Map<String, double>? weights,
      List<BodyMeasurements> measurements = const [],
      Locale? locale}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    weights?.forEach((date, kg) =>
        dao.weightsByDate[date] = WeightEntry(date, kg, source: 'manual'));
    for (final m in measurements) {
      dao.measurementsByDate[m.date] = m;
    }
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates:
          locale == null ? null : AppLocalizations.localizationsDelegates,
      supportedLocales: locale == null
          ? const [Locale('en', 'US')]
          : AppLocalizations.supportedLocales,
      home: BodyScreen(dao: dao, clock: () => clock),
    ));
    await tester.pumpAndSettle();
    return dao;
  }

  Future<void> openLog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('logBodyButton')));
    await tester.pumpAndSettle();
  }

  final dateRow = find.byKey(const Key('bodySheetDateRow'));

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(dateRow);
    await tester.pumpAndSettle();
  }

  /// Picks [day] of the month shown [monthsBack] months before August.
  Future<void> pickDay(WidgetTester tester, String day,
      {int monthsBack = 0}) async {
    await openPicker(tester);
    for (var i = 0; i < monthsBack; i++) {
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(day));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  String field(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

  String dateValue(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(of: dateRow, matching: find.byType(Text)))
      .map((t) => t.data)
      .join('|');

  testWidgets('the Log sheet opens on today, and the date row is a button '
      'that names the date', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    await openLog(tester);
    expect(find.text('Log body · Aug 2'), findsOneWidget);
    expect(dateValue(tester), 'Date|Aug 2');
    final node = tester.getSemantics(dateRow);
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.label, contains('Date'));
    expect(node.label, contains('Aug 2'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    // Above the fields: it is the first thing the sheet asks.
    expect(tester.getRect(dateRow).bottom,
        lessThan(tester.getTopLeft(find.byKey(const Key('bodyWeightField'))).dy));
    handle.dispose();
  });

  testWidgets('zh: the date row reads 日期 and a Chinese short date',
      (tester) async {
    await pump(tester, locale: const Locale('zh'));
    await openLog(tester);
    expect(dateValue(tester), '日期|8月2日');
    expect(find.text('记录身体 · 8月2日'), findsOneWidget);
  });

  testWidgets('no future days: the picker ends today and starts two years '
      'back', (tester) async {
    await pump(tester);
    await openLog(tester);
    await openPicker(tester);
    final dialog = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
    expect(dialog.lastDate, DateTime(2026, 8, 2));
    expect(dialog.firstDate, DateTime(2024, 8, 2));
    expect(dialog.initialDate, DateTime(2026, 8, 2));
    expect(dialog.currentDate, DateTime(2026, 8, 2));
    // Tomorrow is drawn but cannot be chosen.
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Log body · Aug 2'), findsOneWidget);
    expect(dateValue(tester), 'Date|Aug 2');
  });

  testWidgets('an entry older than two years stays reachable and listed',
      (tester) async {
    await pump(tester, weights: {'2023-05-01': 90.2, '2026-08-01': 81.9});
    expect(find.byKey(const Key('bodyDay2023-05-01')), findsOneWidget,
        reason: 'the page loads every day the picker can reach');
    await tester.tap(find.byKey(const Key('bodyDay2023-05-01')));
    await tester.pumpAndSettle();
    expect(find.text('Edit May 1, 2023'), findsOneWidget);
    await openPicker(tester);
    final dialog = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
    expect(dialog.firstDate, DateTime(2023, 5, 1));
    expect(dialog.initialDate, DateTime(2023, 5, 1),
        reason: 'the picker opens on the sheet\'s day');
  });

  testWidgets('picking a past day WITH data prefills it, edits that day '
      'and leaves today alone', (tester) async {
    final dao = await pump(tester,
        weights: {'2026-07-28': 82.4, '2026-08-02': 81.6},
        measurements: [
          const BodyMeasurements('2026-07-28', waistCm: 84, chestCm: 100),
        ]);
    await openLog(tester);
    expect(find.text('Edit Aug 2'), findsOneWidget);
    expect(field(tester, 'bodyWeightField'), '81.6');

    await pickDay(tester, '28', monthsBack: 1);
    expect(find.text('Edit Jul 28'), findsOneWidget);
    expect(dateValue(tester), 'Date|Jul 28');
    expect(field(tester, 'bodyWeightField'), '82.4');
    expect(field(tester, 'bodyWaistField'), '84');
    expect(field(tester, 'bodyChestField'), '100');
    expect(field(tester, 'bodyHipField'), '');
    expect(find.byKey(const Key('bodySheetDelete')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('bodyWaistField')), '83.5');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    final saved = dao.measurementsByDate['2026-07-28']!;
    expect(saved.waistCm, 83.5);
    expect(saved.chestCm, 100, reason: 'the untouched girth survives');
    expect(dao.weightsByDate['2026-07-28']!.kg, 82.4);
    expect(dao.weightsByDate['2026-08-02']!.kg, 81.6, reason: 'today intact');
    expect(dao.measurementsByDate.keys, ['2026-07-28']);
    expect(find.byType(LogBodySheet), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('bodyDay2026-07-28')),
            matching: find.textContaining('W 83.5')),
        findsOneWidget,
        reason: 'History shows the edit');
  });

  testWidgets('Delete after picking a day deletes THAT day', (tester) async {
    final dao = await pump(tester,
        weights: {'2026-08-01': 81.9, '2026-08-02': 81.6});
    await openLog(tester);
    await pickDay(tester, '1');
    expect(find.text('Edit Aug 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bodySheetDelete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete Aug 1?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmDeleteBodyDay')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate.keys, ['2026-08-02']);
    expect(find.byKey(const Key('bodyDay2026-08-01')), findsNothing);
  });

  testWidgets('picking an EMPTY past day logs a new row on that date',
      (tester) async {
    final dao = await pump(tester, weights: {'2026-08-02': 81.6});
    await openLog(tester);
    await pickDay(tester, '25', monthsBack: 1);
    expect(find.text('Log body · Jul 25'), findsOneWidget);
    for (final f in const [
      'bodyWeightField',
      'bodyWaistField',
      'bodyChestField',
      'bodyHipField',
    ]) {
      expect(field(tester, f), '', reason: '$f: today\'s prefill stays home');
    }
    expect(find.byKey(const Key('bodySheetDelete')), findsNothing);

    await tester.enterText(find.byKey(const Key('bodyWeightField')), '82.7');
    await tester.enterText(find.byKey(const Key('bodyHipField')), '97');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate['2026-07-25']!.kg, 82.7);
    expect(dao.weightsByDate['2026-07-25']!.source, 'manual');
    expect(dao.measurementsByDate['2026-07-25']!.hipCm, 97);
    expect(dao.weightsByDate['2026-08-02']!.kg, 81.6);
    // The page reloaded: a new History row, and the chart now has a trend.
    expect(find.byKey(const Key('bodyDay2026-07-25')), findsOneWidget);
    expect(
        tester.getTopLeft(find.byKey(const Key('bodyDay2026-08-02'))).dy,
        lessThan(
            tester.getTopLeft(find.byKey(const Key('bodyDay2026-07-25'))).dy));
    expect(find.byKey(const Key('weightTrendChart')), findsOneWidget);
  });

  testWidgets('typed values move to a picked day that has no data',
      (tester) async {
    final dao = await pump(tester);
    await openLog(tester);
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.2');
    await tester.enterText(find.byKey(const Key('bodyWaistField')), '83');
    await pickDay(tester, '1');
    expect(find.text('Log body · Aug 1'), findsOneWidget);
    expect(field(tester, 'bodyWeightField'), '81.2');
    expect(field(tester, 'bodyWaistField'), '83');
    await tester.tap(find.byKey(const Key('bodySheetSave')));
    await tester.pumpAndSettle();
    expect(dao.weightsByDate.keys, ['2026-08-01']);
    expect(dao.weightsByDate['2026-08-01']!.kg, 81.2);
    expect(dao.measurementsByDate['2026-08-01']!.waistCm, 83);
  });

  testWidgets('an untouched prefill does not travel to another day',
      (tester) async {
    final dao = await pump(tester,
        weights: {'2026-08-02': 81.6},
        measurements: [const BodyMeasurements('2026-08-02', waistCm: 84)]);
    await tester.tap(find.byKey(const Key('bodyDay2026-08-02')));
    await tester.pumpAndSettle();
    // Edit one field; the other stays as stored.
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.0');
    await pickDay(tester, '1');
    expect(find.text('Log body · Aug 1'), findsOneWidget);
    expect(field(tester, 'bodyWeightField'), '81.0', reason: 'typed');
    expect(field(tester, 'bodyWaistField'), '',
        reason: 'Aug 2\'s stored waist is not Aug 1\'s');
    // Nothing was written by moving.
    expect(dao.weightsByDate['2026-08-02']!.kg, 81.6);
    expect(dao.measurementsByDate['2026-08-02']!.waistCm, 84);
  });

  testWidgets('typed values and a picked day WITH data: it asks first — '
      'Cancel keeps both, Discard shows that day', (tester) async {
    final dao = await pump(tester, weights: {'2026-08-01': 80.9});
    await openLog(tester);
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.2');
    await pickDay(tester, '1');
    expect(find.text('Switch to Aug 1?'), findsOneWidget);
    expect(
        find.text('That day already has an entry. What you typed here is '
            'not saved and will be discarded.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Log body · Aug 2'), findsOneWidget);
    expect(field(tester, 'bodyWeightField'), '81.2', reason: 'kept');

    await pickDay(tester, '1');
    await tester.tap(find.byKey(const Key('bodySheetConfirmSwitch')));
    await tester.pumpAndSettle();
    expect(find.text('Edit Aug 1'), findsOneWidget);
    expect(field(tester, 'bodyWeightField'), '80.9',
        reason: 'the day\'s own value, not the discarded one');
    expect(dao.weightsByDate.keys, ['2026-08-01'], reason: 'nothing written');
    expect(dao.weightsByDate['2026-08-01']!.kg, 80.9);
  });

  testWidgets('nothing typed: moving to a day with data does not ask',
      (tester) async {
    await pump(tester, weights: {'2026-08-01': 80.9});
    await openLog(tester);
    await pickDay(tester, '1');
    expect(find.byKey(const Key('bodySheetConfirmSwitch')), findsNothing);
    expect(find.text('Edit Aug 1'), findsOneWidget);
    expect(field(tester, 'bodyWeightField'), '80.9');
  });

  testWidgets('Cancel in the picker keeps the day and what was typed',
      (tester) async {
    await pump(tester);
    await openLog(tester);
    await tester.enterText(find.byKey(const Key('bodyWeightField')), '81.2');
    await openPicker(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Log body · Aug 2'), findsOneWidget);
    expect(field(tester, 'bodyWeightField'), '81.2');
  });

  testWidgets('a history day opens on that day, and the Log button still '
      'opens today', (tester) async {
    await pump(tester, weights: {'2026-07-28': 82.4});
    await tester.tap(find.byKey(const Key('bodyDay2026-07-28')));
    await tester.pumpAndSettle();
    expect(dateValue(tester), 'Date|Jul 28');
    await tester.tapAt(const Offset(10, 10)); // dismiss the sheet
    await tester.pumpAndSettle();
    await openLog(tester);
    expect(dateValue(tester), 'Date|Aug 2');
    expect(find.text('Log body · Aug 2'), findsOneWidget);
  });
}
