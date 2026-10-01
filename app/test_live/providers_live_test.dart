// LIVE provider check — real requests, real providers, the app's real
// analyzers. Opt-in: `flutter test` only runs test/, so this never runs in
// CI or by accident. Use scripts/test_providers_live.sh.
//
// Keys come from a PRIVATE file (default ~/.bitewise/provider_keys.env,
// chmod 600, never in the repo) or from the environment; a provider with
// no key is skipped, not failed. Values are never printed.
//
//   GEMINI_API_KEY  OPENAI_API_KEY  ANTHROPIC_API_KEY  DEEPSEEK_API_KEY
//   XAI_API_KEY     OPENROUTER_API_KEY   QWEN_API_KEY   DOUBAO_API_KEY
//   GLM_API_KEY
//   <PROVIDER>_MODEL          override that provider's model
//   OPENROUTER_MODELS=a,b,c   the OpenRouter matrix (default: the app's
//                             curated OpenRouter list — one key exercises
//                             GPT, Claude, Gemini, Grok, DeepSeek, …)
//
// The "own server" path is checked too when ~/.bitewise/server.env exists.
//
// A provider WITHOUT a key is still probed: the app's own key check is sent
// a deliberately invalid key, and the live service must (a) exist at the
// configured endpoint and (b) refuse it in a way the app reports as "the
// key was rejected" — not as a missing model, a bad request or an outage.
//
// Any OpenAI-compatible server can be added for free local runs:
//   LOCAL_OPENAI_URL=http://localhost:11434/v1/chat/completions   (Ollama)
//   LOCAL_OPENAI_MODEL=llama3.2      LOCAL_OPENAI_VISION=0|1
//
// What is asserted is the CONTRACT — the provider accepted the request and
// answered a well-formed analysis — not the verdict: the fixture is a
// drawn plate, and "not food" is a legitimate answer to it.
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart'
    show KeyProbeResult;
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart'
    show kKnownModels;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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

Map<String, String> _envFile(String path) {
  final f = File(path);
  if (!f.existsSync()) return const {};
  final out = <String, String>{};
  for (final raw in f.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final i = line.indexOf('=');
    if (i <= 0) continue;
    var v = line.substring(i + 1).trim();
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'")))) {
      v = v.substring(1, v.length - 1);
    }
    if (v.isNotEmpty) out[line.substring(0, i).trim()] = v;
  }
  return out;
}

/// A target: one provider + model the run will exercise.
class _Target {
  _Target(this.label, this.provider, this.configure);
  final String label;
  final AiProvider provider;
  final Future<void> Function(AppSettings) configure;
}

class _Row {
  _Row(this.label, this.model);
  final String label;
  final String model;
  String photo = '-';
  String text = '-';
  String note = '';
}

void main() {
  final home = Platform.environment['HOME'] ?? '.';
  final keys = <String, String>{
    ..._envFile(Platform.environment['BITEWISE_PROVIDER_KEYS'] ??
        '$home/.bitewise/provider_keys.env'),
    // The process environment wins over the file.
    for (final e in Platform.environment.entries)
      if (e.value.isNotEmpty) e.key: e.value,
  };
  final server = _envFile(Platform.environment['BITEWISE_SERVER_ENV'] ??
      '$home/.bitewise/server.env');
  String? key(List<String> names) {
    for (final n in names) {
      final v = keys[n];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  // Dart's HttpClient ignores the system proxy; honour HTTPS_PROXY when the
  // shell has one, so the run sees the network the way curl does.
  final inner = HttpClient();
  if ((Platform.environment['HTTPS_PROXY'] ??
          Platform.environment['https_proxy'] ??
          '')
      .isNotEmpty) {
    inner.findProxy = HttpClient.findProxyFromEnvironment;
  }
  final http.Client client = IOClient(inner);

  final photo = File('test_live/fixtures/plate.jpg').readAsBytesSync();
  final rows = <_Row>[];

  final targets = <(_Target, String?)>[];
  void add(String label, AiProvider p, List<String> keyNames,
      Future<void> Function(AppSettings s, String key) setKey,
      Future<void> Function(AppSettings s, String model) setModel,
      {String? model}) {
    final k = key(keyNames);
    final m = model ?? keys['${p.name.toUpperCase()}_MODEL'];
    targets.add((
      _Target(label, p, (s) async {
        await s.setProvider(p);
        await setKey(s, k!);
        if (m != null && m.isNotEmpty) await setModel(s, m);
      }),
      k == null ? 'no key (${keyNames.first})' : null
    ));
  }

  add('Gemini', AiProvider.gemini, ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
      (s, k) => s.setGeminiApiKey(k), (s, m) => s.setModel(m));
  add('OpenAI', AiProvider.openai, ['OPENAI_API_KEY'],
      (s, k) => s.setOpenaiApiKey(k), (s, m) => s.setOpenaiModel(m));
  add('Claude API', AiProvider.anthropic, ['ANTHROPIC_API_KEY'],
      (s, k) => s.setAnthropicApiKey(k), (s, m) => s.setAnthropicModel(m));
  add('DeepSeek', AiProvider.deepseek, ['DEEPSEEK_API_KEY'],
      (s, k) => s.setDeepseekApiKey(k), (s, m) => s.setDeepseekModel(m));
  add('xAI Grok', AiProvider.xai, ['XAI_API_KEY', 'GROK_API_KEY'],
      (s, k) => s.setXaiApiKey(k), (s, m) => s.setXaiModel(m));
  add('Qwen', AiProvider.qwen, ['QWEN_API_KEY', 'DASHSCOPE_API_KEY'],
      (s, k) => s.setQwenApiKey(k), (s, m) => s.setQwenModel(m));
  add('Doubao', AiProvider.doubao, ['DOUBAO_API_KEY', 'ARK_API_KEY'],
      (s, k) => s.setDoubaoApiKey(k), (s, m) => s.setDoubaoModel(m));
  add('GLM', AiProvider.glm, ['GLM_API_KEY', 'ZHIPU_API_KEY'],
      (s, k) => s.setGlmApiKey(k), (s, m) => s.setGlmModel(m));
  final orModels = (keys['OPENROUTER_MODELS'] ?? '')
      .split(',')
      .map((m) => m.trim())
      .where((m) => m.isNotEmpty)
      .toList();
  final orMatrix = orModels.isNotEmpty
      ? orModels
      : kKnownModels['openrouter']!.map((e) => e.$1).toList();
  // No key: one endpoint probe is enough — the matrix needs a real key.
  for (final m
      in key(['OPENROUTER_API_KEY']) == null ? orMatrix.take(1) : orMatrix) {
    add('OpenRouter', AiProvider.openrouter, ['OPENROUTER_API_KEY'],
        (s, k) => s.setOpenrouterApiKey(k),
        (s, mm) => s.setOpenrouterModel(mm),
        model: m);
  }
  // The user's own server (Claude / GLM / Doubao plan).
  final serverUrl = server['SERVER_URL'];
  final serverKey = server['UPLOAD_KEY'];
  targets.add((
    _Target('Own server', AiProvider.server, (s) async {
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl(serverUrl!);
      await s.setServerApiKey(serverKey!);
      final b = server['BACKEND'];
      if (b != null && b.isNotEmpty) await s.setServerBackend(b);
    }),
    (serverUrl == null || serverKey == null)
        ? 'no ~/.bitewise/server.env'
        : null
  ));

  // Optional local OpenAI-compatible server (Ollama, LM Studio, …): the
  // same adapter class the DeepSeek / xAI / OpenRouter providers use.
  final localUrl = keys['LOCAL_OPENAI_URL'];
  final localModel = keys['LOCAL_OPENAI_MODEL'];
  if (localUrl != null && localModel != null) {
    test('Local OpenAI-compatible server — live round trip', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
      final row = _Row('Local', localModel);
      rows.add(row);
      final analyzer = OpenAiCompatAnalyzer(s,
          endpoint: Uri.parse(localUrl),
          label: 'Local',
          keyOf: (_) => keys['LOCAL_OPENAI_KEY'] ?? 'local',
          modelOf: (_) => localModel,
          supportsJsonMode: false,
          client: client);
      final intent = await analyzer.textIntent(
          'Reply with ONLY this JSON and nothing else: {"intent": "query"}');
      row.text = intent == null ? 'FAIL' : 'ok';
      if (keys['LOCAL_OPENAI_VISION'] == '1') {
        final sw = Stopwatch()..start();
        final out = await analyzer.analyzePhoto(photo);
        row
          ..photo = out.analysis == null
              ? 'FAIL'
              : 'ok ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
          ..note = out.analysis == null
              ? (out.error ?? 'no analysis')
              : (out.isFood ? 'food' : 'answered "not food"');
        expect(out.analysis, isNotNull, reason: 'Local: ${out.error}');
      } else {
        row
          ..photo = 'n/a'
          ..note = 'text-only model (set LOCAL_OPENAI_VISION=1 for photos)';
      }
      expect(intent, isNotNull, reason: 'Local: text round trip');
    }, timeout: const Timeout(Duration(minutes: 6)));
  }

  // Keyless: OpenRouter's catalog is public, so every slug the app offers
  // can be checked for existence and image input without spending a call.
  test('OpenRouter catalog — every curated model exists and takes images',
      () async {
    final resp = await client
        .get(Uri.parse('https://openrouter.ai/api/v1/models'))
        .timeout(const Duration(seconds: 40));
    expect(resp.statusCode, 200);
    final models = {
      for (final m in (jsonDecode(resp.body)['data'] as List))
        (m as Map)['id'] as String: m
    };
    final problems = <String>[];
    for (final (slug, _) in kKnownModels['openrouter']!) {
      final m = models[slug];
      if (m == null) {
        problems.add('$slug: not in the catalog');
        continue;
      }
      final inputs =
          ((m['architecture'] as Map?)?['input_modalities'] as List?) ?? [];
      if (!inputs.contains('image')) problems.add('$slug: no image input');
    }
    rows.add(_Row('OR catalog', '${kKnownModels['openrouter']!.length} models')
      ..photo = 'n/a'
      ..text = 'n/a'
      ..note = problems.isEmpty
          ? 'all curated slugs exist and accept images'
          : problems.join('; '));
    expect(problems, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  for (final (t, skip) in targets) {
    test('${t.label} — live photo + text round trip', () async {
      // test_live/ is a test directory in spirit; the analyzer only knows
      // test/.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
      if (skip != null && t.provider == AiProvider.server) {
        rows.add(_Row(t.label, '-')..note = 'SKIPPED: $skip');
        markTestSkipped(skip);
        return;
      }
      if (skip != null) {
        // No key: prove the endpoint and the rejection path live.
        await s.setProvider(t.provider);
        final row = _Row(t.label, s.activeModel)
          ..photo = 'no key'
          ..text = 'no key';
        rows.add(row);
        final probe = await createMultiProviderAnalyzer(s, client: client)
            .probeKey('bitewise-live-probe-not-a-real-key');
        final said = (probe.message ?? '').toLowerCase();
        final refusedAsKey =
            probe.result == KeyProbeResult.rejected && said.contains('key');
        row.note = refusedAsKey
            ? 'endpoint live · invalid key correctly refused'
            : 'ENDPOINT CHECK FAILED: ${probe.result.name} — ${probe.message}';
        expect(refusedAsKey, isTrue,
            reason: '${t.label}: an invalid key must come back as a KEY '
                'rejection, got ${probe.result.name}: ${probe.message}');
        return;
      }
      await t.configure(s);
      final row = _Row(
          t.label,
          t.provider == AiProvider.server
              ? '${s.serverBackend} plan'
              : s.activeModel);
      rows.add(row);
      final analyzer = createMultiProviderAnalyzer(s, client: client);

      final sw = Stopwatch()..start();
      final out = await analyzer.analyzePhoto(photo);
      final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
      if (out.analysis == null) {
        row
          ..photo = 'FAIL'
          ..note = out.error ?? 'no analysis';
      } else {
        final a = out.analysis!;
        row
          ..photo = 'ok ${secs}s'
          ..note = out.isFood
              ? 'food · ${a['total_calories']} kcal · '
                  '${'${a['meal_description'] ?? ''}'.split('\n').first}'
              : 'answered "not food"';
      }

      final intent = await analyzer.textIntent(
          'Reply with ONLY this JSON and nothing else: {"intent": "query"}');
      row.text = intent == null ? 'FAIL' : 'ok';

      expect(out.analysis, isNotNull,
          reason: '${t.label} (${row.model}): ${out.error}');
      expect(intent, isNotNull, reason: '${t.label}: text round trip');
    }, timeout: const Timeout(Duration(minutes: 6)));
  }

  tearDownAll(() {
    client.close();
    String cut(String s, int n) => s.length <= n ? s : '${s.substring(0, n - 1)}…';
    // ignore: avoid_print
    print('\n${'PROVIDER'.padRight(12)} ${'MODEL'.padRight(34)} '
        '${'PHOTO'.padRight(10)} ${'TEXT'.padRight(5)} RESULT');
    for (final r in rows) {
      // ignore: avoid_print
      print('${r.label.padRight(12)} ${cut(r.model, 34).padRight(34)} '
          '${r.photo.padRight(10)} ${r.text.padRight(5)} ${cut(r.note, 90)}');
    }
  });
}
