// The report-to-my-coach image (2026-08-02): a day's intake as one tall
// PNG. Pins the card's content contract and that rasterization actually
// produces a PNG — a silent blank image sent to a coach is worse than an
// error.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/l10n.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/widgets/calorie_ring.dart'
    show ArithmeticRow;
import 'package:calorie_tracker/ui/widgets/day_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'fakes.dart';

Meal _meal(int id, String time, String desc, num kcal,
        {String hash = '', String date = '2026-08-02'}) =>
    Meal(
      id: id,
      date: date,
      time: time,
      timestamp: '2026-08-02T12:00:00',
      source: 'app_photo',
      imageHash: hash,
      analysis: {
        'is_food': true,
        'total_calories': kcal,
        'total_protein_g': 20,
        'total_carbs_g': 50,
        'total_fat_g': 10,
        'meal_description': desc,
        'food_items': [
          {'name': 'Rice (~150 g)', 'estimated_calories': 200},
        ],
      },
    );

void main() {
  testWidgets('the card carries the coach-relevant facts', (tester) async {
    tester.view.physicalSize = const Size(420, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(
        child: DayReportCard(
          date: '2026-08-02',
          meals: [
            ReportMeal(meal: _meal(1, '8:05 AM', 'Soy milk and youtiao', 380)),
            ReportMeal(meal: _meal(2, '12:20 PM', 'Tomato egg noodles', 560)),
          ],
          typicalKcal: 2020,
          burnKcal: 88,
        ),
      ),
    ));
    expect(find.text('Daily intake'), findsOneWidget);
    expect(find.text('Sun, Aug 2, 2026'), findsOneWidget,
        reason: 'the absolute date, with its year');
    expect(find.text('940 kcal'), findsOneWidget, reason: 'day total');
    expect(find.text('Soy milk and youtiao'), findsOneWidget);
    expect(find.text('Tomato egg noodles'), findsOneWidget);
    expect(find.text('8:05 AM'), findsOneWidget);
    expect(find.textContaining('Rice (~150 g)'), findsWidgets,
        reason: 'portion assumptions reach the coach');
    expect(find.text('+88'), findsOneWidget, reason: 'burn in the math');
    // The eaten row is a plain positive figure. It used to read "−940" —
    // a minus subtracting from nothing once Today dropped the "= left"
    // row (testing loop 2026-10-07).
    final eaten = tester
        .widget<ArithmeticRow>(find.byKey(const Key('reportEatenRow')));
    expect(eaten.label, 'Eaten');
    expect(eaten.value, '940');
    expect(find.text('−940'), findsNothing);
    expect(find.text('-940'), findsNothing);
    expect(find.text('Logged with Chopstats'), findsOneWidget);
  });

  testWidgets('without a typical day the eaten row is the same plain figure',
      (tester) async {
    tester.view.physicalSize = const Size(420, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(
        child: DayReportCard(
          date: '2026-08-02',
          meals: [
            ReportMeal(meal: _meal(1, '8:05 AM', 'Soy milk and youtiao', 380)),
          ],
        ),
      ),
    ));
    final eaten = tester
        .widget<ArithmeticRow>(find.byKey(const Key('reportEatenRow')));
    expect(eaten.value, '380');
    expect(eaten.emphasized, isFalse,
        reason: 'nothing to be the result OF without the typical context');
  });

  testWidgets('an empty day still renders honestly', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SingleChildScrollView(
        child: DayReportCard(date: '2026-08-02', meals: []),
      ),
    ));
    expect(find.text('No meals logged.'), findsOneWidget);
  });

  testWidgets('renderDayReport produces a real PNG', (tester) async {
    await tester.runAsync(() async {
      final png = await renderDayReport(
        date: '2026-08-02',
        meals: [
          ReportMeal(meal: _meal(1, '8:05 AM', 'Soy milk and youtiao', 380)),
        ],
        typicalKcal: 2020,
      );
      expect(png.length, greaterThan(1000));
      // PNG magic bytes — the file a coach receives must BE an image.
      expect(png.sublist(0, 8),
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]));
    });
  });

  testWidgets('a zh user\'s coach gets a zh report (detached-tree locale)',
      (tester) async {
    // The card renders OUTSIDE the app's widget tree, so it can't inherit
    // the app locale — renderDayReport must build its own Localizations
    // scope. Rendering must not throw AND the card must show zh strings.
    await tester.runAsync(() async {
      final png = await renderDayReport(
        date: '2026-08-02',
        meals: [
          ReportMeal(meal: _meal(1, '8:05 AM', 'Soy milk and youtiao', 380)),
        ],
        typicalKcal: 2020,
        locale: const Locale('zh'),
      );
      expect(png.sublist(0, 8),
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]));
    });
    // Content contract, checked where text is findable: the same card
    // under a zh app scope.
    tester.view.physicalSize = const Size(420, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SingleChildScrollView(
        child: DayReportCard(
          date: '2026-08-02',
          meals: [
            ReportMeal(
                meal: _meal(1, '8:05 AM', 'Soy milk and youtiao', 380)),
          ],
          typicalKcal: 2020,
        ),
      ),
    ));
    expect(find.text('今日饮食'), findsOneWidget);
    expect(find.text('380 千卡'), findsOneWidget);
    expect(find.text('由筷拍记录'), findsOneWidget);
    // Per-meal macro line uses the zh short labels, as the meal cards do.
    expect(find.text('~380 千卡 · 蛋 20g · 碳 50g · 脂 10g'), findsOneWidget);
    expect(find.textContaining('P 20g'), findsNothing);
    // Dates and clocks localize too (user-reported 2026-08-03: History
    // weekdays stayed English in zh). The date is absolute, with the year
    // (U14): the CLDR zh pattern y年M月d日E.
    expect(find.text('2026年8月2日周日'), findsOneWidget);
    // The item line is the meal cards' own (zh: a full-width colon).
    expect(find.text('• Rice (~150 g)：~200 千卡'), findsOneWidget);
    expect(find.text('08:05'), findsOneWidget,
        reason: 'zh clocks are 24-hour, never AM/PM');
    expect(find.text('8:05 AM'), findsNothing);
  });

  // U14: the share flow always reports TODAY, and the header used the
  // relative day label, so every image read 'Daily intake / Today'. Read
  // later — saved to Photos, forwarded, several days in one chat — the
  // date was gone. The pinned past date above never took that path.
  for (final (locale, todayWord) in const [
    (Locale('en'), 'Today'),
    (Locale('zh'), '今天'),
  ]) {
    testWidgets('$locale: today\'s report is headed with the absolute date, '
        'never "$todayWord"', (tester) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SingleChildScrollView(
          child: DayReportCard(
            date: isoDate(now),
            meals: [
              ReportMeal(
                  meal: _meal(1, '8:05 AM', 'Soy milk and youtiao', 380,
                      date: isoDate(now))),
            ],
          ),
        ),
      ));
      expect(find.text(todayWord), findsNothing);
      final expected = DateFormat.yMMMEd(locale.toString())
          .format(DateTime(now.year, now.month, now.day));
      expect(find.text(expected), findsOneWidget);
      expect(
          tester.widget<Text>(find.byKey(const Key('reportDate'))).data,
          expected);
    });
  }

  test('reportDateLabel: an impossible date shows as stored, never as a '
      'confident wrong day', () {
    // DateTime.parse rolls 02-30 over to Mar 02.
    expect(reportDateLabel('2026-02-30', localeName: 'en'), '2026-02-30');
    expect(reportDateLabel('garbage', localeName: 'zh'), 'garbage');
    expect(reportDateLabel('2026-10-30', localeName: 'en'),
        'Fri, Oct 30, 2026');
  });

  // Owner decision O-1: the image is always light. It is opened on the
  // coach's phone, in that phone's mode; a dark capture sent into a light
  // chat read as a black slab. The caller still passes its own theme.
  testWidgets('a dark app theme still renders a LIGHT report (O-1)',
      (tester) async {
    Future<List<int>> topLeftRgb(ThemeData? theme) async {
      final png = await renderDayReport(
        date: '2026-08-02',
        meals: [
          ReportMeal(meal: _meal(1, '8:05 AM', 'Soy milk and youtiao', 380)),
        ],
        typicalKcal: 2020,
        theme: theme,
      );
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      return [data!.getUint8(0), data.getUint8(1), data.getUint8(2)];
    }

    await tester.runAsync(() async {
      // The root is the light grouped page, #F2F2F7 — not dark's #000000.
      expect(await topLeftRgb(ThemeData(brightness: Brightness.dark)),
          [0xF2, 0xF2, 0xF7]);
      expect(await topLeftRgb(null), [0xF2, 0xF2, 0xF7]);
    });
  });

  testWidgets('the share button appears only when meals exist',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TodayScreen(
                key: UniqueKey(), dao: dao))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shareDayButton')), findsNothing,
        reason: 'an empty day has nothing to report');

    // TODAY's date, computed — a pinned date turns this into a time bomb
    // the first midnight after it's written (it detonated 2026-08-03).
    dao.put(_meal(0, '8:05 AM', 'Soy milk', 110,
        date: isoDate(DateTime.now())));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TodayScreen(
                key: UniqueKey(), dao: dao))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shareDayButton')), findsOneWidget);
  });
}
