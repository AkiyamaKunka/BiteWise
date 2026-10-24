// Provider coverage: which provider gets a lookup client, and the zero-call
// guarantee for every provider without a usable search tool.
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_clients.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_cost.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
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

Future<AppSettings> _settings(AiProvider provider) async {
  SharedPreferences.setMockInitialValues({'settings.provider': provider.name});
  final keys = _Keys();
  // Every provider has a key, so "unsupported" can never be a missing key.
  for (final k in [
    'gemini_api_key',
    'openai_api_key',
    'anthropic_api_key',
    'server_api_key',
    'qwen_api_key',
    'doubao_api_key',
    'glm_api_key',
    'deepseek_api_key',
    'xai_api_key',
    'openrouter_api_key',
  ]) {
    keys.data[k] = 'test-$k';
  }
  return AppSettings.load(
      prefs: await SharedPreferences.getInstance(), keyStore: keys);
}

/// A reply every provider's parser accepts as "something came back".
ScriptedClient _anything() => ScriptedClient([
      (req) => switch (req.url.host) {
            'api.anthropic.com' => fixture200('anthropic_found.json'),
            'openrouter.ai' => fixture200('openrouter_found.json'),
            'api.openai.com' => fixture200('openai_found.json'),
            _ => fixture200('xai_found.json'),
          }
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final unsupported = <AiProvider, String>{
    AiProvider.gemini: LookupUnsupportedReason.needsL1,
    AiProvider.qwen: LookupUnsupportedReason.noSearchTool,
    AiProvider.doubao: LookupUnsupportedReason.noSearchTool,
    AiProvider.glm: LookupUnsupportedReason.noSearchTool,
    AiProvider.deepseek: LookupUnsupportedReason.noSearchTool,
    AiProvider.server: LookupUnsupportedReason.serverJobs,
    AiProvider.openai: LookupUnsupportedReason.awaitingCostSignoff,
    AiProvider.xai: LookupUnsupportedReason.awaitingCostSignoff,
  };

  for (final e in unsupported.entries) {
    test('${e.key.name}: unsupported (${e.value}), zero HTTP calls',
        () async {
      final s = _anything();
      final router = ProviderLookupRouter(await _settings(e.key),
          client: s.client);
      final support = router.lookupSupport();
      expect(support.supported, isFalse);
      expect(support.reason, e.value);
      expect(support.recipient, LookupRecipient.none);
      expect(support.locationAllowed, isFalse);
      final o = await router.submit(bigMacRequest,
          chainDomains: mcdDomains, expectedRecipient: support.recipient);
      expect(o.kind, LookupOutcomeKind.unsupported);
      expect(o.failure!.code, isNot(LookupFailureCode.consentChanged));
      expect((await router.poll('j')).kind, LookupOutcomeKind.unsupported);
      expect(s.requests, isEmpty);
    });
  }

  final supported = <AiProvider, (LookupRecipient, String)>{
    AiProvider.anthropic: (LookupRecipient.anthropic, 'api.anthropic.com'),
    AiProvider.openrouter: (LookupRecipient.openrouter, 'openrouter.ai'),
  };
  for (final e in supported.entries) {
    test('${e.key.name}: one call to ${e.value.$2}', () async {
      final s = _anything();
      final router = ProviderLookupRouter(await _settings(e.key),
          client: s.client);
      expect(router.lookupSupport().supported, isTrue);
      expect(router.lookupSupport().recipient, e.value.$1);
      final o =
          await router.submit(bigMacRequest, expectedRecipient: e.value.$1);
      expect(o.kind, LookupOutcomeKind.done, reason: '${o.failure}');
      expect([for (final r in s.requests) r.url.host], [e.value.$2]);
    });
  }

  test('with owner sign-off, OpenAI and xAI are reachable', () async {
    for (final (p, host, who) in [
      (AiProvider.openai, 'api.openai.com', LookupRecipient.openai),
      (AiProvider.xai, 'api.x.ai', LookupRecipient.xai),
    ]) {
      final s = _anything();
      final router = ProviderLookupRouter(await _settings(p),
          client: s.client,
          enableResponsesProviders: true,
          // xAI's worst case does not fit the 5¢ default (see notes).
          policy: const LookupCostPolicy(maxUsdPerLookup: 0.20));
      expect(router.lookupSupport().supported, isTrue);
      final o = await router.submit(bigMacRequest, expectedRecipient: who);
      expect(o.kind, LookupOutcomeKind.done, reason: '$p ${o.failure}');
      expect([for (final r in s.requests) r.url.host], [host]);
    }
  });

  test('the key is read per call: Settings changes apply to the next lookup',
      () async {
    final settings = await _settings(AiProvider.anthropic);
    final s = _anything();
    final router = ProviderLookupRouter(settings, client: s.client);
    const an = LookupRecipient.anthropic;
    await router.submit(bigMacRequest, expectedRecipient: an);
    await settings.setAnthropicApiKey('rotated-key');
    await router.submit(bigMacRequest, expectedRecipient: an);
    expect([for (final r in s.requests) r.headers['x-api-key']],
        ['test-anthropic_api_key', 'rotated-key']);
    await settings.setProvider(AiProvider.deepseek);
    expect(router.lookupSupport().supported, isFalse);
    await router.submit(bigMacRequest,
        expectedRecipient: router.lookupSupport().recipient);
    expect(s.requests, hasLength(2));
  });

  group('consent is bound to the recipient', () {
    test('a provider switch between the consent check and submit: '
        'zero calls, consentChanged', () async {
      final settings = await _settings(AiProvider.anthropic);
      final s = _anything();
      final router = ProviderLookupRouter(settings, client: s.client);
      // The caller checks consent against the recipient it sees now…
      final consented = router.lookupSupport().recipient;
      expect(consented, LookupRecipient.anthropic);
      // …awaits something (the place query), and the user switches.
      await settings.setProvider(AiProvider.openrouter);
      final o = await router.submit(bigMacRequest,
          chainDomains: mcdDomains, expectedRecipient: consented);
      expect(o.kind, LookupOutcomeKind.unsupported);
      expect(o.failure!.code, LookupFailureCode.consentChanged);
      expect(o.failure!.transient, isFalse);
      expect(o.failure!.message, contains('openrouter'));
      expect(o.result, isNull);
      expect(s.requests, isEmpty);
      // Re-consented for the new recipient, the same call goes through.
      final again = await router.submit(bigMacRequest,
          expectedRecipient: router.lookupSupport().recipient);
      expect(again.kind, LookupOutcomeKind.done, reason: '${again.failure}');
      expect([for (final r in s.requests) r.url.host], ['openrouter.ai']);
    });

    test('a submit that names no recipient is refused: zero calls',
        () async {
      final s = _anything();
      final budget = DailyLookupBudget();
      final router = ProviderLookupRouter(
          await _settings(AiProvider.anthropic),
          client: s.client,
          budget: budget);
      final o = await router.submit(bigMacRequest);
      expect(o.failure!.code, LookupFailureCode.consentChanged);
      expect(s.requests, isEmpty);
      expect(budget.lookupsToday, 0, reason: 'not counted against the day');
    });

    test('a switch to the server: the job client is never reached', () async {
      final settings = await _settings(AiProvider.anthropic);
      final server = _FakeServer();
      final router = ProviderLookupRouter(settings, serverClient: server);
      final consented = router.lookupSupport().recipient;
      await settings.setProvider(AiProvider.server);
      final o =
          await router.submit(bigMacRequest, expectedRecipient: consented);
      expect(o.failure!.code, LookupFailureCode.consentChanged);
      expect(server.submits, 0);
    });

    test('a direct client cross-checks a named recipient', () async {
      final s = _anything();
      final settings = await _settings(AiProvider.openrouter);
      final router = ProviderLookupRouter(settings, client: s.client);
      final o = await router.active
          .submit(bigMacRequest, expectedRecipient: LookupRecipient.anthropic);
      expect(o.failure!.code, LookupFailureCode.consentChanged);
      expect(s.requests, isEmpty);
    });
  });

  test('a server job client is used when one is wired in', () async {
    final router = ProviderLookupRouter(await _settings(AiProvider.server),
        serverClient: _FakeServer());
    expect(router.lookupSupport().recipient, LookupRecipient.claudePlan);
    expect((await router.poll('job-1')).jobId, 'job-1');
    final o = await router.submit(bigMacRequest,
        expectedRecipient: LookupRecipient.claudePlan);
    expect(o.kind, LookupOutcomeKind.pending);
  });
}

class _FakeServer implements LookupClient {
  int submits = 0;
  @override
  LookupSupport lookupSupport() => const LookupSupport(
      supported: true,
      recipient: LookupRecipient.claudePlan,
      locationAllowed: false);
  @override
  Future<LookupOutcome> submit(LookupRequest request,
      {List<String> chainDomains = const [],
      LookupCancelToken? cancel,
      LookupRecipient? expectedRecipient}) async {
    submits++;
    return const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
        jobId: 'job-1');
  }
  @override
  Future<LookupOutcome> poll(String jobId) async => LookupOutcome(
      kind: LookupOutcomeKind.pending,
      provider: LookupRecipient.claudePlan,
      jobId: jobId);
}
