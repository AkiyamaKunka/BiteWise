// New meals are named in Chinese when the app is in Chinese (2026-10-12).
// The server path sends "lang": "zh" to /api/analyze_photo and
// /api/text_intent and lets the server append the shared directive
// (telegram_bot.with_reply_language, fbfc859); the direct providers append
// the same "\n\n<directive>\n" themselves. In English every prompt and body
// is byte-identical to before, and the leftover prompt never carries the
// directive in either language: its item names are matched verbatim
// against the original meal (core/leftover_logic.dart).
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/leftover_logic.dart'
    show formatRecentMealsBlock;
import 'package:calorie_tracker/core/prompts.dart';
import 'package:calorie_tracker/core/shared_generated.dart';
import 'package:calorie_tracker/services/analyzer/gemini_analyzer.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Future<AppSettings> _settings(AiProvider provider, String appLanguage) async {
  SharedPreferences.setMockInitialValues({});
  final keys = _MemKeys()
    ..data['gemini_api_key'] = 'k-gem'
    ..data['openai_api_key'] = 'k-oa'
    ..data['anthropic_api_key'] = 'k-an';
  final s = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(), keyStore: keys);
  await s.setProvider(provider);
  if (provider == AiProvider.server) {
    await s.setServerBaseUrl('http://10.0.0.5');
    await s.setServerApiKey('upload-key');
  }
  await s.setAppLanguage(appLanguage);
  return s;
}

const _food = '{"is_food": true, "meal_description": "Noodles", '
    '"total_calories": 500, "food_items": '
    '[{"name": "Noodles", "estimated_calories": 500}]}';
const _intent = '{"intent": "chat", "reply": "ok"}';
const _leftover = '{"same_meal": true, "leftover_fraction": 0.5}';
const _compact = '{"meal_description": "Noodles", "food_items": '
    '[{"name": "Noodles", "estimated_calories": 500}]}';

final _recent = <Map<String, dynamic>>[
  {
    'time': '12:00 PM',
    'meal_description': 'Noodles',
    'food_items': [
      {'name': 'Noodles', 'estimated_calories': 500}
    ],
  }
];

const _directive = SharedConstants.replyLanguageDirectiveZh;
String _zh(String prompt) => '$prompt\n\n$_directive\n';

Uint8List _jpeg() => Uint8List.fromList(List.filled(64, 7));

/// The text part of a request, whichever provider shape carries it.
String _promptOf(http.Request req) {
  final body = jsonDecode(req.body) as Map<String, dynamic>;
  if (body.containsKey('contents')) {
    return body['contents'][0]['parts'][0]['text'] as String; // Gemini
  }
  final content = (body['messages'] as List).first['content'] as List;
  return (content.firstWhere((c) => c['type'] == 'text') as Map)['text']
      as String;
}

http.Response _reply(AiProvider p, String text) => switch (p) {
      AiProvider.gemini => http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': text}
                  ]
                }
              }
            ]
          }),
          200),
      AiProvider.anthropic => http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': text}
            ]
          }),
          200),
      _ => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': text}
              }
            ]
          }),
          200),
    };

/// One analyzer of [p] whose replies are [replyText], recording requests.
(AnalyzerService, List<http.Request>) _direct(
    AiProvider p, AppSettings s, String replyText) {
  final requests = <http.Request>[];
  final client = MockClient((r) async {
    requests.add(r);
    return _reply(p, replyText);
  });
  final AnalyzerService a = switch (p) {
    AiProvider.gemini => GeminiAnalyzer(s,
        client: client, sleep: (_) async {}, normalizer: (b) async => b),
    AiProvider.anthropic => AnthropicAnalyzer(s,
        client: client, sleep: (_) async {}, normalizer: (b) async => b),
    _ => OpenAiAnalyzer(s,
        client: client, sleep: (_) async {}, normalizer: (b) async => b),
  };
  return (a, requests);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('withReplyLanguage mirrors telegram_bot.with_reply_language', () {
    expect(withReplyLanguage('P', chinese: false), 'P');
    expect(withReplyLanguage('P', chinese: true), 'P\n\n$_directive\n');
  });

  group('direct providers append the directive themselves', () {
    for (final p in const [
      AiProvider.gemini,
      AiProvider.openai,
      AiProvider.anthropic,
    ]) {
      final photoPrompt =
          foodDetectionPrompt + formatRecentMealsBlock(_recent);

      test('${p.name}: photo prompt — en byte-identical, zh directive LAST',
          () async {
        final en = await _settings(p, 'en');
        final (aEn, rEn) = _direct(p, en, _food);
        expect((await aEn.analyzePhoto(_jpeg(), recentMeals: _recent)).isFood,
            isTrue);
        expect(_promptOf(rEn.single), photoPrompt);
        expect(_promptOf(rEn.single), isNot(contains(_directive)));

        final zh = await _settings(p, 'zh');
        final (aZh, rZh) = _direct(p, zh, _food);
        expect((await aZh.analyzePhoto(_jpeg(), recentMeals: _recent)).isFood,
            isTrue);
        expect(_promptOf(rZh.single), _zh(photoPrompt),
            reason: 'after the profile and the recent-meals block');
      });

      test('${p.name}: text-intent prompt — en byte-identical, zh appended',
          () async {
        const ask = 'TEXT INTENT PROMPT: had a coffee';
        final en = await _settings(p, 'en');
        final (aEn, rEn) = _direct(p, en, _intent);
        expect(await aEn.textIntent(ask), isNotNull);
        expect(_promptOf(rEn.single), ask);

        final zh = await _settings(p, 'zh');
        final (aZh, rZh) = _direct(p, zh, _intent);
        expect(await aZh.textIntent(ask), isNotNull);
        expect(_promptOf(rZh.single), _zh(ask));
      });

      test('${p.name}: the leftover prompt never carries the directive',
          () async {
        final zh = await _settings(p, 'zh');
        final (a, r) = _direct(p, zh, _leftover);
        expect(await a.leftoverIntent(_jpeg(), _compact), isNotNull);
        expect(_promptOf(r.single),
            sharedLeftoverPrompt(originalAnalysis: _compact));
      });
    }
  });

  group('server path sends lang and lets the server append', () {
    (ServerAnalyzer, List<http.Request>) server(AppSettings s) {
      final requests = <http.Request>[];
      return (
        ServerAnalyzer(s,
            sleep: (_) async {},
            normalizer: (b) async => b,
            client: MockClient((r) async {
              requests.add(r);
              return http.Response(
                  jsonEncode({
                    'ok': true,
                    'analysis': jsonDecode(_food),
                    'result': jsonDecode(_intent),
                    'leftover': jsonDecode(_leftover),
                    'analyzed_by': 'claude',
                  }),
                  200);
            })),
        requests
      );
    }

    Map<String, dynamic> bodyOf(http.Request r) =>
        jsonDecode(r.body) as Map<String, dynamic>;

    test('zh: analyze_photo and text_intent carry lang, the prompt does not '
        'grow, analyze_leftover carries no lang', () async {
      final s = await _settings(AiProvider.server, 'zh');
      final (a, r) = server(s);
      await a.analyzePhoto(_jpeg(), recentMeals: _recent);
      await a.textIntent('had a coffee');
      await a.leftoverIntent(_jpeg(), _compact);
      expect(r.map((q) => q.url.path).toList(),
          ['/api/analyze_photo', '/api/text_intent', '/api/analyze_leftover']);
      expect(bodyOf(r[0])['lang'], 'zh');
      expect(bodyOf(r[0]).containsKey('prompt'), isFalse);
      expect(bodyOf(r[1])['lang'], 'zh');
      expect(bodyOf(r[1])['prompt'], 'had a coffee',
          reason: 'the server appends the directive — never twice');
      expect(bodyOf(r[2]).containsKey('lang'), isFalse);
    });

    test('en: no lang field anywhere, bodies as before', () async {
      final s = await _settings(AiProvider.server, 'en');
      final (a, r) = server(s);
      await a.analyzePhoto(_jpeg());
      await a.textIntent('had a coffee');
      await a.leftoverIntent(_jpeg(), _compact);
      for (final q in r) {
        expect(bodyOf(q).containsKey('lang'), isFalse, reason: q.url.path);
      }
      expect(bodyOf(r[1])['prompt'], 'had a coffee');
      expect(bodyOf(r[0]).keys.toSet(),
          {'image_b64', 'dietary_profile', 'backend'});
    });
  });
}
