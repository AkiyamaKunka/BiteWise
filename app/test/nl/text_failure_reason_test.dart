/// A text request that fails for a reason a retry cannot fix says so (loop
/// find 2026-10-08). textIntent folds every failure into null, so 文字描述一餐
/// and 修改某餐 told a friend with a wrong key "联系 AI 失败，请重试" forever,
/// while the photo path on the same key said the key was rejected. The
/// analyzers now also answer [TextIntentExplainer.textIntentOutcome] with the
/// photo path's English failure line; the executor names a rejected key or
/// model and keeps spec §4 step 4's retry wording for everything else.
library;

import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/analyzer/gemini_analyzer.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/nl/executor.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// The nl fake plus a failure reason, the way the real analyzers report it.
class ExplainingAnalyzer extends FakeAnalyzer implements TextIntentExplainer {
  String? nextError;

  @override
  Future<TextIntentOutcome> textIntentOutcome(String prompt) async {
    lastPrompt = prompt;
    return TextIntentOutcome(next, error: nextError);
  }
}

Future<AppSettings> _settings(AiProvider provider) async {
  SharedPreferences.setMockInitialValues(const {});
  final s = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(), keyStore: MemoryKeyStore());
  await s.setProvider(provider);
  switch (provider) {
    case AiProvider.qwen:
      await s.setQwenApiKey('sk-test-123');
    case AiProvider.openai:
      await s.setOpenaiApiKey('sk-test-123');
    case AiProvider.anthropic:
      await s.setAnthropicApiKey('sk-test-123');
    case AiProvider.gemini:
      await s.setGeminiApiKey('test-key');
    case AiProvider.server:
      await s.setServerBaseUrl('http://10.0.0.5');
      await s.setServerApiKey('upload-key');
    default:
      fail('unused provider $provider');
  }
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('zh'));

  group('executor wording', () {
    late ExplainingAnalyzer analyzer;
    late AppSettings settings;

    setUp(() async {
      analyzer = ExplainingAnalyzer();
      settings = await testSettings();
    });

    DefaultNlExecutor zh() => DefaultNlExecutor(FakeDao(), analyzer, settings,
        l10n: AppLocalizationsZh());
    DefaultNlExecutor en() => DefaultNlExecutor(FakeDao(), analyzer, settings,
        l10n: AppLocalizationsEn());

    test('a rejected key is named in both text paths, never "请重试"',
        () async {
      analyzer
        ..next = null
        ..nextError = 'The provider rejected the API key. Check Settings.';
      final chat = (await zh().handleText('午饭改成 600')).single.text;
      final describe = (await zh().describeMeal('一碗米饭')).error;
      for (final line in [chat, describe]) {
        expect(line, '❌ 服务拒绝了 API Key，请在设置里检查。');
        expect(line, isNot(contains('请重试')));
      }
      expect((await en().handleText('x')).single.text,
          '❌ The provider rejected the API key. Check the key in Settings.');
    });

    test('a rejected model is named in both text paths', () async {
      analyzer
        ..next = null
        ..nextError = 'Qwen model not found — check the model name in '
            'Settings.';
      expect((await zh().handleText('x')).single.text,
          '❌ 服务不接受这个模型 —— 请在设置里检查模型名。');
      expect((await zh().describeMeal('一碗米饭')).error,
          '❌ 服务不接受这个模型 —— 请在设置里检查模型名。');
    });

    test('Doubao / OpenRouter "model not found" keep their own remedy',
        () async {
      // Neither hint says "model name", so both classified as unknown and
      // the chat said 请重试 to a model id a retry cannot fix (2026-10-12).
      analyzer
        ..next = null
        ..nextError = 'Doubao model not found — Ark needs the EXACT '
            'versioned ID from its model list, and the model must be '
            'activated (开通管理) in the Volcengine console.';
      for (final line in [
        (await zh().handleText('x')).single.text,
        (await zh().describeMeal('一碗米饭')).error!,
      ]) {
        expect(line, startsWith('❌ 豆包找不到这个模型'));
        expect(line, contains('开通管理'));
        expect(line, isNot(contains('请重试')));
      }
      expect((await en().handleText('x')).single.text,
          contains('activated (开通管理)'));
      analyzer.nextError = 'OpenRouter model not found — use the full slug '
          'from openrouter.ai/models (vendor/model, for example '
          'google/gemini-3.8-flash) and pick one that accepts images.';
      for (final line in [
        (await zh().handleText('x')).single.text,
        (await zh().describeMeal('一碗米饭')).error!,
      ]) {
        expect(line, contains('支持图片'));
        expect(line, contains('openrouter.ai/models'));
        expect(line, isNot(contains('请重试')));
      }
      expect((await en().handleText('x')).single.text,
          contains('accepts images'));
    });

    test('an empty provider balance says "top up", never "请重试"', () async {
      // A retry cannot refill an account; the chat used to say 联系 AI
      // 失败，请重试 to a friend whose DeepSeek balance hit zero (2026-10-12).
      analyzer
        ..next = null
        ..nextError =
            'Provider balance or credits exhausted — check your Qwen billing.';
      for (final line in [
        (await zh().handleText('x')).single.text,
        (await zh().describeMeal('一碗米饭')).error,
      ]) {
        expect(line, '❌ 账户余额或额度已用完 —— 请到服务商控制台充值。');
        expect(line, isNot(contains('请重试')));
      }
      expect((await en().handleText('x')).single.text,
          "❌ The provider account is out of balance or credits — top it up "
          "in the provider's console.");
    });

    test('the plan refusing the model for credits says "switch model"',
        () async {
      // retry:false from the Claude Plan server: the selected model needs
      // usage credits this plan lacks; 请重试 reproduces it forever.
      analyzer
        ..next = null
        ..nextError = 'The server cannot analyze right now: Fable 5 requires '
            'usage credits..';
      for (final line in [
        (await zh().handleText('x')).single.text,
        (await zh().describeMeal('一碗米饭')).error,
      ]) {
        expect(line,
            '❌ 你的服务器无法使用所选模型：Fable 5 requires usage credits —— '
            '请在 设置 › AI 服务 › Claude 订阅 里换一个模型。');
      }
      expect((await en().handleText('x')).single.text,
          '❌ Your server cannot use the selected model: Fable 5 requires '
          'usage credits — choose another model in Settings › AI Provider › '
          'Claude Plan.');
    });

    test('retryable and unknown failures keep the spec §4 step 4 wording',
        () async {
      for (final error in [
        null, // parse failure / no reason
        'Error contacting the provider (network or service issue).',
        'Provider rate/spend limit hit — will retry later.',
        'The analyzer is busy',
        'The server cannot analyze right now: the analyzer is busy with '
            'another photo.',
        'The server cannot analyze right now: You have hit your usage '
            'limit. It resets at 3pm.',
        'The server cannot analyze right now: the analysis ran but produced '
            'no usable result.',
      ]) {
        analyzer
          ..next = null
          ..nextError = error;
        expect((await zh().handleText('x')).single.text,
            '❌ 联系 AI 失败，请重试。',
            reason: '$error');
        expect((await zh().describeMeal('一碗米饭')).error,
            '❌ 联系 AI 失败，请重试。',
            reason: '$error');
        expect((await en().handleText('x')).single.text,
            '❌ Error contacting AI. Please try again.',
            reason: '$error');
      }
    });

    test('a reply that parsed still runs, whatever the error field says',
        () async {
      analyzer
        ..next = {'intent': 'chat', 'reply': '好的'}
        ..nextError = null;
      expect((await zh().handleText('x')).single.text, contains('好的'));
    });
  });

  group('analyzers report the reason', () {
    test('Qwen 401: textIntent stays null, the outcome names the key',
        () async {
      final s = await _settings(AiProvider.qwen);
      final a = createQwenAnalyzer(s,
          client: MockClient((_) async => http.Response(
              '{"error":{"code":"invalid_api_key"}}', 401)));
      expect(await a.textIntent('p'), isNull);
      final out = await (a as TextIntentExplainer).textIntentOutcome('p');
      expect(out.json, isNull);
      expect(classifyAnalysisError(out.error), AnalysisErrorKind.rejectedKey);
    });

    test('own server 401: the outcome names the key', () async {
      final s = await _settings(AiProvider.server);
      final a = ServerAnalyzer(s,
          client: MockClient(
              (_) async => http.Response('{"error":"bad key"}', 401)));
      final out = await a.textIntentOutcome('p');
      expect(out.json, isNull);
      expect(classifyAnalysisError(out.error), AnalysisErrorKind.rejectedKey);
    });

    test('OpenAI / Anthropic: a retired model id names the model, so the '
        'executor stops saying "try again"', () async {
      // Both post to one fixed endpoint, so a 404 is the model id. The bare
      // 'Provider request failed: HTTP 404' classified as unknown, which
      // the executor maps to nlErrorContactingAi — forever (2026-10-10).
      final oa = await _settings(AiProvider.openai);
      final oaOut = await OpenAiAnalyzer(oa,
              client: MockClient((_) async => http.Response(
                  '{"error": {"message": "The model `gpt-4o-mini` does not '
                  'exist or you do not have access to it.", "type": '
                  '"invalid_request_error", "code": "model_not_found"}}',
                  404)))
          .textIntentOutcome('p');
      expect(oaOut.json, isNull);
      expect(classifyAnalysisError(oaOut.error), AnalysisErrorKind.badModel,
          reason: '${oaOut.error}');
      final an = await _settings(AiProvider.anthropic);
      final anOut = await AnthropicAnalyzer(an,
              client: MockClient((_) async => http.Response(
                  '{"type": "error", "error": {"type": "not_found_error", '
                  '"message": "model: claude-3-5-sonnet-20241022"}}',
                  404)))
          .textIntentOutcome('p');
      expect(anOut.json, isNull);
      expect(classifyAnalysisError(anOut.error), AnalysisErrorKind.badModel,
          reason: '${anOut.error}');
    });

    test('Gemini: 401 names the key, 404 names the model, daily quota '
        'still latches the pause', () async {
      final s = await _settings(AiProvider.gemini);
      Future<TextIntentOutcome> ask(http.Response r) =>
          GeminiAnalyzer(s, client: MockClient((_) async => r))
              .textIntentOutcome('p');
      expect(
          classifyAnalysisError((await ask(http.Response(
                  '{"error":{"status":"UNAUTHENTICATED"}}', 401)))
              .error),
          AnalysisErrorKind.rejectedKey);
      expect(
          classifyAnalysisError((await ask(http.Response(
                  '{"error":{"status":"NOT_FOUND"}}', 404)))
              .error),
          AnalysisErrorKind.badModel);
      await ask(http.Response(
          '{"error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "message": '
          '"Quota exceeded for quota metric '
          'generate_content_free_tier_requests limit '
          'GenerateRequestsPerDayPerProjectPerModel-FreeTier"}}',
          429));
      expect(s.isQuotaPaused, isTrue);
    });

    test('a parsed reply carries no error', () async {
      final s = await _settings(AiProvider.qwen);
      final a = createQwenAnalyzer(s,
          client: MockClient((_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': '{"intent": "chat", "reply": "hi"}'
                    }
                  }
                ]
              }),
              200)));
      final out = await (a as TextIntentExplainer).textIntentOutcome('p');
      expect(out.json, {'intent': 'chat', 'reply': 'hi'});
      expect(out.error, isNull);
    });

    test('MultiProviderAnalyzer forwards the reason of the ACTIVE provider',
        () async {
      final s = await _settings(AiProvider.qwen);
      final multi = MultiProviderAnalyzer(s,
          client: MockClient((_) async => http.Response('{}', 401)));
      final out = await askTextIntent(multi, 'p');
      expect(out.json, isNull);
      expect(classifyAnalysisError(out.error), AnalysisErrorKind.rejectedKey);
      // And the executor, built on the real wrapper, says so.
      final exec = DefaultNlExecutor(FakeDao(), multi, s,
          l10n: AppLocalizationsZh());
      expect((await exec.describeMeal('一碗米饭')).error,
          '❌ 服务拒绝了 API Key，请在设置里检查。');
    });
  });
}
