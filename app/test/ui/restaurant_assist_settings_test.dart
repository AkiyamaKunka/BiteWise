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
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
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
          inSheet('sent to your own server, which uses Claude web search '
              '(Anthropic)'),
          findsOneWidget);
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
    testWidgets('Also clear learned places clears them; Cancel keeps it on',
        (tester) async {
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
      await tester.tap(find.byKey(const Key('restaurantOffClearPlaces')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
      expect(c.clears, 1);
    });

    testWidgets('Clear learned places asks first', (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan);
      await pump(tester, settings, c);
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
      await tester.ensureVisible(paused);
      await tester.tap(paused);
      await tester.pumpAndSettle();
      expect(inSheet('sent to OpenRouter and its search partner Exa'),
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
      expect(inSheet('OpenRouter and its search partner Exa'), findsOneWidget);
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

    testWidgets('a recipient BiteWise has no copy for cannot be consented to',
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
        'learned places', (tester) async {
      final settings = _planSettings()..provider = 'anthropic';
      final c = _Controls(_anthropic, location: false);
      await pump(tester, settings, c);
      expect(find.byKey(const Key('clearLearnedPlacesRow')), findsNothing);
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
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
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

    testWidgets('a ready server adds no hint', (tester) async {
      final settings = _planSettings();
      final c = _Controls(_plan, server: AssistServerState.ready);
      await pump(tester, settings, c);
      expect(footer(tester), isNot(contains('needs an update')));
      expect(footer(tester), isNot(contains('turned off on your server')));
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
      expect(find.text('同时清除已记住的地点'), findsOneWidget);
      await tester.tap(find.byKey(const Key('restaurantOffConfirm')));
      await tester.pumpAndSettle();
      expect(settings.restaurantAssist, 'off');
    });
  });
}
