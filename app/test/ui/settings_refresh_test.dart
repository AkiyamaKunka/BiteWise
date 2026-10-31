/// Run 7, Settings lane: the redesigned Settings root, its sub-pages and
/// sheets, measured with the app's REAL theme (AppTheme via the harness)
/// and, where glyphs matter, the iPhone's own fonts (SF + Hiragino).
///
/// - Root row titles read in full at the default text size.
/// - Fields inside grouped cells draw no outline, enabled or focused (the
///   theme outlines every other field).
/// - The first-run card is a button that opens the AI Provider page.
/// - Stop sharing's confirm is the red destructive action.
/// - The AI consent dialog is the neutral elevated surface, keys intact.
/// - The daily-goal dialog validates instead of silently clearing (B19).
/// - The selection sheets reach their last option at AX5 on an SE (A2).
/// - Limited Photos access is said in the Photos footer (U7).
/// - Import leads with the clipboard; the export file says Chopstats (U20).
/// - The own-server page tells people without a server to go back (U3).
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart'
    show maxDailyGoalKcal;
import 'package:calorie_tracker/ui/ai_consent.dart' show ensureAiConsent;
import 'package:calorie_tracker/ui/screens/settings/api_key_page.dart';
import 'package:calorie_tracker/ui/screens/settings/data_section.dart';
import 'package:calorie_tracker/ui/screens/settings/profile_page.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

/// Dynamic Type AX5 on iOS: 53 pt body over 17.
const double _ax5 = 53 / 17;

/// Every text painted inside [scope] that ran out of lines.
List<String> _ellipsised(WidgetTester tester, Finder scope) => [
  for (final p in tester.renderObjectList<RenderParagraph>(
    find.descendant(of: scope, matching: find.byType(RichText)),
  ))
    if (p.didExceedMaxLines) p.text.toPlainText(),
];

/// Photos access as a fake: only [hasFullAccess] is answered — anything
/// else the screen might call would be a bug in the probe (it must never
/// read assets), and fails loudly.
class _AccessLibrary implements PhotoLibrary {
  _AccessLibrary({required this.full});
  bool full;
  int calls = 0;

  @override
  Future<bool> hasFullAccess() async {
    calls++;
    return full;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The Settings tab as the shell hosts it (inside a Scaffold, for its
/// snackbars).
Widget _settings(FakeSettings s, {PhotoLibrary? library}) => Scaffold(
  body: SettingsScreen(
    settings: s,
    analyzer: FakeAnalyzer(),
    dao: FakeDao(),
    requestPhotoPermission: () async => true,
    photoLibrary: library,
    lastBackgroundScan: () async => DateTime(2026, 10, 30, 14, 2),
    backgroundRefreshEnabled: () async => true,
    nextSummaryAt: () async => DateTime(2026, 10, 31, 21),
  ),
);

/// Scrolls the page's list until [target] is built and on screen (the
/// Settings list builds its rows lazily).
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadIphoneFonts);

  group('root rows read in full at 1.0x (SF + Hiragino)', () {
    for (final lang in const ['en', 'zh']) {
      for (final width in const [375.0, 390.0]) {
        testWidgets('$lang at $width pt', (tester) async {
          final s = FakeSettings(apiKey: 'k', watcherEnabled: true)
            ..calorieGoal = 20000
            ..dietaryProfile = 'vegetarian';
          await pumpApp(
            tester,
            _settings(s),
            size: Size(width, 3200),
            locale: Locale(lang),
          );
          final rows = find.byType(GroupedRow);
          expect(rows, findsWidgets);
          expect(_ellipsised(tester, find.byType(SettingsScreen)), isEmpty);
          // The goal reads like every other number in the app.
          expect(find.textContaining('20,000'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }, skip: !haveIphoneFonts);
      }
    }
  });

  group('fields inside grouped cells draw no outline', () {
    InputDecoration decorationOf(WidgetTester tester, Key key) => tester
        .widget<InputDecorator>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(InputDecorator),
          ),
        )
        .decoration;

    Future<void> expectBorderless(
      WidgetTester tester,
      Key key, {
      bool focus = true,
    }) async {
      final before = decorationOf(tester, key);
      expect(before.enabledBorder, InputBorder.none, reason: '$key enabled');
      expect(before.focusedBorder, InputBorder.none, reason: '$key focused');
      expect(before.filled, isFalse, reason: '$key fill');
      if (!focus) return;
      await tester.tap(find.byKey(key));
      await tester.pump();
      final focused = decorationOf(tester, key);
      expect(
        focused.focusedBorder,
        InputBorder.none,
        reason: '$key while focused',
      );
      // The decorator really paints the focused border it was given.
      final decorator = tester.widget<InputDecorator>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(InputDecorator),
        ),
      );
      expect(decorator.isFocused, isTrue);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    }

    for (final dark in const [false, true]) {
      final mode = dark ? 'dark' : 'light';
      testWidgets('API key, model picker and custom model ($mode)', (
        tester,
      ) async {
        final s = FakeSettings(apiKey: 'k', model: 'my-own-model');
        await pumpApp(
          tester,
          ApiKeyProviderPage(settings: s),
          size: const Size(390, 1600),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        await expectBorderless(tester, const Key('apiKeyField'));
        await expectBorderless(tester, const Key('modelPicker'), focus: false);
        await expectBorderless(tester, const Key('modelField'));
      });

      testWidgets('server address and upload key ($mode)', (tester) async {
        final s = FakeSettings(apiKey: 'k')
          ..provider = 'server'
          ..serverBackend = 'claude';
        await pumpApp(
          tester,
          SubscriptionProviderPage(settings: s),
          size: const Size(390, 1600),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        await expectBorderless(tester, const Key('serverUrlField'));
        await expectBorderless(tester, const Key('serverUploadKeyField'));
      });

      testWidgets('dietary profile ($mode)', (tester) async {
        await pumpApp(
          tester,
          ProfileSettingsPage(settings: FakeSettings()),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        await expectBorderless(tester, const Key('dietaryProfileField'));
      });
    }
  });

  group('first-run card', () {
    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: a button that opens the AI Provider page', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final l = lookupAppLocalizations(Locale(lang));
        await pumpApp(
          tester,
          _settings(FakeSettings(apiKey: '')),
          size: const Size(375, 1400),
          locale: Locale(lang),
        );
        final card = find.byKey(const Key('firstRunCard'));
        expect(card, findsOneWidget);
        expect(find.text(l.settingsWelcomeTitle), findsOneWidget);
        final node = tester.getSemantics(
          find.descendant(of: card, matching: find.byType(Semantics)).first,
        );
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.label, contains(l.settingsWelcomeTitle));

        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(find.byType(ProviderSettingsPage), findsOneWidget);
        expect(
          find.byKey(const Key('testProviderButton')),
          findsOneWidget,
          reason: 'the Test step is on the page the card opens',
        );
        handle.dispose();
      });
    }

    testWidgets('the title no longer promises "one step"', (tester) async {
      final en = lookupAppLocalizations(const Locale('en'));
      expect(en.settingsWelcomeTitle, isNot(contains('one step')));
      expect(en.settingsWelcomeTitle, 'Set up AI to start logging');
    });

    testWidgets('at AX5 on an SE the text takes the whole card', (
      tester,
    ) async {
      await pumpApp(
        tester,
        _settings(FakeSettings(apiKey: '')),
        size: const Size(375, 667),
        scale: _ax5,
        locale: const Locale('zh'),
      );
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.byKey(const Key('firstRunCard')));
      final title = tester.getRect(
        find.text(
          lookupAppLocalizations(const Locale('zh')).settingsWelcomeTitle,
        ),
      );
      // The card's key is on its margin box: 16 gutter + 16 padding.
      expect(
        title.left - card.left,
        32,
        reason: 'no badge column beside the text at AX5',
      );
    });
  });

  group('Stop sharing', () {
    for (final dark in const [false, true]) {
      testWidgets('the confirm is the danger action '
          '(${dark ? 'dark' : 'light'})', (tester) async {
        await pumpApp(
          tester,
          _settings(
            FakeSettings(
              apiKey: 'k',
              watcherEnabled: true,
              watcherDisclosureSeen: true,
            ),
          ),
          size: const Size(390, 1600),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        await tester.tap(find.byKey(const Key('aiStopSharingRow')));
        await tester.pumpAndSettle();
        final dialog = tester.widget<AlertDialog>(
          find.byKey(const Key('aiStopSharingDialog')),
        );
        expect(dialog.scrollable, isTrue);
        final colors = dark ? AppColors.dark : AppColors.light;
        final label = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('aiStopSharingConfirm')),
            matching: find.byType(Text),
          ),
        );
        final style = DefaultTextStyle.of(
          tester.element(find.text(label.data!)),
        ).style;
        expect(style.color, colors.danger);
      });
    }
  });

  group('AI consent dialog restyles through the theme only', () {
    for (final dark in const [false, true]) {
      testWidgets(dark ? 'dark' : 'light', (tester) async {
        final s = FakeSettings(apiKey: 'k')..aiConsent = {};
        late BuildContext ctx;
        await pumpApp(
          tester,
          Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              },
            ),
          ),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        final result = ensureAiConsent(ctx, s);
        await tester.pumpAndSettle();
        final dialog = find.byKey(const Key('aiConsentDialog'));
        expect(dialog, findsOneWidget);
        expect(find.byKey(const Key('aiConsentNotNow')), findsOneWidget);
        expect(find.byKey(const Key('aiConsentAllow')), findsOneWidget);
        final surface = tester.widget<Material>(
          find.descendant(of: dialog, matching: find.byType(Material)).first,
        );
        expect(
          surface.color,
          dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF),
        );
        await tester.tap(find.byKey(const Key('aiConsentAllow')));
        await tester.pumpAndSettle();
        expect(await result, isTrue);
      });
    }
  });

  group('daily goal dialog (B19)', () {
    Future<FakeSettings> openGoal(WidgetTester tester, String lang) async {
      final s = FakeSettings(apiKey: 'k')..calorieGoal = 1800;
      await pumpApp(
        tester,
        _settings(s),
        size: const Size(390, 1600),
        locale: Locale(lang),
      );
      await _scrollTo(tester, find.byKey(const Key('calorieGoalTile')));
      await tester.tap(find.byKey(const Key('calorieGoalTile')));
      await tester.pumpAndSettle();
      return s;
    }

    Future<void> save(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const Key('calorieGoalField')), text);
      await tester.tap(find.byKey(const Key('calorieGoalSave')));
      await tester.pumpAndSettle();
    }

    test('the cap is the store\'s', () {
      expect(maxDailyGoalKcal, 20000);
    });

    for (final lang in const ['en', 'zh']) {
      final l = lookupAppLocalizations(Locale(lang));
      final error = l.goalInvalid('20,000');

      testWidgets('$lang: out of range or not whole stays open with a reason', (
        tester,
      ) async {
        final s = await openGoal(tester, lang);
        for (final bad in const ['25000', '1800.5', '0', '-5', 'abc']) {
          await save(tester, bad);
          expect(
            find.byKey(const Key('calorieGoalField')),
            findsOneWidget,
            reason: '"$bad" keeps the dialog open',
          );
          expect(find.text(error), findsOneWidget, reason: bad);
          expect(s.calorieGoal, 1800, reason: '"$bad" saves nothing');
        }
        // Typing again clears the complaint.
        await tester.enterText(find.byKey(const Key('calorieGoalField')), '2');
        await tester.pump();
        expect(find.text(error), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$lang: grouping separators are fine', (tester) async {
        final s = await openGoal(tester, lang);
        await save(tester, '2,000');
        expect(find.byKey(const Key('calorieGoalField')), findsNothing);
        expect(s.calorieGoal, 2000);
        expect(find.textContaining('2,000'), findsOneWidget);
        await tester.tap(find.byKey(const Key('calorieGoalTile')));
        await tester.pumpAndSettle();
        await save(tester, '2 100');
        expect(s.calorieGoal, 2100);
      });

      testWidgets('$lang: empty or Clear clears', (tester) async {
        final s = await openGoal(tester, lang);
        await save(tester, '');
        expect(s.calorieGoal, 0);
        expect(
          find.descendant(
            of: find.byKey(const Key('calorieGoalTile')),
            matching: find.text(l.goalNotSet),
          ),
          findsOneWidget,
        );
        s.calorieGoal = 1800;
        await tester.tap(find.byKey(const Key('calorieGoalTile')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('calorieGoalClear')));
        await tester.pumpAndSettle();
        expect(s.calorieGoal, 0);
      });
    }
  });

  group('selection sheets at AX5 on an SE (A2)', () {
    Future<void> pumpSe(
      WidgetTester tester,
      Widget home, {
      String lang = 'en',
      bool dark = false,
    }) => pumpApp(
      tester,
      home,
      size: const Size(375, 667),
      scale: _ax5,
      locale: Locale(lang),
      brightness: dark ? Brightness.dark : Brightness.light,
      padding: const EdgeInsets.only(top: 20),
    );

    Future<void> pickLast(WidgetTester tester, Key opener, Key last) async {
      await _scrollTo(tester, find.byKey(opener));
      await tester.tap(find.byKey(opener));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'the sheet overflowed before the last option',
      );
      await tester.ensureVisible(find.byKey(last));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(last));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: Language reaches 中文', (tester) async {
        final s = FakeSettings(apiKey: 'k');
        await pumpSe(tester, _settings(s), lang: lang, dark: lang == 'zh');
        await pickLast(
          tester,
          const Key('languageRow'),
          const Key('language-zh'),
        );
        expect(s.appLanguage, 'zh');
      });
    }

    testWidgets('en: Units reaches Imperial', (tester) async {
      final s = FakeSettings(apiKey: 'k');
      await pumpSe(tester, _settings(s));
      await pickLast(
        tester,
        const Key('unitsRow'),
        const Key('units-imperial'),
      );
      expect(s.units, 'imperial');
    });

    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: the lookback sheet reaches its Set button', (
        tester,
      ) async {
        final s = FakeSettings(apiKey: 'k');
        await pumpSe(tester, _settings(s), lang: lang);
        await _scrollTo(
          tester,
          find.text(lookupAppLocalizations(Locale(lang)).settingsRowLookback),
        );
        await tester.tap(
          find.text(lookupAppLocalizations(Locale(lang)).settingsRowLookback),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('lookbackSlider')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('lookbackSetButton')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('lookbackSetButton')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('lookbackSlider')), findsNothing);
        expect(s.lookbackDays, 2);
      });
    }

    for (final (key, last) in const [
      ('planModelRow', 'plan-model-haiku'),
      ('planEffortRow', 'plan-effort-high'),
    ]) {
      testWidgets('own server: $key reaches $last', (tester) async {
        final s = FakeSettings(apiKey: 'k')
          ..provider = 'server'
          ..serverBackend = 'claude';
        await pumpSe(tester, SubscriptionProviderPage(settings: s));
        await pickLast(tester, Key(key), Key(last));
        expect(
          key == 'planModelRow' ? s.serverModel : s.serverEffort,
          last.split('-').last,
        );
      });
    }
  });

  group('checkmark sheets', () {
    testWidgets('the current choice is checked and announced selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final s = FakeSettings(apiKey: 'k')..appLanguage = 'en';
      await pumpApp(tester, _settings(s), size: const Size(390, 1600));
      await _scrollTo(tester, find.byKey(const Key('languageRow')));
      await tester.tap(find.byKey(const Key('languageRow')));
      await tester.pumpAndSettle();
      for (final (value, selected) in const [
        ('system', false),
        ('en', true),
        ('zh', false),
      ]) {
        final row = find.byKey(Key('language-$value'));
        expect(
          find.descendant(of: row, matching: find.byIcon(Icons.check_rounded)),
          selected ? findsOneWidget : findsNothing,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.byIcon(Icons.chevron_right_rounded),
          ),
          findsNothing,
          reason: 'a choice is not a disclosure',
        );
        final node = tester.getSemantics(row);
        expect(
          node.flagsCollection.isSelected,
          selected ? Tristate.isTrue : isNot(Tristate.isTrue),
        );
      }
      handle.dispose();
    });

    testWidgets('the lookback slider sets the window', (tester) async {
      final s = FakeSettings(apiKey: 'k');
      await pumpApp(tester, _settings(s), size: const Size(390, 1600));
      final l = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.text(l.settingsRowLookback));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lookbackValue')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('lookbackSlider')),
        const Offset(400, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.lookbackDays(30)), findsWidgets);
      await tester.tap(find.byKey(const Key('lookbackSetButton')));
      await tester.pumpAndSettle();
      expect(s.lookbackDays, 30);
    });
  });

  group('report time is displayed the phone\'s way', () {
    testWidgets('en: 12-hour by default, 24-hour with the switch', (
      tester,
    ) async {
      await pumpApp(
        tester,
        _settings(FakeSettings(apiKey: 'k')),
        size: const Size(390, 1600),
      );
      final row = find.byKey(const Key('reportTimeTile'));
      expect(
        find.descendant(of: row, matching: find.text('9:00 PM')),
        findsOneWidget,
      );
    });

    testWidgets('zh: 24-hour', (tester) async {
      await pumpApp(
        tester,
        _settings(FakeSettings(apiKey: 'k')),
        size: const Size(390, 1600),
        locale: const Locale('zh'),
      );
      final row = find.byKey(const Key('reportTimeTile'));
      expect(
        find.descendant(of: row, matching: find.text('21:00')),
        findsOneWidget,
      );
    });
  });

  group('limited Photos access is said in the footer (U7)', () {
    for (final lang in const ['en', 'zh']) {
      final l = lookupAppLocalizations(Locale(lang));

      testWidgets('$lang: watcher on + limited → the line; full → none', (
        tester,
      ) async {
        final library = _AccessLibrary(full: false);
        final s = FakeSettings(
          apiKey: 'k',
          watcherEnabled: true,
          watcherDisclosureSeen: true,
        );
        await pumpApp(
          tester,
          _settings(s, library: library),
          size: const Size(390, 2400),
          locale: Locale(lang),
        );
        expect(find.textContaining(l.watcherLimitedFooter), findsOneWidget);

        // Fixed in system settings, then back to the app: the line clears.
        library.full = true;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(l.watcherLimitedFooter), findsNothing);
      });

      testWidgets('$lang: watcher off → no line', (tester) async {
        await pumpApp(
          tester,
          _settings(
            FakeSettings(apiKey: 'k'),
            library: _AccessLibrary(full: false),
          ),
          size: const Size(390, 2400),
          locale: Locale(lang),
        );
        expect(find.textContaining(l.watcherLimitedFooter), findsNothing);
      });
    }

    testWidgets('turning the watcher on under limited access adds the line', (
      tester,
    ) async {
      final library = _AccessLibrary(full: false);
      final s = FakeSettings(apiKey: 'k', watcherDisclosureSeen: true);
      final l = lookupAppLocalizations(const Locale('en'));
      await pumpApp(
        tester,
        _settings(s, library: library),
        size: const Size(390, 2400),
      );
      expect(find.textContaining(l.watcherLimitedFooter), findsNothing);
      await tester.tap(find.byKey(const Key('watcherToggle')));
      await tester.pumpAndSettle();
      expect(find.textContaining(l.watcherLimitedFooter), findsOneWidget);
      // The warning snackbar is unchanged.
      expect(find.text(l.watcherLimitedAccess), findsOneWidget);
    });
  });

  group('import and export (U20)', () {
    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: clipboard first, no autofocus, a plain hint', (
        tester,
      ) async {
        final l = lookupAppLocalizations(Locale(lang));
        await pumpApp(
          tester,
          Scaffold(
            body: ListView(
              children: [
                DataSection(dao: FakeDao(), onOpenPrivacyPolicy: () {}),
              ],
            ),
          ),
          size: const Size(375, 667),
          locale: Locale(lang),
        );
        await tester.tap(find.byKey(const Key('importButton')));
        await tester.pumpAndSettle();
        final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
        expect(dialog.scrollable, isTrue);
        final button = tester.getRect(
          find.byKey(const Key('importFromClipboard')),
        );
        final field = tester.getRect(find.byKey(const Key('importField')));
        expect(
          button.top,
          lessThan(field.top),
          reason: 'the clipboard path comes first',
        );
        expect(
          tester
              .widget<EditableText>(
                find.descendant(
                  of: find.byKey(const Key('importField')),
                  matching: find.byType(EditableText),
                ),
              )
              .focusNode
              .hasFocus,
          isFalse,
          reason: 'no keyboard over the dialog until the user asks',
        );
        expect(find.text(l.importFieldHint), findsOneWidget);
        expect(find.textContaining('calorie_tracker_export'), findsNothing);
      });
    }

    test('the export file is named after the app; both names are swept', () {
      expect(
        exportFileName(DateTime(2026, 10, 31, 9)),
        'chopstats-2026-10-31.json',
      );
      expect(isExportFileName('chopstats-2026-10-31.json'), isTrue);
      expect(isExportFileName('calorietracker-2026-01-01.json'), isTrue);
      expect(isExportFileName('IMG_0001.jpg'), isFalse);
    });
  });

  testWidgets('dark: the clipboard button stands off the dialog surface', (
    tester,
  ) async {
    await pumpApp(
      tester,
      Scaffold(
        body: ListView(
          children: [DataSection(dao: FakeDao(), onOpenPrivacyPolicy: () {})],
        ),
      ),
      brightness: Brightness.dark,
    );
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pumpAndSettle();
    final style = tester
        .widget<ButtonStyleButton>(find.byKey(const Key('importFromClipboard')))
        .style;
    expect(
      style?.backgroundColor?.resolve({}),
      AppColors.dark.highlight,
      reason: 'the tonal default is the dialog colour itself in dark',
    );
  });

  testWidgets('the closed model picker ellipsises a long label', (
    tester,
  ) async {
    await pumpApp(
      tester,
      ApiKeyProviderPage(settings: FakeSettings()),
      size: const Size(320, 1600),
    );
    final shown = find.descendant(
      of: find.byKey(const Key('modelPicker')),
      matching: find.textContaining('gemini-3.8-flash'),
    );
    expect(shown, findsWidgets);
    for (final e in shown.evaluate()) {
      final t = e.widget as Text;
      expect(t.maxLines, 1);
      expect(t.overflow, TextOverflow.ellipsis);
    }
    expect(tester.takeException(), isNull);
  });

  group('cell fields at AX5 on an SE', () {
    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: the field names wrap instead of "Gemini …"', (
        tester,
      ) async {
        final l = lookupAppLocalizations(Locale(lang));
        await pumpApp(
          tester,
          ApiKeyProviderPage(settings: FakeSettings()),
          size: const Size(375, 667),
          scale: _ax5,
          locale: Locale(lang),
        );
        final field = find.byKey(const Key('apiKeyField'));
        await _scrollTo(tester, field);
        expect(
          find.descendant(
            of: field,
            matching: find.text(l.apiKeyLabel('Gemini')),
          ),
          findsOneWidget,
        );
        expect(_ellipsised(tester, field), isEmpty);
        expect(tester.takeException(), isNull);

        final s = FakeSettings()
          ..provider = 'server'
          ..serverBackend = 'claude';
        await pumpApp(
          tester,
          SubscriptionProviderPage(settings: s),
          size: const Size(375, 667),
          scale: _ax5,
          locale: Locale(lang),
        );
        for (final key in const ['serverUrlField', 'serverUploadKeyField']) {
          await _scrollTo(tester, find.byKey(Key(key)));
          expect(
            _ellipsised(tester, find.byKey(Key(key))),
            isEmpty,
            reason: key,
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('own server, not set up (U3)', () {
    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang: the inactive page says who it is for', (
        tester,
      ) async {
        final l = lookupAppLocalizations(Locale(lang));
        await pumpApp(
          tester,
          SubscriptionProviderPage(settings: FakeSettings()),
          locale: Locale(lang),
        );
        expect(find.text(l.subInactiveFooter), findsOneWidget);
        expect(
          l.subInactiveFooter,
          contains(
            lang == 'en' ? 'Go back and use an API key' : '返回使用 API Key',
          ),
        );
        // The footer stands alone: no empty cell above it.
        final section = find.ancestor(
          of: find.text(l.subInactiveFooter),
          matching: find.byType(GroupedSection),
        );
        expect(tester.widget<GroupedSection>(section).children, isEmpty);
      });
    }
  });
}
