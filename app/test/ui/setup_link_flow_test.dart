// One-click setup (2026-09-28): a bitewise://setup link must be CONFIRMED
// before it changes where photos go, then land the user on Settings with
// the server configured. Malformed links are refused with a message.
import 'dart:async';

import 'package:calorie_tracker/core/setup_link.dart'
    show setupLinkRepeatWindow;
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/provider_names.dart'
    show providerDisplayLabel;
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const key = 'k1234567890abcdef';
  final good = Uri.parse(
      'bitewise://setup?server=http%3A%2F%2F10.0.0.7&key=$key&backend=claude');

  (UiServices, FakeSettings, StreamController<Uri>) rig() {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final links = StreamController<Uri>.broadcast();
    return (
      UiServices(
        dao: FakeDao(),
        analyzer: FakeAnalyzer(),
        executor: FakeExecutor(),
        settings: settings,
        picker: FakePicker(),
        requestPhotoPermission: () async => true,
        setupLinks: links.stream,
      ),
      settings,
      links,
    );
  }

  testWidgets('a valid link asks first, then configures the server',
      (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    expect(find.textContaining('http://10.0.0.7'), findsOneWidget);
    expect(find.textContaining('••••cdef'), findsOneWidget,
        reason: 'the key is shown masked, never in full');
    // The AI is named as Settings names it, not by the link's raw id, and
    // never as a 'Plan' (owner decision R-F5, 2026-10-29).
    expect(find.textContaining('AI: Claude (server)'), findsOneWidget);
    expect(find.textContaining(': claude'), findsNothing);
    expect(find.textContaining('Plan'), findsNothing);
    expect(settings.serverBaseUrl, isNot('http://10.0.0.7'),
        reason: 'nothing changes before confirmation');

    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.provider, 'server');
    expect(settings.serverBackend, 'claude');
    expect(settings.serverBaseUrl, 'http://10.0.0.7');
    expect(settings.apiKey, key);
    await links.close();
  });

  // The owner's phone is Chinese: the sheet read 套餐：claude (the raw
  // backend id) while the Settings row it lands on said Claude 订阅 (since
  // R-F5, 2026-10-29: AI：你服务器上的 Claude), and
  // its 12-glyph title wrapped to an orphaned 器？ on the iPhone 17 Pro
  // (loop find 2026-10-10). The id is still what gets saved.
  testWidgets('zh: the sheet names the plan as Settings does, title fits',
      (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomeShell(services: services),
    ));
    links.add(Uri.parse(
        'bitewise://setup?server=http%3A%2F%2F10.0.0.7&key=$key&backend=glm'));
    await tester.pumpAndSettle();
    expect(find.text('用此链接配置服务器？'), findsOneWidget);
    expect(find.textContaining('AI：你服务器上的 GLM'), findsOneWidget);
    expect(find.textContaining('：glm'), findsNothing);
    expect(find.textContaining('套餐'), findsNothing);

    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.serverBackend, 'glm',
        reason: 'the raw id is saved; only the sheet shows the label');
    await links.close();
  });

  testWidgets('cancel leaves settings untouched', (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.apiKey, 'old');
    expect(settings.serverBaseUrl, isNot('http://10.0.0.7'));
    await links.close();
  });

  testWidgets('a malformed link is refused, not guessed', (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(Uri.parse('bitewise://setup?server=ftp%3A%2F%2Fx&key=$key'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
    expect(find.text('That setup link is not valid.'), findsOneWidget);
    expect(settings.apiKey, 'old');
    await links.close();
  });

  testWidgets('a cold-start link is handled too', (tester) async {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      initialSetupLink: () async => good,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
  });

  // Review 2026-10-25: app_links' stream also carries the link that
  // cold-started the app, which the initial-link read delivered already —
  // two confirmations for one link (simctl openurl on a cold start).
  testWidgets('a cold-start link that the stream repeats asks once',
      (tester) async {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final links = StreamController<Uri>.broadcast();
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      setupLinks: links.stream,
      initialSetupLink: () async => good,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing,
        reason: 'no second dialog behind the first');
    expect(settings.apiKey, key);
    await links.close();
  });

  testWidgets('the same link opened again later asks again', (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // The window is measured on the wall clock.
    await tester.runAsync(() => Future<void>.delayed(
        setupLinkRepeatWindow + const Duration(milliseconds: 50)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    expect(settings.apiKey, 'old');
    await links.close();
  });

  // iOS share sheet: receive_sharing_intent bounces the extension to the
  // host app by opening `ShareMedia-<bundle>:share`, and app_links forwards
  // that URL to us too. It is not a setup link; it must not produce the
  // "not valid" snackbar (seen on every share before this test existed).
  final shareBounce =
      Uri.parse('ShareMedia-dev.calorietracker.calorieTracker:share');

  testWidgets('the share-extension bounce URL is ignored silently (warm)',
      (tester) async {
    final (services, settings, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(shareBounce);
    await tester.pumpAndSettle();
    expect(find.text('That setup link is not valid.'), findsNothing);
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
    expect(settings.apiKey, 'old');
    await links.close();
  });

  testWidgets('the share-extension bounce URL is ignored silently (cold)',
      (tester) async {
    final settings = FakeSettings(apiKey: 'old', watcherEnabled: false);
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      initialSetupLink: () async => shareBounce,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    await tester.pumpAndSettle();
    expect(find.text('That setup link is not valid.'), findsNothing);
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
    expect(settings.apiKey, 'old');
  });

  // Android push (ui lane, sweep C12): confirming a link while Watch
  // Camera Roll is on sends every new library photo, non-food included, to
  // the new server from then on, yet the dialog never said so (the
  // recipient-change dialog does). Every case above has the watcher off.
  group('with Watch Camera Roll on', () {
    (UiServices, FakeSettings, StreamController<Uri>) watching(
        {int lookbackDays = 3}) {
      final settings = FakeSettings(
          apiKey: 'old', watcherEnabled: true, lookbackDays: lookbackDays);
      final links = StreamController<Uri>.broadcast();
      return (
        UiServices(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          executor: FakeExecutor(),
          settings: settings,
          picker: FakePicker(),
          requestPhotoPermission: () async => true,
          setupLinks: links.stream,
        ),
        settings,
        links,
      );
    }

    // The dialog's body: the one text that shows the masked key.
    String dialogText(WidgetTester tester) => tester
        .widgetList<Text>(find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .singleWhere((t) => t.contains('••••'));

    testWidgets('the camera-roll notice leads, as in the recipient-change '
        'dialog', (tester) async {
      final (services, settings, links) = watching();
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      links.add(good);
      await tester.pumpAndSettle();
      final l = AppLocalizationsEn();
      final notice = l.watcherDisclosureBody(
          providerDisplayLabel(l, 'server', 'claude'), 3);
      final text = dialogText(tester);
      expect(text, startsWith(notice));
      expect(text.indexOf(notice), lessThan(text.indexOf('Server: ')));
      expect(text, contains(l.setupLinkSharing(
          l.aiConsentPlanCompany('claude'))));

      await tester.tap(find.byKey(const Key('setupLinkConfirm')));
      await tester.pumpAndSettle();
      expect(settings.provider, 'server');
      expect(settings.watcherEnabled, isTrue);
      await links.close();
    });

    testWidgets('zh: the notice names the plan as Settings does',
        (tester) async {
      final (services, _, links) = watching(lookbackDays: 45);
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomeShell(services: services),
      ));
      links.add(Uri.parse('bitewise://setup?server=https%3A%2F%2Fmy.example'
          '&key=$key&backend=glm'));
      await tester.pumpAndSettle();
      final l = AppLocalizationsZh();
      // The lookback is clamped to 30 days, as the switch's notice is.
      expect(
          dialogText(tester),
          startsWith(l.watcherDisclosureBody(
              providerDisplayLabel(l, 'server', 'glm'), 30)));
      await links.close();
    });

    testWidgets('cancel still changes nothing', (tester) async {
      final (services, settings, links) = watching();
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      links.add(good);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.apiKey, 'old');
      expect(settings.provider, isNot('server'));
      await links.close();
    });
  });

  testWidgets('with the watcher off there is no camera-roll notice',
      (tester) async {
    final (services, _, links) = rig();
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    links.add(good);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('Watch Camera Roll')),
        findsNothing);
    await links.close();
  });

  // A plain-http server gets photos, meal text and the upload key over an
  // unencrypted connection; the dialog says so (the privacy lane's
  // kRequireHttpsServer decides whether such a link is taken at all).
  group('the plain-http line', () {
    final l = AppLocalizationsEn();

    testWidgets('an http:// server: the dialog says it needs https',
        (tester) async {
      final (services, _, links) = rig();
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      links.add(good);
      await tester.pumpAndSettle();
      expect(find.textContaining(l.setupLinkCleartext), findsOneWidget);
      await links.close();
    });

    testWidgets('an https:// server: no such line', (tester) async {
      final (services, _, links) = rig();
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      links.add(Uri.parse('bitewise://setup?server=https%3A%2F%2Fmy.example'
          '&key=$key&backend=claude'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('http://')),
          findsNothing);
      expect(find.textContaining(l.setupLinkCleartext), findsNothing);
      await links.close();
    });

    testWidgets('an HTTP:// server in capitals is plain http too',
        (tester) async {
      final (services, _, links) = rig();
      await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
      links.add(Uri.parse('bitewise://setup?server=HTTP%3A%2F%2F10.0.0.7'
          '&key=$key&backend=claude'));
      await tester.pumpAndSettle();
      expect(find.textContaining(l.setupLinkCleartext), findsOneWidget);
      await links.close();
    });

    testWidgets('zh: the line is Chinese', (tester) async {
      final (services, _, links) = rig();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomeShell(services: services),
      ));
      links.add(good);
      await tester.pumpAndSettle();
      expect(find.textContaining(AppLocalizationsZh().setupLinkCleartext),
          findsOneWidget);
      await links.close();
    });
  });
}
