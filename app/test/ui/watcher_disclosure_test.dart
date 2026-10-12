/// Turning on 监控相册 asks first, once (App Store guideline 5.1.2(i):
/// explicit consent before personal data goes to a third-party AI). The
/// notice names the CURRENT provider; Cancel leaves the switch off with no
/// permission request, no start and no sweep; Continue persists the flag
/// and proceeds exactly as before; a second enable goes straight through.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';

import 'fakes.dart';

void main() {
  late int permissionCalls;

  Future<void> pump(WidgetTester tester, Locale locale,
      FakeSettings settings, FakeIntake intake) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    permissionCalls = 0;
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SettingsScreen(
          settings: settings,
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          photoIntake: intake,
          requestPhotoPermission: () async {
            permissionCalls++;
            return true;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapToggle(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('watcherToggle')));
    await tester.pumpAndSettle();
  }

  for (final (locale, title, provider, cancel, go) in const [
    (Locale('zh'), '照片会发送给 AI 服务', 'DeepSeek', '取消', '继续'),
    (Locale('en'), 'Photos will be sent to your AI service', 'DeepSeek',
        'Cancel', 'Continue'),
  ]) {
    final tag = locale.languageCode;

    testWidgets('[$tag] first enable shows the notice naming the provider; '
        'Cancel arms nothing', (tester) async {
      final settings = FakeSettings(watcherEnabled: false)
        ..provider = 'deepseek'
        ..apiKey = 'k';
      final intake = FakeIntake();
      await pump(tester, locale, settings, intake);
      await tapToggle(tester);

      expect(find.byKey(const Key('watcherDisclosureDialog')), findsOneWidget);
      expect(find.text(title), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('watcherDisclosureDialog')),
              matching: find.textContaining(provider)),
          findsOneWidget,
          reason: 'the body names where the photos go');
      await tester.tap(find.text(cancel));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('watcherDisclosureDialog')), findsNothing);
      expect(permissionCalls, 0, reason: 'no OS prompt after Cancel');
      expect(intake.started, isFalse);
      expect(intake.backfillScans, 0);
      expect(settings.watcherEnabled, isFalse);
      expect(settings.watcherDisclosureSeen, isFalse,
          reason: 'Cancel is not consent — ask again next time');
      expect(tester.widget<Switch>(find.byKey(const Key('watcherToggle'))).value,
          isFalse);
    });

    testWidgets('[$tag] Continue saves the flag and proceeds; the second '
        'enable skips the notice', (tester) async {
      final settings = FakeSettings(apiKey: 'k', watcherEnabled: false);
      final intake = FakeIntake();
      await pump(tester, locale, settings, intake);
      await tapToggle(tester);
      await tester.tap(find.text(go));
      await tester.pumpAndSettle();

      expect(settings.watcherDisclosureSeen, isTrue);
      expect(permissionCalls, 1);
      expect(intake.started, isTrue);
      expect(intake.backfillScans, 1);
      expect(settings.watcherEnabled, isTrue);

      await tapToggle(tester); // off
      expect(settings.watcherEnabled, isFalse);
      await tapToggle(tester); // on again
      expect(find.byKey(const Key('watcherDisclosureDialog')), findsNothing);
      expect(permissionCalls, 2);
      expect(settings.watcherEnabled, isTrue);
    });
  }

  testWidgets('a watcher that is already on is never prompted, and turning '
      'it off asks nothing', (tester) async {
    final settings = FakeSettings(apiKey: 'k', watcherEnabled: true);
    final intake = FakeIntake();
    await pump(tester, const Locale('zh'), settings, intake);
    expect(find.byKey(const Key('watcherDisclosureDialog')), findsNothing);
    await tapToggle(tester);
    expect(find.byKey(const Key('watcherDisclosureDialog')), findsNothing);
    expect(settings.watcherEnabled, isFalse);
  });
}
