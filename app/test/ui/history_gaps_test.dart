// History gap-day rows (2026-07-31): days with zero logged meals used to
// simply VANISH from the list — a watcher outage looked like a normal
// list. Interior gaps (plus the span up to today) now render as dimmed
// 'no meals logged' rows, tappable to the day editor; leading empty spans
// stay collapsed. This suite shipped a day late — the feature went out
// untested (loop debt, closed here).
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/day_detail_screen.dart';
import 'package:calorie_tracker/ui/screens/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

String _iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Meal _meal(String date, {num cal = 500, int id = 0}) => Meal(
      id: id,
      date: date,
      time: '12:00 PM',
      timestamp: '${date}T12:00:00.000',
      source: 'app_watch',
      imageHash: 'h$date$id',
      analysis: {'is_food': true, 'total_calories': cal},
    );

void main() {
  Future<FakeDao> pump(WidgetTester tester, List<Meal> meals) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    var id = 1;
    for (final m in meals) {
      dao.meals.add(Meal(
          id: id++,
          date: m.date,
          time: m.time,
          timestamp: m.timestamp,
          source: m.source,
          imageHash: m.imageHash,
          analysis: m.analysis));
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: HistoryScreen(dao: dao, days: 30))));
    await tester.pumpAndSettle();
    return dao;
  }

  testWidgets('an interior gap day renders dimmed with "no meals logged"',
      (tester) async {
    final now = DateTime.now();
    final d3 = _iso(now.subtract(const Duration(days: 3)));
    final d1 = _iso(now.subtract(const Duration(days: 1)));
    final d2 = _iso(now.subtract(const Duration(days: 2)));
    await pump(tester, [_meal(d3, cal: 700), _meal(d1, cal: 600)]);

    expect(find.byKey(Key('historyDay$d2')), findsOneWidget,
        reason: 'the missed day must EXIST as a row');
    expect(find.text('no meals logged'), findsWidgets);
    // Logged days still show their totals.
    expect(find.byKey(Key('historyDay$d3')), findsOneWidget);
    expect(find.byKey(Key('historyDay$d1')), findsOneWidget);
  });

  testWidgets('the span extends to TODAY even when today is empty',
      (tester) async {
    final now = DateTime.now();
    final today = _iso(now);
    final d2 = _iso(now.subtract(const Duration(days: 2)));
    await pump(tester, [_meal(d2)]);
    expect(find.byKey(Key('historyDay$today')), findsOneWidget,
        reason: '"nothing logged yet today/yesterday" is exactly the gap '
            'worth noticing');
  });

  testWidgets('LEADING empty span stays collapsed — a new user never sees '
      '29 empty rows', (tester) async {
    final now = DateTime.now();
    final today = _iso(now);
    final d29 = _iso(now.subtract(const Duration(days: 29)));
    await pump(tester, [_meal(today)]);
    expect(find.byKey(Key('historyDay$d29')), findsNothing,
        reason: 'days before the OLDEST logged day are not rendered');
    expect(find.text('no meals logged'), findsNothing);
  });

  testWidgets('gap rows open the day detail (the remedy is one tap away)',
      (tester) async {
    final now = DateTime.now();
    final d1 = _iso(now.subtract(const Duration(days: 1)));
    final d3 = _iso(now.subtract(const Duration(days: 3)));
    await pump(tester, [_meal(d3), _meal(d1)]);
    final d2 = _iso(now.subtract(const Duration(days: 2)));
    await tester.tap(find.byKey(Key('historyDay$d2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('addMealToDay')), findsOneWidget,
        reason: 'DayDetail with its + FAB is the fix for a missed day');
    // The '+' read as just 'button' to a screen reader: every tap target
    // on the day must carry a name.
    expect(find.byTooltip('Add a meal to this day'), findsOneWidget);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });

  testWidgets('zh day detail: the + and the corrected mark are named in '
      'Chinese', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    final dao = FakeDao();
    final today = _iso(DateTime.now());
    dao.meals.add(Meal(
        id: 1,
        date: today,
        time: '12:00 PM',
        timestamp: '${today}T12:00:00.000',
        source: 'app_watch',
        imageHash: 'h1',
        corrected: true,
        analysis: {'is_food': true, 'total_calories': 500}));
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DayDetailScreen(dao: dao, date: today)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('给这一天加一餐'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('已修正')), findsOneWidget,
        reason: 'the pencil on a corrected meal was silent');
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('a hand-edited FUTURE meal stays OUT of History — the §5.3 '
      'window ends at today', (tester) async {
    // The query window is [today-29, today] (server parity), so a
    // future-dated meal never reaches _perDay; the span-end guard in the
    // screen exists only for clock skew between load and build.
    final now = DateTime.now();
    final today = _iso(now);
    final future = _iso(now.add(const Duration(days: 2)));
    await pump(tester, [_meal(today), _meal(future)]);
    expect(find.byKey(Key('historyDay$future')), findsNothing);
    expect(find.byKey(Key('historyDay$today')), findsOneWidget);
  });

  testWidgets('day iteration crosses a month boundary without skips or '
      'duplicates', (tester) async {
    // Seed the 1st of this month and 28 days earlier — the generated span
    // must contain every date exactly once (the day+1 CONSTRUCTOR rule;
    // a Duration(hours:24) add would drift under DST).
    final now = DateTime.now();
    final old = now.subtract(const Duration(days: 28));
    await pump(tester, [_meal(_iso(old))]);
    final tiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .length;
    expect(tiles, 29,
        reason: '28 days ago .. today inclusive = 29 unique rows');
  });

  testWidgets('the trend chart keeps a slot per CALENDAR day — gaps stay '
      'gaps, and tapping one opens that day', (tester) async {
    // Fed only the logged days, two meals six days apart used to paint as
    // two adjacent half-width bars while the rows below listed five
    // "no meals logged" days between them.
    final now = DateTime.now();
    final d6 = _iso(now.subtract(const Duration(days: 6)));
    final today = _iso(now);
    await pump(tester, [_meal(d6, cal: 700), _meal(today, cal: 300)]);

    final chart = find.byKey(const Key('calorieTrendChart'));
    final painter = tester.widget<CustomPaint>(chart).painter as dynamic;
    final values = (painter.values as List).cast<num>();
    expect(values, [700, 0, 0, 0, 0, 0, 300],
        reason: 'd-6 .. today inclusive, gap days as empty (0) slots');
    expect(painter.average, 500,
        reason: 'the dashed line stays the days-with-data mean the caption '
            'prints (spec §5.3), not diluted over the gap days');
    expect(find.text('Average: ~500 kcal / day'), findsOneWidget);

    // Middle slot (index 3) = three days ago, a gap day.
    final rect = tester.getRect(chart);
    final slot = rect.width / values.length;
    await tester.tapAt(Offset(rect.left + slot * 3.5, rect.center.dy));
    await tester.pumpAndSettle();
    expect(
        tester.widget<DayDetailScreen>(find.byType(DayDetailScreen)).date,
        _iso(now.subtract(const Duration(days: 3))));
  });

  testWidgets('a screen reader gets no tap on the chart or the average '
      'caption — it used to open the middle day, not a chosen one',
      (tester) async {
    // The chart's GestureDetector exported a semantic tap that merged into
    // the caption: VoiceOver read the average as a button, and a double
    // tap ran onTapUp at the chart's CENTRE (the middle slot's day). The
    // day rows are the accessible drill-down; sighted taps are pinned by
    // the test above.
    final handle = tester.ensureSemantics();
    final now = DateTime.now();
    final meals = [
      for (final back in [0, 2, 4, 6, 8])
        _meal(_iso(now.subtract(Duration(days: back))), cal: 500 + back),
    ];
    await pump(tester, meals);

    for (final key in const ['historyAverage', 'calorieTrendChart']) {
      final data = tester.getSemantics(find.byKey(Key(key))).getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isFalse,
          reason: '$key must not be activatable by a screen reader');
    }
    // The rows still are.
    final row = tester
        .getSemantics(find.byKey(Key('historyDay${_iso(now)}')))
        .getSemanticsData();
    expect(row.hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });
}
