// The per-recipient AI consent store (App Store 5.1.2(i)): the route ids,
// the one-time seed for installs that already agreed, and persistence.
import 'package:calorie_tracker/core/ai_consent.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings_test.dart' show MemoryKeyStore, freshSettings;

const _kRoutes = 'settings.ai_consent_routes';
const _kVersions = 'settings.ai_consent_versions';
const _kDeclined = 'settings.ai_consent_update_declined';

Future<AppSettings> _reload() async => AppSettings.load(
    prefs: await SharedPreferences.getInstance(), keyStore: MemoryKeyStore());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('aiConsentRoute', () {
    test('an API key is its provider; the server is its PLAN', () {
      expect(aiConsentRoute('gemini', 'claude'), 'gemini');
      expect(aiConsentRoute('deepseek', 'glm'), 'deepseek',
          reason: 'the server plan is irrelevant off the server');
      expect(aiConsentRoute('server', 'claude'), 'server:claude');
      expect(aiConsentRoute('server', 'glm'), 'server:glm');
      expect(aiConsentRoute('server', 'doubao'), 'server:doubao');
      expect(aiConsentRoute('server', ''), 'server:claude',
          reason: 'the store falls back to claude the same way');
    });

    test('every route is listed, and the mainland-China ones are routes', () {
      for (final p in AiProvider.values.where((p) => p != AiProvider.server)) {
        expect(allAiConsentRoutes, contains(aiConsentRoute(p.name, 'claude')));
      }
      for (final b in AppSettings.serverBackends) {
        expect(allAiConsentRoutes, contains(aiConsentRoute('server', b)));
      }
      expect(allAiConsentRoutes.containsAll(aiRoutesInMainlandChina), isTrue);
    });
  });

  group('first launch of the consent build', () {
    test('a fresh install has no consent and writes nothing', () async {
      final (s, prefs, _) = await freshSettings();
      for (final r in allAiConsentRoutes) {
        expect(s.hasAiConsent(r), isFalse, reason: r);
      }
      expect(prefs.getStringList(_kRoutes), isNull);
    });

    test('the watcher ON seeds the CURRENT recipient (the owner: Claude '
        'Plan) and nothing else', () async {
      final (s, prefs, _) = await freshSettings(initial: {
        'settings.watcher_enabled': true,
        'settings.provider': 'server',
        'settings.server_backend': 'claude',
      });
      expect(s.activeAiConsentRoute, 'server:claude');
      expect(s.hasAiConsent('server:claude'), isTrue);
      expect(s.hasAiConsent('server:glm'), isFalse);
      expect(s.hasAiConsent('gemini'), isFalse);
      expect(prefs.getStringList(_kRoutes), ['server:claude']);
    });

    test('an accepted camera-roll notice seeds it too — WITHOUT a key',
        () async {
      // A watcher left on with no key would otherwise start sending,
      // unasked, the moment a key is pasted.
      final (s, prefs, keys) = await freshSettings(initial: {
        'settings.watcher_disclosure_seen': true,
        'settings.provider': 'deepseek',
      });
      expect(keys.data, isEmpty);
      expect(s.hasAiConsent('deepseek'), isTrue);
      expect(prefs.getStringList(_kRoutes), ['deepseek']);
    });

    test('the seed is frozen: a later provider change is not consent',
        () async {
      final (s, _, _) = await freshSettings(initial: {
        'settings.watcher_enabled': true,
        'settings.provider': 'gemini',
      });
      await s.setProvider(AiProvider.openai);
      expect(s.hasAiConsent('openai'), isFalse);
      final again = await _reload();
      expect(again.provider, AiProvider.openai);
      expect(again.hasAiConsent('openai'), isFalse,
          reason: 'never re-derived from the provider chosen since');
      expect(again.hasAiConsent('gemini'), isTrue);
    });

    test('a stored list is never re-seeded, even an empty one (Stop '
        'sharing)', () async {
      final (s, _, _) = await freshSettings(initial: {
        'settings.watcher_enabled': true,
        'settings.provider': 'gemini',
        _kRoutes: <String>[],
      });
      expect(s.hasAiConsent('gemini'), isFalse);
    });
  });

  test('grant and withdraw persist across a reload', () async {
    final (s, prefs, _) = await freshSettings();
    var notified = 0;
    s.addListener(() => notified++);
    await s.setAiConsent('qwen', granted: true);
    await s.setAiConsent('server:glm', granted: true);
    expect(notified, 2);
    expect((await _reload()).hasAiConsent('server:glm'), isTrue);
    await s.setAiConsent('qwen', granted: false);
    expect(prefs.getStringList(_kRoutes), ['server:glm']);
    final again = await _reload();
    expect(again.hasAiConsent('qwen'), isFalse);
    expect(again.hasAiConsent('server:glm'), isTrue);
  });

  // Re-consent (run 7): the consent text changed what is sent (B14: a
  // photo taken before 4 a.m. also carries the day before's meals), so each
  // grant remembers the text it was given under.
  group('the consent text a grant was given under', () {
    test('the current text is version 2 and is what sends the previous '
        'day', () {
      expect(aiConsentWordingVersion, 2);
      expect(aiConsentPreviousDayVersion, 2);
    });

    test('a new grant records the current text, across a reload', () async {
      final (s, prefs, _) = await freshSettings();
      expect(s.aiConsentVersion('gemini'), 0, reason: 'not allowed');
      await s.setAiConsent('gemini', granted: true);
      expect(s.aiConsentVersion('gemini'), aiConsentWordingVersion);
      expect(prefs.getStringList(_kVersions), ['gemini=2']);
      expect((await _reload()).aiConsentVersion('gemini'), 2);
      expect(s.previousDayLeftoverContext, isTrue);
    });

    test('a grant from before versions existed is version 1, and sends '
        'that day only', () async {
      final (s, prefs, _) = await freshSettings(initial: {
        _kRoutes: ['gemini', 'server:claude'],
      });
      expect(s.aiConsentVersion('gemini'), 1);
      expect(s.aiConsentVersion('server:claude'), 1);
      expect(s.previousDayLeftoverContext, isFalse);
      expect(prefs.getStringList(_kVersions), isNull,
          reason: 'reading writes nothing');
      // Allowing it again (the update question) records the new text.
      await s.setAiConsent('gemini', granted: true);
      expect(s.aiConsentVersion('gemini'), 2);
      expect(s.aiConsentVersion('server:claude'), 1, reason: 'per recipient');
      expect(s.previousDayLeftoverContext, isTrue);
    });

    test("the owner's seeded grant is version 1: they never saw the new "
        'text', () async {
      final (s, prefs, _) = await freshSettings(initial: {
        'settings.watcher_enabled': true,
        'settings.provider': 'server',
        'settings.server_backend': 'claude',
      });
      expect(s.hasAiConsent('server:claude'), isTrue);
      expect(s.aiConsentVersion('server:claude'), 1);
      expect(s.previousDayLeftoverContext, isFalse);
      expect(prefs.getStringList(_kVersions), isNull);
      expect((await _reload()).aiConsentVersion('server:claude'), 1);
    });

    test('Stop Sharing forgets the version; allowing again records the new '
        'text', () async {
      final (s, prefs, _) = await freshSettings(initial: {
        _kRoutes: ['gemini'],
      });
      await s.declineAiConsentUpdate('gemini');
      await s.setAiConsent('gemini', granted: false);
      expect(s.aiConsentVersion('gemini'), 0);
      expect(s.aiConsentUpdateDeclined('gemini'), isFalse);
      expect(prefs.getStringList(_kVersions), isEmpty);
      expect(prefs.getStringList(_kDeclined), isEmpty);
      expect(s.previousDayLeftoverContext, isFalse);
      await s.setAiConsent('gemini', granted: true);
      expect(s.aiConsentVersion('gemini'), 2);
      expect(s.previousDayLeftoverContext, isTrue);
    });

    test('Not now to the update is remembered per recipient and changes '
        'nothing else', () async {
      final (s, prefs, _) = await freshSettings(initial: {
        _kRoutes: ['gemini', 'openai'],
      });
      var notified = 0;
      s.addListener(() => notified++);
      await s.declineAiConsentUpdate('gemini');
      expect(notified, 1);
      expect(s.aiConsentUpdateDeclined('gemini'), isTrue);
      expect(s.aiConsentUpdateDeclined('openai'), isFalse);
      expect(s.hasAiConsent('gemini'), isTrue);
      expect(s.aiConsentVersion('gemini'), 1);
      expect(s.previousDayLeftoverContext, isFalse);
      expect(prefs.getStringList(_kRoutes), ['gemini', 'openai']);
      expect(prefs.getStringList(_kDeclined), ['gemini=2']);
      expect((await _reload()).aiConsentUpdateDeclined('gemini'), isTrue);
    });

    test('an answer to an older update does not silence a newer one',
        () async {
      final (s, _, _) = await freshSettings(initial: {
        _kRoutes: ['gemini'],
        _kDeclined: ['gemini=1'],
      });
      expect(s.aiConsentUpdateDeclined('gemini'), isFalse);
    });

    test('the previous day follows the CURRENT recipient', () async {
      final (s, _, _) = await freshSettings(initial: {
        _kRoutes: ['gemini', 'openai'],
        _kVersions: ['gemini=2'],
      });
      expect(s.activeAiConsentRoute, 'gemini');
      expect(s.previousDayLeftoverContext, isTrue);
      await s.setProvider(AiProvider.openai);
      expect(s.aiConsentVersion('openai'), 1);
      expect(s.previousDayLeftoverContext, isFalse);
      await s.setProvider(AiProvider.anthropic);
      expect(s.previousDayLeftoverContext, isFalse, reason: 'no grant');
    });

    test('a malformed entry reads as no version (version 1)', () async {
      final (s, _, _) = await freshSettings(initial: {
        _kRoutes: ['gemini', 'qwen', 'server:glm'],
        _kVersions: ['gemini=x', '=2', 'qwen', 'server:glm=2'],
      });
      expect(s.aiConsentVersion('gemini'), 1);
      expect(s.aiConsentVersion('qwen'), 1);
      expect(s.aiConsentVersion('server:glm'), 2,
          reason: "a route's own ':' is kept");
    });
  });

  test('the UI adapter reads and writes the same store', () async {
    final (s, _, _) = await freshSettings();
    final store = createSettingsStore(s);
    expect(store.hasAiConsent('gemini'), isFalse);
    await store.setAiConsent('gemini', granted: true);
    expect(s.hasAiConsent('gemini'), isTrue);
    await store.setAiConsent('gemini', granted: false);
    expect(store.hasAiConsent('gemini'), isFalse);
    await s.setAiConsent('openai', granted: true);
    expect(store.aiConsentVersion('openai'), aiConsentWordingVersion);
    await store.declineAiConsentUpdate('openai');
    expect(s.aiConsentUpdateDeclined('openai'), isTrue);
    expect(store.aiConsentUpdateDeclined('openai'), isTrue);
  });
}
