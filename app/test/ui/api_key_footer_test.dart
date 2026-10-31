/// Every API-key provider's page says where its key comes from. Gemini
/// (the default), OpenAI and Anthropic fell through to the generic
/// 'The key saves as you type' footer while the six newer providers named
/// their console (2026-10-12 testing loop).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/settings/api_key_page.dart';

import 'fakes.dart';

const _consoleHost = {
  'gemini': 'aistudio.google.com/apikey',
  'openai': 'platform.openai.com/api-keys',
  'anthropic': 'console.anthropic.com',
  'qwen': 'bailian.console.aliyun.com',
  'doubao': 'console.volcengine.com/ark',
  'glm': 'open.bigmodel.cn',
  'deepseek': 'platform.deepseek.com',
  'xai': 'console.x.ai',
  'openrouter': 'openrouter.ai/keys',
};

Future<void> _pump(WidgetTester tester, Locale locale, String provider) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final settings = FakeSettings()..provider = provider;
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ApiKeyProviderPage(settings: settings),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final MapEntry(key: provider, value: host) in _consoleHost.entries) {
    testWidgets('$provider: the key footer names $host in en and zh',
        (tester) async {
      await _pump(tester, const Locale('en'), provider);
      expect(find.textContaining(host), findsOneWidget);
      expect(find.text('The key saves as you type. Stored securely on this '
          'device only.'), findsNothing);

      await _pump(tester, const Locale('zh'), provider);
      final zh = find.textContaining(host);
      expect(zh, findsOneWidget);
      expect(tester.widget<Text>(zh).data, startsWith('从 '));
    });
  }

  // English is neutral (owner decision R-F11, 2026-10-29): the free tier,
  // no VPN note. The Chinese footer keeps its mainland-China hint.
  // Run 7 (U1/U4): the free tier's small daily limit and its data use
  // (Google may use inputs and have people review them) are said where
  // the free tier is offered, with billing as the way out.
  testWidgets('Gemini says it has a free tier; only Chinese adds the VPN '
      'hint', (tester) async {
    await _pump(tester, const Locale('en'), 'gemini');
    expect(
        find.text('From aistudio.google.com/apikey (Google AI Studio). Has a '
            'free tier, but it allows only a limited number of photos a day, '
            'and on it Google may use what you send to improve its AI and '
            'let people review it. Turning on billing in AI Studio lifts the '
            'limit and avoids this — worth doing before photos are logged '
            'automatically. Stored securely on this device only.'),
        findsOneWidget);
    await _pump(tester, const Locale('zh'), 'gemini');
    final zh = tester.widget<Text>(find.textContaining('aistudio')).data!;
    expect(zh, startsWith('从 aistudio.google.com/apikey 获取（Google AI '
        'Studio）。有免费额度，中国大陆需 VPN。'));
    for (final word in ['改进', '人工', '开通付费', '仅安全存储在本机。']) {
      expect(zh, contains(word));
    }
  });
}
