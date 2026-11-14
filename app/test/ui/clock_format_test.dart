// Android push (ui lane, sweeps C9/C18): times follow the phone's 12/24-
// hour setting everywhere, as Report Time already did.
// - dayTimeLabel built 'HH:mm' by hand, so Settings showed 'Report Time
//   9:30 PM' above 'Next summary Today 21:30' (UX run screenshot 04).
// - displayClock passed the stored '%I:%M %p' through in English, so meal
//   cards said '04:56 AM' even on a 24-hour phone (screenshot 75).
// - The editor's date pill showed the raw ISO date (screenshot 30).
// Display only: meals.time keeps the server-parity '%I:%M %p' string.
// Chinese stays 24-hour, as before.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/format.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart' show initializeDateFormatting;

import 'fakes.dart';

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();
  final now = DateTime(2026, 7, 17, 9);

  group('dayTimeLabel', () {
    test('12-hour English: h:mm AM/PM, no leading zero', () {
      String l12(DateTime when, {DateTime? at}) =>
          dayTimeLabel(en, when, now: at ?? now, use24h: false);
      expect(l12(DateTime(2026, 7, 17, 21, 30)), 'Today 9:30 PM');
      expect(l12(DateTime(2026, 7, 18, 7)), 'Tomorrow 7:00 AM');
      expect(l12(DateTime(2026, 7, 16, 14, 2)), 'Yesterday 2:02 PM');
      expect(l12(DateTime(2026, 7, 15, 14, 2)), '07-15 2:02 PM');
      expect(l12(DateTime(2026, 7, 17, 12)), 'Today 12:00 PM');
      expect(l12(DateTime(2026, 7, 18, 0, 1), at: DateTime(2026, 7, 17, 23, 59)),
          'Tomorrow 12:01 AM');
    });

    test('24-hour English: HH:mm', () {
      expect(dayTimeLabel(en, DateTime(2026, 7, 17, 21, 30), now: now,
              use24h: true),
          'Today 21:30');
      expect(dayTimeLabel(en, DateTime(2026, 7, 18, 7), now: now, use24h: true),
          'Tomorrow 07:00');
    });

    test('Chinese is 24-hour either way', () {
      for (final use24h in const [true, false]) {
        expect(
            dayTimeLabel(zh, DateTime(2026, 7, 17, 21, 30),
                now: now, use24h: use24h),
            '今天 21:30');
      }
    });

    testWidgets('by default it follows the phone', (tester) async {
      addTearDown(
          tester.platformDispatcher.clearAlwaysUse24HourTestValue);
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      expect(dayTimeLabel(en, DateTime(2026, 7, 17, 21, 30), now: now),
          'Today 21:30');
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = false;
      expect(dayTimeLabel(en, DateTime(2026, 7, 17, 21, 30), now: now),
          'Today 9:30 PM');
      // The pause footer's 'until' goes the same way.
      expect(
          autoScanPausedLine(en,
              kind: 'rejectedKey',
              until: DateTime(2026, 7, 18, 7),
              provider: 'gemini',
              serverBackend: 'claude',
              now: now),
          contains('Tomorrow 7:00 AM'));
    });
  });

  group('displayClock', () {
    test('English 12-hour: h:mm AM/PM from the stored string', () {
      expect(displayClock('04:56 AM', localeName: 'en', use24h: false),
          '4:56 AM');
      expect(displayClock('12:05 PM', localeName: 'en', use24h: false),
          '12:05 PM');
      expect(displayClock('12:30 AM', localeName: 'en', use24h: false),
          '12:30 AM');
      expect(displayClock('09:30 PM', use24h: false), '9:30 PM');
    });

    test('English 24-hour: HH:mm', () {
      expect(displayClock('04:56 AM', localeName: 'en', use24h: true), '04:56');
      expect(displayClock('12:30 AM', localeName: 'en', use24h: true), '00:30');
      expect(displayClock('09:30 PM', localeName: 'en', use24h: true), '21:30');
    });

    test('Chinese: 24-hour either way', () async {
      await initializeDateFormatting('zh'); // what the app's delegates do
      for (final use24h in const [true, false]) {
        expect(displayClock('09:30 PM', localeName: 'zh', use24h: use24h),
            '21:30');
      }
    });

    test('an unreadable stored clock shows as stored', () {
      for (final use24h in const [true, false]) {
        expect(displayClock('lunch', localeName: 'en', use24h: use24h),
            'lunch');
        expect(displayClock('', localeName: 'en', use24h: use24h), '');
      }
    });

    testWidgets('by default it follows the phone', (tester) async {
      addTearDown(
          tester.platformDispatcher.clearAlwaysUse24HourTestValue);
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      expect(displayClock('04:56 AM', localeName: 'en'), '04:56');
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = false;
      expect(displayClock('04:56 AM', localeName: 'en'), '4:56 AM');
    });
  });

  group('the meal editor', () {
    Meal meal() => Meal(
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
          },
        );

    Future<void> pump(WidgetTester tester, {Locale? locale}) async {
      final dao = FakeDao()..seed(meal());
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MealEditorScreen(
            dao: dao,
            meal: dao.meals.first,
            now: () => DateTime(2026, 7, 24, 19, 5)),
      ));
      await tester.pumpAndSettle();
    }

    String pill(WidgetTester tester, String key) => tester
        .widget<Text>(find.descendant(
            of: find.byKey(Key(key)), matching: find.byType(Text)))
        .data!;

    testWidgets('the date pill reads as a date, the time pill as the phone '
        'tells time', (tester) async {
      addTearDown(
          tester.platformDispatcher.clearAlwaysUse24HourTestValue);
      tester.platformDispatcher.alwaysUse24HourFormatTestValue = false;
      await pump(tester);
      expect(pill(tester, 'editorDateButton'), 'Jul 24');
      expect(pill(tester, 'editorTimeButton'), '1:30 PM');

      tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(pill(tester, 'editorTimeButton'), '13:30');
    });

    testWidgets('zh: 7月24日 and 13:30', (tester) async {
      await pump(tester, locale: const Locale('zh'));
      expect(pill(tester, 'editorDateButton'), '7月24日');
      expect(pill(tester, 'editorTimeButton'), '13:30');
    });

    testWidgets('a meal from another year names the year', (tester) async {
      final dao = FakeDao()
        ..seed(Meal(
          id: 2,
          date: '2025-12-31',
          time: '11:00 PM',
          timestamp: '2025-12-31T23:00:00.000',
          source: 'app_manual',
          analysis: const {'is_food': true, 'total_calories': 300},
        ));
      await tester.pumpWidget(MaterialApp(
        home: MealEditorScreen(
            dao: dao,
            meal: dao.meals.first,
            now: () => DateTime(2026, 1, 1, 9)),
      ));
      await tester.pumpAndSettle();
      expect(pill(tester, 'editorDateButton'), 'Dec 31, 2025');
    });
  });

  // The screen the bug was seen on (UX run screenshot 04): Report Time and
  // the next summary under it now say the time the same way.
  group('Settings', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final slot = DateTime(now.year, now.month, now.day, 21, 30);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            key: UniqueKey(),
            settings: FakeSettings(apiKey: 'k', reportTime: '21:30'),
            analyzer: FakeAnalyzer(),
            dao: FakeDao(),
            requestPhotoPermission: () async => true,
            nextSummaryAt: () async => slot,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    String rowText(WidgetTester tester, String key) => tester
        .widgetList<Text>(find.descendant(
            of: find.byKey(Key(key)), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .join(' | ');

    for (final use24h in const [false, true]) {
      testWidgets('Report Time and Next summary agree '
          '(${use24h ? '24' : '12'}-hour phone)', (tester) async {
        addTearDown(
            tester.platformDispatcher.clearAlwaysUse24HourTestValue);
        tester.platformDispatcher.alwaysUse24HourFormatTestValue = use24h;
        await pump(tester);
        final clock = use24h ? '21:30' : '9:30 PM';
        expect(rowText(tester, 'reportTimeTile'), contains(clock));
        expect(rowText(tester, 'nextSummaryRow'), contains('Today $clock'));
      });
    }
  });
}
