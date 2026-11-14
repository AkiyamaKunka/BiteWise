// The automatic-scan pause (AppSettings.analysis_blocked_*) end to end,
// with the REAL settings, analyzers and pipeline: the pause must be armed
// by nothing but a genuine credential refusal, and anything that proves
// the credentials work must lift it (second adversarial review of the
// latch, 2026-10-12).
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/background_glue.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart' show FakeAnalyzer, FakeDao;

class _MemKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

IntakePhoto _auto(int n) =>
    IntakePhoto(Uint8List.fromList([n, n, n]), 'a$n', 'IMG_$n.jpg');

void main() {
  group('a web filter / captive portal answering 401/403', () {
    // The owner's Claude Plan server is plain HTTP; its own 401 is JSON
    // {"error":"Unauthorized"}. An HTML/text 401/403 is something on the
    // path answering instead, and read as "key rejected" it parked the
    // automatic scan for 24 h on a key that works (probes A1/A2).
    final pages = {
      'HTML 403': () => http.Response(
          '<html><body><h1>403 Forbidden</h1>Access denied by web filter'
          '</body></html>',
          403,
          headers: {'content-type': 'text/html'}),
      'text 401': () => http.Response('Login required', 401),
    };
    for (final entry in pages.entries) {
      test('${entry.key}: no pause, the photo is released for the next scan',
          () async {
        SharedPreferences.setMockInitialValues({});
        final s = await AppSettings.load(
            prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
        await s.setProvider(AiProvider.server);
        await s.setServerBaseUrl('https://10.0.0.5');
        await s.setServerApiKey('k');
        final analyzer = ServerAnalyzer(s,
            normalizer: (b) async => b,
            sleep: (_) async {},
            client: MockClient((_) async => entry.value()));
        final dao = FakeDao();
        final out = await PhotoPipeline(
                dao: dao, analyzer: analyzer, latch: autoScanLatchFor(s))
            .process(_auto(1));
        expect(out.kind, PhotoOutcomeKind.failed);
        expect(out.retryable, isTrue, reason: '${out.detail}');
        expect(out.errorKind, AnalysisErrorKind.network,
            reason: '${out.detail}');
        expect(dao.ledger, isEmpty, reason: 'released, not burned');
        expect(s.isAnalysisBlocked, isFalse);
        expect(s.canAutoAnalyze, isTrue);
      });
    }

    test('a JSON 401 from the server itself still pauses the scan', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
      await s.setProvider(AiProvider.server);
      await s.setServerBaseUrl('https://10.0.0.5');
      await s.setServerApiKey('k');
      final analyzer = ServerAnalyzer(s,
          normalizer: (b) async => b,
          sleep: (_) async {},
          client: MockClient(
              (_) async => http.Response('{"error": "Unauthorized"}', 401)));
      final out = await PhotoPipeline(
              dao: FakeDao(), analyzer: analyzer, latch: autoScanLatchFor(s))
          .process(_auto(1));
      expect(out.errorKind, AnalysisErrorKind.rejectedKey);
      expect(s.analysisBlockedKind, 'rejectedKey');
    });
  });

  group('two engines, one preferences store', () {
    // The background run is another isolate with its own preferences
    // cache; the foreground never saw what it wrote, and the credentials
    // revision lived in memory only (probes B1/B2).
    const rejected = AnalysisOutcome(
        error: 'The provider rejected the API key. Check Settings.',
        wall: Duration.zero);

    Future<(AppSettings fg, _MemKeys keys)> foreground() async {
      SharedPreferences.setMockInitialValues({});
      final keys = _MemKeys();
      final fg = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
      await fg.setGeminiApiKey('old');
      return (fg, keys);
    }

    Future<AppSettings> otherIsolate(_MemKeys keys) async {
      SharedPreferences.resetStatic(); // its own cache, the same store
      return AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: keys);
    }

    test('B1: a pause the background armed is lifted by a key edit in the '
        'still-open foreground', () async {
      final (fg, keys) = await foreground();
      final bg = await otherIsolate(keys);
      await PhotoPipeline(
              dao: FakeDao(),
              analyzer: FakeAnalyzer()..nextPhotoOutcome = rejected,
              latch: autoScanLatchFor(bg))
          .process(_auto(1));
      expect(bg.analysisBlockedKind, 'rejectedKey');

      await fg.setGeminiApiKey('new-working-key');
      await fg.reloadAnalysisBlock(); // the next resume
      expect(fg.canAutoAnalyze, isTrue);
      final nextRun = await otherIsolate(keys);
      expect(nextRun.canAutoAnalyze, isTrue,
          reason: 'the next background run scans with the new key');
    });

    test('B3: a photo the open app is handed after the background paused '
        'the scan is released without an upload', () async {
      final (fg, keys) = await foreground();
      // The foreground engine loaded first; its in-memory latch is clear.
      expect(fg.canAutoAnalyze, isTrue);

      final bg = await otherIsolate(keys);
      await PhotoPipeline(
              dao: FakeDao(),
              analyzer: FakeAnalyzer()..nextPhotoOutcome = rejected,
              latch: autoScanLatchFor(bg))
          .process(_auto(1));
      expect(bg.analysisBlockedKind, 'rejectedKey');

      // A photo event queued while the process was frozen reaches the
      // foreground isolate — no resume catch-up ran first.
      final notices = <PhotoOutcome>[];
      var fgCalls = 0;
      final dao = FakeDao();
      final out = await PhotoPipeline(
              dao: dao,
              analyzer: FakeAnalyzer()
                ..nextPhotoOutcome = rejected
                ..onAnalyze = () async => fgCalls++,
              notify: notices.add,
              latch: autoScanLatchFor(fg))
          .process(_auto(2));
      expect(fgCalls, 0, reason: 'no second upload on the rejected key');
      expect(out.retryable, isTrue, reason: 'released for the scan after');
      expect(out.errorKind, AnalysisErrorKind.rejectedKey);
      expect(dao.ledger, isEmpty);
      expect(notices, isEmpty, reason: 'no late rejected-key snackbar');
      expect(fg.analysisBlockedKind, 'rejectedKey');
    });

    test('B2: the old key\'s refusal landing after the edit arms nothing',
        () async {
      final (fg, keys) = await foreground();
      final bg = await otherIsolate(keys);
      // The user replaces the key WHILE the background's photo is at the
      // provider with the old one.
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = rejected
        ..onAnalyze = () => fg.setGeminiApiKey('new');
      final out = await PhotoPipeline(
              dao: FakeDao(), analyzer: analyzer, latch: autoScanLatchFor(bg))
          .process(_auto(1));
      expect(out.retryable, isTrue, reason: 'released all the same');
      expect(bg.isAnalysisBlocked, isFalse);
      await fg.reloadAnalysisBlock();
      expect(fg.canAutoAnalyze, isTrue);
      expect((await otherIsolate(keys)).canAutoAnalyze, isTrue);
    });
  });

  // An empty balance (DeepSeek/OpenRouter 402, OpenAI insufficient_quota,
  // Qwen Arrearage …) refuses every photo the same way, but it was
  // released silently: every catch-up re-read, re-decoded and re-uploaded
  // the whole lookback window, and nothing said why logging had stopped
  // (run 7, B6). It now parks the automatic scan like a rejected key, for
  // two hours, and says so once.
  group('an empty provider balance', () {
    Future<(AppSettings, OpenAiCompatAnalyzer, List<int>)> setup(
        {required bool Function() broke}) async {
      SharedPreferences.setMockInitialValues({});
      final s = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
      await s.setProvider(AiProvider.deepseek);
      await s.setDeepseekApiKey('sk-test');
      final uploads = <int>[0];
      final analyzer = OpenAiCompatAnalyzer(s,
          endpoint: Uri.parse('https://api.deepseek.test/chat/completions'),
          label: 'DeepSeek',
          keyOf: (s) => s.deepseekApiKey,
          modelOf: (s) => s.deepseekModel,
          normalizer: (b) async => b,
          sleep: (_) async {},
          client: MockClient((_) async {
            uploads[0]++;
            if (broke()) {
              return http.Response(
                  jsonEncode({
                    'error': {
                      'message': 'Insufficient Balance',
                      'type': 'unknown_error'
                    }
                  }),
                  402);
            }
            return http.Response(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'content': jsonEncode({
                          'is_food': true,
                          'total_calories': 420,
                          'meal_description': 'Fried rice',
                        })
                      }
                    }
                  ]
                }),
                200);
          }));
      return (s, analyzer, uploads);
    }

    test('one upload, one notice, then the scan is parked; photos kept',
        () async {
      final (s, analyzer, uploads) = await setup(broke: () => true);
      final notes = <PhotoOutcome>[];
      final dao = FakeDao();
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          notify: notes.add,
          latch: autoScanLatchFor(s));
      for (var scan = 0; scan < 2; scan++) {
        for (var n = 1; n <= 3; n++) {
          final out = await pipeline.process(_auto(n));
          expect(out.kind, PhotoOutcomeKind.failed);
          expect(out.retryable, isTrue, reason: 'scan $scan photo $n');
          expect(out.errorKind, AnalysisErrorKind.billing);
        }
      }
      expect(uploads[0], 1, reason: 'was 6: every photo, every scan');
      expect(dao.ledger, isEmpty, reason: 'released, never burned');
      expect(notes, hasLength(1));
      expect(outcomeSnackbar(AppLocalizationsZh(), notes.single),
          contains(AppLocalizationsZh().errBilling));
      expect(s.analysisBlockedKind, 'billing');
      expect(s.canAutoAnalyze, isFalse);
      expect(s.canAnalyze, isTrue, reason: 'deliberate adds still analyze');
      await s.reloadAnalysisBlock(); // as the other engine reads it
      expect(s.analysisBlockedKind, 'billing');
      final until = s.analysisBlockedUntil!;
      expect(until.difference(DateTime.now()).inMinutes,
          inInclusiveRange(115, 120));

      // The Settings footer and the background card name it.
      final zh = autoScanPausedLine(AppLocalizationsZh(),
          kind: s.analysisBlockedKind,
          until: until,
          provider: s.provider.name,
          serverBackend: s.serverBackend)!;
      expect(zh, startsWith('监控相册已暂停：'));
      expect(zh, contains('DeepSeek'));
      expect(zh, contains('充值'));
      final en = autoScanPausedLine(AppLocalizationsEn(),
          kind: 'billing',
          until: until,
          provider: 'deepseek',
          serverBackend: 'claude')!;
      expect(en, startsWith('Watch Camera Roll is paused:'));
      expect(en, contains('Test This Provider'));

      // A deliberate add still goes out (it is how the fix is tested).
      final picked = await pipeline.process(IntakePhoto(
          Uint8List.fromList([9, 9, 9]), 'p1', 'IMG_9.jpg',
          deliberate: true));
      expect(uploads[0], 2);
      expect(picked.errorKind, AnalysisErrorKind.billing);
      expect(notes, hasLength(1), reason: 'the dialog shows that one');

      // A passing Test This Provider after the top-up resumes at once.
      await s.credentialsProven(reachedGeneration: true);
      expect(s.analysisBlockedKind, isNull);
      expect(s.canAutoAnalyze, isTrue);
    });

    test('a deliberate photo after the top-up lifts it too', () async {
      var broke = true;
      final (s, analyzer, uploads) = await setup(broke: () => broke);
      final dao = FakeDao();
      final pipeline =
          PhotoPipeline(dao: dao, analyzer: analyzer, latch: autoScanLatchFor(s));
      await pipeline.process(_auto(1));
      expect(s.analysisBlockedKind, 'billing');
      broke = false; // topped up at the provider's console
      final out = await pipeline.process(IntakePhoto(
          Uint8List.fromList([7, 7, 7]), 'p7', 'IMG_7.jpg',
          deliberate: true));
      expect(out.kind, PhotoOutcomeKind.saved);
      expect(s.analysisBlockedKind, isNull);
      expect((await pipeline.process(_auto(1))).kind, PhotoOutcomeKind.saved);
      expect(uploads[0], 3);
    });
  });
}
