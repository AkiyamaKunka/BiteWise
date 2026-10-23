// PRIVACY property (design R5a/R5b): whatever the inputs, a lookup request
// carries exactly the fixed instructions plus the §4 data block — no
// coordinates, timestamps, city, street, dietary profile, meal description
// or image — and only the headers a provider needs. Random requests, every
// supported client, settings seeded with sensitive values.
import 'dart:convert';
import 'dart:math';

import 'package:calorie_tracker/services/assist/clients/lookup_clients.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

// Sensitive values that exist on the phone around a lookup and must never
// reach a provider: the photo's fix, its time, the place, the profile.
const _lat = '43.07305';
const _lon = '-89.40123';
const _when = '2026-10-23T12:34:56';
const _city = 'Madisonville';
const _street = '702 State Street';
const _profile = 'PROFILE-MARKER no peanuts, type 2 diabetic';

const _bodyKeys = <String, Set<String>>{
  'api.anthropic.com': {
    'model', 'max_tokens', 'output_config', 'messages', 'tools'
  },
  'openrouter.ai': {'model', 'messages', 'plugins', 'tools', 'max_tokens'},
  'api.openai.com': {
    'model', 'input', 'tools', 'include', 'max_tool_calls',
    'max_output_tokens', 'store'
  },
  'api.x.ai': {
    'model', 'input', 'tools', 'max_turns', 'max_output_tokens', 'store'
  },
};

const _headerKeys = {
  'x-api-key',
  'anthropic-version',
  'authorization',
  'content-type',
  'http-referer',
  'x-openrouter-title',
};

String _rand(Random r, int maxLen) {
  const pool = 'abcdefghijklmnopqrstuvwxyz ABC0123456789<>/"\'\\{}[]'
      '\u0000\u0007\n\t’é漢字🍔';
  final n = r.nextInt(maxLen + 1);
  return String.fromCharCodes([
    for (var i = 0; i < n; i++) pool.runes.elementAt(r.nextInt(pool.runes.length))
  ]);
}

LookupRequest _randomRequest(Random r) => LookupRequest(
      items: [
        for (var i = 0; i < 1 + r.nextInt(15); i++)
          LookupRequestItem(
              name: _rand(r, 120),
              qty: r.nextInt(30) - 3,
              unit: _rand(r, 30),
              brand: _rand(r, 90)),
      ],
      orderMerchant: _rand(r, 90),
      chains: [
        for (var i = 0; i < r.nextInt(5); i++)
          LookupRequestChain(key: _rand(r, 20), name: _rand(r, 80)),
      ],
      country: r.nextBool() ? 'US' : _rand(r, 3),
      lang: r.nextBool() ? 'zh' : null,
    );

String _promptOf(String host, Map<String, dynamic> body) => switch (host) {
      'api.anthropic.com' => (((body['messages'] as List).first
              as Map)['content'] as List)
          .first['text'] as String,
      'openrouter.ai' => ((body['messages'] as List).first as Map)['content']
          as String,
      'api.openai.com' => body['input'] as String,
      _ => ((body['input'] as List).first as Map)['content'] as String,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('random requests × every supported client', () async {
    SharedPreferences.setMockInitialValues({});
    final keys = _Keys()
      ..data['anthropic_api_key'] = 'k-an'
      ..data['openrouter_api_key'] = 'k-or'
      ..data['openai_api_key'] = 'k-oa'
      ..data['xai_api_key'] = 'k-xa';
    final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(), keyStore: keys);
    await settings.setDietaryProfile(_profile);

    final seen = <http.Request>[];
    final s = ScriptedClient([
      (req) {
        seen.add(req);
        // Any reply: the property is about what was SENT.
        return http.Response('{"error":{"code":503}}', 503);
      }
    ]);
    final router = ProviderLookupRouter(settings,
        client: s.client,
        enableResponsesProviders: true,
        policy: const LookupCostPolicy(maxUsdPerLookup: 1));
    final r = Random(20261023);
    for (var round = 0; round < 40; round++) {
      final req = _randomRequest(r);
      for (final p in [
        AiProvider.anthropic,
        AiProvider.openrouter,
        AiProvider.openai,
        AiProvider.xai,
      ]) {
        await settings.setProvider(p);
        await router.submit(req,
            chainDomains: r.nextBool() ? mcdDomains : const []);
      }
      // Brand path: no location-derived chain survives brandOnly().
      await settings.setProvider(AiProvider.anthropic);
      await router.submit(req.brandOnly());
      final last = seen.last;
      expect(dataBlock(_promptOf(last.url.host,
              jsonDecode(last.body) as Map<String, dynamic>))['chains'],
          isEmpty);
    }
    expect(seen, hasLength(40 * 5));

    for (final req in seen) {
      final host = req.url.host;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(_bodyKeys[host]!.containsAll(body.keys), isTrue,
          reason: '$host sent ${body.keys}');
      expect(
          _headerKeys
              .containsAll(req.headers.keys.map((k) => k.toLowerCase())),
          isTrue,
          reason: '$host sent headers ${req.headers.keys}');
      final prompt = _promptOf(host, body);
      expect(prompt, startsWith(kPlaceholderLookupPrompt));
      final data = dataBlock(prompt);
      expect(data.keys.toSet().difference(
          {'items', 'order_merchant', 'chains', 'country', 'lang'}), isEmpty);
      for (final item in data['items'] as List) {
        expect((item as Map).keys.toSet(), {'name', 'qty', 'unit', 'brand'});
      }
      for (final c in data['chains'] as List) {
        expect((c as Map).keys.toSet(), {'key', 'name', 'size'});
      }
      // The data block is the WHOLE remainder of the prompt.
      expect(prompt,
          '$kPlaceholderLookupPrompt<data>${jsonEncode(data)}</data>');
      final wire = req.body;
      for (final secret in [_lat, _lon, _when, _city, _street, _profile]) {
        expect(wire.contains(secret), isFalse, reason: '$host: $secret');
      }
      expect(wire.contains('image_url'), isFalse);
      expect(wire.contains('"image"'), isFalse);
      expect(wire.contains('base64'), isFalse);
      // A key travels only in its header, never in the body.
      for (final k in ['k-an', 'k-or', 'k-oa', 'k-xa']) {
        expect(wire.contains(k), isFalse);
      }
    }
  });
}
