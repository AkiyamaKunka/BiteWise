/// The user's own server as a connection type, worded neutrally (owner
/// decision R-F5, 2026-10-29). App Review reads "Subscription", a premium
/// badge, "photos cost nothing extra" and "needs credits on Pro" as an
/// in-app subscription sold outside the App Store; nothing is sold here.
/// So: "Your own server" (你自己的服务器) with a server icon, the AI named
/// bare on the pages that already say where it runs ("Claude") and as
/// "Claude (server)" / 你服务器上的 Claude everywhere else. Behaviour is
/// unchanged — the owner's own Claude setup stays selected and asks nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';

import 'fakes.dart';

Widget _app(Locale locale, Widget home) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

/// The owner's own setup: their server, the Claude plan, the recipient
/// already allowed (the one-time seed), Watch Camera Roll on.
FakeSettings _owner() => FakeSettings(watcherEnabled: true)
  ..provider = 'server'
  ..apiKey =
      'upload-key' // the server's slot: keys are provider-scoped
  ..serverBackend = 'claude'
  ..serverBaseUrl = 'http://10.0.0.7'
  ..aiConsent = {'server:claude'};

/// Every string painted on the screen right now.
List<String> _texts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

/// Plan, subscription and price talk, per language. ("Account credit" in
/// the Test footer is a diagnosis, not an upsell, and stays.)
final _upsell = {
  'en': RegExp(
    r'\b(subscriptions?|plans?|flat-rate)\b|costs? nothing|needs credits|'
    r'\bon pro\b|premium',
    caseSensitive: false,
  ),
  'zh': RegExp(r'订阅|套餐|月费|额外花钱|另购|Pro 需'),
};

void main() {
  for (final (lang, l) in [
    ('en', AppLocalizationsEn() as AppLocalizations),
    ('zh', AppLocalizationsZh() as AppLocalizations),
  ]) {
    testWidgets('$lang: the row says "your own server" with a server icon', (
      tester,
    ) async {
      final settings = _owner();
      await tester.pumpWidget(
        _app(
          Locale(lang),
          ProviderSettingsPage(settings: settings, analyzer: FakeAnalyzer()),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('subscriptionTypeRow'));
      final title = lang == 'en' ? 'Your own server' : '你自己的服务器';
      expect(l.typeSubscription, title);
      expect(
        find.descendant(of: row, matching: find.text(title)),
        findsOneWidget,
      );
      // The value names the AI bare: the title already says where it runs.
      expect(
        find.descendant(of: row, matching: find.text('Claude')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.check)),
        findsOneWidget,
        reason: 'the owner\'s server is still the active choice',
      );
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.dns_outlined)),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.workspace_premium_outlined), findsNothing);
      for (final text in _texts(tester)) {
        expect(_upsell[lang]!.hasMatch(text), isFalse, reason: text);
      }
    });

    testWidgets('$lang: the own-server page talks about the server, not a '
        'plan to buy', (tester) async {
      // A phone-shaped view: the model sheet overflows the default 800×600.
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final settings = _owner();
      await tester.pumpWidget(
        _app(
          Locale(lang),
          SubscriptionProviderPage(
            settings: settings,
            startClaudeAuth: () async => (url: null, error: 'x'),
            completeClaudeAuth: (_) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.subPageTitle), findsWidgets); // large + bar title
      expect(l.subPageTitle, l.typeSubscription);
      expect(find.byKey(const Key('connectClaudeButton')), findsOneWidget);
      // The model picker, where the Fable row said "needs credits on Pro".
      await tester.ensureVisible(find.byKey(const Key('planModelRow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planModelRow')));
      await tester.pumpAndSettle();
      expect(find.text(l.planModelFable), findsOneWidget);
      for (final text in _texts(tester)) {
        expect(_upsell[lang]!.hasMatch(text), isFalse, reason: text);
      }
      for (final (backend, name) in [
        ('claude', 'Claude'),
        ('glm', 'GLM'),
        ('doubao', lang == 'en' ? 'Doubao' : '豆包'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key('planChoice-$backend')),
            matching: find.text(name),
          ),
          findsOneWidget,
        );
      }
    });
  }

  test('outside those pages the AI carries "(server)" / 你服务器上的, and '
      'the English copy drops the upsell lines', () {
    final en = AppLocalizationsEn();
    final zh = AppLocalizationsZh();
    expect(providerDisplayLabel(en, 'server', 'claude'), 'Claude (server)');
    expect(providerDisplayLabel(zh, 'server', 'claude'), '你服务器上的 Claude');
    expect(en.connectionTypeFooter, isNot(contains('cost nothing')));
    expect(zh.connectionTypeFooter, isNot(contains('不再额外花钱')));
    expect(en.planFooter, isNot(contains('costs nothing')));
    expect(en.planModelFable, 'Fable — frontier');
    expect(zh.planModelFable, 'Fable — 旗舰');
    expect(
      en.errServerModelRefused('r'),
      contains('Settings › AI Provider › Your own server › Model'),
    );
    expect(
      zh.errServerModelRefused('r'),
      contains('设置 › AI 服务 › 你自己的服务器 › 模型'),
    );
  });

  testWidgets('the owner\'s setup keeps working with zero taps: no dialog, '
      'nothing rewritten', (tester) async {
    final settings = _owner();
    await tester.pumpWidget(
      _app(
        const Locale('en'),
        SettingsScreen(
          settings: settings,
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          requestPhotoPermission: () async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('aiProviderRow')),
        matching: find.text('Claude (server)'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('aiProviderRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subscriptionTypeRow')));
    await tester.pumpAndSettle();
    // Re-picking the active AI is a no-op: no consent dialog, no writes.
    await tester.tap(find.byKey(const Key('planChoice-claude')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('aiConsentDialog')), findsNothing);
    expect(settings.provider, 'server');
    expect(settings.serverBackend, 'claude');
    expect(settings.apiKey, 'upload-key');
    expect(settings.aiConsentWrites, isEmpty);
    expect(settings.watcherEnabled, isTrue);
  });
}
