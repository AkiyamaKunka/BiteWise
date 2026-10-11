// _AppSettingsStore: the ONE piece of production code that maps the UI's
// provider-scoped apiKey/model onto AppSettings' seven per-provider slots.
//
// It had ZERO tests: every widget test used FakeSettings, which SIMULATES
// the routing correctly, so the suite would stay green while the real
// adapter wrote a Qwen key into the Gemini slot. The comment in
// widget_test.dart claimed this was "exercised at integration time" — but
// the E2E needs a live key and never runs in CI (review 2026-07-31).
import 'package:calorie_tracker/services/report/notifications.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/di.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;

Future<(AppSettings, SettingsStore)> build() async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load(
      prefs: await SharedPreferences.getInstance(),
      keyStore: MemoryKeyStore());
  return (settings, createSettingsStore(settings));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('apiKey reads and writes the ACTIVE provider slot', () async {
    final (settings, store) = await build();
    await settings.setGeminiApiKey('gem');
    await settings.setQwenApiKey('qw');

    expect(store.apiKey, 'gem');
    await store.update(provider: 'qwen');
    expect(store.provider, 'qwen');
    expect(store.apiKey, 'qw', reason: 'the ACTIVE slot, not a cached one');

    // A write while Qwen is active must land in the QWEN slot only.
    await store.update(apiKey: 'qw2');
    expect(settings.qwenApiKey, 'qw2');
    expect(settings.geminiApiKey, 'gem',
        reason: "another provider's key must never be overwritten");
  });

  test('model is provider-scoped too, with each default preserved',
      () async {
    final (settings, store) = await build();
    expect(store.model, AppSettings.defaultModel);
    await store.update(provider: 'glm');
    expect(store.model, AppSettings.defaultGlmModel);
    await store.update(model: 'glm-4.6v');
    expect(settings.glmModel, 'glm-4.6v');

    await store.update(provider: 'doubao');
    expect(store.model, AppSettings.defaultDoubaoModel,
        reason: 'switching providers must not carry the GLM model over');
    expect(settings.glmModel, 'glm-4.6v', reason: 'and must not clobber it');
  });

  test('the server provider needs BOTH url and key to count as configured',
      () async {
    final (settings, store) = await build();
    await store.update(provider: 'server');
    expect(store.apiKey, isEmpty);
    await store.update(apiKey: 'upload-key');
    expect(store.apiKey, isEmpty,
        reason: 'a key without an address cannot analyze anything');
    await store.update(serverBaseUrl: 'http://10.0.0.5/');
    expect(store.apiKey, 'upload-key');
    expect(settings.serverBaseUrl, 'http://10.0.0.5',
        reason: 'trailing slashes are trimmed so path joins never double');
  });

  test('canAnalyze and the quota latch travel through the seam', () async {
    final (settings, store) = await build();
    expect(store.canAnalyze, isFalse, reason: 'no key yet');
    await store.update(apiKey: 'k');
    expect(store.canAnalyze, isTrue);

    await settings.setQuotaPauseUntil(
        DateTime.now().add(const Duration(hours: 2)));
    expect(store.isQuotaPaused, isTrue);
    expect(store.quotaPauseUntil, isNotNull);
    expect(store.canAnalyze, isFalse);
  });

  test('an unknown provider string is ignored, not crashed on', () async {
    final (_, store) = await build();
    await store.update(provider: 'not-a-provider');
    expect(store.provider, 'gemini');
  });

  test('serverBackend round-trips and rejects unknown values', () async {
    final (settings, store) = await build();
    expect(store.serverBackend, 'claude');
    await store.update(serverBackend: 'doubao');
    expect(store.serverBackend, 'doubao');
    expect(settings.serverBackend, 'doubao');
    await store.update(serverBackend: 'gpt');
    expect(store.serverBackend, 'claude');
  });

  test('reportTime: iOS re-arms the OS card and NEVER the in-process Timer '
      '(loop find 2026-10-07)', () async {
    // Both armed at once made a suspended iPhone app wake the next morning
    // and post a second, stale 昨天 card on top of the OS one.
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: MemoryKeyStore());
    final notifier = ReportNotifier(presenter: (_, _, _) async {});
    var rearmed = 0;
    final ios = createSettingsStore(settings,
        notifier: notifier, onReportTimeChanged: () async => rearmed++);
    await ios.update(reportTime: '23:55');
    expect(settings.reportTime, '23:55');
    expect(rearmed, 1);
    expect(notifier.nextDailyFire, isNull,
        reason: 'no Timer on the OS path');

    // Android (no OS hook) keeps the Timer path.
    final android = createSettingsStore(settings, notifier: notifier);
    await android.update(reportTime: '22:00');
    expect(notifier.nextDailyFire, isNotNull);
    notifier.cancelDaily();
  });

  test('summaryEnabled off cancels BOTH the Timer and the OS card, a slot '
      'edit while off arms nothing, on re-arms (2026-10-10)', () async {
    // Friends on the pre-08-16 APKs got a nightly card with no off
    // switch; muting the OS channel was the only escape and silenced meal
    // cards too.
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(),
        keyStore: MemoryKeyStore());
    final cancelled = <int>[];
    final notifier = ReportNotifier(
        presenter: (_, _, _) async {},
        canceller: (id) async => cancelled.add(id));

    // Android: the in-process Timer path.
    final android = createSettingsStore(settings, notifier: notifier);
    expect(android.summaryEnabled, isTrue, reason: 'default on');
    await android.update(reportTime: '22:00');
    expect(notifier.nextDailyFire, isNotNull);
    await android.update(summaryEnabled: false);
    expect(settings.summaryEnabled, isFalse);
    expect(android.summaryEnabled, isFalse);
    expect(notifier.nextDailyFire, isNull, reason: 'the Timer is cancelled');
    expect(cancelled, [ReportNotifier.dailyReportNotificationId],
        reason: 'and the card the OS holds is withdrawn');
    await android.update(reportTime: '23:00');
    expect(settings.reportTime, '23:00');
    expect(notifier.nextDailyFire, isNull,
        reason: 'a slot edit while off must arm nothing');
    await android.update(summaryEnabled: true);
    expect(notifier.nextDailyFire, isNotNull, reason: 'on re-arms');
    notifier.cancelDaily();

    // iOS: the OS hook, never the Timer.
    var rearmed = 0;
    final ios = createSettingsStore(settings,
        notifier: notifier, onReportTimeChanged: () async => rearmed++);
    await ios.update(summaryEnabled: false);
    await ios.update(reportTime: '21:00');
    expect(rearmed, 0, reason: 'off: no re-arm, not even for a slot edit');
    expect(cancelled, hasLength(2));
    await ios.update(summaryEnabled: true);
    expect(rearmed, 1);
    expect(notifier.nextDailyFire, isNull, reason: 'no Timer on the OS path');
  });
}
