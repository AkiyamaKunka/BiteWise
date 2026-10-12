// One-click setup (2026-09-28): a bitewise://setup link must be CONFIRMED
// before it changes where photos go, then land the user on Settings with
// the server configured. Malformed links are refused with a message.
import 'dart:async';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/app.dart';
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
        reports: FakeReports(),
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
    // The plan is named as Settings names it, not by the link's raw id.
    expect(find.textContaining('Plan: Claude Plan'), findsOneWidget);
    expect(find.textContaining('Plan: claude'), findsNothing);
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
  // backend id) while the Settings row it lands on says Claude 订阅, and
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
    expect(find.textContaining('套餐：GLM 套餐'), findsOneWidget);
    expect(find.textContaining('套餐：glm'), findsNothing);

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
      reports: FakeReports(),
      initialSetupLink: () async => good,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
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
      reports: FakeReports(),
      initialSetupLink: () async => shareBounce,
    );
    await tester.pumpWidget(MaterialApp(home: HomeShell(services: services)));
    await tester.pumpAndSettle();
    expect(find.text('That setup link is not valid.'), findsNothing);
    expect(find.byKey(const Key('setupLinkConfirm')), findsNothing);
    expect(settings.apiKey, 'old');
  });
}
