/// The AI consent is read again AT THE SEND (photo_pipeline.dart
/// AiSendGate; release-candidate review of 1.6.0, privacy).
///
/// Settings › Stop Sharing with … says "Stopped — nothing more is sent to
/// {provider}." and docs/PRIVACY.md says it "stops all sending to that
/// recipient" and that "nothing is sent to it until you tap Allow". The UI
/// asks when a photo is ADMITTED (ensureAiConsent, SharedPhotoConsentGate),
/// but an admitted photo can wait in the pipeline's FIFO behind another one
/// — a shared photo behind a camera-roll catch-up, picked photos whose add
/// screen was closed, the coverage screen's Log all — and the analyzer
/// picks its provider per call. Such a photo was uploaded after Stop
/// Sharing was confirmed, or to a provider nobody had allowed.
///
/// Here: the real pipeline, the real share gate, the real Settings row and
/// coverage screen. A queued photo is let go unsent and untouched (not
/// hashed, no ledger row, a kept tombstone), said in words that ask for it
/// again; a verdict already obtained is still settled; the background run
/// re-reads the consent from disk; the production adapter over the real
/// settings follows the consent, the provider and the key.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/ai_consent.dart';
import 'package:calorie_tracker/ui/background_glue.dart' show aiSendGateFor;
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/coverage_screen.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;
import 'fakes.dart';

/// The gate over the UI's settings store, by the rule production applies
/// to the real settings ([aiSendGateFor], pinned below and in
/// production_wiring_test): held back only while a key is set and the
/// current recipient is not allowed.
AiSendGate _gate(FakeSettings s) =>
    AiSendGate(allowed: () => !aiConsentNeeded(s));

Future<String> _hash(Uint8List bytes) async => 'h${bytes.first}';

const AnalysisOutcome _notFood = AnalysisOutcome(
    analysis: {'is_food': false}, isFood: false, wall: Duration.zero);

const AnalysisOutcome _food = AnalysisOutcome(
    analysis: {
      'is_food': true,
      'meal_description': 'Ramen',
      'total_calories': 600,
    },
    isFood: true,
    wall: Duration.zero);

IntakePhoto _photo(int n, {bool deliberate = false}) => IntakePhoto(
    Uint8List.fromList([n, n, n]), 'a$n', 'IMG_$n.jpg',
    deliberate: deliberate);

class _MemKeys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();

  group('a photo admitted earlier and still queued', () {
    testWidgets('is not uploaded after Stop Sharing is confirmed: let go '
        'unhashed, and the share is asked for again', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Gemini is allowed (FakeSettings allows every route by default).
      final settings = FakeSettings(apiKey: 'k');
      expect(aiConsentNeeded(settings), isFalse);

      // The app's one pipeline. The analyzer call IS the upload.
      final uploads = <int>[];
      final hashed = <int>[];
      final said = <PhotoOutcome>[];
      final firstInFlight = Completer<void>();
      final releaseFirst = Completer<void>();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _notFood;
      var n = 0;
      analyzer.onAnalyze = () async {
        final mine = ++n;
        uploads.add(mine);
        if (mine == 1) {
          firstInFlight.complete();
          await releaseFirst.future;
        }
      };
      final dao = FakeDao();
      final pipeline = PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        notify: said.add,
        sendGate: _gate(settings),
        // No isolates and no decoding in a widget test.
        hasher: (bytes) {
          hashed.add(bytes.first);
          return _hash(bytes);
        },
        thumbnailer: (_) async => null,
      );
      // The share sheet's intake, held by the consent gate as in di.dart.
      final shared = StreamController<IntakePhoto>();
      pipeline
          .bindStream(SharedPhotoConsentGate(settings).gate(shared.stream));

      // Photo 1 (picked): in flight — its upload has started.
      unawaited(pipeline.enqueue(_photo(1, deliberate: true)));
      await tester.pump();
      await firstInFlight.future;
      // Photo 2 (shared): admitted by the gate (the recipient is allowed)
      // and queued behind photo 1. Nothing of it has been sent.
      shared.add(IntakePhoto(Uint8List.fromList([2]), '', 'shared.jpg',
          deliberate: true));
      await tester.pump();
      expect(uploads, [1]);
      expect(pipeline.isIdle, isFalse);

      // Settings › Stop Sharing with Gemini › Stop Sharing.
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: SettingsScreen(
          settings: settings,
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          photoIntake: FakeIntake(),
          requestPhotoPermission: () async => true,
        )),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('aiStopSharingRow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('aiStopSharingConfirm')));
      await tester.pumpAndSettle();
      expect(settings.hasAiConsent('gemini'), isFalse);
      expect(find.text('Stopped — nothing more is sent to Gemini.'),
          findsOneWidget);
      expect(uploads, [1], reason: 'photo 2 is still only queued');

      // The request in flight ends; the queue moves on.
      releaseFirst.complete();
      for (var i = 0; i < 20 && !pipeline.isIdle; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(pipeline.isIdle, isTrue);

      expect(uploads, [1],
          reason: 'after "Stopped — nothing more is sent to Gemini." the '
              'queued photo must not be uploaded to Gemini');
      expect(hashed, [1], reason: 'the held photo is not even hashed');
      expect(dao.ledger.keys, ['h1'], reason: 'and leaves no ledger row');
      // Nobody awaits a shared photo: it is said, and asks for the share
      // again — sharing it again asks for the consent first.
      expect(said, hasLength(1));
      final o = said.single;
      expect(o.kind, PhotoOutcomeKind.failed);
      expect(o.retryable, isTrue);
      expect(o.shared, isTrue);
      expect(o.reason, notAllowedReason);
      expect(
          outcomeSnackbar(en, o),
          'The shared photo was not analyzed this time (this AI service is '
          'not allowed to receive your photos) — share it again later.');
      expect(outcomeSnackbar(zh, o),
          '分享的照片这次没能分析（还没有允许把照片发送给这个 AI 服务）—— 请稍后重新分享。');
      await shared.close();
    });

    // The same gap, the other way round: the analyzer reads the provider
    // per call, the API key page asks nothing while Watch Camera Roll is
    // off (confirmAiRecipientChange returns true), and the queued photo
    // went to a recipient that was NEVER allowed.
    testWidgets('is not uploaded to a provider that was never allowed',
        (tester) async {
      final settings = FakeSettings(keys: {'gemini': 'k', 'openai': 'k2'})
        ..aiConsent = {'gemini'};
      expect(aiConsentNeeded(settings), isFalse);

      // (provider at the moment of the upload, was it allowed then?)
      final uploads = <(String, bool)>[];
      final firstInFlight = Completer<void>();
      final releaseFirst = Completer<void>();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _notFood;
      analyzer.onAnalyze = () async {
        uploads.add((
          settings.provider,
          settings.hasAiConsent(currentAiConsentRoute(settings)),
        ));
        if (uploads.length == 1) {
          firstInFlight.complete();
          await releaseFirst.future;
        }
      };
      final pipeline = PhotoPipeline(
        dao: FakeDao(),
        analyzer: analyzer,
        sendGate: _gate(settings),
        hasher: _hash,
        thumbnailer: (_) async => null,
      );
      final shared = StreamController<IntakePhoto>();
      pipeline
          .bindStream(SharedPhotoConsentGate(settings).gate(shared.stream));

      unawaited(pipeline.enqueue(_photo(1, deliberate: true)));
      await tester.pump();
      await firstInFlight.future;
      shared.add(IntakePhoto(Uint8List.fromList([2]), '', 'shared.jpg',
          deliberate: true));
      await tester.pump();

      // Settings › AI Provider › API Key › OpenAI (Watch Camera Roll off:
      // no question at the switch; the next foreground send would ask).
      expect(
          await confirmAiRecipientChange(
              tester.element(find.byType(View).first), settings,
              provider: 'openai', serverBackend: settings.serverBackend),
          isTrue);
      settings.provider = 'openai';
      expect(aiConsentNeeded(settings), isTrue,
          reason: 'OpenAI was never allowed: a new send would ask first');

      releaseFirst.complete();
      for (var i = 0; i < 20 && !pipeline.isIdle; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(uploads, [('gemini', true)],
          reason: 'the queued photo must not go to OpenAI, which the user '
              'never allowed');
      await shared.close();
    });

    testWidgets('Photo Coverage, re-analyze all: after Stop Sharing only '
        'the photo in flight is uploaded, the run stops and says why, and '
        'the other tombstones are kept', (tester) async {
      final library = FakePhotoLibrary()
        ..assets = [
          FakeAsset('b1', 'S1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
          FakeAsset('b2', 'S2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
          FakeAsset('b3', 'S3.jpg', DateTime(2026, 7, 26, 10), bytesOf(3)),
        ];
      final dao = FakeDao();
      dao.ledger['h1'] = IngestionStatus.skipped;
      dao.ledger['h2'] = IngestionStatus.skipped;
      dao.ledger['h3'] = IngestionStatus.skipped;
      final settings = FakeSettings(apiKey: 'k');
      var uploads = 0;
      final firstInFlight = Completer<void>();
      final releaseFirst = Completer<void>();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _notFood;
      analyzer.onAnalyze = () async {
        if (++uploads == 1) {
          firstInFlight.complete();
          await releaseFirst.future;
        }
      };
      final pipeline = PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        sendGate: _gate(settings),
        hasher: _hash,
        thumbnailer: (_) async => null,
      );
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CoverageScreen(
          auditor: CoverageAuditor(
              library: library,
              dao: dao,
              hasher: (bytes) async => 'h${bytes.first}',
              clock: () => DateTime(2026, 7, 26, 12, 0)),
          processPhoto: pipeline.enqueue,
          requestPhotoPermission: () async => true,
          initialLookbackDays: 2,
          // As Settings wires it.
          canAnalyze: () => settings.canAnalyze,
          ensureConsent: (ctx) => ensureAiConsent(ctx, settings),
          library: library,
        ),
      ));
      await tester.tap(find.byKey(const Key('runCoverageCheck')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reanalyzeAllSkipped')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmBulkAction')));
      await tester.pump();
      await firstInFlight.future;

      // Settings › Stop Sharing, confirmed meanwhile: the consent is gone.
      await settings.setAiConsent('gemini', granted: false);

      releaseFirst.complete();
      await tester.pumpAndSettle();
      expect(uploads, 1);
      expect(
          find.textContaining('stopped after 2 of 3: Nothing was sent: this '
              'AI service is not allowed to receive your photos.'),
          findsOneWidget);
      expect(dao.ledger, {
        'h1': IngestionStatus.skipped, // analyzed again: still not food
        'h2': IngestionStatus.skipped, // held back: its tombstone untouched
        'h3': IngestionStatus.skipped, // never started
      });
    });
  });

  group('the gate, photo by photo', () {
    test('a deliberate re-add that may not be sent keeps the tombstone it '
        'would have reclaimed', () async {
      final dao = FakeDao()..ledger['h1'] = IngestionStatus.skipped;
      var hashed = 0, uploads = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = _food
        ..onAnalyze = () async => uploads++;
      final out = await PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        sendGate: AiSendGate(allowed: () => false),
        hasher: (bytes) {
          hashed++;
          return _hash(bytes);
        },
        thumbnailer: (_) async => null,
      ).process(_photo(1, deliberate: true));
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(out.retryable, isTrue);
      expect(out.reason, notAllowedReason);
      expect(uploads, 0);
      expect(hashed, 0);
      expect(dao.ledger, {'h1': IngestionStatus.skipped});
      expect(dao.meals, isEmpty);
    });

    test('a consent withdrawn while the photo is prepared is caught at the '
        'send, and its reservation released', () async {
      final dao = FakeDao();
      var allowed = true;
      var uploads = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = _food
        ..onAnalyze = () async => uploads++;
      final out = await PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        sendGate: AiSendGate(allowed: () => allowed),
        // Stop Sharing lands while the original is being hashed.
        hasher: (bytes) {
          allowed = false;
          return _hash(bytes);
        },
        thumbnailer: (_) async => null,
      ).process(_photo(1));
      expect(out.reason, notAllowedReason);
      expect(out.retryable, isTrue);
      expect(uploads, 0);
      expect(dao.ledger, isEmpty, reason: 'released, not left processing');
      expect(dao.meals, isEmpty);
    });

    test('the background run re-reads the consent from disk before the '
        'send; a store that cannot be re-read leaves its own copy to decide',
        () async {
      // The open app stopped sharing after this run loaded its settings.
      var allowed = true, refreshed = 0, uploads = 0;
      final dao = FakeDao();
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = _food
        ..onAnalyze = () async => uploads++;
      final out = await PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        sendGate: AiSendGate(
            allowed: () => allowed,
            refresh: () async {
              refreshed++;
              allowed = false;
            }),
        hasher: _hash,
        thumbnailer: (_) async => null,
      ).process(_photo(1));
      expect(refreshed, 1);
      expect(out.reason, notAllowedReason);
      expect(uploads, 0);
      expect(dao.ledger, isEmpty);

      final sent = await PhotoPipeline(
        dao: FakeDao(),
        analyzer: analyzer,
        sendGate: AiSendGate(
            allowed: () => true,
            refresh: () async => throw StateError('prefs unreadable')),
        hasher: _hash,
        thumbnailer: (_) async => null,
      ).process(_photo(2));
      expect(sent.kind, PhotoOutcomeKind.saved);
      expect(uploads, 1);
    });

    test('a gate that cannot answer holds the photo back', () async {
      var uploads = 0;
      final dao = FakeDao();
      final out = await PhotoPipeline(
        dao: dao,
        analyzer: FakeAnalyzer()
          ..nextPhotoOutcome = _food
          ..onAnalyze = () async => uploads++,
        sendGate:
            AiSendGate(allowed: () => throw StateError('settings are gone')),
        hasher: _hash,
        thumbnailer: (_) async => null,
      ).process(_photo(1));
      expect(out.reason, notAllowedReason);
      expect(uploads, 0);
      expect(dao.ledger, isEmpty);
    });

    test('a verdict the photo already got is settled, never held back: '
        'nothing is uploaded for it', () async {
      // A picked photo is analyzed (allowed then). While the request is
      // out, another run marks the photo not-food and the user stops
      // sharing. The picked run settles the food verdict it holds once
      // more, under a fresh reservation, with no second upload — the gate
      // is about sending, and this sends nothing.
      final dao = FakeDao();
      var allowed = true, uploads = 0;
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _food;
      analyzer.onAnalyze = () async {
        uploads++;
        dao.ledger['h1'] = IngestionStatus.skipped;
        dao.stamps.remove('h1');
        allowed = false;
      };
      final out = await PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        sendGate: AiSendGate(allowed: () => allowed),
        hasher: _hash,
        thumbnailer: (_) async => null,
      ).process(_photo(1, deliberate: true));
      expect(out.kind, PhotoOutcomeKind.saved);
      expect(uploads, 1);
      expect(dao.ledger, {'h1': IngestionStatus.saved});
      expect(dao.meals, hasLength(1));
    });
  });

  group('the words for a photo that was not sent', () {
    Future<PhotoOutcome> held({bool deliberate = true}) => PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          sendGate: AiSendGate(allowed: () => false),
          hasher: _hash,
          thumbnailer: (_) async => null,
        ).process(_photo(1, deliberate: deliberate));

    test('its own sentence in both languages, never "kept for retry"',
        () async {
      final o = await held();
      const sentence = 'Nothing was sent: this AI service is not allowed to '
          'receive your photos. Chopstats asks first the next time you add '
          'one.';
      expect(o.message, sentence);
      // The coverage screen's stop line and any plain snackbar.
      expect(outcomeBody(en, o), sentence);
      expect(outcomeSnackbar(en, o), sentence);
      expect(outcomeBody(zh, o),
          '没有发送任何内容：还没有允许把照片发送给这个 AI 服务。下次添加照片时，筷拍会先征求你的同意。');
      expect(outcomeSnackbar(zh, o), isNot(contains('已保留')));
    });

    test('a picked photo whose screen was closed asks for the pick again; '
        'the add flow\'s dialog names the reason', () async {
      final o = await held();
      final picked = unannouncedOutcome(o, picked: true)!;
      expect(picked.reason, notAllowedReason);
      expect(
          outcomeSnackbar(en, picked),
          'This photo was not analyzed (this AI service is not allowed to '
          'receive your photos) — pick it again later.');
      expect(outcomeSnackbar(zh, picked),
          '这张照片没能分析（还没有允许把照片发送给这个 AI 服务）—— 请稍后重新选择它。');
      expect(
          outcomeBody(en, o, deliberate: true),
          'This photo was not analyzed this time (this AI service is not '
          'allowed to receive your photos) — tap Retry, or pick it again '
          'later.');
    });

    testWidgets('the add flow\'s Retry asks for the consent before it sends '
        'the photo again', (tester) async {
      final settings = FakeSettings(apiKey: 'k');
      final picker = FakePicker()
        ..photos = [
          IntakePhoto(Uint8List.fromList(List.filled(16, 3)), 'a0', 'a0.jpg',
              capturedAt: DateTime(2026, 7, 30, 12)),
        ];
      var turns = 0, sends = 0;
      final services = makeServices(
          settings: settings,
          picker: picker,
          processPhoto: (photo) async {
            if (++turns == 1) {
              // Allowed at the pick; stopped while the photo waited its
              // turn: the pipeline's verdict for it.
              settings.aiConsent = {};
              return held();
            }
            sends++;
            return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
          });
      await tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AddPhotoScreen(services: services)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('aiConsentDialog')), findsNothing,
          reason: 'allowed at the pick');
      expect(
          find.textContaining('this AI service is not allowed to receive '
              'your photos'),
          findsOneWidget);
      expect(turns, 1);

      await tester.tap(find.byKey(const Key('retryAnalysisButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('aiConsentDialog')), findsOneWidget,
          reason: 'Retry asks first');
      await tester.tap(find.byKey(const Key('aiConsentNotNow')));
      await tester.pumpAndSettle();
      expect(turns, 1, reason: 'Not now: the photo is not offered again');
      expect(find.text('Nothing was sent.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('aiConsentAllow')));
      await tester.pumpAndSettle();
      expect(settings.aiConsentWrites, [('gemini', true)]);
      expect(sends, 1);
    });
  });

  group('aiSendGateFor: the gate over the real settings', () {
    Future<AppSettings> load([Map<String, Object> stored = const {}]) async {
      SharedPreferences.setMockInitialValues(stored);
      return AppSettings.load(
          prefs: await SharedPreferences.getInstance(), keyStore: _MemKeys());
    }

    test('follows the consent of the recipient the provider choice sends '
        'to, and the key', () async {
      final s = await load();
      final gate = aiSendGateFor(s);
      expect(gate.refresh, isNull,
          reason: 'the app\'s own engine never re-reads from disk');
      expect(gate.allowed(), isTrue,
          reason: 'no key: nothing can leave, the analyzer says so');
      await s.setGeminiApiKey('k');
      expect(gate.allowed(), isFalse, reason: 'a key, and nobody allowed');
      await s.setAiConsent('gemini', granted: true);
      expect(gate.allowed(), isTrue);

      // Another provider is another recipient.
      await s.setOpenaiApiKey('k2');
      await s.setProvider(AiProvider.openai);
      expect(gate.allowed(), isFalse);
      await s.setProvider(AiProvider.gemini);
      expect(gate.allowed(), isTrue);

      // Stop Sharing.
      await s.setAiConsent('gemini', granted: false);
      expect(gate.allowed(), isFalse);
    });

    test('the background run sees a Stop Sharing the open app confirmed '
        'after it loaded', () async {
      final s = await load({
        'settings.ai_consent_routes': <String>['gemini'],
      });
      await s.setGeminiApiKey('k');
      final gate = aiSendGateFor(s, rereadFromDisk: true);
      expect(gate.allowed(), isTrue);

      // The other engine's write: this one's copy does not know yet.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('settings.ai_consent_routes', const []);
      expect(gate.allowed(), isTrue);
      await gate.refresh!();
      expect(gate.allowed(), isFalse);

      // Allowed again over there.
      await prefs.setStringList('settings.ai_consent_routes', ['gemini']);
      await gate.refresh!();
      expect(gate.allowed(), isTrue);
    });

    test('end to end: a queued automatic photo is not uploaded once the '
        'real settings say the recipient is stopped', () async {
      final s = await load({
        'settings.ai_consent_routes': <String>['gemini'],
      });
      await s.setGeminiApiKey('k');
      final uploads = <int>[];
      final firstInFlight = Completer<void>();
      final releaseFirst = Completer<void>();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = _notFood;
      analyzer.onAnalyze = () async {
        uploads.add(uploads.length + 1);
        if (uploads.length == 1) {
          firstInFlight.complete();
          await releaseFirst.future;
        }
      };
      final dao = FakeDao();
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          sendGate: aiSendGateFor(s),
          hasher: _hash,
          thumbnailer: (_) async => null);
      final first = pipeline.enqueue(_photo(1));
      final second = pipeline.enqueue(_photo(2));
      await firstInFlight.future;
      await s.setAiConsent(s.activeAiConsentRoute, granted: false);
      releaseFirst.complete();
      expect((await first).kind, PhotoOutcomeKind.skipped);
      final o = await second;
      expect(o.reason, notAllowedReason);
      expect(o.retryable, isTrue, reason: 'the watcher keeps it as unread');
      expect(uploads, [1]);
      expect(dao.ledger.keys, ['h1']);
    });
  });
}
