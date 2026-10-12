/// Photo pipeline glue (spec §2.3/§3.5/§6): reservation policies, status
/// transitions, food_items sanitization, and per-photo error containment.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';

import 'fakes.dart';

IntakePhoto _photo({bool deliberate = false}) => IntakePhoto(
    Uint8List.fromList([1, 2, 3]), 'asset1', 'IMG_20260716_193042.jpg',
    deliberate: deliberate);

String get _hash =>
    md5.convert(Uint8List.fromList([1, 2, 3])).toString().toLowerCase();

Map<String, dynamic> _foodAnalysis() => {
      'is_food': true,
      'meal_description': 'Ramen',
      'total_calories': 600,
      'food_items': [
        {'name': 'Ramen', 'estimated_calories': 600},
        'junk-entry',
        42,
      ],
    };

void main() {
  test('enqueue() serializes with the bound-stream FIFO — never concurrent',
      () async {
    final dao = FakeDao();
    var active = 0, maxActive = 0;
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true}, isFood: true, wall: Duration.zero)
      ..onAnalyze = () async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 8));
        active--;
      };
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final stream = StreamController<IntakePhoto>();
    pipeline.bindStream(stream.stream);

    IntakePhoto photo(int n, String id) => IntakePhoto(
        Uint8List.fromList([n]), id, 'IMG_$n.jpg', deliberate: true);

    // Interleave stream photos (the watcher path) with direct enqueues
    // (the coverage screen's Log all): the whole point of enqueue over
    // process is that these NEVER overlap an analyzer call.
    stream.add(photo(1, 's1'));
    stream.add(photo(2, 's2'));
    final e1 = pipeline.enqueue(photo(3, 'e1'));
    stream.add(photo(4, 's3'));
    final e2 = pipeline.enqueue(photo(5, 'e2'));
    await Future.wait([e1, e2]);
    await stream.close();
    // Polled, not a fixed 60 ms: each photo hashes on a compute() isolate,
    // and a loaded machine overran the fixed wait (flaky, 2026-10-12).
    await _until(() => dao.meals.length == 5);

    expect(maxActive, 1,
        reason: 'a second concurrent analyzer call is the free-tier RPM '
            '429 self-inflict the FIFO exists to prevent');
    expect(dao.meals, hasLength(5));
  });

  test('a saved photo meal gets a stored thumbnail (spec §9)', () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true, 'total_calories': 100},
          isFood: true,
          wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    // Real 1x1 JPEG so the thumbnailer can decode it.
    final jpeg = base64Decode(
        '/9j/4AAQSkZJRgABAQEAAAAAAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLD'
        'BkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2w'
        'BDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjI'
        'yMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAA'
        'AQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAA'
        'AF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGR'
        'olJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXq'
        'DhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT'
        '1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAA'
        'AAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBh'
        'JBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg'
        '5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOU'
        'lZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5'
        'ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==');
    final outcome = await pipeline.process(
        IntakePhoto(jpeg, 'a1', 'IMG_1.jpg', deliberate: true));
    expect(outcome.kind, PhotoOutcomeKind.saved);
    final mealId = dao.meals.single.id;
    expect(dao.thumbs[mealId], isNotNull,
        reason: 'the pipeline persists a thumbnail at save time');
    expect(dao.thumbs[mealId]!.length, lessThan(jpeg.length + 4096),
        reason: 'thumb stays small');
  });

  test('a throwing thumb save never un-saves the meal', () async {
    final dao = _ThumbThrowingDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': true},
          isFood: true,
          wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final outcome = await pipeline.process(IntakePhoto(
        Uint8List.fromList([1, 2, 3]), 'a1', 'x.jpg',
        deliberate: true));
    expect(outcome.kind, PhotoOutcomeKind.saved);
    expect(dao.meals, hasLength(1));
  });


  test('food photo → reserved, saved meal, ledger saved, sanitized items',
      () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final notes = <PhotoOutcome>[];
    final pipeline =
        PhotoPipeline(dao: dao, analyzer: analyzer, notify: notes.add);

    final out = await pipeline.process(_photo());

    expect(out.kind, PhotoOutcomeKind.saved);
    expect(dao.meals, hasLength(1));
    expect(dao.meals.single.imageHash, _hash); // md5 of ORIGINAL bytes §6.2
    expect(dao.meals.single.source, 'app_watch');
    // Hostile entries dropped before persisting (spec §3.5).
    expect(dao.meals.single.analysis['food_items'], [
      {'name': 'Ramen', 'estimated_calories': 600}
    ]);
    expect(dao.ledger[_hash], IngestionStatus.saved);
    expect(notes, hasLength(1)); // notification-style snackbar on save
    // The snackbar gets the OUTCOME (worded in the app language by
    // di.dart), the very one process() returns.
    expect(notes.single, same(out));
  });

  test('non-food photo → skipped tombstone, no meal', () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          analysis: {'is_food': false}, isFood: false, wall: Duration.zero);
    final out =
        await PhotoPipeline(dao: dao, analyzer: analyzer).process(_photo());
    expect(out.kind, PhotoOutcomeKind.skipped);
    expect(out.message, 'No food detected in this photo.'); // spec §5.4 copy
    expect(dao.meals, isEmpty);
    expect(dao.ledger[_hash], IngestionStatus.skipped);
  });

  test('PERMANENT failed analysis → ledger failed, kept for retry', () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome =
          const AnalysisOutcome(error: 'bad key', wall: Duration.zero);
    final out =
        await PhotoPipeline(dao: dao, analyzer: analyzer).process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed);
    expect(dao.ledger[_hash], IngestionStatus.failed);
    expect(dao.meals, isEmpty);
  });

  test('a throwing snackbar on a PERMANENT failure keeps the real verdict',
      () async {
    // The failure notify used to sit outside any shield: a throw fell into
    // the outer catch and the user read "Photo intake failed: …" instead of
    // why the analysis failed.
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome =
          const AnalysisOutcome(error: 'bad key', wall: Duration.zero);
    final seen = <PhotoOutcome>[];
    final out = await PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        notify: (o) {
          seen.add(o);
          throw StateError('snackbar died');
        }).process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed);
    expect(out.message, 'bad key');
    expect(seen.single, same(out));
    expect(dao.ledger[_hash], IngestionStatus.failed);
  });

  test('RETRYABLE failed analysis → reservation released, not burned',
      () async {
    final dao = FakeDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = const AnalysisOutcome(
          error: 'rate limit', retryable: true, wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final out = await pipeline.process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed);
    // Released: NO ledger row — the next scan re-offers the photo instead
    // of dropping it forever (automated intake never reclaims 'failed').
    expect(dao.ledger.containsKey(_hash), isFalse);

    // And a later scan CAN save it once the transient trouble clears.
    analyzer.nextPhotoOutcome = AnalysisOutcome(
        analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final retry = await pipeline.process(_photo());
    expect(retry.kind, PhotoOutcomeKind.saved);
    expect(dao.ledger[_hash], IngestionStatus.saved);
  });

  group('a rejected key on the automatic scan', () {
    // A 401/403 (xAI's 400 'Incorrect API key', Gemini auth) used to burn
    // EVERY scanned photo to 'failed' — watch intake never reclaims, so the
    // backlog was gone for good once the key was fixed — and stacked one
    // snackbar per photo (2026-10-12).
    const rejected = AnalysisOutcome(
        error: 'The provider rejected the API key. Check Settings.',
        wall: Duration.zero);

    test('5 photos → no failed rows, all released, ONE notice', () async {
      final dao = FakeDao();
      final notes = <PhotoOutcome>[];
      var now = DateTime(2026, 10, 12, 9, 0);
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = rejected;
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          notify: notes.add,
          clock: () => now);
      final intake = _SinkCapturingIntake();
      pipeline.bind(intake);
      final photos = [
        for (var i = 1; i <= 5; i++)
          IntakePhoto(Uint8List.fromList([i, i]), 'a$i', 'IMG_$i.jpg'),
      ];
      for (final p in photos) {
        expect(await intake.sink!(p, null), isFalse,
            reason: 'released to the intake: a later scan re-offers it');
        now = now.add(const Duration(seconds: 30));
      }
      expect(dao.ledger.values, isNot(contains(IngestionStatus.failed)));
      expect(dao.ledger, isEmpty, reason: 'every hash free to re-offer');
      expect(notes, hasLength(1));
      expect(notes.single.errorKind, AnalysisErrorKind.rejectedKey);
      expect(notes.single.retryable, isTrue);

      // Throttled per process, not silenced: ten minutes on, it says it
      // again — and once the key works, the same photo saves.
      now = now.add(PhotoPipeline.rejectedKeyNoticeInterval);
      final again = await pipeline.process(photos.first);
      expect(again.retryable, isTrue);
      expect(notes, hasLength(2));

      analyzer.nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      expect((await pipeline.process(photos.first)).kind,
          PhotoOutcomeKind.saved);
    });

    test('a deliberate add keeps the permanent verdict and its dialog text',
        () async {
      final dao = FakeDao();
      final notes = <PhotoOutcome>[];
      final out = await PhotoPipeline(
              dao: dao,
              analyzer: FakeAnalyzer()..nextPhotoOutcome = rejected,
              notify: notes.add)
          .process(_photo(deliberate: true));
      expect(out.kind, PhotoOutcomeKind.failed);
      expect(out.retryable, isFalse);
      expect(dao.ledger[_hash], IngestionStatus.failed);
      expect(notes.single, same(out));
      final zh = AppLocalizationsZh();
      expect(outcomeBody(zh, out), zh.errRejectedKey);
    });
  });

  group('the automatic-analysis latch', () {
    // After a rejected key every scan re-uploaded the whole lookback window
    // (Android every 30 min, each launch/resume, iOS refresh): the photos
    // were released and nothing remembered why (review 2026-10-12).
    const rejected = AnalysisOutcome(
        error: 'The provider rejected the API key. Check Settings.',
        wall: Duration.zero);
    const region = AnalysisOutcome(
        error: 'Gemini is not available from your current network region '
            '(check the VPN).',
        retryable: true,
        wall: Duration.zero);

    ({AutoScanLatch latch, List<String> log, void Function() bump}) memLatch() {
      AnalysisErrorKind? armed;
      var rev = 0;
      final log = <String>[];
      return (
        latch: AutoScanLatch(
          blockedKind: () => armed,
          revision: () => rev,
          block: (k, r) async {
            log.add('block:${k.name}@$r');
            if (r == rev) armed = k;
          },
          clear: () async {
            log.add('clear');
            armed = null;
          },
        ),
        log: log,
        bump: () {
          rev++;
          armed = null; // what every AppSettings credential setter does
        },
      );
    }

    test('after one rejected key, later watch photos are released WITHOUT '
        'an analyzer call; a deliberate add still calls it', () async {
      final dao = FakeDao();
      var calls = 0;
      final analyzer = FakeAnalyzer()
        ..nextPhotoOutcome = rejected
        ..onAnalyze = () async => calls++;
      final m = memLatch();
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: dao, analyzer: analyzer, notify: notes.add, latch: m.latch);
      final intake = _SinkCapturingIntake();
      pipeline.bind(intake);
      for (var i = 1; i <= 4; i++) {
        expect(
            await intake.sink!(
                IntakePhoto(Uint8List.fromList([i, i]), 'a$i', 'IMG_$i.jpg'),
                null),
            isFalse,
            reason: 'released: the scan after the fix re-offers it');
      }
      expect(calls, 1, reason: 'photos 2..4 never reached the analyzer');
      expect(m.log, ['block:rejectedKey@0']);
      expect(dao.ledger, isEmpty, reason: 'latched photos are not reserved');
      expect(notes, hasLength(1));

      final latched = await pipeline
          .process(IntakePhoto(Uint8List.fromList([9]), 'a9', 'IMG_9.jpg'));
      expect(latched.kind, PhotoOutcomeKind.failed);
      expect(latched.retryable, isTrue);
      expect(latched.errorKind, AnalysisErrorKind.rejectedKey);

      // The user picks a photo by hand: it bypasses the latch.
      await pipeline.process(_photo(deliberate: true));
      expect(calls, 2);
    });

    test('a success — a deliberate add after the fix — lifts it', () async {
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = rejected;
      final m = memLatch();
      final pipeline =
          PhotoPipeline(dao: FakeDao(), analyzer: analyzer, latch: m.latch);
      await pipeline.process(_photo());
      expect(m.latch.blockedKind(), AnalysisErrorKind.rejectedKey);

      analyzer.nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
      expect((await pipeline.process(_photo(deliberate: true))).kind,
          PhotoOutcomeKind.saved);
      expect(m.latch.blockedKind(), isNull);
      // …and the automatic scan reaches the analyzer again.
      var calls = 0;
      analyzer.onAnalyze = () async => calls++;
      await pipeline.process(
          IntakePhoto(Uint8List.fromList([7]), 'a7', 'IMG_7.jpg'));
      expect(calls, 1);
    });

    test('a refusal of a key the user has since replaced does not latch',
        () async {
      final m = memLatch();
      final analyzer = FakeAnalyzer()..nextPhotoOutcome = rejected;
      // The key is edited WHILE the photo is at the provider.
      analyzer.onAnalyze = () async => m.bump();
      await PhotoPipeline(dao: FakeDao(), analyzer: analyzer, latch: m.latch)
          .process(_photo());
      expect(m.log, ['block:rejectedKey@0']);
      expect(m.latch.blockedKind(), isNull);
    });

    test('a blocked region on the automatic scan latches and says so ONCE',
        () async {
      // regionBlocked used to be released silently on every photo of
      // every scan: no notice at all, and the whole window re-uploaded.
      var now = DateTime(2026, 10, 12, 9, 0);
      var calls = 0;
      final m = memLatch();
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()
            ..nextPhotoOutcome = region
            ..onAnalyze = () async => calls++,
          notify: notes.add,
          latch: m.latch,
          clock: () => now);
      for (var i = 1; i <= 3; i++) {
        final out = await pipeline.process(
            IntakePhoto(Uint8List.fromList([i]), 'a$i', 'IMG_$i.jpg'));
        expect(out.retryable, isTrue);
        now = now.add(const Duration(seconds: 30));
      }
      expect(calls, 1);
      expect(m.log, ['block:regionBlocked@0']);
      expect(notes, hasLength(1));
      expect(notes.single.errorKind, AnalysisErrorKind.regionBlocked);
      final zh = AppLocalizationsZh();
      expect(outcomeSnackbar(zh, notes.single), contains('VPN'));
    });

    test('a deliberate refusal never arms it', () async {
      final m = memLatch();
      await PhotoPipeline(
              dao: FakeDao(),
              analyzer: FakeAnalyzer()..nextPhotoOutcome = rejected,
              latch: m.latch)
          .process(_photo(deliberate: true));
      expect(m.log, isEmpty);
    });
  });

  test('bound streams process photos ONE at a time (no Gemini burst)',
      () async {
    final dao = FakeDao();
    var active = 0, maxActive = 0, calls = 0;
    final analyzer = FakeAnalyzer();
    analyzer.onAnalyze = () async {
      active++;
      calls++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      active--;
    };
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);
    final controller = StreamController<IntakePhoto>.broadcast();
    pipeline.bindStream(controller.stream);
    for (var i = 0; i < 4; i++) {
      controller.add(IntakePhoto(
          Uint8List.fromList([i, i, i]), 'a$i', 'IMG_$i.jpg'));
    }
    while (calls < 4) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(maxActive, 1); // FIFO: a backfill batch must never fan out
  });

  test('watch intake never reclaims a skipped hash; deliberate add does',
      () async {
    final dao = FakeDao();
    dao.ledger[_hash] = IngestionStatus.skipped;
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);

    // Automated intake: strict, no reclaim (spec §2.3 caller policies).
    final auto = await pipeline.process(_photo());
    expect(auto.kind, PhotoOutcomeKind.alreadyTracked);
    expect(dao.meals, isEmpty);

    // Deliberate re-add reclaims failed/skipped/deleted (spec §2.3).
    final deliberate = await pipeline.process(_photo(deliberate: true));
    expect(deliberate.kind, PhotoOutcomeKind.saved);
    expect(dao.meals.single.source, 'app_photo');
  });

  test('a photo another run is still analyzing is IN FLIGHT — retryable, '
      'untouched, not "already logged"', () async {
    // iOS expires the ~30 s background grant mid-analysis; that run's
    // 'processing' row survives until the launch sweep releases it (up to
    // 15 min). Both paths used to read the refused reservation as
    // alreadyTracked (terminal), so the watermark and the watcher's
    // seen-set passed over a photo nobody had analyzed (2026-10-07).
    final dao = FakeDao();
    dao.ledger[_hash] = IngestionStatus.processing;
    var analyzerCalls = 0;
    final analyzer = FakeAnalyzer()
      ..onAnalyze = () async {
        analyzerCalls++;
      };
    final pipeline = PhotoPipeline(dao: dao, analyzer: analyzer);

    final auto = await pipeline.process(_photo());
    expect(auto.kind, PhotoOutcomeKind.inFlight);
    expect(auto.retryable, isTrue,
        reason: 'the frontier must halt in front of it and the watcher '
            'must forget it was seen');
    expect(auto.message,
        'This photo is still being analyzed — check back in a moment.');
    expect(auto.errorKind, AnalysisErrorKind.none);

    // The deliberate path: same answer, and it must NOT steal the analysis
    // (reclaim covers failed/skipped/deleted only — unchanged).
    final deliberate = await pipeline.process(_photo(deliberate: true));
    expect(deliberate.kind, PhotoOutcomeKind.inFlight,
        reason: 'the add flow must not say "already logged" about a photo '
            'that is still being analyzed');
    expect(deliberate.retryable, isTrue);

    expect(analyzerCalls, 0);
    expect(dao.ledger[_hash], IngestionStatus.processing,
        reason: 'the other run\'s row is left alone for it (or the launch '
            'sweep) to finish');
    expect(dao.meals, isEmpty);
  });

  test('bind(): an in-flight photo is RELEASED to the intake (sink false), '
      'a claimed one is terminal', () async {
    final dao = FakeDao();
    dao.ledger[_hash] = IngestionStatus.processing;
    final pipeline = PhotoPipeline(dao: dao, analyzer: FakeAnalyzer());
    final intake = _SinkCapturingIntake();
    pipeline.bind(intake);
    expect(await intake.sink!(_photo(), null), isFalse,
        reason: 'false = the watcher drops its seen entry and halts the '
            'frontier; a later scan re-offers the photo');

    dao.ledger[_hash] = IngestionStatus.saved;
    expect(await intake.sink!(_photo(), null), isTrue,
        reason: 'a real verdict stays terminal — coverage may pass it');
  });

  test('deliberate add inside the 5-minute duplicate window is refused',
      () async {
    final dao = FakeDao()..duplicatePhoto = true;
    final pipeline = PhotoPipeline(dao: dao, analyzer: FakeAnalyzer());
    final out = await pipeline.process(_photo(deliberate: true));
    expect(out.kind, PhotoOutcomeKind.duplicate);
    expect(dao.ledger, isEmpty); // refused before reservation (spec §2.3)
  });

  test('a throwing DAO is contained and the hash marked failed', () async {
    final dao = _ThrowingSaveDao();
    final analyzer = FakeAnalyzer()
      ..nextPhotoOutcome = AnalysisOutcome(
          analysis: _foodAnalysis(), isFood: true, wall: Duration.zero);
    final out =
        await PhotoPipeline(dao: dao, analyzer: analyzer).process(_photo());
    expect(out.kind, PhotoOutcomeKind.failed); // contained, no throw (spec §6)
    expect(dao.ledger[_hash], IngestionStatus.failed);
  });

  group('bindStream (share sheet) announces the verdicts nobody awaits', () {
    // A shared photo has no awaiting caller — the add flow awaits enqueue()
    // and shows a dialog, the watcher is meant to stay quiet — so a share
    // that ended not-food / duplicate / already logged / still analyzing
    // gave NO feedback at all, indistinguishable from a share that silently
    // failed (simulator, 2026-10-10).
    const notFood = AnalysisOutcome(
        analysis: {'is_food': false}, isFood: false, wall: Duration.zero);

    /// Shares [photos] through a bound stream and returns what notify saw
    /// once [done] holds (plus a beat, to catch a late second snackbar).
    Future<List<PhotoOutcome>> share(FakeDao dao, FakeAnalyzer analyzer,
        List<IntakePhoto> photos, bool Function(FakeDao dao) done,
        {void Function(PhotoOutcome)? onNotify}) async {
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: dao,
          analyzer: analyzer,
          notify: (o) {
            notes.add(o);
            onNotify?.call(o);
          });
      final stream = StreamController<IntakePhoto>();
      pipeline.bindStream(stream.stream);
      photos.forEach(stream.add);
      await stream.close();
      await _until(() => done(dao));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await pipeline.dispose();
      return notes;
    }

    test('not food → exactly one snackbar, kind skipped', () async {
      final dao = FakeDao();
      final notes = await share(
          dao,
          FakeAnalyzer()..nextPhotoOutcome = notFood,
          [_photo(deliberate: true)],
          (d) => d.ledger[_hash] == IngestionStatus.skipped);
      expect(notes.map((o) => o.kind), [PhotoOutcomeKind.skipped]);
    });

    for (final (what, dao, kind) in [
      (
        'a duplicate inside the 5-minute window',
        FakeDao()..duplicatePhoto = true,
        PhotoOutcomeKind.duplicate
      ),
      (
        'an already logged photo',
        FakeDao()..ledger[_hash] = IngestionStatus.saved,
        PhotoOutcomeKind.alreadyTracked
      ),
      (
        'a photo another run is still analyzing',
        FakeDao()..ledger[_hash] = IngestionStatus.processing,
        PhotoOutcomeKind.inFlight
      ),
    ]) {
      test('$what → exactly one snackbar, kind ${kind.name}', () async {
        final seen = <PhotoOutcome>[];
        final notes = await share(dao, FakeAnalyzer(), [_photo(deliberate: true)],
            (_) => seen.isNotEmpty,
            onNotify: seen.add);
        expect(notes.map((o) => o.kind), [kind]);
        expect(dao.meals, isEmpty);
      });
    }

    test('a save and a permanent failure are still said ONCE (by process)',
        () async {
      final saved = await share(
          FakeDao(),
          FakeAnalyzer()
            ..nextPhotoOutcome = AnalysisOutcome(
                analysis: _foodAnalysis(), isFood: true, wall: Duration.zero),
          [_photo(deliberate: true)],
          (d) => d.ledger[_hash] == IngestionStatus.saved);
      expect(saved.map((o) => o.kind), [PhotoOutcomeKind.saved]);

      final failed = await share(
          FakeDao(),
          FakeAnalyzer()
            ..nextPhotoOutcome =
                const AnalysisOutcome(error: 'bad key', wall: Duration.zero),
          [_photo(deliberate: true)],
          (d) => d.ledger[_hash] == IngestionStatus.failed);
      expect(failed.map((o) => o.kind), [PhotoOutcomeKind.failed]);
    });

    test('a transient failure is said ONCE and asks for a re-share: the '
        'share copy is gone, so silence read as success', () async {
      var analyzed = false;
      final dao = FakeDao();
      final notes = await share(
          dao,
          FakeAnalyzer()
            ..nextPhotoOutcome = const AnalysisOutcome(
                error: 'rate limit', retryable: true, wall: Duration.zero)
            ..onAnalyze = () async => analyzed = true,
          [_photo(deliberate: true)],
          (_) => analyzed);
      expect(dao.ledger, isEmpty); // released, no row (spec §2.3)
      expect(notes, hasLength(1));
      final o = notes.single;
      expect(o.kind, PhotoOutcomeKind.failed);
      expect(o.shared, isTrue);
      final zh = AppLocalizationsZh();
      expect(outcomeSnackbar(zh, o), zh.outcomeShareRetryMsg('服务正在限流'));
      expect(outcomeSnackbar(zh, o), isNot(contains('已保留')));
    });

    test('enqueue() (the add flow) is NOT told — it renders its own dialog',
        () async {
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()..nextPhotoOutcome = notFood,
          notify: notes.add);
      final out = await pipeline.enqueue(_photo(deliberate: true));
      expect(out.kind, PhotoOutcomeKind.skipped);
      expect(notes, isEmpty,
          reason: 'a second snackbar behind the add flow\'s dialog');
    });

    test('bind() (the automatic watcher) stays quiet about a skipped photo',
        () async {
      // Every screenshot the automatic scan sees is "not food"; announcing
      // that with the app open would be a toast per screenshot.
      final notes = <PhotoOutcome>[];
      final pipeline = PhotoPipeline(
          dao: FakeDao(),
          analyzer: FakeAnalyzer()..nextPhotoOutcome = notFood,
          notify: notes.add);
      final intake = _SinkCapturingIntake();
      pipeline.bind(intake);
      expect(await intake.sink!(_photo(), null), isTrue);
      expect(notes, isEmpty);
    });

    test('a throwing snackbar never poisons the shared FIFO', () async {
      // bindStream's notify runs ON the tail every path chains onto: an
      // unshielded throw would reject it and no later photo (watcher,
      // share, coverage Log/Retry) would process until an app restart.
      final second = Uint8List.fromList([4, 5, 6]);
      final secondHash = md5.convert(second).toString().toLowerCase();
      final dao = FakeDao();
      final notes = await share(
          dao,
          FakeAnalyzer()..nextPhotoOutcome = notFood,
          [
            _photo(deliberate: true),
            IntakePhoto(second, 'asset2', 'IMG_2.jpg', deliberate: true),
          ],
          (d) => d.ledger[secondHash] == IngestionStatus.skipped,
          onNotify: (_) => throw StateError('snackbar died'));
      expect(dao.ledger[_hash], IngestionStatus.skipped);
      expect(notes, hasLength(2));
    });
  });
}

/// Polls until [done] holds: bound-stream photos resolve on the pipeline's
/// private FIFO, which nothing outside the pipeline can await.
Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    expect(DateTime.now().isBefore(deadline), isTrue,
        reason: 'the bound stream never reached the expected state');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Hands the test the sink `bind()` attaches, so it can be driven directly.
class _SinkCapturingIntake implements PhotoIntake {
  Future<bool> Function(IntakePhoto, DateTime?)? sink;
  @override
  Stream<IntakePhoto> get photos => const Stream.empty();
  @override
  void attachSink(Future<bool> Function(IntakePhoto, DateTime?)? s) =>
      sink = s;
  @override
  Future<DateTime?> backfillScan({int lookbackDays = 0, DateTime? since}) async =>
      null;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _ThrowingSaveDao extends FakeDao {
  @override
  Future<int> saveMeal(Meal meal,
      {IngestionStatus? markStatus, String? ownerStamp}) async {
    throw StateError('disk full');
  }
}


class _ThumbThrowingDao extends FakeDao {
  @override
  Future<void> saveMealThumb(int mealId, Uint8List jpeg) async {
    throw StateError('disk full');
  }
}
