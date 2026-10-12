import 'dart:async';

import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// In-memory stand-in for flutter_secure_storage (no platform channel in
/// unit tests).
class MemoryKeyStore implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Future<(AppSettings, SharedPreferences, MemoryKeyStore)> freshSettings(
    {Map<String, Object> initial = const {}}) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  final keys = MemoryKeyStore();
  final s = await AppSettings.load(prefs: prefs, keyStore: keys);
  return (s, prefs, keys);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults on a fresh install', () async {
    final (s, _, _) = await freshSettings();
    expect(s.geminiApiKey, isNull);
    expect(s.model, AppSettings.defaultModel);
    expect(s.lookbackDays, 2);
    expect(s.reportTime, '21:30');
    // ON by default: the summary predates its switch (2026-10-10) and
    // every existing install, the owner's included, expects it to keep
    // arriving — the switch exists so a friend can turn it OFF.
    expect(s.summaryEnabled, isTrue);
    expect(s.watcherEnabled, isFalse);
    expect(s.dietaryProfile, isNull);
    expect(s.quotaPauseUntil, isNull);
    expect(s.isQuotaPaused, isFalse);
  });

  test('setters persist and a second load sees the values', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setGeminiApiKey('  sk-test-123  ');
    await s.setModel('gemini-2.5-pro');
    await s.setLookbackDays(7);
    await s.setReportTime('08:05');
    await s.setSummaryEnabled(false);
    await s.setWatcherEnabled(true);
    await s.setDietaryProfile('vegetarian, Cantonese cuisine');
    final pause = DateTime(2026, 7, 18, 9, 30);
    await s.setQuotaPauseUntil(pause);

    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.geminiApiKey, 'sk-test-123');
    expect(again.model, 'gemini-2.5-pro');
    expect(again.lookbackDays, 7);
    expect(again.reportTime, '08:05');
    expect(again.summaryEnabled, isFalse, reason: 'off survives a relaunch');
    expect(again.watcherEnabled, isTrue);
    expect(again.dietaryProfile, 'vegetarian, Cantonese cuisine');
    expect(again.quotaPauseUntil, pause);
  });

  test('the quota pause is stored as a UTC instant and read back local',
      () async {
    // Zone-less, a pause armed in Shanghai re-parsed in Chicago and lasted
    // 13 hours longer after the flight.
    final (s, prefs, keys) = await freshSettings();
    final pause = DateTime(2026, 10, 20, 11, 30);
    await s.setQuotaPauseUntil(pause);
    final stored = prefs.getString('settings.quota_pause_until')!;
    expect(stored, endsWith('Z'));
    expect(DateTime.parse(stored).isAtSameMomentAs(pause), isTrue);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.quotaPauseUntil, pause); // same instant, local again
  });

  test('CHANGING the key clears the quota-pause latch; re-saving it does not',
      () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setGeminiApiKey('key-A');
    final pause = DateTime.now().add(const Duration(hours: 6));
    await s.setQuotaPauseUntil(pause);

    // Same key re-entered: the pause still belongs to it — keep the latch.
    await s.setGeminiApiKey('key-A');
    expect(s.quotaPauseUntil, pause);

    // Different key: fresh project, fresh quota — a stale latch here means
    // "Key OK" with silently dead analysis for up to 12 h.
    await s.setGeminiApiKey('key-B');
    expect(s.quotaPauseUntil, isNull);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.quotaPauseUntil, isNull); // cleared in persistence too
  });

  test('API key lives only in secure storage, never in prefs', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setGeminiApiKey('sk-secret');
    expect(keys.data.values, contains('sk-secret'));
    for (final k in prefs.getKeys()) {
      expect(prefs.get(k).toString(), isNot(contains('sk-secret')));
    }
  });

  test('clearing the API key deletes it from secure storage', () async {
    final (s, _, keys) = await freshSettings();
    await s.setGeminiApiKey('sk-secret');
    await s.setGeminiApiKey('   ');
    expect(s.geminiApiKey, isNull);
    expect(keys.data, isEmpty);
  });

  test('lookbackDays clamps to 1..30 on set and on load', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setLookbackDays(0);
    expect(s.lookbackDays, 1);
    await s.setLookbackDays(99);
    expect(s.lookbackDays, 30);
    // A hand-edited out-of-range stored value clamps at load time too.
    await prefs.setInt('settings.lookback_days', 500);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.lookbackDays, 30);
  });

  test('reportTime rejects non-HH:mm values and survives bad stored data',
      () async {
    final (s, prefs, keys) = await freshSettings();
    expect(() => s.setReportTime('9pm'), throwsArgumentError);
    expect(() => s.setReportTime('25:00'), throwsArgumentError);
    expect(s.reportTime, '21:30');
    await prefs.setString('settings.report_time', 'garbage');
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.reportTime, '21:30');
  });

  test('blank model resets to the default', () async {
    final (s, _, _) = await freshSettings();
    await s.setModel('   ');
    expect(s.model, AppSettings.defaultModel);
  });

  test('blank dietary profile reads back as null', () async {
    final (s, prefs, keys) = await freshSettings();
    await s.setDietaryProfile('  ');
    expect(s.dietaryProfile, isNull);
    final again = await AppSettings.load(prefs: prefs, keyStore: keys);
    expect(again.dietaryProfile, isNull);
  });

  test('isQuotaPaused is true only while now < pause-until', () async {
    final (s, _, _) = await freshSettings();
    await s.setQuotaPauseUntil(DateTime.now().add(const Duration(hours: 1)));
    expect(s.isQuotaPaused, isTrue);
    await s.setQuotaPauseUntil(
        DateTime.now().subtract(const Duration(seconds: 1)));
    expect(s.isQuotaPaused, isFalse);
    await s.setQuotaPauseUntil(null);
    expect(s.quotaPauseUntil, isNull);
  });

  test('the summary watermark is read fresh, so a write from the '
      'heartbeat isolate is seen past this isolate\'s cache', () async {
    final (s, prefs, _) = await freshSettings();
    expect(await s.freshSummaryPostedDate(), '');
    await s.markSummaryPosted('2026-10-07');
    expect(await s.freshSummaryPostedDate(), '2026-10-07');

    // Another engine (the WorkManager run) writes the native store; this
    // isolate's cached SharedPreferences does not see it on its own.
    SharedPreferences.setMockInitialValues(
        {'settings.summary_posted_date': '2026-10-08'});
    expect(prefs.getString('settings.summary_posted_date'), '2026-10-07',
        reason: 'precondition: the cache is stale');
    expect(await s.freshSummaryPostedDate(), '2026-10-08');
  });

  test('setters notify listeners', () async {
    final (s, _, _) = await freshSettings();
    var notifications = 0;
    s.addListener(() => notifications++);
    await s.setModel('m');
    await s.setLookbackDays(3);
    await s.setWatcherEnabled(true);
    await s.setGeminiApiKey('k');
    expect(notifications, 4);
  });

  testWidgets("repliesInChinese follows the phone's language on 'system'",
      (tester) async {
    final (s, _, _) = await freshSettings();
    await s.setAppLanguage('system');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final real = AppSettings.systemLanguageCode;
    addTearDown(() => AppSettings.systemLanguageCode = real);
    AppSettings.systemLanguageCode =
        () => tester.platformDispatcher.locale.languageCode;
    tester.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
    expect(s.repliesInChinese, isTrue);
    tester.platformDispatcher.localeTestValue = const Locale('en', 'US');
    expect(s.repliesInChinese, isFalse);
    // An explicit choice wins over the phone.
    await s.setAppLanguage('zh');
    expect(s.repliesInChinese, isTrue);
    tester.platformDispatcher.localeTestValue = const Locale('zh');
    await s.setAppLanguage('en');
    expect(s.repliesInChinese, isFalse);
  });

  group('automatic-analysis latch (rejected key / blocked region)', () {
    test('arms, persists across a load, and gates canAutoAnalyze only',
        () async {
      final (s, prefs, keys) = await freshSettings();
      await s.setGeminiApiKey('k');
      expect(s.canAutoAnalyze, isTrue);
      await s.blockAutomaticAnalysis('rejectedKey',
          revision: s.credentialRevision);
      expect(s.isAnalysisBlocked, isTrue);
      expect(s.analysisBlockedKind, 'rejectedKey');
      expect(s.canAutoAnalyze, isFalse);
      expect(s.canAnalyze, isTrue, reason: 'deliberate adds still analyze');

      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.analysisBlockedKind, 'rejectedKey');
      expect(again.canAutoAnalyze, isFalse);
      // Kind, time and provider only — nothing derived from the key.
      final stored = {
        for (final k in prefs.getKeys())
          if (k.startsWith('settings.analysis_blocked')) k: prefs.get(k),
      };
      expect(stored.keys, hasLength(3));
      expect(stored['settings.analysis_blocked_kind'], 'rejectedKey');
      expect(stored['settings.analysis_blocked_provider'], 'gemini');
      expect(DateTime.tryParse('${stored['settings.analysis_blocked_until']}'),
          isNotNull);
    });

    test('expires by itself: 24 h for a rejected key, 2 h for a region',
        () async {
      final (s, _, _) = await freshSettings();
      final now = DateTime.now();
      await s.blockAutomaticAnalysis('rejectedKey',
          now: now.subtract(const Duration(hours: 23)));
      expect(s.isAnalysisBlocked, isTrue);
      await s.blockAutomaticAnalysis('rejectedKey',
          now: now.subtract(const Duration(hours: 24, minutes: 1)));
      expect(s.isAnalysisBlocked, isFalse);
      expect(s.analysisBlockedKind, isNull);

      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.subtract(const Duration(hours: 1)));
      expect(s.analysisBlockedKind, 'regionBlocked');
      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.subtract(const Duration(hours: 2, minutes: 1)));
      expect(s.isAnalysisBlocked, isFalse);

      await s.blockAutomaticAnalysis('billing');
      expect(s.isAnalysisBlocked, isFalse, reason: 'only the two kinds');
    });

    test('an end further out than the TTL (clock set back) is no pause',
        () async {
      final (s, prefs, keys) = await freshSettings();
      final now = DateTime.now();
      // Armed while the clock read a month ahead.
      await s.blockAutomaticAnalysis('rejectedKey',
          now: now.add(const Duration(days: 30)));
      expect(s.isAnalysisBlocked, isFalse);
      expect(s.analysisBlockedUntil, isNull);
      expect(s.canAutoAnalyze, s.canAnalyze);
      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.add(const Duration(hours: 1)));
      expect(s.isAnalysisBlocked, isFalse, reason: '3 h out > 2 h TTL');
      // The same from disk, as another isolate would read it.
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.isAnalysisBlocked, isFalse);
      // A nudge of a minute or two is not skew.
      await s.blockAutomaticAnalysis('regionBlocked',
          now: now.add(const Duration(minutes: 2)));
      expect(s.isAnalysisBlocked, isTrue);
    });

    test('EVERY credential, provider, model or server edit lifts it',
        () async {
      final (s, _, _) = await freshSettings();
      final edits = <String, Future<void> Function()>{
        'gemini key': () => s.setGeminiApiKey('k2'),
        'gemini model': () => s.setModel('gemini-x'),
        'provider': () => s.setProvider(AiProvider.openai),
        'openai key': () => s.setOpenaiApiKey('o'),
        'anthropic key': () => s.setAnthropicApiKey('a'),
        'qwen key': () => s.setQwenApiKey('q'),
        'doubao key': () => s.setDoubaoApiKey('d'),
        'glm key': () => s.setGlmApiKey('g'),
        'deepseek key': () => s.setDeepseekApiKey('ds'),
        'xai key': () => s.setXaiApiKey('x'),
        'openrouter key': () => s.setOpenrouterApiKey('or'),
        'server key': () => s.setServerApiKey('sv'),
        'server address': () => s.setServerBaseUrl('http://host.test'),
        'server plan': () => s.setServerBackend('glm'),
        'server model': () => s.setServerModel('sonnet'),
        'openai model': () => s.setOpenaiModel('m'),
        'anthropic model': () => s.setAnthropicModel('m'),
        'qwen model': () => s.setQwenModel('m'),
        'doubao model': () => s.setDoubaoModel('m'),
        'glm model': () => s.setGlmModel('m'),
        'deepseek model': () => s.setDeepseekModel('m'),
        'xai model': () => s.setXaiModel('m'),
        'openrouter model': () => s.setOpenrouterModel('m'),
      };
      for (final MapEntry(:key, :value) in edits.entries) {
        await s.blockAutomaticAnalysis('rejectedKey');
        expect(s.isAnalysisBlocked, isTrue, reason: key);
        final rev = s.credentialRevision;
        await value();
        expect(s.isAnalysisBlocked, isFalse, reason: key);
        expect(s.credentialRevision, greaterThan(rev), reason: key);
      }
    });

    test('a refusal read before a key edit is dropped (stale revision)',
        () async {
      final (s, _, _) = await freshSettings();
      final before = s.credentialRevision;
      await s.setGeminiApiKey('new-key');
      await s.blockAutomaticAnalysis('rejectedKey', revision: before);
      expect(s.isAnalysisBlocked, isFalse);
    });

    test('clearAnalysisBlock lifts it, on disk too', () async {
      final (s, prefs, keys) = await freshSettings();
      await s.blockAutomaticAnalysis('regionBlocked');
      await s.clearAnalysisBlock();
      expect(s.isAnalysisBlocked, isFalse);
      final again = await AppSettings.load(prefs: prefs, keyStore: keys);
      expect(again.isAnalysisBlocked, isFalse);
    });

    test('belongs to the provider that set it', () async {
      final (s, prefs, _) = await freshSettings();
      await s.blockAutomaticAnalysis('regionBlocked');
      // Another engine switched providers on disk after we armed it.
      await prefs.setString('settings.provider', AiProvider.deepseek.name);
      await prefs.setString(
          'settings.analysis_blocked_provider', AiProvider.gemini.name);
      final other = await AppSettings.load(
          prefs: prefs, keyStore: MemoryKeyStore());
      expect(other.provider, AiProvider.deepseek);
      expect(other.isAnalysisBlocked, isFalse);
    });

    test('reloadAnalysisBlock sees what the background engine wrote',
        () async {
      final (s, prefs, _) = await freshSettings();
      expect(s.isAnalysisBlocked, isFalse);
      // The background isolate armed it on disk.
      await prefs.setString('settings.analysis_blocked_until',
          DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String());
      await prefs.setString('settings.analysis_blocked_kind', 'rejectedKey');
      // A torn arm without its provider is no pause (2026-10-12): the
      // provider is written first, so it can only be missing by accident.
      await s.reloadAnalysisBlock();
      expect(s.isAnalysisBlocked, isFalse);
      expect(s.canAutoAnalyze, s.canAnalyze);
      await prefs.setString(
          'settings.analysis_blocked_provider', AiProvider.gemini.name);
      await s.reloadAnalysisBlock();
      expect(s.analysisBlockedKind, 'rejectedKey');
    });

    test('a passing key probe lifts a rejected-key pause; a region pause '
        'only when the probe reached the generation endpoint', () async {
      final (s, _, _) = await freshSettings();
      await s.blockAutomaticAnalysis('rejectedKey');
      await s.credentialsProven(reachedGeneration: false);
      expect(s.isAnalysisBlocked, isFalse);

      await s.blockAutomaticAnalysis('regionBlocked');
      await s.credentialsProven(reachedGeneration: false);
      expect(s.analysisBlockedKind, 'regionBlocked',
          reason: "the server's auth check never meets a region refusal");
      await s.credentialsProven(reachedGeneration: true);
      expect(s.isAnalysisBlocked, isFalse);
    });

    test('a passing probe lifts a pause the background engine armed on disk',
        () async {
      final (fg, _, keys) = await freshSettings();
      await fg.setGeminiApiKey('k');
      SharedPreferences.resetStatic(); // the other isolate: its own cache
      final bg = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
      await bg.blockAutomaticAnalysis('rejectedKey',
          revision: bg.credentialRevision);
      expect(fg.isAnalysisBlocked, isFalse, reason: 'stale cache');
      await fg.credentialsProven(reachedGeneration: true);
      SharedPreferences.resetStatic();
      final next = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
      expect(next.isAnalysisBlocked, isFalse);
    });

    test("a passing probe leaves another provider's pause alone", () async {
      final (s, prefs, _) = await freshSettings();
      await s.setProvider(AiProvider.deepseek);
      // Gemini's pause, still on disk from before the switch.
      await prefs.setString('settings.analysis_blocked_until',
          DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String());
      await prefs.setString('settings.analysis_blocked_kind', 'rejectedKey');
      await prefs.setString(
          'settings.analysis_blocked_provider', AiProvider.gemini.name);
      // DeepSeek's probe says nothing about Gemini's key.
      await s.credentialsProven(reachedGeneration: true);
      expect(prefs.getString('settings.analysis_blocked_provider'),
          AiProvider.gemini.name);
    });

    test('clearAnalysisBlock writes nothing when no pause is set', () async {
      // Every successful photo calls it: three removes per meal for nothing.
      final store = _CountingStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await s.clearAnalysisBlock();
      expect(store.writes, 0);
      await s.blockAutomaticAnalysis('rejectedKey');
      store.writes = 0;
      await s.clearAnalysisBlock();
      expect(store.writes, 3, reason: 'a set pause is removed');
      expect(s.isAnalysisBlocked, isFalse);
    });

    test('a reload landing between the arm\'s writes does not leave the '
        'footer saying "not paused"', () async {
      // The arm set its in-memory pause, then awaited its disk writes; a
      // resume's reloadAnalysisBlock read the half-written keys in between
      // and cleared it — and the arm's own notify then showed that.
      final store = _GatedStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await s.setGeminiApiKey('k');
      final shown = <bool>[];
      s.addListener(() => shown.add(s.isAnalysisBlocked));
      store.gate = Completer<void>();
      final arm = s.blockAutomaticAnalysis('rejectedKey',
          revision: s.credentialRevision);
      await store.gated.future; // the arm is mid-write
      await s.reloadAnalysisBlock();
      expect(s.isAnalysisBlocked, isFalse, reason: 'the race itself');
      store.gate!.complete();
      await arm;
      expect(s.isAnalysisBlocked, isTrue);
      expect(s.analysisBlockedKind, 'rejectedKey');
      expect(shown.last, isTrue, reason: 'the last notify says paused');
    });
  });
}

/// The in-memory preferences store, holding the latch's FIRST disk write
/// until [gate] completes ([gated] says it got there).
class _GatedStore extends InMemorySharedPreferencesStore {
  _GatedStore() : super.empty();
  Completer<void>? gate;
  final gated = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final g = gate;
    if (g != null && key.endsWith('settings.analysis_blocked_provider')) {
      if (!gated.isCompleted) gated.complete();
      await g.future;
    }
    return super.setValue(valueType, key, value);
  }
}

/// The in-memory preferences store, counting writes and removes.
class _CountingStore extends InMemorySharedPreferencesStore {
  _CountingStore() : super.empty();
  int writes = 0;
  @override
  Future<bool> remove(String key) {
    writes++;
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    writes++;
    return super.setValue(valueType, key, value);
  }
}
