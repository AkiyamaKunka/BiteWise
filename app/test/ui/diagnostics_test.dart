// The staged provider checks behind the "Test AI provider" page. Each
// stage maps a distinct failure class from the provider feedback matrix;
// these tests prove each class lands in the right stage with an
// actionable fix — the page exists because a refused backend spent an
// hour looking like "the API is broken" (2026-07-31).
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/background_runs.dart';
import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:calorie_tracker/ui/diagnostics.dart';
import 'package:calorie_tracker/ui/provider_names.dart';
import 'package:calorie_tracker/ui/screens/diagnostics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

Uint8List _img() => Uint8List.fromList(List.filled(32, 9));

ProviderDiagnostics _diag({
  FakeSettings? settings,
  FakeAnalyzer? analyzer,
  http.Client? client,
}) =>
    ProviderDiagnostics(
      settings: settings ?? FakeSettings(),
      analyzer: analyzer ?? _okAnalyzer(),
      // English l10n keeps every existing stage/summary assertion below
      // byte-identical to the strings this page shipped with.
      l10n: AppLocalizationsEn(),
      client: client ?? MockClient((_) async => http.Response('ok', 404)),
      testImage: _img,
    );

FakeAnalyzer _okAnalyzer() => FakeAnalyzer()
  ..nextTextIntent = {'ok': true}
  ..nextPhotoOutcome = const AnalysisOutcome(
      analysis: {'is_food': false, 'reason': 'a test disc'},
      isFood: false,
      wall: Duration.zero);

void main() {
  test('all six stages pass on a healthy setup', () async {
    final results = await _diag().run().toList();
    expect(results, hasLength(6));
    expect(results.map((r) => r.status).toSet(), {DiagStatus.pass});
    expect(results.first.stage, 'Configuration');
    expect(results.last.stage, 'Quota');
  });

  test('missing key stops at Configuration with a fix', () async {
    final results =
        await _diag(settings: FakeSettings(apiKey: '')).run().toList();
    expect(results, hasLength(1));
    expect(results.single.status, DiagStatus.fail);
    expect(results.single.fix, contains('Settings'));
  });

  test('server provider without an address stops at Configuration',
      () async {
    final settings = FakeSettings(apiKey: 'k')..provider = 'server';
    final results = await _diag(settings: settings).run().toList();
    expect(results.single.summary, contains('server address'));
  });

  test('unreachable intl endpoint names the VPN, and stops', () async {
    final results = await _diag(
      client: MockClient((_) async => throw Exception('network is down')),
    ).run().toList();
    expect(results, hasLength(2));
    expect(results.last.stage, 'Endpoint reachability');
    expect(results.last.status, DiagStatus.fail);
    expect(results.last.fix, contains('VPN'),
        reason: 'gemini is unreachable from mainland China without one');
  });

  test('a passing key probe tells the store the credentials work — the '
      'automatic-scan pause lifts without a key edit', () async {
    // Review 2026-10-12: the owner who fixed the account at the provider's
    // console and pressed 测试当前服务 still waited a day for the scan.
    final settings = FakeSettings();
    await _diag(settings: settings).run().toList();
    // Probe OK (a generation call for a direct provider), then the photo
    // round-trip.
    expect(settings.credentialsProvenCalls, [true, true]);

    // The server's probe is its auth check — no generation endpoint — so
    // that alone must not lift a region pause; its photo round-trip may.
    final server = FakeSettings()
      ..provider = 'server'
      ..apiKey = 'k'
      ..serverBaseUrl = 'http://h.test';
    await _diag(settings: server).run().toList();
    expect(server.credentialsProvenCalls, [false, true]);

    // A rejected probe proves nothing.
    final refused = FakeSettings();
    await _diag(
            settings: refused,
            analyzer: _okAnalyzer()
              ..onValidateKey = (_) async => 'The provider rejected the key.')
        .run()
        .toList();
    expect(refused.credentialsProvenCalls, isEmpty);
  });

  test('rejected key stops at Authentication; out-of-credit only WARNS '
      'and continues', () async {
    final rejected = _okAnalyzer()
      ..onValidateKey = (_) async => 'The provider rejected the API key.';
    var results = await _diag(analyzer: rejected).run().toList();
    expect(results.last.stage, 'Authentication');
    expect(results.last.status, DiagStatus.fail);

    // probeKey, NOT validateKey: validateKey ACCEPTS a quota-class reply
    // (the key did authenticate), so an empty account is invisible to it —
    // this stage used to pin a string no production analyzer could ever
    // return, i.e. a fake-only contract (review 2026-07-31).
    final broke = _okAnalyzer()
      ..onProbeKey = (_) async => const KeyProbe(KeyProbeResult.outOfCredit,
          message: 'Provider balance or credits exhausted.');
    results = await _diag(analyzer: broke).run().toList();
    final auth = results.firstWhere((r) => r.stage == 'Authentication');
    expect(auth.status, DiagStatus.warn);
    expect(auth.summary, contains('cannot pay'));
    expect(auth.fix, contains('free tier'));
    expect(results, hasLength(6),
        reason: 'out-of-credit is a warning, not a dead stop — the later '
            'stages still tell the user what else works');
  });

  test('a rate-limited key warns differently from an empty account',
      () async {
    final limited = _okAnalyzer()
      ..onProbeKey = (_) async => const KeyProbe(KeyProbeResult.rateLimited,
          message: 'Rate limit hit.');
    final results = await _diag(analyzer: limited).run().toList();
    final auth = results.firstWhere((r) => r.stage == 'Authentication');
    expect(auth.status, DiagStatus.warn);
    expect(auth.summary, contains('rate-limiting'));
    expect(auth.fix, contains('Wait'),
        reason: 'waiting fixes a rate limit; it never fixes a dead balance');
  });

  test('a wrong model id stops at Authentication naming the MODEL, never '
      '"re-copy the key"', () async {
    // A retired or mistyped model id used to read "The key was not
    // accepted" with a re-copy-the-key fix — for a key that worked.
    final badModel = _okAnalyzer()
      ..onProbeKey = (_) async => const KeyProbe(
          KeyProbeResult.modelNotFound,
          message: 'GLM model not found — check the model name in '
              'Settings.');
    final results = await _diag(
            settings: FakeSettings(model: 'gemini-9.9-nope'),
            analyzer: badModel)
        .run()
        .toList();
    expect(results.last.stage, 'Authentication');
    expect(results.last.status, DiagStatus.fail);
    expect(results.last.summary, contains('"gemini-9.9-nope"'));
    expect(results.last.summary, isNot(contains('not accepted')));
    expect(results.last.detail, contains('model not found'));
    expect(results.last.fix, AppLocalizationsEn().diagFixPickModel);
    expect(results.last.fix, isNot(contains('Re-copy')));
    // The owner reads the Chinese page.
    expect(AppLocalizationsZh().diagModelNotFound('gemini-9.9-nope'),
        allOf(contains('找不到模型'), isNot(contains('未被接受'))));
  });

  test('a region-blocked Gemini stops at Authentication with a VPN fix, '
      'never "re-copy the key"', () async {
    final blocked = _okAnalyzer()
      ..onProbeKey = (_) async => const KeyProbe(
          KeyProbeResult.regionBlocked,
          message: 'Gemini is not available from your current network '
              'region (check the VPN).');
    final results = await _diag(analyzer: blocked).run().toList();
    expect(results.last.stage, 'Authentication');
    expect(results.last.status, DiagStatus.fail);
    expect(results.last.summary,
        AppLocalizationsEn().errRegionBlocked('Gemini'));
    expect(results.last.fix, AppLocalizationsEn().diagFixVpnRegion('Gemini'));
    expect(results.last.fix, isNot(contains('Re-copy')));
    expect(AppLocalizationsZh().errRegionBlocked('OpenAI'), contains('VPN'));
  });

  testWidgets('a stage that THROWS is reported, never silently green',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final boom = _okAnalyzer()
      ..onProbeKey = (_) async => throw StateError('provider exploded');
    await tester.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(diagnostics: _diag(analyzer: boom))));
    await tester.tap(find.byKey(const Key('runDiagnostics')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Everything works'), findsNothing,
        reason: 'a half-finished run must never wear the green verdict');
    expect(find.text('Test run'), findsOneWidget);
    expect(find.textContaining('provider exploded'), findsOneWidget);
  });

  test('junk text reply warns; photo failure carries the verbatim error '
      'and retryability', () async {
    final analyzer = _okAnalyzer()
      ..nextTextIntent = null
      ..nextPhotoOutcome = const AnalysisOutcome(
          error: 'Doubao model not found — Ark needs the EXACT versioned '
              'ID from its model list.',
          retryable: false,
          wall: Duration.zero);
    final results = await _diag(analyzer: analyzer).run().toList();
    expect(results.firstWhere((r) => r.stage == 'Text analysis').status,
        DiagStatus.warn);
    final photo = results.firstWhere((r) => r.stage == 'Photo analysis');
    expect(photo.status, DiagStatus.fail);
    expect(photo.summary, contains('retry will NOT fix'));
    expect(photo.detail, contains('EXACT versioned ID'),
        reason: 'the provider-specific message must reach the user');
  });

  test('a failed text request never claims photos work when the photo '
      'request failed too, and only then suggests a model change',
      () async {
    // textIntent returns null for every failure (busy server, closed
    // Claude window, timeout, junk reply). On a closed window the photo
    // row failed for the same reason while this row still said "photo
    // analysis can still work" and prescribed a model change.
    final en = AppLocalizationsEn();
    final bothDown = _okAnalyzer()
      ..nextTextIntent = null
      ..nextPhotoOutcome = const AnalysisOutcome(
          error: 'Claude usage window is closed — try again later.',
          retryable: true,
          wall: Duration.zero);
    var results = await _diag(analyzer: bothDown).run().toList();
    expect(results, hasLength(6));
    expect(results.map((r) => r.stage).toList().sublist(3, 5),
        ['Text analysis', 'Photo analysis'],
        reason: 'the text row still comes before the photo row');
    var text = results.firstWhere((r) => r.stage == 'Text analysis');
    expect(text.status, DiagStatus.warn);
    expect(text.summary, isNot(contains('did not return usable JSON')),
        reason: 'a busy or closed server is not the model\'s JSON');
    expect(text.detail, isNot(contains('can still work')));
    expect(text.detail, en.diagTextBadPhotoAlsoFailed);
    expect(text.fix, isNot(contains('pick a different model')));
    expect(text.fix, en.diagFixTextFollowPhoto);
    final zh = AppLocalizationsZh();
    expect(zh.diagTextBadPhotoAlsoFailed, isNot(contains('仍然可以')));
    expect(zh.diagTextBad, isNot(startsWith('模型没有')));

    // Photo fine, text broken: the model's text output is the suspect,
    // so the conditional model-change fix stays.
    final textOnly = _okAnalyzer()..nextTextIntent = null;
    results = await _diag(analyzer: textOnly).run().toList();
    text = results.firstWhere((r) => r.stage == 'Text analysis');
    expect(text.detail, en.diagTextBadDetail);
    expect(text.fix, en.diagFixTextPickModel);
    expect(zh.diagFixTextPickModel, contains('照片分析正常'));
  });

  test('quota pause surfaces as a warning with the until-time', () async {
    final settings = FakeSettings()
      ..isQuotaPaused = true
      ..quotaPauseUntil = DateTime(2026, 7, 31, 22, 0);
    final results = await _diag(settings: settings).run().toList();
    final quota = results.firstWhere((r) => r.stage == 'Quota');
    expect(quota.status, DiagStatus.warn);
    expect(quota.detail, contains('2026-07-31'));
  });

  test('the Chinese page names the provider and plan as the settings do, '
      'never by raw id', () async {
    // The owner's 测试 AI 服务 read '服务“qwen”已配置 Key' and 'qwen的接口有
    // 响应' while every other screen says 'Qwen 通义千问'; the server row
    // read '后端：claude' beside a Settings row that says 'Claude 订阅'.
    final zh = AppLocalizationsZh();
    final qwen = FakeSettings()
      ..provider = 'qwen'
      ..apiKey = 'k';
    var results = await ProviderDiagnostics(
      settings: qwen,
      analyzer: _okAnalyzer(),
      l10n: zh,
      client: MockClient((_) async => http.Response('ok', 404)),
      testImage: _img,
    ).run().take(2).toList();
    expect(results[0].summary, contains('Qwen 通义千问'));
    expect(results[1].summary, contains('Qwen 通义千问'));
    for (final r in results) {
      expect(r.summary, isNot(contains('“qwen”')));
      expect(r.summary, isNot(startsWith('qwen')));
    }

    results = await ProviderDiagnostics(
      settings: qwen,
      analyzer: _okAnalyzer(),
      l10n: zh,
      client: MockClient((_) async => throw Exception('network is down')),
      testImage: _img,
    ).run().toList();
    expect(results.last.summary, zh.diagEndpointUnreachable('Qwen 通义千问'));

    final plan = FakeSettings()
      ..provider = 'server'
      ..apiKey = 'k'
      ..serverBaseUrl = 'https://example.invalid'
      ..serverBackend = 'claude';
    results = await ProviderDiagnostics(
      settings: plan,
      analyzer: _okAnalyzer(),
      l10n: zh,
      client: MockClient((_) async => http.Response('ok', 404)),
      testImage: _img,
    ).run().take(1).toList();
    expect(results.single.summary, contains('Claude 订阅'));
    expect(results.single.summary, isNot(contains('：claude')));
  });

  test('a rejected key with no evidence shows no English detail line',
      () async {
    // probeKey now leaves a genuine auth refusal message-less; the card
    // under 'Key 未被接受' used to repeat it in English.
    final rejected = _okAnalyzer()
      ..onProbeKey = (_) async => const KeyProbe(KeyProbeResult.rejected);
    final results = await _diag(analyzer: rejected).run().toList();
    expect(results.last.stage, 'Authentication');
    expect(results.last.status, DiagStatus.fail);
    expect(results.last.detail, isNull);
    expect(results.last.fix, AppLocalizationsEn().diagFixRecopyKey);
  });

  test('plan row values: English unchanged, Chinese matches the picker',
      () {
    final en = AppLocalizationsEn();
    final zh = AppLocalizationsZh();
    // English widths are pinned by row_fit_layout_test (loop find
    // 2026-10-08) — these stay byte-identical.
    expect(providerDisplayLabel(en, 'server', 'claude'), 'Claude Plan');
    expect(providerDisplayLabel(en, 'server', 'glm'), 'GLM Plan');
    expect(providerDisplayLabel(en, 'server', 'doubao'), 'Doubao Plan');
    expect(providerDisplayLabel(zh, 'server', 'claude'), zh.planClaude);
    expect(providerDisplayLabel(zh, 'server', 'glm'), 'GLM 套餐');
    expect(providerDisplayLabel(zh, 'server', 'doubao'), '豆包套餐');
    expect(providerDisplayLabel(zh, 'qwen', 'claude'), 'Qwen 通义千问');
  });

  test('the welcome card and the VPN fix list DeepSeek as mainland-direct',
      () {
    // The API Key page tags DeepSeek 中国直连 and lists it first in its
    // footer; the welcome card one tap earlier still said only Qwen,
    // Doubao or GLM work without a VPN (stale since DeepSeek landed).
    for (final l in [AppLocalizationsEn(), AppLocalizationsZh()]) {
      expect(l.settingsWelcomeBody, contains('DeepSeek'));
      expect(l.diagFixVpn, contains('DeepSeek'));
      // OpenRouter is not VPN-tagged, so the card must not lump it in.
      expect(l.settingsWelcomeBody, isNot(contains('其余服务')));
      expect(l.settingsWelcomeBody, isNot(contains('the other providers')));
    }
  });

  testWidgets('the screen streams results and renders the verdict',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(diagnostics: _diag())));
    await tester.tap(find.byKey(const Key('runDiagnostics')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('diagVerdict')), findsOneWidget);
    expect(find.textContaining('Everything works'), findsOneWidget);
    expect(find.text('Photo analysis'), findsOneWidget);
  });

  testWidgets('problems show the count and the fixes', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final analyzer = _okAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          error: 'quota hit', retryable: true, wall: Duration.zero);
    await tester.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(
            diagnostics: _diag(analyzer: analyzer))));
    await tester.tap(find.byKey(const Key('runDiagnostics')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 problem'), findsOneWidget);
    expect(find.textContaining('TEMPORARY'), findsOneWidget);
  });

  // 2026-10-18: what the background scans did, from their own record.
  group('recent background scans', () {
    final t0 = DateTime.utc(2026, 10, 18, 3, 0);
    final killed = BackgroundRunRecord(
        start: t0,
        platform: 'ios',
        stage: BackgroundRunStage.photo,
        enumerated: 3,
        offered: 2,
        analyzed: 1,
        saved: 1,
        watermarkBefore: DateTime.utc(2026, 10, 11, 2, 26));
    final budget = BackgroundRunRecord(
        start: t0.subtract(const Duration(minutes: 30)),
        end: t0.subtract(const Duration(minutes: 29, seconds: 46)),
        platform: 'ios',
        stage: BackgroundRunStage.done,
        stopReason: BackgroundStop.budget,
        released: 2);
    final failed = BackgroundRunRecord(
        start: t0.subtract(const Duration(hours: 1)),
        end: t0.subtract(const Duration(hours: 1)),
        platform: 'ios',
        stage: BackgroundRunStage.done,
        stopReason: 'error:PlatformException');

    Future<void> pump(WidgetTester tester, List<BackgroundRunRecord> runs,
        {Locale? locale}) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          locale: locale,
          localizationsDelegates:
              locale == null ? null : AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiagnosticsScreen(
              diagnostics: _diag(), loadBackgroundRuns: () async => runs)));
      await tester.pumpAndSettle();
    }

    testWidgets('a killed run shows the step it was on and its counts; '
        'finished ones say how they ended', (tester) async {
      await pump(tester, [killed, budget, failed]);
      expect(find.text('Recent background scans'), findsOneWidget);
      expect(
          find.text('Ended by the system before it finished — last step: '
              'processing a photo.'),
          findsOneWidget);
      expect(find.textContaining('did not finish'), findsOneWidget);
      expect(
          find.text('Photos: 3 listed, 2 read, 1 processed, 1 logged, '
              '0 left for later'),
          findsOneWidget);
      expect(find.textContaining('2026-10-'), findsWidgets);
      expect(find.text('Used its time; the rest waits for the next scan.'),
          findsOneWidget);
      expect(find.textContaining('14 s'), findsOneWidget);
      expect(find.text('Stopped by an error (PlatformException).'),
          findsOneWidget);
    });

    testWidgets('in Chinese', (tester) async {
      await pump(tester, [killed], locale: const Locale('zh'));
      expect(find.text('最近的后台扫描'), findsOneWidget);
      expect(find.text('在完成前被系统结束，最后一步：处理照片。'), findsOneWidget);
      expect(find.text('照片：列出 3，读取 2，处理完 1，记录 1，留待之后 0'),
          findsOneWidget);
      expect(find.textContaining('未完成'), findsOneWidget);
    });

    testWidgets('only the latest five are listed', (tester) async {
      final runs = [
        for (var i = 0; i < 7; i++)
          BackgroundRunRecord(
              start: t0.subtract(Duration(minutes: 30 * i)),
              end: t0.subtract(Duration(minutes: 30 * i)),
              platform: 'android',
              stage: BackgroundRunStage.done,
              stopReason: BackgroundStop.done),
      ];
      await pump(tester, runs);
      expect(find.text('Finished.'), findsNWidgets(diagBackgroundRunsShown));
    });

    testWidgets('no record yet says so', (tester) async {
      await pump(tester, const []);
      expect(find.text('No background scan has been recorded yet.'),
          findsOneWidget);
    });

    test('every stop reason has its own words', () {
      final l = AppLocalizationsEn();
      BackgroundRunRecord ended(String reason) => BackgroundRunRecord(
          start: t0,
          end: t0,
          platform: 'ios',
          stage: BackgroundRunStage.done,
          stopReason: reason);
      final lines = {
        for (final r in [
          BackgroundStop.done,
          BackgroundStop.budget,
          BackgroundStop.paused,
          BackgroundStop.noKey,
          BackgroundStop.watcherOff,
          BackgroundStop.noPermission,
          'error:StateError',
        ])
          backgroundRunVerdict(l, ended(r)),
      };
      expect(lines, hasLength(7));
      expect(backgroundRunVerdict(l, ended('error:StateError')),
          'Stopped by an error (StateError).');
    });
  });

  // Design G1b: what the change history caught for the automatic scan.
  group('late imports', () {
    final now = DateTime(2026, 10, 23, 12);
    final lastAt = DateTime(2026, 10, 23, 11, 30);
    LateImportStats stats(String status) => LateImportStats(caught: [
          DateTime(2026, 10, 12, 9), // older than 7 days
          DateTime(2026, 10, 20, 9),
          DateTime(2026, 10, 22, 19),
        ], lastAt: lastAt, lastStatus: status);

    Future<void> pump(WidgetTester tester, LateImportStats? record,
        {Locale? locale, Size size = const Size(800, 4000), double scale = 1}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      if (scale != 1) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpWidget(MaterialApp(
          locale: locale,
          localizationsDelegates:
              locale == null ? null : AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiagnosticsScreen(
              diagnostics: _diag(),
              loadBackgroundRuns: () async => const [],
              loadLateImports: () async => record,
              now: () => now)));
      await tester.pumpAndSettle();
    }

    testWidgets('how many were caught this week and when it last looked',
        (tester) async {
      await pump(tester, stats('ok'));
      expect(find.text('Late imports (other apps, glasses)'), findsOneWidget);
      expect(find.text('2 caught in 7 days · last ${localStamp(lastAt)}'),
          findsOneWidget);
      expect(find.text('History expired — rescanning'), findsNothing);
      expect(find.text('Needs iOS 16'), findsNothing);
    });

    testWidgets('a rescan in progress says so', (tester) async {
      await pump(tester, stats(lateImportRescanning));
      expect(find.text('History expired — rescanning'), findsOneWidget);
    });

    testWidgets('an iPhone without the change history says so',
        (tester) async {
      await pump(tester, stats('unsupported'));
      expect(find.text('Needs iOS 16'), findsOneWidget);
    });

    testWidgets('in Chinese', (tester) async {
      await pump(tester, stats(lateImportRescanning),
          locale: const Locale('zh'));
      expect(find.text('后导入的照片（其他 App、眼镜）'), findsOneWidget);
      expect(find.text('7 天内补录 2 张 · 最近 ${localStamp(lastAt)}'),
          findsOneWidget);
      expect(find.text('历史已过期 — 正在重新扫描'), findsOneWidget);
    });

    testWidgets('no record (Android, or never looked): no section',
        (tester) async {
      await pump(tester, null);
      expect(find.byKey(const Key('diagLateImports')), findsNothing);
    });

    // The row wraps rather than cut: a narrow phone at the largest text
    // size, both languages.
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      testWidgets('fits a 320-pt phone at 2x text ($locale)', (tester) async {
        await pump(tester, stats(lateImportRescanning),
            locale: locale, size: const Size(320, 6000), scale: 2);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('diagLateImports')), findsOneWidget);
      });
    }

    test('status lines exist only where they help', () {
      final l = AppLocalizationsEn();
      expect(lateImportStatusLine(l, null), isNull);
      expect(lateImportStatusLine(l, 'ok'), isNull);
      expect(lateImportStatusLine(l, 'denied'), isNull);
      expect(lateImportStatusLine(l, lateImportRescanning),
          'History expired — rescanning');
      expect(lateImportStatusLine(AppLocalizationsZh(), 'unsupported'),
          '需要 iOS 16');
    });
  });
}
