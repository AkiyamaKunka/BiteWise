/// Three provider-settings strings spoke English, or a raw timestamp,
/// inside the Chinese UI (2026-10-07 testing loop):
///
/// - the red quota-pause banner on the AI 服务 page (the root footer one
///   level up was already Chinese);
/// - the custom-model helper footer on the API Key page;
/// - the 测试当前服务 quota detail, which printed DateTime.toString()
///   ('2026-10-06 23:00:00.000').
///
/// The pages are pumped with the REAL delegates in zh and in en, so the
/// Chinese actually appears and the English stays byte-identical to what
/// the literals said.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/diagnostics.dart';
import 'package:calorie_tracker/ui/screens/settings/api_key_page.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart'
    show ProviderSettingsPage, defaultModelFor;

import 'fakes.dart';

Widget _app(Locale locale, Widget home) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _pump(WidgetTester tester, Locale locale, Widget home) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(locale, home));
  await tester.pumpAndSettle();
}

String _bannerText(WidgetTester tester) => tester
    .widget<Text>(find.descendant(
        of: find.byKey(const Key('quotaPauseBanner')),
        matching: find.byType(Text)))
    .data!;

/// The pre-l10n English footer for each branch of the old switch.
String _enHelper(String provider) {
  final base = 'Default: ${defaultModelFor(provider)}';
  return switch (provider) {
    'qwen' => '$base. Doubles as the cheap tier — '
        'qwen3-vl-plus is the stronger paid model.',
    'doubao' => '$base. Doubao needs the '
        'EXACT versioned ID from the Ark model list — undated names '
        'are rejected.',
    'glm' => '$base (free tier). glm-4.6v is the '
        'stronger paid model.',
    'deepseek' => '$base — the only DeepSeek model that accepts photos.',
    'openrouter' => '$base. Any vendor/model slug from '
        'openrouter.ai/models that accepts images works.',
    _ => base,
  };
}

const _zhHelperMarker = {
  'gemini': '默认：',
  'qwen': '便宜档',
  'doubao': '带日期的完整模型 ID',
  'glm': '免费档',
  'deepseek': '唯一能识别照片',
  'openrouter': '支持图片',
};

/// A model name no curated list carries, so the page opens on Custom.
FakeSettings _customModelOn(String provider) {
  final s = FakeSettings(models: {provider: 'my-own-model'});
  s.provider = provider;
  return s;
}

void main() {
  group('quota-pause banner on the AI Provider page', () {
    FakeSettings paused({DateTime? until}) => FakeSettings(apiKey: 'k')
      ..isQuotaPaused = true
      ..quotaPauseUntil = until;

    testWidgets('en: byte-identical to the old literal, with and without '
        'the until-time', (tester) async {
      await _pump(tester, const Locale('en'),
          ProviderSettingsPage(settings: paused(), analyzer: FakeAnalyzer()));
      expect(
          _bannerText(tester),
          'Analyses are paused — the daily quota was hit. New photos are '
          'kept and retried automatically; changing the key or provider '
          'resumes now.');

      await _pump(
          tester,
          const Locale('en'),
          ProviderSettingsPage(
              settings: paused(until: DateTime(2026, 7, 31, 23, 30)),
              analyzer: FakeAnalyzer()));
      expect(
          _bannerText(tester),
          'Analyses are paused — the daily quota was hit (until 11:30 PM). '
          'New photos are kept and retried automatically; changing the key '
          'or provider resumes now.');
    });

    testWidgets('zh: Chinese, with the until-time, and no English',
        (tester) async {
      await _pump(
          tester,
          const Locale('zh'),
          ProviderSettingsPage(
              settings: paused(until: DateTime(2026, 7, 31, 23, 30)),
              analyzer: FakeAnalyzer()));
      final text = _bannerText(tester);
      expect(text, startsWith('分析已暂停'));
      expect(text, contains('11:30'));
      expect(text, isNot(contains('Analyses are paused')));
      expect(text, isNot(contains('AI 服务页')),
          reason: 'the banner IS on that page; it must not point at it');

      await _pump(tester, const Locale('zh'),
          ProviderSettingsPage(settings: paused(), analyzer: FakeAnalyzer()));
      expect(_bannerText(tester),
          '分析已暂停 — 已达当日额度。新照片会保留并自动重试；更换 Key 或服务后立即恢复。');
    });
  });

  group('custom-model helper footer on the API Key page', () {
    for (final provider in _zhHelperMarker.keys) {
      testWidgets('$provider: en byte-identical, zh in Chinese',
          (tester) async {
        await _pump(tester, const Locale('en'),
            ApiKeyProviderPage(settings: _customModelOn(provider)));
        expect(find.text(_enHelper(provider)), findsOneWidget);

        await _pump(tester, const Locale('zh'),
            ApiKeyProviderPage(settings: _customModelOn(provider)));
        expect(find.text(_enHelper(provider)), findsNothing);
        final zh = find.textContaining(
            '默认：${defaultModelFor(provider)}');
        expect(zh, findsOneWidget);
        expect(tester.widget<Text>(zh).data,
            contains(_zhHelperMarker[provider]!));
      });
    }

    testWidgets('a curated model shows no helper', (tester) async {
      await _pump(tester, const Locale('zh'),
          ApiKeyProviderPage(settings: FakeSettings()));
      expect(find.textContaining('默认：'), findsNothing);
    });
  });

  test('diagnostics: the pause detail is a local date and clock, not '
      'DateTime.toString()', () async {
    final settings = FakeSettings()
      ..isQuotaPaused = true
      ..quotaPauseUntil = DateTime(2026, 10, 6, 23, 0);
    final results = await ProviderDiagnostics(
      settings: settings,
      analyzer: FakeAnalyzer()
        ..nextTextIntent = {'ok': true}
        ..nextPhotoOutcome = const AnalysisOutcome(
            analysis: {'is_food': false, 'reason': 'a test disc'},
            isFood: false,
            wall: Duration.zero),
      l10n: AppLocalizationsZh(),
      client: MockClient((_) async => http.Response('ok', 404)),
      testImage: () => Uint8List.fromList(List.filled(32, 9)),
    ).run().toList();
    final quota = results.last;
    expect(quota.status, DiagStatus.warn);
    expect(quota.detail, '暂停至 2026-10-06 23:00。');
    expect(quota.detail, isNot(matches(RegExp(r'\d{2}:\d{2}:\d{2}'))));
  });
}
