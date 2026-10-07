/// Row text that must FIT (2026-10-07 testing loop, round 3).
///
/// - The 记录剩菜 meal picker crammed day + clock, calories and a chevron
///   onto the description's line: the description — the thing that names
///   the meal — got 87 px in Chinese, 20–43 px in English, and 0 px plus
///   a RenderFlex overflow at the largest English text size.
/// - The English API-key page ellipsised four of nine provider names and
///   the Gemini note; the English subscription page cut 'Doubao Agent
///   Plan' / 'Volcengine subscription' and 'Thinking effort' / 'High —
///   most thorough' to fragments.
///
/// Both locales, at real phone widths. The picker checks are layout
/// invariants that hold under the test font (the description owns the
/// full cell width; nothing is ellipsised or overflows). Whether a STRING
/// fits depends on the glyphs, so the settings checks load the iPhone's
/// own system fonts (SF + Hiragino, macOS only — skipped elsewhere).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:calorie_tracker/ui/screens/settings/api_key_page.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart'
    show kApiKeyChoices, kPlanChoices;
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';

import 'fakes.dart';

Widget _app(Locale locale, Widget home, {ThemeData? theme}) => MaterialApp(
      locale: locale,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void _phone(WidgetTester tester, double width, {double scale = 1.0}) {
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  if (scale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
}

Meal _meal(int id, DateTime day, String time, num kcal, String desc) => Meal(
      id: id,
      date: isoDate(day),
      time: time,
      timestamp: '${isoDate(day)}T12:00:00',
      source: 'app_watch',
      imageHash: '',
      analysis: {
        'is_food': true,
        'meal_description': desc,
        'total_calories': kcal,
        'food_items': const [],
      },
    );

/// Every text painted inside [row] that ran out of lines, by its text.
List<String> _ellipsised(WidgetTester tester, Finder row) => [
      for (final p in tester.renderObjectList<RenderParagraph>(
          find.descendant(of: row, matching: find.byType(RichText))))
        if (p.didExceedMaxLines) p.text.toPlainText(),
    ];

void main() {
  group('leftover meal picker: the description owns the row', () {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    const copy = {
      'zh': (today: '番茄炒蛋盖饭和一碗汤', older: '牛肉面配煎蛋',
          kcal: '千卡', todayWord: '今天', olderWord: '昨天'),
      'en': (today: 'Chicken rice bowl', older: 'Beef noodle soup with egg',
          kcal: 'kcal', todayWord: 'Today', olderWord: 'Yesterday'),
    };

    for (final lang in copy.keys) {
      for (final scale in const [1.0, 1.35]) {
        testWidgets('$lang at ${scale}x on a 390 pt phone', (tester) async {
          final c = copy[lang]!;
          _phone(tester, 390, scale: scale);
          final dao = FakeDao()
            ..put(_meal(1, now, '12:30 PM', 1200, c.today))
            ..put(_meal(2, yesterday, '06:15 PM', 980, c.older));
          await tester.pumpWidget(_app(Locale(lang),
              LeftoverScreen(services: makeServices(dao: dao))));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: 'the old one-line row overflowed at 1.35x in en');

          for (final (id, desc, day, kcal) in [
            (1, c.today, c.todayWord, '1,200'),
            (2, c.older, c.olderWord, '980'),
          ]) {
            final row = find.byKey(Key('leftoverMeal-$id'));
            final title = find.descendant(of: row, matching: find.text(desc));
            expect(title, findsOneWidget);
            // GroupedSection's ONE 16 pt gutter + the row's 16 pt padding,
            // each side: nothing else shares the description's line.
            expect(tester.getSize(title).width, 390 - 4 * 16.0,
                reason: '"$desc" must get the full cell width');
            expect(_ellipsised(tester, row), isEmpty,
                reason: 'neither line of meal $id may be cut');
            // Calories still tell two 午餐 apart — on the second line.
            final detail = find.descendant(
                of: row, matching: find.textContaining(c.kcal));
            expect(detail, findsOneWidget);
            final line = tester.widget<Text>(detail).data!;
            expect(line, contains(day));
            expect(line, contains(kcal));
            expect(tester.getTopLeft(detail).dy,
                greaterThan(tester.getBottomLeft(title).dy - 0.5),
                reason: 'day · calories sit BELOW the description');
          }
          // Still the tap target the flow tests drive.
          await tester.tap(find.byKey(const Key('leftoverMeal-1')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('leftoverChosenMeal')), findsOneWidget);
        });
      }
    }
  });

  // ── Settings rows, measured with the iPhone's glyphs ──────────────────
  const sfPath = '/System/Library/Fonts/SFNS.ttf';
  const cjkPath = '/System/Library/Fonts/Hiragino Sans GB.ttc';
  final haveIphoneFonts =
      File(sfPath).existsSync() && File(cjkPath).existsSync();
  final iphoneTheme = ThemeData(
      fontFamily: 'SFTest', fontFamilyFallback: const ['HiraginoTest']);

  Future<void> loadFont(String family, String path) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(
          ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }

  group('settings rows fit at the default text size (SF + Hiragino)', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadFont('SFTest', sfPath);
      await loadFont('HiraginoTest', cjkPath);
    });

    // 375 pt: the narrowest current iPhone; 390 pt: the common one.
    for (final lang in const ['en', 'zh']) {
      for (final width in const [375.0, 390.0]) {
        testWidgets('API key providers, $lang at $width pt', (tester) async {
          _phone(tester, width);
          await tester.pumpWidget(_app(
              Locale(lang), ApiKeyProviderPage(settings: FakeSettings()),
              theme: iphoneTheme));
          await tester.pumpAndSettle();
          for (final (id, _, _) in kApiKeyChoices) {
            expect(_ellipsised(tester, find.byKey(Key('providerChoice-$id'))),
                isEmpty,
                reason: 'provider row $id must read in full');
          }
          expect(tester.takeException(), isNull);
        });

        for (final effort in const ['', 'low', 'medium', 'high']) {
          testWidgets(
              'subscription plans + effort "$effort", $lang at $width pt',
              (tester) async {
            _phone(tester, width);
            final settings = FakeSettings()
              ..provider = 'server'
              ..serverBackend = 'claude'
              ..serverEffort = effort;
            await tester.pumpWidget(_app(
                Locale(lang), SubscriptionProviderPage(settings: settings),
                theme: iphoneTheme));
            await tester.pumpAndSettle();
            for (final key in [
              for (final (backend, _, _) in kPlanChoices)
                'planChoice-$backend',
              'planModelRow',
              'planEffortRow',
            ]) {
              expect(_ellipsised(tester, find.byKey(Key(key))), isEmpty,
                  reason: '$key must read in full');
            }
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }, skip: haveIphoneFonts ? false : 'needs the macOS system fonts');
}
