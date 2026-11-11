// RC 1.6.0: the restaurant lookup's sheets and dialogs at the largest
// text sizes, on a 320-375 pt phone and on a phone in landscape, with the
// iPhone's own fonts (the method of large_text_overflow_test.dart; macOS
// only, skipped elsewhere). Before the fixes:
//   * the mode picker (Off / When unsure / Always) could not scroll: from
//     AX4 on a 390 pt phone 'Always' was below the screen, at AX5 on a 320
//     pt phone every mode was, and in landscape 'Always' showed 12 px. The
//     language, units and plan pickers had the same sheet;
//   * the consent sheet pinned its title and three buttons, so at AX5 the
//     disclosure got 0-13 px (on 320x568 'Not now' was below the screen);
//   * 'Which restaurant?' pinned its title and search field over the list,
//     so with the keyboard up the list got 0 px (AX5, 320 pt) or 16 px
//     (landscape);
//   * the 'Use the published numbers?', Clear and Off dialogs pinned their
//     titles: the new total was cut off (or its box squeezed to nothing,
//     which throws no overflow), and at AX5 on 320x568 the confirm button
//     of the accept and Off dialogs was below the screen.
import 'dart:io';
import 'dart:typed_data';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart'
    show LookupRecipient, LookupSupport;
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/settings/restaurant_section.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/widgets/chain_picker_sheet.dart';
import 'package:calorie_tracker/ui/widgets/restaurant_consent_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import '../support/assist_fixtures.dart';
import 'fakes.dart';

const sfPath = '/System/Library/Fonts/SFNS.ttf';
const cjkPath = '/System/Library/Fonts/Hiragino Sans GB.ttc';
final haveIphoneFonts = File(sfPath).existsSync() && File(cjkPath).existsSync();

Future<void> loadFont(String family, String path) async {
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

const LookupSupport plan = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: true,
  recipientHostTag: '0a1b2c3d',
);
const LookupSupport anthropic = LookupSupport(
  supported: true,
  recipient: LookupRecipient.anthropic,
  locationAllowed: true,
);

/// A phone: its size, status bar / home indicator, and text size.
typedef Phone = (String name, Size size, EdgeInsets pad, double scale);

const Phone ax5se1 = ('AX5 320x568', Size(320, 568), EdgeInsets.only(top: 20), 3.1);
const Phone ax4se1 =
    ('AX4 320x568', Size(320, 568), EdgeInsets.only(top: 20), 2.76);
const Phone ax5se2 = ('AX5 375x667', Size(375, 667), EdgeInsets.only(top: 20), 3.1);
const Phone ax3se2 =
    ('AX3 375x667', Size(375, 667), EdgeInsets.only(top: 20), 2.35);
const Phone ax4x =
    ('AX4 390x844', Size(390, 844), EdgeInsets.only(top: 47, bottom: 34), 2.76);
const Phone ax5x =
    ('AX5 390x844', Size(390, 844), EdgeInsets.only(top: 47, bottom: 34), 3.1);
// Android (no orientation lock): a 360x640 phone turned sideways.
const Phone landscape =
    ('landscape 640x360', Size(640, 360), EdgeInsets.only(top: 24), 1.0);

AppLocalizations l(String lang) => lookupAppLocalizations(Locale(lang));

void main() {
  setUp(debugResetRestaurantConsentSheet);

  Future<void> pumpAt(
    WidgetTester tester,
    String lang,
    Phone phone,
    Widget home,
  ) async {
    final (_, size, pad, scale) = phone;
    final padding = FakeViewPadding(top: pad.top, bottom: pad.bottom);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(lang),
        theme: ThemeData(
          fontFamily: 'AxSF',
          fontFamilyFallback: const ['AxHiragino'],
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every pending overflow / layout exception, as one string ('' = none).
  String drain(WidgetTester tester) {
    final out = <String>[];
    Object? e;
    while ((e = tester.takeException()) != null) {
      out.add('$e'.split('\n').first);
    }
    return out.join(' | ');
  }

  /// [finder] lies fully on the screen of [phone].
  void expectOnScreen(WidgetTester tester, Finder finder, Phone phone,
      {required String reason}) {
    final (_, size, pad, _) = phone;
    final r = tester.getRect(finder);
    expect(r.top, greaterThanOrEqualTo(-0.5), reason: reason);
    expect(r.bottom, lessThanOrEqualTo(size.height - pad.bottom + 0.5),
        reason: reason);
  }

  /// The first scroll view inside [of], jumped to its end.
  Future<void> scrollToEnd(WidgetTester tester, Finder of) async {
    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: of, matching: find.byType(Scrollable)).first);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
  }

  Widget opener(Future<void> Function(BuildContext) open) => Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      );

  Widget section(FakeSettings settings) => Scaffold(
        body: ListView(children: [
          RestaurantAssistSection(
            settings: settings,
            controls: RestaurantAssistControls(
              lookupSupport: () => anthropic,
              clearLearnedPlaces: () async => true,
              locationSupported: true,
            ),
          ),
        ]),
      );

  group('restaurant sheets and dialogs, small phone / large text / landscape',
      () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadFont('AxSF', sfPath);
      await loadFont('AxHiragino', cjkPath);
    });

    for (final (lang, phone) in const [
      ('en', ax5se1),
      ('zh', ax5se1),
      ('en', ax4x),
      ('en', ax5x),
      ('zh', ax5x),
      ('en', landscape),
    ]) {
      testWidgets('mode picker, $lang, ${phone.$1}: Always can be reached and '
          'chosen', (tester) async {
        final settings = FakeSettings()
          ..provider = 'anthropic'
          ..apiKey = 'k';
        await pumpAt(tester, lang, phone, section(settings));
        expect(drain(tester), '');
        await tester.ensureVisible(find.byKey(const Key('restaurantModeRow')));
        await tester.tap(find.byKey(const Key('restaurantModeRow')));
        await tester.pumpAndSettle();
        expect(drain(tester), '', reason: 'the picker sheet overflowed');
        final always = find.byKey(const Key('restaurantMode-always'));
        await tester.ensureVisible(always);
        await tester.pumpAndSettle();
        expectOnScreen(tester, always, phone,
            reason: "'Always' cannot be brought on screen");
        await tester.tap(always);
        await tester.pumpAndSettle();
        // Always asks for the consent first.
        expect(find.byKey(const Key('restaurantConsentSheet')), findsOneWidget);
        expect(drain(tester), '');
      });
    }

    testWidgets('language picker, en, ${landscape.$1}: every language can be '
        'reached', (tester) async {
      final settings = FakeSettings(apiKey: 'k');
      await pumpAt(
        tester,
        'en',
        landscape,
        SettingsScreen(
          settings: settings,
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          requestPhotoPermission: () async => true,
        ),
      );
      drain(tester);
      final row = find.byKey(const Key('languageRow'));
      await tester.scrollUntilVisible(row, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(drain(tester), '', reason: 'the language sheet overflowed');
      final zh = find.byKey(const Key('language-zh'));
      await tester.ensureVisible(zh);
      await tester.pumpAndSettle();
      expectOnScreen(tester, zh, landscape,
          reason: "'中文' cannot be brought on screen");
      await tester.tap(zh);
      await tester.pumpAndSettle();
      expect(settings.appLanguage, 'zh');
    });

    for (final (lang, phone) in const [
      ('en', ax5se1),
      ('zh', ax5se1),
      ('en', ax4se1),
      ('en', ax5se2),
      ('zh', ax5se2),
      ('en', ax5x),
      ('en', landscape),
    ]) {
      testWidgets('consent sheet, $lang, ${phone.$1}: the disclosure has room '
          'and every button is on screen', (tester) async {
        await pumpAt(
          tester,
          lang,
          phone,
          opener((context) => showRestaurantConsentSheet(context,
              kind: RestaurantConsentKind.enable,
              support: plan,
              locationSupported: true)),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(drain(tester), '', reason: 'the consent sheet overflowed');
        for (final k in const [
          'restaurantConsentUseLocation',
          'restaurantConsentBrandOnly',
          'restaurantConsentDecline',
        ]) {
          expectOnScreen(tester, find.byKey(Key(k)), phone,
              reason: '$k is below the screen');
        }
        // One line of body text is 14 * 1.43 * scale high; at least two
        // lines of the disclosure show at once (one at 1.0x landscape is
        // far more than two lines).
        final viewport = tester
            .getSize(find.byKey(const Key('restaurantConsentScroll')))
            .height;
        expect(viewport, greaterThanOrEqualTo(14 * 1.43 * phone.$4 * 2),
            reason: 'the disclosure gets less than two lines of room');
        // Its last bullet can be scrolled to its end, above the buttons.
        final last = find.text(l(lang).restaurantConsentOff);
        await scrollToEnd(tester, find.byKey(const Key('restaurantConsentScroll')));
        expect(
            tester.getRect(last).bottom,
            lessThanOrEqualTo(tester
                    .getRect(
                        find.byKey(const Key('restaurantConsentUseLocation')))
                    .top +
                0.5));
      });
    }

    for (final (lang, phone, keyboard) in const [
      ('en', ax5se1, 253.0),
      ('zh', ax5se1, 253.0),
      ('en', ax5x, 336.0),
      ('en', landscape, 200.0),
    ]) {
      testWidgets('chain picker, $lang, ${phone.$1}, keyboard up: a chain '
          'can be picked', (tester) async {
        String? picked;
        await pumpAt(
          tester,
          lang,
          phone,
          opener((context) async => picked = await showChainPickerSheet(context)),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        // The field autofocuses: the keyboard comes up.
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(drain(tester), '', reason: 'the chain picker overflowed');
        await tester.enterText(
            find.byKey(const Key('chainPickerSearch')), 'burger');
        await tester.pumpAndSettle();
        expect(drain(tester), '');
        final row = find.byKey(const Key('chainPick-burger_king'));
        await tester.scrollUntilVisible(row, 100,
            // The first: the search field has a Scrollable of its own.
            scrollable: find
                .descendant(
                    of: find.byKey(const Key('chainPickerList')),
                    matching: find.byType(Scrollable))
                .first);
        await tester.pumpAndSettle();
        final r = tester.getRect(row);
        final field = tester.getRect(find.byKey(const Key('chainPickerSearch')));
        final keyboardTop = phone.$2.height - keyboard;
        expect(keyboardTop - field.bottom, greaterThanOrEqualTo(r.height),
            reason: 'no room for one whole row between the search field '
                'and the keyboard');
        expect(r.center.dy, inInclusiveRange(field.bottom, keyboardTop),
            reason: 'the row is under the search field or the keyboard');
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(picked, 'burger_king');
      });
    }

    for (final (lang, phone) in const [
      ('en', ax5se1),
      ('zh', ax5se1),
      ('en', ax3se2),
      ('en', ax4x),
      ('en', ax5x),
      ('en', landscape),
    ]) {
      testWidgets('accept dialog, $lang, ${phone.$1}: the new total can be '
          'read and the confirm button is on screen', (tester) async {
        final dao = FakeDao()..seed(assistMeal(suggestedFriesSizes()));
        await pumpAt(
          tester,
          lang,
          phone,
          MealEditorScreen(
            dao: dao,
            meal: dao.meals.first,
            now: () => DateTime(2026, 10, 24, 19, 5),
            assist: FakeAssist(dao).controls(),
            settings: FakeSettings()
              ..restaurantAssist = 'auto'
              ..restaurantAssistConsentAt = DateTime(2026, 10, 24)
              ..restaurantAssistConsentRecipient = 'anthropic',
          ),
        );
        expect(drain(tester), '', reason: 'the editor itself');
        final use = find.byKey(const Key('assistUsePublished'));
        await tester.ensureVisible(use);
        await tester.pumpAndSettle();
        await tester.tap(use);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('assistAcceptConfirm')), findsOneWidget);
        // A content box squeezed to nothing throws no overflow: where the
        // total and the buttons are is checked too.
        expect(drain(tester), '', reason: 'the accept dialog overflowed');
        final ok = find.byKey(const Key('assistAcceptConfirmOk'));
        expectOnScreen(tester, ok, phone,
            reason: 'the confirm button is below the screen');
        final total = find.textContaining(
            lang == 'zh' ? '这餐的总热量将变为' : "This meal's total will be");
        // Scrolled to its end (at AX5 on a 320 pt phone the line alone is
        // taller than the room above the buttons).
        await scrollToEnd(
            tester, find.byKey(const Key('assistAcceptConfirm')));
        final cancel = find.descendant(
            of: find.byKey(const Key('assistAcceptConfirm')),
            matching: find.byType(TextButton));
        final buttonsTop = [tester.getRect(ok).top, tester.getRect(cancel).top]
            .reduce((a, b) => a < b ? a : b);
        final t = tester.getRect(total);
        expect(t.bottom, lessThanOrEqualTo(buttonsTop + 0.5),
            reason: 'the new total is drawn under or past the buttons');
        expect(t.bottom, greaterThan(0),
            reason: 'the new total is above the screen');
        await tester.tap(ok);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('assistAcceptConfirm')), findsNothing);
      });
    }

    for (final (lang, phone) in const [
      ('en', ax5se1),
      ('zh', ax5se1),
      ('en', ax5x),
    ]) {
      testWidgets('Clear and Off dialogs, $lang, ${phone.$1}: the confirm '
          'button is on screen', (tester) async {
        final settings = FakeSettings()
          ..provider = 'anthropic'
          ..apiKey = 'k'
          ..restaurantAssist = 'auto'
          ..restaurantAssistConsentAt = DateTime(2026, 10, 24)
          ..restaurantAssistConsentRecipient = 'anthropic';
        await pumpAt(tester, lang, phone, section(settings));
        expect(drain(tester), '');
        final clear = find.byKey(const Key('clearLearnedPlacesRow'));
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(drain(tester), '', reason: 'the Clear dialog overflowed');
        expectOnScreen(tester, find.byKey(const Key('clearPlacesConfirm')),
            phone,
            reason: 'Clear is below the screen');
        await tester.tap(find.descendant(
            of: find.byKey(const Key('clearPlacesDialog')),
            matching: find.byType(TextButton)));
        await tester.pumpAndSettle();

        final state = tester.state<RestaurantAssistSectionState>(
            find.byType(RestaurantAssistSection));
        // ignore: unawaited_futures
        state.setMode('off');
        await tester.pumpAndSettle();
        expect(drain(tester), '', reason: 'the Off dialog overflowed');
        final ok = find.byKey(const Key('restaurantOffConfirm'));
        expectOnScreen(tester, ok, phone,
            reason: 'Turn off is below the screen');
        await tester.tap(ok);
        await tester.pumpAndSettle();
        expect(settings.restaurantAssist, 'off');
      });
    }
  }, skip: haveIphoneFonts ? false : 'needs the macOS system fonts');
}
