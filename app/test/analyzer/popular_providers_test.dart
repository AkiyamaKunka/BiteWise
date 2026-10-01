// The providers added 2026-09-30 — DeepSeek, xAI Grok, OpenRouter — and the
// refreshed defaults. Request shapes are pinned to what each vendor's own
// documentation specified that day; nothing here was captured live (see
// test_live/ for the opt-in live run).
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_analyzer_test.dart' show MemoryKeyStore;

const _foodJson = '{"is_food": true, "meal_description": "Beef noodles", '
    '"total_calories": 620, "food_items": []}';

http.Response _ok(String text) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': text}
        }
      ]
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Future<(AppSettings, MemoryKeyStore, SharedPreferences)> _fresh() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final keys = MemoryKeyStore();
  return (await AppSettings.load(prefs: prefs, keyStore: keys), keys, prefs);
}

/// The factory's configuration, re-instantiated with a mock transport and
/// an identity normalizer — every wire-relevant field comes from the
/// FACTORY, so a mis-wired factory fails here.
OpenAiCompatAnalyzer _wired(
        OpenAiCompatAnalyzer cfg, AppSettings s, http.Client c) =>
    OpenAiCompatAnalyzer(s,
        endpoint: cfg.endpoint,
        label: cfg.label,
        keyOf: cfg.keyOf,
        modelOf: cfg.modelOf,
        supportsJsonMode: cfg.supportsJsonMode,
        extraBody: cfg.extraBody,
        extraHeaders: cfg.extraHeaders,
        notFoundHint: cfg.notFoundHint,
        client: c,
        sleep: (_) async {},
        normalizer: (b) async => b);

void main() {
  final photo = Uint8List.fromList(List.filled(64, 7));

  Future<(http.Request, Map<String, dynamic>)> send(
      OpenAiCompatAnalyzer Function(AppSettings) factory,
      AppSettings s) async {
    final requests = <http.Request>[];
    final out = await _wired(
        factory(s),
        s,
        MockClient((r) async {
          requests.add(r);
          return _ok(_foodJson);
        })).analyzePhoto(photo);
    expect(out.isFood, isTrue);
    final req = requests.single;
    return (req, jsonDecode(req.body) as Map<String, dynamic>);
  }

  test('DeepSeek: chat-completions endpoint, deepseek-flash, JSON mode, '
      'thinking switched OFF', () async {
    final (s, _, _) = await _fresh();
    await s.setDeepseekApiKey('sk-ds');
    final (req, body) = await send(createDeepseekAnalyzer, s);
    expect(req.url.toString(), 'https://api.deepseek.com/chat/completions');
    expect(req.headers['Authorization'], 'Bearer sk-ds');
    expect(body['model'], 'deepseek-flash');
    expect(body['response_format'], {'type': 'json_object'});
    // Thinking defaults to ENABLED on DeepSeek and bills the reasoning.
    expect(body['thinking'], {'type': 'disabled'});
    expect(body['max_tokens'], isA<int>());
    final content = ((body['messages'] as List).first as Map)['content'] as List;
    expect((content[1] as Map)['image_url']['url'],
        startsWith('data:image/jpeg;base64,'));
  });

  test('xAI: chat-completions endpoint, grok default, NO response_format',
      () async {
    final (s, _, _) = await _fresh();
    await s.setXaiApiKey('xai-k');
    final (req, body) = await send(createXaiAnalyzer, s);
    expect(req.url.toString(), 'https://api.x.ai/v1/chat/completions');
    expect(req.headers['Authorization'], 'Bearer xai-k');
    expect(body['model'], AppSettings.defaultXaiModel);
    expect(body.containsKey('response_format'), isFalse,
        reason: 'JSON mode on the image path is undocumented — never risk '
            'a 400 on every photo');
    expect(body.containsKey('thinking'), isFalse);
  });

  test('OpenRouter: endpoint, attribution headers, bearer survives them, '
      'slug model, NO response_format', () async {
    final (s, _, _) = await _fresh();
    await s.setOpenrouterApiKey('sk-or');
    await s.setOpenrouterModel('x-ai/grok-4.7');
    final (req, body) = await send(createOpenRouterAnalyzer, s);
    expect(req.url.toString(), 'https://openrouter.ai/api/v1/chat/completions');
    expect(req.headers['Authorization'], 'Bearer sk-or');
    expect(req.headers['X-OpenRouter-Title'], 'BiteWise');
    expect(req.headers['HTTP-Referer'], contains('BiteWise'));
    expect(body['model'], 'x-ai/grok-4.7');
    expect(body.containsKey('response_format'), isFalse,
        reason: 'one key fronts hundreds of models; json_object is not '
            'universal');
  });

  test('extra headers can never replace the bearer or the content type',
      () async {
    final (s, _, _) = await _fresh();
    await s.setOpenrouterApiKey('real-key');
    final requests = <http.Request>[];
    await OpenAiCompatAnalyzer(s,
            endpoint: Uri.parse('https://example.invalid/v1/chat/completions'),
            label: 'X',
            keyOf: (s) => s.openrouterApiKey,
            modelOf: (_) => 'm',
            extraHeaders: const {
              'Authorization': 'Bearer hijack',
              'Content-Type': 'text/plain',
            },
            client: MockClient((r) async {
              requests.add(r);
              return _ok(_foodJson);
            }),
            normalizer: (b) async => b)
        .analyzePhoto(photo);
    expect(requests.single.headers['Authorization'], 'Bearer real-key');
    expect(requests.single.headers['Content-Type'], 'application/json');
  });

  test('each new FACTORY reads its own key and model slot', () async {
    final (s, _, _) = await _fresh();
    await s.setDeepseekApiKey('k-ds');
    await s.setXaiApiKey('k-xa');
    await s.setOpenrouterApiKey('k-or');
    await s.setDeepseekModel('m-ds');
    await s.setXaiModel('m-xa');
    await s.setOpenrouterModel('m-or');
    final wire = <String, List<String?>>{};
    for (final f in [
      createDeepseekAnalyzer,
      createXaiAnalyzer,
      createOpenRouterAnalyzer
    ]) {
      final (req, body) = await send(f, s);
      wire[req.url.host] = [
        req.headers['Authorization'],
        body['model'] as String
      ];
    }
    expect(wire['api.deepseek.com'], ['Bearer k-ds', 'm-ds']);
    expect(wire['api.x.ai'], ['Bearer k-xa', 'm-xa']);
    expect(wire['openrouter.ai'], ['Bearer k-or', 'm-or']);
  });

  test('the new providers persist keys (secure store) and models (prefs)',
      () async {
    final (s, keys, prefs) = await _fresh();
    await s.setDeepseekApiKey('dk');
    await s.setXaiApiKey('xk');
    await s.setOpenrouterApiKey('rk');
    await s.setOpenrouterModel('~x-ai/grok-latest');

    await s.setProvider(AiProvider.deepseek);
    expect(s.activeApiKey, 'dk');
    expect(s.activeModel, AppSettings.defaultDeepseekModel);
    expect(s.providerDisplayName, 'DeepSeek');
    await s.setProvider(AiProvider.xai);
    expect(s.activeApiKey, 'xk');
    expect(s.activeModel, AppSettings.defaultXaiModel);
    await s.setProvider(AiProvider.openrouter);
    expect(s.activeApiKey, 'rk');
    expect(s.activeModel, '~x-ai/grok-latest');

    expect(keys.data['deepseek_api_key'], 'dk');
    expect(keys.data['xai_api_key'], 'xk');
    expect(keys.data['openrouter_api_key'], 'rk');
    expect(prefs.getKeys().where((k) => k.contains('key')), isEmpty,
        reason: 'keys never touch shared_preferences');

    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.provider, AiProvider.openrouter);
    expect(again.openrouterApiKey, 'rk');
    expect(again.openrouterModel, '~x-ai/grok-latest');
    // Blank resets to the default.
    await again.setOpenrouterModel('  ');
    expect(again.openrouterModel, AppSettings.defaultOpenrouterModel);
  });

  test('the multi-provider router reaches each new provider', () async {
    final (s, _, _) = await _fresh();
    await s.setDeepseekApiKey('a');
    await s.setXaiApiKey('b');
    await s.setOpenrouterApiKey('c');
    final hosts = <String>[];
    final analyzer = createMultiProviderAnalyzer(s,
        client: MockClient((r) async {
      hosts.add(r.url.host);
      return _ok('{"intent": "query"}');
    }));
    for (final p in [
      AiProvider.deepseek,
      AiProvider.xai,
      AiProvider.openrouter
    ]) {
      await s.setProvider(p);
      await analyzer.textIntent('what did I eat');
    }
    expect(hosts, ['api.deepseek.com', 'api.x.ai', 'openrouter.ai']);
  });

  group('picker and settings agree', () {
    test('every key-based provider has a curated list whose FIRST entry is '
        'its AppSettings default', () async {
      // The screens name the default from the curated list (no module
      // imports there) — this is what keeps the two from drifting.
      final (s, _, _) = await _fresh();
      for (final p in AiProvider.values) {
        if (p == AiProvider.server) continue;
        await s.setProvider(p);
        expect(kKnownModels.containsKey(p.name), isTrue, reason: p.name);
        expect(defaultModelFor(p.name), s.activeModel, reason: p.name);
        expect(kApiKeyChoices.any((c) => c.$1 == p.name), isTrue,
            reason: '${p.name} must be selectable');
        if (p != AiProvider.gemini) {
          expect(providerLabel(p.name), isNot('Gemini'),
              reason: '${p.name} must not fall through to the default label');
        }
      }
    });

    test('defaults are the current generation, not retired ids', () {
      // Google limits the 2.5 models to accounts that already used them;
      // gpt-4o-mini and claude-sonnet-5 are superseded generations.
      expect(AppSettings.defaultModel, 'gemini-3.8-flash');
      expect(AppSettings.defaultOpenaiModel, 'gpt-6-luna');
      expect(AppSettings.defaultAnthropicModel, 'claude-sonnet-5-5');
      expect(AppSettings.defaultDeepseekModel, 'deepseek-flash');
      expect(AppSettings.defaultXaiModel, 'grok-4.7');
    });
  });
}
