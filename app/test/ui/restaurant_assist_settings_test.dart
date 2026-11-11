/// Settings › Restaurant nutrition and its consent sheets (design R7a; the
/// watcher_disclosure_test pattern): the sheet is shown once and names the
/// recipient chain; Not now keeps the assist Off; Brand only turns the
/// location off; the consent is stamped with the time and the CURRENT
/// recipient; a new recipient pauses the assist and asks again; a manual
/// lookup without consent asks first; the Off dialog can clear learned
/// places. The copy says what really leaves the phone: on iPhone the photo
/// location goes only to Apple Maps, the recipient gets chain and food
/// names, the own server gets location-derived names only over https, and
/// Claude Plan only suggests.
///
/// Settings › Stop Sharing with … (the AI consent's own row) also stops the
/// assist when its lookups go to that same company or server: the mode
/// goes Off and the assist's consent is forgotten, before the AI consent is
/// withdrawn, and the dialog says so. A different recipient is left alone.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/ai_consent.dart'
    show allAiConsentRoutes;
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart'
    show AssistWhereNow;
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/screens/settings/restaurant_section.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/widgets/restaurant_consent_sheet.dart';

import 'fakes.dart';

final DateTime _now = DateTime(2026, 10, 24, 12, 0);

const LookupSupport _plan = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: true,
  recipientHostTag: '0a1b2c3d',
);
const LookupSupport _planHttp = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: false,
  recipientHostTag: '0a1b2c3d',
);
const LookupSupport _anthropic = LookupSupport(
  supported: true,
  recipient: LookupRecipient.anthropic,
  locationAllowed: true,
);
const LookupSupport _openrouter = LookupSupport(
  supported: true,
  recipient: LookupRecipient.openrouter,
  locationAllowed: true,
);

/// The controls the tests drive: a mutable recipient, a count of clears.
class _Controls {
  _Controls(this.support,
      {this.location = true, this.server = AssistServerState.unknown});

  LookupSupport support;
  final bool location;
  AssistServerState server;

  /// What the phone's time zone and region say (MealAssist.whereNow).
  AssistWhereNow where = AssistWhereNow.us;
  int clears = 0;
  final ValueNotifier<LookupSupport?> consentNeeded =
      ValueNotifier<LookupSupport?>(null);

  RestaurantAssistControls get controls => RestaurantAssistControls(
        lookupSupport: () => support,
        clearLearnedPlaces: () async {
          clears++;
          return true;
        },
        consentNeeded: consentNeeded,
        serverState: () async => server,
        locationSupported: location,
        whereNow: () => where,
        now: () => _now,
      );
}

FakeSettings _planSettings({String url = 'https://bitewise.example.test'}) =>
    FakeSettings()
      ..provider = 'server'
      ..serverBackend = 'claude'
      ..serverBaseUrl = url
      ..apiKey = 'k';

void main() {
  setUp(debugResetRestaurantConsentSheet);

  Future<void> pump(WidgetTester tester, FakeSettings settings, _Controls c,
      {Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SettingsScreen(
          settings: settings,
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          requestPhotoPermission: () async => true,
          changes: settings,
          restaurantAssist: c.controls,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pickMode(WidgetTester tester, String mode) async {
    await tester.ensureVisible(find.byKey(const Key('restaurantModeRow')));
    await tester.tap(find.byKey(const Key('restaurantModeRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('restaurantMode-$mode')));
    await tester.pumpAndSettle();
  }

  Finder sheet() => find.byKey(const Key('restaurantConsentSheet'));
  Finder inSheet(String text) =>
      find.descendant(of: sheet(), matching: find.textContaining(text));
  String footer(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(
          of: find.byType(SettingsScreen), matching: find.byType(Text)))
      .map((t) => t.data ?? '')
      .firstWhere((t) => t.startsWith('When your AI is unsure') ||
          t.startsWith('当 AI 对餐厅餐'));

  // Review 2026-10-25 (device): with long content the sheet's title sat
  // right under the status bar.
  testWidgets('a tall consent sheet stays below the status bar',
      (tester) async {
    tester.view.physicalSize = const Size(390, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 640),
          padding: EdgeInsets.only(top: 47, bottom: 34),
          textScaler: TextScaler.linear(1.6),
        ),
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRestaurantConsentSheet(context,
                  kind: RestaurantConsentKind.enable,
                  support: _plan,
                  locationSupported: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final title = find.text('Look up restaurant nutrition?');
    expect(title, findsOneWidget);
    // The sheet's surface (its drag handle first) starts below the status
    // bar, so the title is never under it.
    expect(tester.getTopLeft(find.byType(BottomSheet)).dy,
        greaterThanOrEqualTo(47));
    expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(47 + 48));
  });

  group('the first enable', () {
    testWidgets('the sheet names the recipient chain; Not now keeps Off and '
        'stamps nothing', (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      expect(find.text('Restaurant nutrition'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('restaurantModeRow')),
              matching: find.text('Off')),
          findsOneWidget);

      await pickMode(tester, 'auto');
      expect(sheet(), findsOneWidget);
      expect(inSheet('Look up restaurant nutrition?'), findsOneWidget);
      // On iPhone the photo's location goes only to Apple Maps.
      expect(inSheet('asks Apple Maps which restaurants are nearby'),
          findsOneWidget);
      // The recipient chain, and what never leaves the phone.
      expect(
          inSheet('the country code US (only meals eaten in the US are looked '
              'up) and the reply language are sent to your own server (it '
              'uses Claude web search, by Anthropic), which searches the web'),
          findsOneWidget);
      expect(
          inSheet("While your phone's time zone is outside the US, nothing "
              'is looked up.'),
          findsOneWidget);
      // One "which" in the sentence: the recipient's name is a parenthesis.
      final sent = tester
          .widgetList<Text>(
              find.descendant(of: sheet(), matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .firstWhere((t) => t.contains('sent to your own server'));
      expect(RegExp(r'\bwhich\b').allMatches(sent), hasLength(1));
      expect(
          inSheet('The photo, its location, the city, the street and the '
              'distance are never sent.'),
          findsOneWidget);
      // The own server: the https rule, and suggestions only.
      expect(inSheet('only over https'), findsOneWidget);
      expect(inSheet('only suggests the chain'), findsOneWidget);
      expect(inSheet('replaces your AI'), findsNothing,
          reason: 'Claude Plan never changes numbers by itself as built');

      await tester.tap(find.byKey(const Key('restaurantConsentDecline')));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(find.text('Not now'), findsNothing);
      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentAt, isNull);
      expect(settings.restaurantAssistConsentRecipient, isNull);
    });

    testWidgets('Use location turns it on with the location, stamped with '
        'the time and the recipient', (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      await pickMode(tester, 'auto');
      await tester.tap(find.byKey(const Key('restaurantConsentUseLocation')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'auto');
      expect(settings.restaurantAssistLocation, isTrue);
      expect(settings.restaurantAssistConsentAt, _now);
      expect(settings.restaurantAssistConsentRecipient, 'claude_plan:0a1b2c3d');
      expect(settings.restaurantAssistUpdates, 1,
          reason: 'mode and consent in ONE write');
      expect(
          find.descendant(
              of: find.byKey(const Key('restaurantModeRow')),
              matching: find.text('When unsure')),
          findsOneWidget);
      final toggle = find.byKey(const Key('restaurantLocationToggle'));
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(find.byKey(const Key('restaurantPausedRow')), findsNothing);
    });

    testWidgets('Brand only turns it on with the location off',
        (tester) async {
      final settings = _planSettings();
      final c = _Controls(_anthropic);
      settings.provider = 'anthropic';
      await pump(tester, settings, c);
      await pickMode(tester, 'always');
      // A direct provider: applies when the chain's own site is clear.
      expect(inSheet("replaces your AI's numbers only when"), findsOneWidget);
      expect(inSheet('sent to Anthropic (Claude web search)'), findsOneWidget);
      expect(inSheet('only over https'), findsNothing,
          reason: 'the https rule is the own server\'s');
      await tester.tap(find.byKey(const Key('restaurantConsentBrandOnly')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'always');
      expect(settings.restaurantAssistLocation, isFalse);
      expect(settings.restaurantAssistConsentRecipient, 'anthropic');
      expect(
          tester
              .widget<Switch>(find.byKey(const Key('restaurantLocationToggle')))
              .value,
          isFalse);
      expect(footer(tester),
          contains('Brand only: uses brand names printed on cups'));
      expect(footer(tester),
          contains('Lookups go to Anthropic (Claude web search) with your key.'));
      // The sub-toggle turns the location on afterwards.
      await tester.tap(find.byKey(const Key('restaurantLocationToggle')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssistLocation, isTrue);
    });

    testWidgets('the sheet shows once: off and on again needs no sheet, but '
        'stamps a fresh consent time', (tester) async {
      final settings = _planSettings()
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = true
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'claude_plan:0a1b2c3d';
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      await pickMode(tester, 'off');
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentRecipient, 'claude_plan:0a1b2c3d',
          reason: 'Off keeps the consent; only a new recipient asks again');

      await pickMode(tester, 'always');
      expect(sheet(), findsNothing);
      expect(settings.restaurantAssist, 'always');
      expect(settings.restaurantAssistConsentAt, _now,
          reason: 'meals logged while it was off are not looked up');

      // When unsure ↔ Always keeps the consent time.
      settings.restaurantAssistConsentAt = DateTime(2026, 10, 2);
      await pickMode(tester, 'auto');
      expect(settings.restaurantAssist, 'auto');
      expect(settings.restaurantAssistConsentAt, DateTime(2026, 10, 2));
    });
  });

  group('the Off dialog', () {
    testWidgets('Also clear learned places and saved lookup answers clears '
        'them; Cancel keeps it on', (tester) async {
      final settings = _planSettings()
        ..restaurantAssist = 'auto'
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'claude_plan:0a1b2c3d';
      final c = _Controls(_plan);
      await pump(tester, settings, c);

      await pickMode(tester, 'off');
      expect(find.text('Turn off restaurant lookup?'), findsOneWidget);
      expect(find.text('Pending lookups are cancelled.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'auto');
      expect(c.clears, 0);

      await pickMode(tester, 'off');
      // The box names everything that one clear deletes on iOS: the
      // places, and the saved answers (with the lookups still waiting).
      expect(find.text('Also clear learned places and saved lookup answers'),
          findsOneWidget);
      expect(find.byKey(const Key('restaurantOffClearAnswers')), findsNothing);
      expect(
          tester
              .widget<CheckboxListTile>(
                  find.byKey(const Key('restaurantOffClearPlaces')))
              .value,
          isFalse,
          reason: 'unticked: the saved answers stay unless cleared');
      await tester.tap(find.byKey(const Key('restaurantOffClearPlaces')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
      expect(c.clears, 1);
    });

    testWidgets('Off without the box keeps what was learned', (tester) async {
      final settings = _planSettings()
        ..restaurantAssist = 'auto'
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'claude_plan:0a1b2c3d';
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      await pickMode(tester, 'off');
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
      expect(c.clears, 0);
    });

    testWidgets('Clear learned places asks first', (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      expect(find.byKey(const Key('clearSavedAnswersRow')), findsNothing,
          reason: 'iOS: Clear learned places clears the answers too');
      final row = find.byKey(const Key('clearLearnedPlacesRow'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Clear learned places?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.clears, 0);
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clearPlacesConfirm')));
      await tester.pumpAndSettle();
      expect(c.clears, 1);
      expect(find.text('Learned places cleared.'), findsOneWidget);
    });
  });

  group('a new recipient', () {
    testWidgets('pauses the assist: the paused row asks again and stamps the '
        'new recipient', (tester) async {
      final settings = _planSettings()
        ..provider = 'openrouter'
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = true
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(_openrouter);
      await pump(tester, settings, c);
      final paused = find.byKey(const Key('restaurantPausedRow'));
      expect(paused, findsOneWidget);
      expect(footer(tester), contains('Lookups are paused until you agree'));
      expect(
          footer(tester),
          contains('Lookups go to OpenRouter, which passes them on to the '
              'maker of the model you picked, and to its search partner '
              'Exa.'));
      await tester.ensureVisible(paused);
      await tester.tap(paused);
      await tester.pumpAndSettle();
      // OpenRouter answers with the model picked in Settings, so the sheet
      // names that model's maker too (RC 1.6.0 review, 2026-11-10).
      expect(
          inSheet('sent to OpenRouter (which passes them on to the maker of '
              'the model you picked) and its search partner Exa, which '
              'searches the web'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantConsentBrandOnly')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssistConsentRecipient, 'openrouter');
      expect(settings.restaurantAssistConsentAt, _now);
      expect(settings.restaurantAssistLocation, isFalse);
      expect(settings.restaurantAssist, 'auto', reason: 'the mode stays');
      expect(paused, findsNothing);
    });

    testWidgets('coming back from the AI provider page with another '
        'recipient asks at once', (tester) async {
      final settings = _planSettings()
        ..provider = 'anthropic'
        ..restaurantAssist = 'auto'
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(_anthropic);
      await pump(tester, settings, c);
      final section = tester.state<RestaurantAssistSectionState>(
          find.byType(RestaurantAssistSection));
      final before = section.currentRecipientStamp();
      expect(before, 'anthropic');
      // Nothing changed: no sheet.
      await section.promptIfRecipientChanged(before);
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      // The user picked OpenRouter on the provider page.
      settings.provider = 'openrouter';
      c.support = _openrouter;
      final asked = section.promptIfRecipientChanged(before);
      await tester.pumpAndSettle();
      expect(
          inSheet('OpenRouter (which passes them on to the maker of the model '
              'you picked) and its search partner Exa'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantConsentUseLocation')));
      await tester.pumpAndSettle();
      await asked;
      expect(settings.restaurantAssistConsentRecipient, 'openrouter');
    });

    testWidgets('another server is another recipient', (tester) async {
      final settings = _planSettings()
        ..restaurantAssist = 'always'
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'claude_plan:ffffffff';
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      expect(find.byKey(const Key('restaurantPausedRow')), findsOneWidget);
    });

    testWidgets('the app shell asks when the assist pauses, once per '
        'recipient, and never over another screen', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final settings = FakeSettings()
        ..provider = 'openrouter'
        ..apiKey = 'k'
        ..restaurantAssist = 'auto'
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(_openrouter);
      await tester.pumpWidget(CalorieTrackerApp(
          services:
              makeServices(settings: settings, restaurantAssist: c.controls)));
      await tester.pumpAndSettle();

      c.consentNeeded.value = _openrouter;
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantConsentDecline')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssistConsentRecipient, 'anthropic');

      // The assist asks again on its next sweep: not again this session.
      c.consentNeeded.value = null;
      c.consentNeeded.value = _openrouter;
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);

      // Over another screen (the editor, say) it waits for the next sweep.
      const plan = _plan;
      c.support = plan;
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('another screen')))));
      await tester.pumpAndSettle();
      c.consentNeeded.value = plan;
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);

      // A third recipient asks; Use location answers it.
      c.consentNeeded.value = null;
      c.consentNeeded.value = plan;
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantConsentUseLocation')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssistConsentRecipient, 'claude_plan:0a1b2c3d');
      expect(settings.restaurantAssistLocation, isTrue);

      // Off: the shell never asks.
      settings.restaurantAssist = 'off';
      c.support = _anthropic;
      c.consentNeeded.value = _anthropic;
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
    });
  });

  group('a manual lookup without consent', () {
    Future<BuildContext> host(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (context) {
          ctx = context;
          return const SizedBox.expand();
        })),
      ));
      return ctx;
    }

    testWidgets('shows the sheet with Cancel; Cancel looks nothing up',
        (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan);
      final ctx = await host(tester);
      final pending = restaurantManualLookupChoice(ctx,
          settings: settings, controls: c.controls);
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Not now'), findsNothing);
      await tester.tap(find.byKey(const Key('restaurantConsentDecline')));
      await tester.pumpAndSettle();
      expect(await pending, isNull);
      expect(settings.restaurantAssistConsentAt, isNull);
    });

    testWidgets('an answer stamps the consent but leaves the mode and the '
        'location setting alone; a covered consent asks nothing',
        (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan);
      final ctx = await host(tester);
      final pending = restaurantManualLookupChoice(ctx,
          settings: settings, controls: c.controls);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restaurantConsentUseLocation')));
      await tester.pumpAndSettle();
      expect((await pending)?.useLocation, isTrue);
      expect(settings.restaurantAssistConsentRecipient, 'claude_plan:0a1b2c3d');
      expect(settings.restaurantAssistConsentAt, _now);
      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistLocation, isFalse);

      final again = restaurantManualLookupChoice(ctx,
          settings: settings, controls: c.controls);
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect((await again)?.useLocation, isFalse,
          reason: 'the location setting decides once consent covers');
    });

    // The state the editor really shows this sheet in: the mode is on and
    // the consent names the recipient before (the assist is paused). The
    // answer un-pauses the automatic lookups for the new recipient, so
    // Brand only must not leave 'Use photo location' on from the old one.
    testWidgets('paused for a new recipient: Brand only also turns the '
        'location setting off, with the consent it stamps', (tester) async {
      final settings = FakeSettings()
        ..provider = 'openrouter'
        ..apiKey = 'k'
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = true
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(_openrouter);
      // What the engine would read at each change of the settings: never
      // the new consent together with the old location setting.
      final seen = <(String?, bool)>[];
      settings.addListener(() => seen.add((
            settings.restaurantAssistConsentRecipient,
            settings.restaurantAssistLocation,
          )));
      final ctx = await host(tester);
      final pending = restaurantManualLookupChoice(ctx,
          settings: settings, controls: c.controls);
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantConsentBrandOnly')));
      await tester.pumpAndSettle();
      expect((await pending)?.useLocation, isFalse);
      expect(settings.restaurantAssistConsentRecipient, 'openrouter');
      expect(settings.restaurantAssistConsentAt, _now);
      expect(settings.restaurantAssist, 'auto', reason: 'the mode stays');
      expect(settings.restaurantAssistLocation, isFalse,
          reason: 'Brand only is the only answer given about OpenRouter');
      expect(seen, [('openrouter', false)]);

      final again = restaurantManualLookupChoice(ctx,
          settings: settings, controls: c.controls);
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect((await again)?.useLocation, isFalse);
    });

    testWidgets('paused for a new recipient: Use location is for that one '
        'lookup and never turns the location setting on', (tester) async {
      final settings = FakeSettings()
        ..provider = 'openrouter'
        ..apiKey = 'k'
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = false
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(_openrouter);
      final ctx = await host(tester);
      final pending = restaurantManualLookupChoice(ctx,
          settings: settings, controls: c.controls);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restaurantConsentUseLocation')));
      await tester.pumpAndSettle();
      expect((await pending)?.useLocation, isTrue);
      expect(settings.restaurantAssistConsentRecipient, 'openrouter');
      expect(settings.restaurantAssistLocation, isFalse);
    });

    testWidgets('a recipient the app has no copy for cannot be consented to',
        (tester) async {
      final settings = FakeSettings()..provider = 'gemini';
      final c = _Controls(const LookupSupport.unsupported('needs_l1'));
      final ctx = await host(tester);
      expect(
          await restaurantManualLookupChoice(ctx,
              settings: settings, controls: c.controls),
          isNull);
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
    });
  });

  group('where the location cannot be used', () {
    testWidgets('an http own server: Use location disabled, brand only, '
        'with the https hint', (tester) async {
      final settings = _planSettings(url: 'http://bitewise.example.test')
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = true
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'claude_plan:0a1b2c3d';
      final c = _Controls(_planHttp);
      await pump(tester, settings, c);
      final toggle = find.byKey(const Key('restaurantLocationToggle'));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(tester.widget<Switch>(toggle).onChanged, isNull);
      expect(footer(tester),
          contains('Nearby-restaurant lookups need https on your server.'));

      // The sheet (a new server) offers Brand only.
      settings.restaurantAssistConsentRecipient = 'claude_plan:ffffffff';
      settings.notifyListeners();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('restaurantPausedRow')));
      await tester.tap(find.byKey(const Key('restaurantPausedRow')));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const Key('restaurantConsentUseLocation')))
              .onPressed,
          isNull);
      await tester.tap(find.byKey(const Key('restaurantConsentBrandOnly')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssistLocation, isFalse);
    });

    testWidgets('Android: no Apple Maps bullet, Use location disabled, no '
        'learned places; the saved answers can be cleared', (tester) async {
      final settings = _planSettings()..provider = 'anthropic';
      final c = _Controls(_anthropic, location: false);
      await pump(tester, settings, c);
      expect(find.byKey(const Key('clearLearnedPlacesRow')), findsNothing);
      expect(find.byKey(const Key('clearSavedAnswersRow')), findsOneWidget);
      await pickMode(tester, 'auto');
      expect(inSheet('Apple Maps'), findsNothing);
      expect(inSheet('does not read where the photo was taken'),
          findsOneWidget);
      expect(inSheet('The photo is never sent for this.'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const Key('restaurantConsentUseLocation')))
              .onPressed,
          isNull);
      await tester.tap(find.byKey(const Key('restaurantConsentBrandOnly')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'auto');
      expect(tester
          .widget<Switch>(find.byKey(const Key('restaurantLocationToggle')))
          .onChanged, isNull);
      expect(footer(tester),
          contains('On Android, lookups use printed brands only for now.'));
      await pickMode(tester, 'off');
      expect(find.byKey(const Key('restaurantOffClearPlaces')), findsNothing,
          reason: 'nothing is learned without a location');
      // Usual foods D16: the saved lookup answers can go with Off.
      final box = find.byKey(const Key('restaurantOffClearAnswers'));
      expect(box, findsOneWidget);
      expect(find.text('Also clear saved lookup answers'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(box).value, isFalse);
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(c.clears, 0, reason: 'unticked');
    });

    testWidgets('Android: Off with Also clear saved lookup answers clears '
        'them', (tester) async {
      final settings = FakeSettings()
        ..provider = 'anthropic'
        ..apiKey = 'k'
        ..restaurantAssist = 'auto'
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(_anthropic, location: false);
      await pump(tester, settings, c);
      await pickMode(tester, 'off');
      await tester.tap(find.byKey(const Key('restaurantOffClearAnswers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
      expect(c.clears, 1);
    });

    testWidgets('Android: Clear saved lookup answers asks first, then '
        'clears through the same clear (en, zh)', (tester) async {
      for (final (locale, title, body, done) in const [
        (
          Locale('en'),
          'Clear saved lookup answers?',
          'Chopstats forgets the restaurant nutrition it looked up and the '
              'lookups still waiting.',
          'Saved lookup answers cleared.',
        ),
        (
          Locale('zh'),
          '清除保存的查询结果？',
          '筷拍会忘记查到的餐厅营养信息和还在等待的查询。',
          '已清除保存的查询结果。',
        ),
      ]) {
        final settings = FakeSettings()
          ..provider = 'anthropic'
          ..apiKey = 'k';
        final c = _Controls(_anthropic, location: false);
        await pump(tester, settings, c, locale: locale);
        final row = find.byKey(const Key('clearSavedAnswersRow'));
        expect(
            find.descendant(
                of: row,
                matching: find.text(locale.languageCode == 'en'
                    ? 'Clear saved lookup answers'
                    : '清除保存的查询结果')),
            findsOneWidget);
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('clearAnswersDialog')), findsOneWidget);
        expect(find.text(title), findsOneWidget);
        expect(find.textContaining(body), findsOneWidget);
        await tester.tap(find.text(locale.languageCode == 'en' ? 'Cancel' : '取消'));
        await tester.pumpAndSettle();
        expect(c.clears, 0);
        await tester.tap(row);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('clearAnswersConfirm')));
        await tester.pumpAndSettle();
        expect(c.clears, 1);
        expect(find.text(done), findsOneWidget);
        // Let the snackbar go before the next locale.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    });
  });

  group('the footer', () {
    testWidgets('an unsupported provider: no way to turn it on, and why',
        (tester) async {
      final settings = FakeSettings()
        ..provider = 'gemini'
        ..apiKey = 'k';
      final c = _Controls(const LookupSupport.unsupported('needs_l1'));
      await pump(tester, settings, c);
      final row = find.byKey(const Key('restaurantModeRow'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('restaurantMode-auto')), findsNothing);
      expect(footer(tester), contains('Not available with Gemini yet.'));
    });

    testWidgets('Claude Plan without an address asks for one', (tester) async {
      final settings = _planSettings(url: '');
      final c = _Controls(const LookupSupport.unsupported(
          LookupUnsupportedReason.noServerAddress));
      await pump(tester, settings, c);
      expect(footer(tester), contains('Add your server address to use this.'));
    });

    for (final (state, line) in const [
      (AssistServerState.outdated,
          'Your server needs an update for this feature.'),
      (AssistServerState.disabled,
          'Restaurant lookup is turned off on your server.'),
    ]) {
      testWidgets('the own server says ${state.name}', (tester) async {
        final settings = _planSettings();
        final c = _Controls(_plan, server: state);
        await pump(tester, settings, c);
        expect(footer(tester), contains(line));
        expect(
            footer(tester),
            contains('Lookups go to your own server, which uses Claude web '
                'search (Anthropic).'));
        expect(footer(tester),
            contains('published numbers are only suggested'));
      });
    }

    // Review (run 6): lookups are for US meals only; say so where nothing
    // would be looked up on this phone as it is set now.
    testWidgets('US meals only, always; on Shanghai time, nothing is looked '
        'up', (tester) async {
      final settings = _planSettings()
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = true
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'claude_plan:0a1b2c3d';
      final c = _Controls(_plan, server: AssistServerState.ready);
      await pump(tester, settings, c);
      expect(footer(tester),
          contains('Only meals eaten in the US are looked up.'));
      expect(footer(tester), isNot(contains('time zone')));
      expect(footer(tester), isNot(contains('region')));

      c.where = AssistWhereNow.timeZone;
      settings.notifyListeners();
      await tester.pumpAndSettle();
      expect(footer(tester),
          contains("Your phone's time zone is outside the US, so nothing is "
              'looked up now'));

      // Off: the helper's US line only.
      settings.restaurantAssist = 'off';
      settings.notifyListeners();
      await tester.pumpAndSettle();
      expect(footer(tester), isNot(contains('time zone')));
    });

    testWidgets('a region other than the US: a hint only where no photo '
        'location can be used', (tester) async {
      final settings = _planSettings()
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = true
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'claude_plan:0a1b2c3d';
      final c = _Controls(_plan, server: AssistServerState.ready)
        ..where = AssistWhereNow.region;
      await pump(tester, settings, c);
      expect(footer(tester), isNot(contains("Your phone's region")),
          reason: 'a photo taken in the US can still be looked up');

      settings.restaurantAssistLocation = false;
      settings.notifyListeners();
      await tester.pumpAndSettle();
      expect(footer(tester),
          contains("Your phone's region is not the US and the photo's "
              'location is not used here, so nothing is looked up.'));

      // An http own server reads no location either.
      c.support = _planHttp;
      settings.restaurantAssistLocation = true;
      settings.serverBaseUrl = 'http://bitewise.example.test';
      settings.notifyListeners();
      await tester.pumpAndSettle();
      expect(footer(tester), contains("Your phone's region is not the US"));
    });

    testWidgets('Android with another region: the hint', (tester) async {
      final settings = FakeSettings()
        ..provider = 'anthropic'
        ..apiKey = 'k'
        ..restaurantAssist = 'auto'
        ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(_anthropic, location: false)
        ..where = AssistWhereNow.region;
      await pump(tester, settings, c);
      expect(footer(tester), contains('On Android, lookups use printed brands'));
      expect(footer(tester), contains("Your phone's region is not the US"));
    });

    // Usual foods D16: while a mode is on, the footer says found chain
    // answers are kept up to a year, right after who receives lookups.
    testWidgets('the saved answers line follows the recipient footnote while '
        'on, and is gone when Off or unsupported', (tester) async {
      final en = lookupAppLocalizations(const Locale('en'));
      final hint = en.restaurantSavedAnswersHint;
      for (final (support, android) in const [
        (_plan, false),
        (_anthropic, true),
      ]) {
        final settings = _planSettings()
          ..restaurantAssist = 'always'
          ..restaurantAssistLocation = true
          ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
          ..restaurantAssistConsentRecipient = support.recipientStamp;
        if (support == _anthropic) settings.provider = 'anthropic';
        final c = _Controls(support,
            location: !android, server: AssistServerState.ready);
        await pump(tester, settings, c);
        final lines = footer(tester).split('\n');
        final note = restaurantRecipientCopy(en, support.recipient)!.footnote;
        final at = lines.indexOf(note);
        expect(at, isNot(-1), reason: '$lines');
        expect(lines[at + 1], hint, reason: '$lines');
        expect(lines.where((l) => l == hint), hasLength(1));

        settings.restaurantAssist = 'off';
        settings.notifyListeners();
        await tester.pumpAndSettle();
        expect(footer(tester), isNot(contains(hint)), reason: 'Off');
      }

      final unsupported = FakeSettings()
        ..provider = 'gemini'
        ..apiKey = 'k'
        ..restaurantAssist = 'auto';
      await pump(tester, unsupported,
          _Controls(const LookupSupport.unsupported('needs_l1')));
      expect(footer(tester), isNot(contains(hint)), reason: 'unsupported');
    });

    testWidgets('a ready server adds no hint', (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan, server: AssistServerState.ready);
      await pump(tester, settings, c);
      expect(footer(tester), isNot(contains('needs an update')));
      expect(footer(tester), isNot(contains('turned off on your server')));
    });

    // Owner decision 2026-11-05: "When unsure" also looks up a restaurant
    // meal the AI was fairly sure about when a chain's brand is printed
    // (the auto_branding trigger). The footer's first line is where
    // Settings says when a lookup happens; the mode keeps its name.
    for (final (locale, phrase, helper, mode) in const [
      (
        Locale('en'),
        "fairly sure about one that shows a chain's brand",
        'When your AI is unsure about a restaurant meal, or fairly sure '
            "about one that shows a chain's brand on a cup, bag or receipt, "
            'Chopstats checks whether the chain publishes nutrition for it. '
            'Only meals eaten in the US are looked up.',
        'When unsure',
      ),
      (
        Locale('zh'),
        '比较有把握但杯子、袋子或小票上印有连锁品牌',
        '当 AI 对餐厅餐的估算没有把握，或者比较有把握但杯子、袋子或小票上印有连锁品牌时，'
            '筷拍会查看该连锁店是否公布了营养信息。只查询在美国吃的餐。',
        '不确定时',
      ),
    ]) {
      testWidgets('says when a lookup happens: the AI unsure, or fairly sure '
          'and a chain\'s brand printed ($locale)', (tester) async {
        final settings = _planSettings()
          ..restaurantAssist = 'auto'
          ..restaurantAssistLocation = true
          ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
          ..restaurantAssistConsentRecipient = 'claude_plan:0a1b2c3d';
        final c = _Controls(_plan, server: AssistServerState.ready);
        await pump(tester, settings, c, locale: locale);
        expect(footer(tester), contains(phrase));
        expect(footer(tester), startsWith(helper));
        expect(
            find.descendant(
                of: find.byKey(const Key('restaurantModeRow')),
                matching: find.text(mode)),
            findsOneWidget);

        // The same first line in every mode.
        for (final other in ['always', 'off']) {
          settings.restaurantAssist = other;
          settings.notifyListeners();
          await tester.pumpAndSettle();
          expect(footer(tester), startsWith(helper), reason: other);
        }
      });
    }
  });

  // The owner's requirement before PR #19 ships (docs/RELEASING.md):
  // Settings › Stop Sharing with … says "nothing more is sent to …", and no
  // lookup reads the AI consent — the assist has its own. So the row also
  // turns the assist Off, and forgets its consent, when its lookups go to
  // that same company or server (restaurantAssistStopFor).
  group('Stop Sharing with …', () {
    String bodyWithLookups(String provider) =>
        'Chopstats stops sending photos, meal text and restaurant lookups to '
        '$provider. Watch Camera Roll and restaurant lookups turn off, and '
        'pending lookups are cancelled. Meals already logged stay on this '
        'phone. Chopstats asks again before it sends anything to $provider.';
    String plainBody(String provider) =>
        'Chopstats stops sending photos and meal text to $provider, and '
        'Watch Camera Roll turns off. Meals already logged stay on this '
        'phone. The next time you use AI analysis, Chopstats asks again.';
    String doneWithLookups(String provider) =>
        'Stopped — nothing more is sent to $provider. Restaurant lookups are '
        'off.';
    String plainDone(String provider) =>
        'Stopped — nothing more is sent to $provider.';

    final consentAt = DateTime(2026, 10, 1);

    /// [provider] with the assist in [mode] and a consent stamped
    /// [consent] (null: never given).
    FakeSettings assist(String provider, String mode, String? consent) =>
        _planSettings()
          ..provider = provider
          ..apiKey = 'k'
          ..restaurantAssist = mode
          ..restaurantAssistLocation = true
          ..restaurantAssistConsentAt = consent == null ? null : consentAt
          ..restaurantAssistConsentRecipient = consent;

    Finder row() => find.byKey(const Key('aiStopSharingRow'));
    Finder dialog() => find.byKey(const Key('aiStopSharingDialog'));
    Finder modeValue(String label) => find.descendant(
        of: find.byKey(const Key('restaurantModeRow')),
        matching: find.text(label));

    Future<void> open(WidgetTester tester) async {
      await tester.ensureVisible(row());
      await tester.tap(row());
      await tester.pumpAndSettle();
      expect(dialog(), findsOneWidget);
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('aiStopSharingConfirm')));
      await tester.pumpAndSettle();
      expect(dialog(), findsNothing);
    }

    testWidgets('lookups go to the same company: the dialog says so; the '
        'assist goes Off and its consent is forgotten, in one write',
        (tester) async {
      final settings = assist('anthropic', 'auto', 'anthropic');
      final c = _Controls(_anthropic);
      await pump(tester, settings, c);
      expect(restaurantConsentCovers(settings, _anthropic), isTrue);
      expect(modeValue('When unsure'), findsOneWidget);

      await open(tester);
      expect(find.text('Stop sharing with Claude?'), findsOneWidget);
      expect(find.text(bodyWithLookups('Claude')), findsOneWidget);
      expect(find.text(plainBody('Claude')), findsNothing);
      await confirm(tester);

      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentAt, isNull);
      expect(settings.restaurantAssistConsentRecipient, isNull);
      expect(settings.restaurantAssistUpdates, 1,
          reason: 'Off and the forgotten consent in ONE write');
      expect(settings.restaurantAssistLocation, isTrue,
          reason: "'Use photo location' is kept: nothing is sent by it");
      expect(c.clears, 0, reason: 'the learned places are kept');
      expect(settings.aiConsentWrites, [('anthropic', false)]);
      expect(settings.hasAiConsent('anthropic'), isFalse);
      expect(settings.hasAiConsent('openrouter'), isTrue,
          reason: 'only the current recipient is withdrawn');
      expect(restaurantConsentCovers(settings, _anthropic), isFalse);
      expect(modeValue('Off'), findsOneWidget);
      expect(find.text(doneWithLookups('Claude')), findsOneWidget);
      expect(row(), findsNothing);
    });

    testWidgets('the own server, the same server: Off and forgotten, and '
        'Watch Camera Roll goes off as before', (tester) async {
      final settings = assist('server', 'always', 'claude_plan:0a1b2c3d')
        ..watcherEnabled = true
        ..watcherDisclosureSeen = true;
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      await open(tester);
      expect(find.text(bodyWithLookups('Claude (server)')), findsOneWidget);
      await confirm(tester);

      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentAt, isNull);
      expect(settings.restaurantAssistConsentRecipient, isNull);
      expect(settings.restaurantAssistUpdates, 1);
      expect(settings.hasAiConsent('server:claude'), isFalse);
      expect(settings.hasAiConsent('server:glm'), isTrue,
          reason: 'another plan on the server is another recipient');
      expect(settings.hasAiConsent('anthropic'), isTrue,
          reason: 'an Anthropic key is another recipient than the server');
      expect(settings.watcherEnabled, isFalse);
      expect(restaurantConsentCovers(settings, _plan), isFalse);
      expect(find.text(doneWithLookups('Claude (server)')), findsOneWidget);
    });

    testWidgets('the own server, a consent for another host of the same '
        'plan (the address changed): Off and forgotten', (tester) async {
      final settings = assist('server', 'auto', 'claude_plan:ffffffff');
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      expect(find.byKey(const Key('restaurantPausedRow')), findsOneWidget);
      await open(tester);
      expect(find.text(bodyWithLookups('Claude (server)')), findsOneWidget);
      await confirm(tester);

      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentAt, isNull);
      expect(settings.restaurantAssistConsentRecipient, isNull,
          reason: 'the AI consent is per plan: any host of it is forgotten');
      expect(settings.restaurantAssistUpdates, 1);
      expect(settings.hasAiConsent('server:claude'), isFalse);
      expect(find.text(doneWithLookups('Claude (server)')), findsOneWidget);
    });

    testWidgets('paused for this recipient (the consent names another '
        'one): Off, and that other consent is kept', (tester) async {
      final settings = assist('anthropic', 'auto', 'openrouter');
      final c = _Controls(_anthropic);
      await pump(tester, settings, c);
      expect(find.byKey(const Key('restaurantPausedRow')), findsOneWidget);
      await open(tester);
      expect(find.text(bodyWithLookups('Claude')), findsOneWidget);
      await confirm(tester);

      // Left on, the app shell would ask to consent to the recipient the
      // user just stopped.
      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentRecipient, 'openrouter');
      expect(settings.restaurantAssistConsentAt, consentAt);
      expect(settings.restaurantAssistUpdates, 1);
      expect(settings.hasAiConsent('anthropic'), isFalse);
      expect(restaurantConsentCovers(settings, _anthropic), isFalse);
      expect(find.byKey(const Key('restaurantPausedRow')), findsNothing);
      expect(find.text(doneWithLookups('Claude')), findsOneWidget);
    });

    testWidgets('a different recipient is left alone: no write, the mode '
        'and the consent stay, the plain dialog and snackbar',
        (tester) async {
      // Stop Sharing with Gemini, which gets no lookups; the assist's
      // consent names Anthropic.
      final settings = FakeSettings()
        ..provider = 'gemini'
        ..apiKey = 'k'
        ..restaurantAssist = 'auto'
        ..restaurantAssistLocation = true
        ..restaurantAssistConsentAt = consentAt
        ..restaurantAssistConsentRecipient = 'anthropic';
      final c = _Controls(const LookupSupport.unsupported('needs_l1'));
      await pump(tester, settings, c);
      await open(tester);
      expect(find.text(plainBody('Gemini')), findsOneWidget);
      expect(find.textContaining('restaurant lookups'), findsNothing);
      await confirm(tester);

      expect(settings.restaurantAssistUpdates, 0);
      expect(settings.restaurantAssist, 'auto');
      expect(settings.restaurantAssistConsentRecipient, 'anthropic');
      expect(settings.restaurantAssistConsentAt, consentAt);
      expect(settings.restaurantAssistLocation, isTrue);
      expect(settings.hasAiConsent('gemini'), isFalse);
      expect(settings.hasAiConsent('anthropic'), isTrue);
      expect(restaurantConsentCovers(settings, _anthropic), isTrue);
      expect(find.text(plainDone('Gemini')), findsOneWidget);
      expect(find.textContaining('Restaurant lookups are off'), findsNothing);
    });

    testWidgets('already Off with a consent for this recipient: the consent '
        'is forgotten, the plain copy; turning lookups on asks again',
        (tester) async {
      final settings = assist('anthropic', 'off', 'anthropic');
      final c = _Controls(_anthropic);
      await pump(tester, settings, c);
      await open(tester);
      expect(find.text(plainBody('Claude')), findsOneWidget,
          reason: 'nothing the user sees on is switched off');
      await confirm(tester);

      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentAt, isNull);
      expect(settings.restaurantAssistConsentRecipient, isNull);
      expect(settings.restaurantAssistUpdates, 1);
      expect(settings.hasAiConsent('anthropic'), isFalse);
      expect(find.text(plainDone('Claude')), findsOneWidget);

      // The mode row's own Off keeps the consent, so On again needs no
      // sheet ('the sheet shows once', above). After Stop Sharing the
      // sheet is shown again: a new, explicit consent.
      await pickMode(tester, 'always');
      expect(sheet(), findsOneWidget);
      expect(settings.restaurantAssist, 'off');
      await tester.tap(find.byKey(const Key('restaurantConsentDecline')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentRecipient, isNull);
    });

    testWidgets('after the stop, allowing AI analysis again does not turn '
        'lookups back on; turning them on asks', (tester) async {
      final settings = assist('anthropic', 'auto', 'anthropic');
      final c = _Controls(_anthropic);
      await pump(tester, settings, c);
      await open(tester);
      await confirm(tester);
      await settings.setAiConsent('anthropic', granted: true);
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
      expect(restaurantConsentCovers(settings, _anthropic), isFalse);
      expect(modeValue('Off'), findsOneWidget);

      await pickMode(tester, 'auto');
      expect(sheet(), findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantConsentBrandOnly')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'auto');
      expect(settings.restaurantAssistConsentRecipient, 'anthropic');
      expect(settings.restaurantAssistConsentAt, _now);
    });

    testWidgets('Cancel writes nothing', (tester) async {
      final settings = assist('anthropic', 'auto', 'anthropic');
      final c = _Controls(_anthropic);
      await pump(tester, settings, c);
      await open(tester);
      await tester.tap(find.descendant(
          of: dialog(), matching: find.text('Cancel')));
      await tester.pumpAndSettle();
      expect(dialog(), findsNothing);
      expect(settings.restaurantAssistUpdates, 0);
      expect(settings.aiConsentWrites, isEmpty);
      expect(settings.restaurantAssist, 'auto');
      expect(settings.restaurantAssistConsentRecipient, 'anthropic');
      expect(settings.hasAiConsent('anthropic'), isTrue);
      expect(row(), findsOneWidget);
    });

    // No lookup reads the AI consent: only the assist's own mode and
    // consent stop one. So they go first, and at no moment is the AI
    // consent withdrawn while lookups to that recipient are still on.
    testWidgets('the assist is stopped BEFORE the AI consent is withdrawn',
        (tester) async {
      final settings = assist('anthropic', 'auto', 'anthropic')
        ..watcherEnabled = true
        ..watcherDisclosureSeen = true;
      final c = _Controls(_anthropic);
      await pump(tester, settings, c);
      await open(tester);
      final seen = <({String mode, String? consent, bool ai, bool watcher})>[];
      settings.addListener(() => seen.add((
            mode: settings.restaurantAssist,
            consent: settings.restaurantAssistConsentRecipient,
            ai: settings.hasAiConsent('anthropic'),
            watcher: settings.watcherEnabled,
          )));
      await confirm(tester);

      // The first thing the settings say: the assist Off and its consent
      // forgotten, in one write, with the AI consent still standing.
      expect(seen, isNotEmpty);
      expect(seen.first,
          (mode: 'off', consent: null, ai: true, watcher: true));
      // At no notification is the AI consent withdrawn while lookups to
      // that recipient are still on, or still consented to.
      expect(
          seen.where((e) => !e.ai && (e.mode != 'off' || e.consent != null)),
          isEmpty);
      // Then the AI consent is withdrawn and Watch Camera Roll goes off.
      expect(seen.last.ai, isFalse);
      expect(seen.last.watcher, isFalse);
      expect(settings.aiConsentWrites, [('anthropic', false)]);
    });

    // The body is about half as long again. A bare Text in an AlertDialog
    // is squeezed and cut off, silently, when the dialog runs out of room
    // (a short screen, a large text size): the content scrolls instead.
    testWidgets('the longer body scrolls on a short screen instead of being '
        'cut off', (tester) async {
      final settings = assist('server', 'auto', 'claude_plan:0a1b2c3d');
      final c = _Controls(_plan);
      await pump(tester, settings, c);
      tester.view.physicalSize = const Size(800, 300);
      await tester.pumpAndSettle();
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(bodyWithLookups('Claude (server)')), findsOneWidget);
      final positions = tester
          .stateList<ScrollableState>(find.descendant(
              of: dialog(), matching: find.byType(Scrollable)))
          .map((s) => s.position)
          .toList();
      expect(positions, isNotEmpty,
          reason: 'the dialog content is a scroll view');
      expect(positions.any((p) => p.maxScrollExtent > 0), isTrue,
          reason: 'the rest of the text can be scrolled to');
      // The buttons stay on screen.
      await confirm(tester);
      expect(settings.restaurantAssist, 'off');
    });

    testWidgets('中文: the dialog and the snackbar', (tester) async {
      final settings = assist('server', 'auto', 'claude_plan:0a1b2c3d');
      final c = _Controls(_plan);
      await pump(tester, settings, c, locale: const Locale('zh'));
      await open(tester);
      expect(
          find.text('筷拍不再把照片、餐食文字和餐厅营养查询发送给 你服务器上的 Claude，'
              '「监控相册」和餐厅营养查询都会关闭，未完成的查询会被取消。'
              '已记录的餐食仍保存在这台手机上。再向 你服务器上的 Claude '
              '发送任何内容之前，筷拍会再次征求你的同意。'),
          findsOneWidget);
      await confirm(tester);
      expect(settings.restaurantAssist, 'off');
      expect(settings.restaurantAssistConsentRecipient, isNull);
      expect(find.text('已停止 — 不再向 你服务器上的 Claude 发送任何内容，餐厅营养查询已关闭。'),
          findsOneWidget);
    });
  });

  // The rule itself (the truth table in restaurant_consent_sheet.dart),
  // without a widget: R is the AI-consent route being withdrawn.
  group('restaurantAssistStopFor', () {
    final consentAt = DateTime(2026, 10, 1);
    FakeSettings state(String mode, String? consent) => FakeSettings()
      ..restaurantAssist = mode
      ..restaurantAssistLocation = true
      ..restaurantAssistConsentAt = consent == null ? null : consentAt
      ..restaurantAssistConsentRecipient = consent;
    RestaurantAssistControls reaching(LookupSupport support) =>
        _Controls(support).controls;
    final unreadable = RestaurantAssistControls(
      lookupSupport: () => throw StateError('no lookup router'),
      clearLearnedPlaces: () async => true,
    );
    const noAddress = LookupSupport.unsupported(
        LookupUnsupportedReason.noServerAddress);
    const noSearch =
        LookupSupport.unsupported(LookupUnsupportedReason.needsL1);
    const otherPlan = LookupSupport.unsupported(
        LookupUnsupportedReason.serverBackendNotClaude);

    const offAndForgotten = (turnOff: true, forgetConsent: true);
    const offOnly = (turnOff: true, forgetConsent: false);
    const forgottenOnly = (turnOff: false, forgetConsent: true);
    const untouched = (turnOff: false, forgetConsent: false);

    final rows = <(
      String,
      String mode,
      String? consent,
      RestaurantAssistControls? controls,
      String route,
      RestaurantAssistStop,
    )>[
      ('1: on, reaches R, the consent names R and covers', 'auto',
          'anthropic', reaching(_anthropic), 'anthropic', offAndForgotten),
      ('1: the same on the own server', 'always', 'claude_plan:0a1b2c3d',
          reaching(_plan), 'server:claude', offAndForgotten),
      ('2: on, reaches R, the consent names another host of the plan',
          'auto', 'claude_plan:ffffffff', reaching(_plan), 'server:claude',
          offAndForgotten),
      ('3: on, reaches R, the consent names another route', 'auto',
          'openrouter', reaching(_anthropic), 'anthropic', offOnly),
      ('3: on, reaches R, no consent at all', 'always', null,
          reaching(_openrouter), 'openrouter', offOnly),
      ('4: on, no lookup possible now, the consent names R', 'auto',
          'claude_plan:0a1b2c3d', reaching(noAddress), 'server:claude',
          offAndForgotten),
      ('5: on, lookups go elsewhere, the consent names another route',
          'auto', 'anthropic', reaching(noSearch), 'gemini', untouched),
      ('5: on, no lookup possible, no consent', 'auto', null,
          reaching(noSearch), 'gemini', untouched),
      ('5: another plan on the same server is another recipient', 'auto',
          'claude_plan:0a1b2c3d', reaching(otherPlan), 'server:glm',
          untouched),
      ('5: an Anthropic key is not the own server on the Claude plan',
          'auto', 'claude_plan:0a1b2c3d', reaching(_plan), 'anthropic',
          untouched),
      ('6: on, no controls (cannot be told): fails closed', 'auto',
          'openrouter', null, 'anthropic', offOnly),
      ('6: on, no controls, the consent names R', 'auto', 'anthropic', null,
          'anthropic', offAndForgotten),
      ('6: on, lookupSupport throws: fails closed', 'always', null,
          unreadable, 'gemini', offOnly),
      ('6: on, lookupSupport throws, the consent names R', 'auto',
          'openrouter', unreadable, 'openrouter', offAndForgotten),
      ('7: off, the consent names R', 'off', 'anthropic',
          reaching(_anthropic), 'anthropic', forgottenOnly),
      ('7: off, the consent names another host of the plan', 'off',
          'claude_plan:ffffffff', reaching(_plan), 'server:claude',
          forgottenOnly),
      ('7: off, the lookup client is not even asked', 'off', 'anthropic',
          unreadable, 'anthropic', forgottenOnly),
      ('8: off, the consent names another route', 'off', 'openrouter',
          reaching(_anthropic), 'anthropic', untouched),
      ('8: off, no consent, nothing to tell by', 'off', null, null,
          'anthropic', untouched),
    ];
    for (final (name, mode, consent, controls, route, want) in rows) {
      test(name, () {
        expect(restaurantAssistStopFor(state(mode, consent), controls, route),
            want);
      });
    }

    test('stopRestaurantAssistFor: one write (Off, the consent forgotten '
        'only when it names R), started before its first await', () async {
      final both = state('auto', 'anthropic');
      final stopping =
          stopRestaurantAssistFor(both, reaching(_anthropic), 'anthropic');
      // Not awaited yet: Settings already say Off and no consent.
      expect(both.restaurantAssist, 'off');
      expect(both.restaurantAssistConsentRecipient, isNull);
      expect(await stopping, offAndForgotten);
      expect(both.restaurantAssistUpdates, 1);
      expect(both.restaurantAssistConsentAt, isNull);
      expect(both.restaurantAssistLocation, isTrue);

      final kept = state('auto', 'openrouter');
      expect(
          await stopRestaurantAssistFor(
              kept, reaching(_anthropic), 'anthropic'),
          offOnly);
      expect(kept.restaurantAssistUpdates, 1);
      expect(kept.restaurantAssist, 'off');
      expect(kept.restaurantAssistConsentRecipient, 'openrouter');
      expect(kept.restaurantAssistConsentAt, consentAt);

      final forgotten = state('off', 'anthropic');
      expect(
          await stopRestaurantAssistFor(
              forgotten, reaching(_anthropic), 'anthropic'),
          forgottenOnly);
      expect(forgotten.restaurantAssistUpdates, 1);
      expect(forgotten.restaurantAssist, 'off');
      expect(forgotten.restaurantAssistConsentRecipient, isNull);

      final other = state('auto', 'anthropic');
      expect(
          await stopRestaurantAssistFor(other, reaching(noSearch), 'gemini'),
          untouched);
      expect(other.restaurantAssistUpdates, 0, reason: 'no write, no signal');
      expect(other.restaurantAssist, 'auto');
      expect(other.restaurantAssistConsentRecipient, 'anthropic');
    });

    // Every route × mode × stored consent × recipient a lookup would reach.
    test('afterwards no consent covers a recipient of the stopped route, a '
        'mode that reached it is Off, and anything else is left alone',
        () async {
      const supports = <LookupSupport>[
        _plan,
        _planHttp,
        _anthropic,
        _openrouter,
        LookupSupport(
            supported: true,
            recipient: LookupRecipient.openai,
            locationAllowed: true),
        LookupSupport(
            supported: true,
            recipient: LookupRecipient.xai,
            locationAllowed: true),
        noAddress,
      ];
      const stamps = <String?>[
        null,
        'anthropic',
        'openrouter',
        'openai',
        'xai',
        'claude_plan:0a1b2c3d',
        'claude_plan:ffffffff',
        'none',
        'bogus',
      ];
      var checked = 0;
      for (final route in allAiConsentRoutes) {
        for (final mode in const ['off', 'auto', 'always']) {
          for (final stamp in stamps) {
            for (final support in supports) {
              final settings = state(mode, stamp);
              final why = '$route | $mode | $stamp | '
                  '${support.recipientStamp}';
              final named = lookupRecipientOfStamp(stamp);
              final namesRoute =
                  named != null && lookupAiConsentRoute(named) == route;
              final reaches = mode != 'off' &&
                  support.supported &&
                  lookupAiConsentRoute(support.recipient) == route;
              final did = await stopRestaurantAssistFor(
                  settings, reaching(support), route);
              // P1: no consent is left for a recipient of the route.
              for (final s in supports) {
                if (lookupAiConsentRoute(s.recipient) == route) {
                  expect(restaurantConsentCovers(settings, s), isFalse,
                      reason: why);
                }
              }
              // P2: lookups that reached it, or were consented for it, are
              // Off.
              if (reaches || namesRoute) {
                expect(settings.restaurantAssist, 'off', reason: why);
              }
              // A different recipient: nothing is written at all.
              if (!reaches && !namesRoute) {
                expect(did, untouched, reason: why);
                expect(settings.restaurantAssistUpdates, 0, reason: why);
                expect(settings.restaurantAssist, mode, reason: why);
                expect(settings.restaurantAssistConsentRecipient, stamp,
                    reason: why);
              } else {
                expect(settings.restaurantAssistUpdates, 1, reason: why);
              }
              // A consent for another route is never forgotten.
              if (!namesRoute) {
                expect(settings.restaurantAssistConsentRecipient, stamp,
                    reason: why);
              }
              expect(settings.restaurantAssistLocation, isTrue, reason: why);
              checked++;
            }
          }
        }
      }
      expect(checked, allAiConsentRoutes.length * 3 * 9 * 7);
    });
  });

  group('中文', () {
    testWidgets('the group, the sheet and its buttons', (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan);
      await pump(tester, settings, c, locale: const Locale('zh'));
      expect(find.text('餐厅营养'), findsOneWidget);
      expect(find.text('查询餐厅营养'), findsOneWidget);
      expect(footer(tester), contains('查询会发送到你自己的服务器'));
      expect(footer(tester), contains('公布的数值只作为建议'));
      await pickMode(tester, 'auto');
      expect(inSheet('查找餐厅公布的营养？'), findsOneWidget);
      expect(inSheet('向 Apple 地图查询附近的餐厅'), findsOneWidget);
      expect(inSheet('发送给你自己的服务器（它使用 Anthropic 的 Claude 网页搜索）'),
          findsOneWidget);
      expect(inSheet('照片本身、拍摄位置、城市、街道和距离都不会发送'), findsOneWidget);
      expect(inSheet('只会通过 https 发送到你的服务器'), findsOneWidget);
      expect(inSheet('筷拍只会建议连锁店公布的数值'), findsOneWidget);
      expect(find.text('使用位置'), findsOneWidget);
      expect(find.text('仅按品牌'), findsOneWidget);
      expect(find.text('暂不'), findsOneWidget);
      await tester.tap(find.text('仅按品牌'));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'auto');
      expect(find.text('不确定时'), findsOneWidget);
      expect(find.text('使用照片位置'), findsOneWidget);
      await pickMode(tester, 'off');
      expect(find.text('关闭餐厅查询？'), findsOneWidget);
      expect(find.text('同时清除已记住的地点和保存的查询结果'), findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
    });
  });
}
