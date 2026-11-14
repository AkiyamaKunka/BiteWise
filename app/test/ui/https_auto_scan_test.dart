// Review of the privacy lane, finding 1: a saved http:// server address
// did not stop the automatic scan. The server key counted as present
// whenever the address was set, so canAutoAnalyze stayed true: every
// resume, library change and background run read, hashed and reserved the
// whole window, the analyzer refused each photo (retryable), the pipeline
// released it silently and the watermark never moved — battery spent and
// automatic logging stopped, without a word. Now the automatic scan does
// not run at an address the app sends nothing to (its own background stop
// reason), Settings says why, and a deliberate add still gets the
// needs-https line (canAnalyze stays true).
import 'package:calorie_tracker/core/ai_consent.dart' show aiConsentRoute;
import 'package:calorie_tracker/core/server_transport.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/photo/background_runs.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/diagnostics_screen.dart'
    show backgroundRunVerdict;
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_glue_test.dart' show EmittingIntake, MemoryKeyStore, photo;
import 'fakes.dart' show FakeAnalyzer, FakeDao, FakeIntake, FakeSettings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugRequireHttpsServerOverride = null);

  Future<(AppSettings, SharedPreferences)> serverAt(String url) async {
    SharedPreferences.setMockInitialValues({
      'settings.watcher_enabled': true,
      'settings.lookback_days': 2,
    });
    final prefs = await SharedPreferences.getInstance();
    final s = await AppSettings.load(prefs: prefs, keyStore: MemoryKeyStore());
    await s.setProvider(AiProvider.server);
    await s.setServerBaseUrl(url);
    await s.setServerApiKey('upload-key');
    await s.setAiConsent(aiConsentRoute('server', 'claude'), granted: true);
    return (s, prefs);
  }

  /// Three background runs over a 3-photo window.
  Future<({int scans, int offered, int requests, String? stop})> runs(
      AppSettings s, SharedPreferences prefs) async {
    final sent = <http.BaseRequest>[];
    final intake = EmittingIntake()..batch = [photo(1), photo(2), photo(3)];
    var offered = 0;
    String? stop;
    for (var run = 0; run < 3; run++) {
      final recorder = BackgroundRunRecorder(prefs, platform: 'android');
      await recorder.begin();
      await headlessBackfillWith(
        settings: s,
        prefs: prefs,
        intake: intake,
        pipeline: () async => PhotoPipeline(
            dao: FakeDao(),
            analyzer: ServerAnalyzer(s,
                normalizer: (b) async => b,
                client: MockClient((r) async {
                  sent.add(r);
                  return http.Response('{}', 200);
                }))),
        showMealCard: (_, _) async {},
        photoOffered: () => offered++,
        recorder: recorder,
      );
      stop = recorder.current?.stopReason;
    }
    return (
      scans: intake.scans,
      offered: offered,
      requests: sent.length,
      stop: stop
    );
  }

  for (final url in ['http://10.0.0.5', 'HTTP://h.example:5000', 'h.example']) {
    test('switch on, "$url": no automatic scan reads a photo; a deliberate '
        'add may still try (and is told why)', () async {
      debugRequireHttpsServerOverride = true;
      final (s, prefs) = await serverAt(url);
      expect(s.canAutoAnalyze, isFalse);
      expect(s.canAnalyze, isTrue);
      expect(s.autoAnalysisNeedsHttps, isTrue);
      final r = await runs(s, prefs);
      expect(r.scans, 0);
      expect(r.offered, 0);
      expect(r.requests, 0);
      expect(r.stop, BackgroundStop.needsHttps);
    });
  }

  test('https://: scanned as before', () async {
    debugRequireHttpsServerOverride = true;
    final (s, prefs) = await serverAt('https://h.example');
    expect(s.canAutoAnalyze, isTrue);
    expect(s.autoAnalysisNeedsHttps, isFalse);
    final r = await runs(s, prefs);
    expect(r.scans, greaterThan(0));
    expect(r.offered, greaterThan(0));
  });

  test('switch off: an http:// address is scanned as before', () async {
    debugRequireHttpsServerOverride = false;
    final (s, prefs) = await serverAt('http://10.0.0.5');
    expect(s.canAutoAnalyze, isTrue);
    final r = await runs(s, prefs);
    expect(r.scans, greaterThan(0));
    expect(r.requests, greaterThan(0));
  });

  test('another provider with an http:// server address saved is not '
      'affected', () async {
    debugRequireHttpsServerOverride = true;
    final (s, _) = await serverAt('http://10.0.0.5');
    await s.setProvider(AiProvider.gemini);
    await s.setGeminiApiKey('gk');
    expect(s.autoAnalysisNeedsHttps, isFalse);
    expect(s.canAutoAnalyze, isTrue);
  });

  test('no address: no key, as before (not "needs https")', () async {
    debugRequireHttpsServerOverride = true;
    final (s, prefs) = await serverAt('');
    expect(s.canAutoAnalyze, isFalse);
    expect(s.autoAnalysisNeedsHttps, isFalse);
    expect((await runs(s, prefs)).stop, BackgroundStop.noKey);
  });

  test('the fake store follows the same rule', () {
    debugRequireHttpsServerOverride = true;
    final f = FakeSettings(keys: {'server': 'k'})
      ..provider = 'server'
      ..serverBaseUrl = 'http://10.0.0.5';
    expect(f.canAnalyze, isTrue);
    expect(f.canAutoAnalyze, isFalse);
    f.serverBaseUrl = 'https://10.0.0.5';
    expect(f.canAutoAnalyze, isTrue);
  });

  test('Test AI provider names the stop in both languages', () {
    for (final locale in ['en', 'zh']) {
      final l = lookupAppLocalizations(Locale(locale));
      final line = backgroundRunVerdict(
          l,
          BackgroundRunRecord(
              start: DateTime.utc(2026, 11, 13, 9),
              end: DateTime.utc(2026, 11, 13, 9, 0, 1),
              platform: 'android',
              stopReason: BackgroundStop.needsHttps));
      expect(line, contains(l.diagBgStopNeedsHttps), reason: locale);
    }
  });

  // The user is told: the Photos footer while Watch Camera Roll is on, and
  // the snackbar when it is turned on (as for a latched scan), and no sweep
  // reads the window.
  for (final locale in const [Locale('en'), Locale('zh')]) {
    testWidgets('Settings says automatic logging is not running, and why '
        '(${locale.languageCode})', (tester) async {
      debugRequireHttpsServerOverride = true;
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final l = lookupAppLocalizations(locale);
      final settings = FakeSettings(
          keys: {'server': 'up'}, watcherDisclosureSeen: true)
        ..provider = 'server'
        ..serverBaseUrl = 'http://10.0.0.5';
      final intake = FakeIntake();
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: SettingsScreen(
          settings: settings,
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          photoIntake: intake,
          requestPhotoPermission: () async => true,
        )),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining(l.autoScanNeedsHttps), findsNothing,
          reason: 'watcher off: nothing is said');
      await tester.tap(find.byKey(const Key('watcherToggle')));
      await tester.pumpAndSettle();
      expect(find.textContaining(l.autoScanNeedsHttps), findsNWidgets(2),
          reason: 'the enable snackbar and the Photos footer');
      expect(intake.backfillScans, 0, reason: 'no sweep reads the window');
    });
  }
}
