// Coverage screen flow: run check → summary; "Log all" pushes each missing
// photo through the injected pipeline callback and re-audits.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/coverage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;
import 'fakes.dart';

Future<String> testHash(List<int> bytes) async => 'h${bytes.first}';

void main() {
  late FakePhotoLibrary library;
  late FakeDao dao;
  late CoverageAuditor auditor;
  final processed = <IntakePhoto>[];

  setUp(() {
    library = FakePhotoLibrary();
    dao = FakeDao();
    processed.clear();
    auditor = CoverageAuditor(
        library: library,
        dao: dao,
        hasher: testHash,
        clock: () => DateTime(2026, 7, 26, 12, 0));
  });

  Widget host() => MaterialApp(
        home: CoverageScreen(
          auditor: auditor,
          processPhoto: (photo) async {
            processed.add(photo);
            // Simulate the pipeline logging it: ledger gains the hash.
            dao.ledger[await testHash(photo.bytes)] = IngestionStatus.saved;
            return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
          },
          requestPhotoPermission: () async => true,
          initialLookbackDays: 2,
          library: library,
        ),
      );

  testWidgets('run check → summary; log all → processed and re-audited',
      (tester) async {
    library.assets = [
      FakeAsset('a1', 'IMG_1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
      FakeAsset('a2', 'IMG_2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
    ];
    dao.ledger['h1'] = IngestionStatus.saved;

    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverageSummary')), findsOneWidget);
    expect(find.textContaining('1 never scanned'), findsOneWidget);
    expect(find.text('IMG_2.jpg'), findsOneWidget);

    await tester.tap(find.byKey(const Key('logAllMissing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmBulkAction')));
    await tester.pumpAndSettle();

    expect(processed, hasLength(1));
    expect(processed.single.assetId, 'a2');
    expect(processed.single.deliberate, isTrue);
    // Re-audit after acting: now fully covered.
    expect(find.textContaining('accounted for'), findsOneWidget);
    expect(find.byKey(const Key('logAllMissing')), findsNothing);
  });

  testWidgets('a quota-paused bulk action is REFUSED, tombstones survive',
      (tester) async {
    // Without the gate this ran to "completion" in seconds with zero model
    // calls and DELETED every 'skipped' row (reserve reclaims → release
    // deletes), turning 21 known-not-food photos into "never scanned".
    library.assets = [
      FakeAsset('a9', 'Screenshot.jpg', DateTime(2026, 7, 26, 8), bytesOf(9)),
    ];
    dao.ledger['h9'] = IngestionStatus.skipped;
    await tester.pumpWidget(MaterialApp(
      home: CoverageScreen(
        auditor: auditor,
        processPhoto: (photo) async {
          processed.add(photo);
          return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
        },
        requestPhotoPermission: () async => true,
        initialLookbackDays: 2,
        canAnalyze: () => false, // quota latch armed / no key
        library: library,
      ),
    ));
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reanalyzeAllSkipped')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('confirmBulkAction')), findsNothing);
    expect(find.textContaining('No analysis is possible'), findsOneWidget);
    expect(processed, isEmpty);
    expect(dao.ledger['h9'], IngestionStatus.skipped,
        reason: 'the tombstone must survive a refused run');
  });

  testWidgets('quota latch arming MID-RUN stops the batch; later tombstones '
      'survive', (tester) async {
    // The 9dfd509 gate checked canAnalyze ONCE, before the loop — a bool
    // captured when the screen was pushed. But the latch arms mid-batch:
    // photo 1's daily-quota 429 sets the pause, and every photo pushed
    // after that is reserved (reclaiming its 'skipped' tombstone), makes
    // zero model calls, and is released — which DELETES the just-reclaimed
    // row. A probe run erased 4 of 5 tombstones that way. The fix is a live
    // re-check each iteration plus breaking on a retryable outcome.
    library.assets = [
      FakeAsset('b1', 'S1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
      FakeAsset('b2', 'S2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
      FakeAsset('b3', 'S3.jpg', DateTime(2026, 7, 26, 10), bytesOf(3)),
    ];
    dao.ledger['h1'] = IngestionStatus.skipped;
    dao.ledger['h2'] = IngestionStatus.skipped;
    dao.ledger['h3'] = IngestionStatus.skipped;
    var paused = false;
    await tester.pumpWidget(MaterialApp(
      home: CoverageScreen(
        auditor: auditor,
        processPhoto: (photo) async {
          processed.add(photo);
          // Photo 1 exhausts the daily quota: the analyzer arms the latch
          // and the pipeline releases the reservation — deleting the row
          // reserve had just flipped to 'processing'.
          paused = true;
          dao.ledger.remove(await testHash(photo.bytes));
          return const PhotoOutcome(
              PhotoOutcomeKind.failed, 'quota', retryable: true);
        },
        requestPhotoPermission: () async => true,
        initialLookbackDays: 2,
        canAnalyze: () => !paused, // LIVE read, true at confirm time
        library: library,
      ),
    ));
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reanalyzeAllSkipped')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmBulkAction')));
    await tester.pumpAndSettle();

    expect(processed, hasLength(1),
        reason: 'photos 2 and 3 must never be reserved-and-released');
    expect(dao.ledger['h2'], IngestionStatus.skipped,
        reason: 'tombstone 2 survives the aborted run');
    expect(dao.ledger['h3'], IngestionStatus.skipped,
        reason: 'tombstone 3 survives the aborted run');
    expect(find.textContaining('stopped after 1 of 3'), findsOneWidget);
    expect(find.textContaining('not touched'), findsOneWidget);
  });

  testWidgets('cancelling the bulk confirmation spends nothing', (tester) async {
    library.assets = [
      FakeAsset('a2', 'IMG_2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
    ];
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logAllMissing')));
    await tester.pumpAndSettle();
    // 20 photos ≈ 8 minutes of model calls: the user must be able to escape.
    expect(find.textContaining('model call'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(processed, isEmpty);
  });

  testWidgets('denied permission shows the error and never scans',
      (tester) async {
    library.assets = [
      FakeAsset('a1', 'IMG_1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
    ];
    await tester.pumpWidget(MaterialApp(
      home: CoverageScreen(
        auditor: auditor,
        processPhoto: (p) async =>
            const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'),
        requestPhotoPermission: () async => false,
        initialLookbackDays: 2,
      ),
    ));
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coverageError')), findsOneWidget);
    expect(find.byKey(const Key('coverageSummary')), findsNothing);
  });

  testWidgets('fully covered day shows the green summary with no actions',
      (tester) async {
    library.assets = [
      FakeAsset('a1', 'IMG_1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
    ];
    dao.ledger['h1'] = IngestionStatus.skipped;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    expect(find.textContaining('accounted for'), findsOneWidget);
    expect(find.byKey(const Key('logAllMissing')), findsNothing);
    expect(find.byKey(const Key('retryAllFailed')), findsNothing);
  });

  testWidgets('skipped photos can be RE-ANALYZED (improved rules revisit them)',
      (tester) async {
    // A 'skipped' tombstone is permanent for the automated path, so after the
    // prompt learned to accept takeout order screenshots (2026-07-27) the
    // only way to revisit them is a deliberate re-add.
    library.assets = [
      FakeAsset('a9', 'Screenshot_order.jpg', DateTime(2026, 7, 26, 8),
          bytesOf(9)),
    ];
    dao.ledger['h9'] = IngestionStatus.skipped;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reanalyzeAllSkipped')), findsOneWidget);

    await tester.tap(find.byKey(const Key('reanalyzeAllSkipped')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmBulkAction')));
    await tester.pumpAndSettle();
    expect(processed.single.assetId, 'a9');
    expect(processed.single.deliberate, isTrue,
        reason: 'only a deliberate re-add reclaims a skipped ledger row');
  });

  testWidgets('a leftover photo is a read-only summary line, never "not food"',
      (tester) async {
    // Re-analyzing a leftover tombstone logged the remains as a second meal
    // on top of the already-reduced original.
    library.assets = [
      FakeAsset('a8', 'IMG_8.jpg', DateTime(2026, 7, 26, 13), bytesOf(8)),
    ];
    dao.ledger['h8'] = IngestionStatus.skipped;
    dao.seed(const Meal(
      id: 5,
      date: '2026-07-26',
      time: '12:00 PM',
      timestamp: 'x',
      source: 'app_watch',
      analysis: {
        'is_food': true,
        'leftover': {'leftover_photo_md5': 'h8'},
      },
    ));
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 leftover photos (deducted from their meal)'),
        findsOneWidget);
    expect(find.textContaining('0 not food'), findsOneWidget);
    expect(find.byKey(const Key('reanalyzeAllSkipped')), findsNothing);
    expect(find.text('IMG_8.jpg'), findsNothing);
  });

  // The deleted / in-flight / unreadable / too-large fragments were English
  // literals glued onto an otherwise localized line, so the Chinese UI read
  // "已记录 0 餐 · 0 张非食物 · 1 deleted by you · 1 in progress".
  Future<void> auditDeletedInFlightUnreadable(
      WidgetTester tester, Locale locale) async {
    library.assets = [
      FakeAsset('d1', 'IMG_D.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
      FakeAsset('p2', 'IMG_P.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
      FakeAsset('u3', 'IMG_U.jpg', DateTime(2026, 7, 26, 10), null),
    ];
    dao.ledger['h1'] = IngestionStatus.deleted;
    dao.ledger['h2'] = IngestionStatus.processing;
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CoverageScreen(
        auditor: auditor,
        processPhoto: (p) async =>
            const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'),
        requestPhotoPermission: () async => true,
        initialLookbackDays: 2,
        library: library,
      ),
    ));
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
  }

  testWidgets('the Chinese summary counts are Chinese, not English fragments',
      (tester) async {
    await auditDeletedInFlightUnreadable(tester, const Locale('zh'));
    expect(
        find.text('已记录 0 餐 · 0 张非食物 · 1 张已被你删除 · 1 张分析中 · '
            '1 张无法读取'),
        findsOneWidget);
    expect(find.textContaining('deleted by you'), findsNothing);
    expect(find.textContaining('in progress'), findsNothing);
    expect(find.textContaining('unreadable'), findsNothing);
  });

  testWidgets('the English summary counts read exactly as before',
      (tester) async {
    await auditDeletedInFlightUnreadable(tester, const Locale('en'));
    expect(
        find.textContaining(
            '1 deleted by you · 1 in progress · 1 unreadable'),
        findsOneWidget);
  });

  test('every summary count has a Chinese string', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    expect(zh.covDeletedCount(2), '2 张已被你删除');
    expect(zh.covInFlightCount(2), '2 张分析中');
    expect(zh.covUnreadableCount(2), '2 张无法读取');
    expect(zh.covTooLargeCount(2), '2 张过大无法分析');
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.covTooLargeCount(2), '2 too large to analyze');
  });

  testWidgets('failed photos get a Retry all that goes through the pipeline',
      (tester) async {
    library.assets = [
      FakeAsset('a3', 'IMG_3.jpg', DateTime(2026, 7, 26, 8), bytesOf(3)),
    ];
    dao.ledger['h3'] = IngestionStatus.failed;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('retryAllFailed')), findsOneWidget);

    await tester.tap(find.byKey(const Key('retryAllFailed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmBulkAction')));
    await tester.pumpAndSettle();
    expect(processed.single.assetId, 'a3');
    expect(find.textContaining('accounted for'), findsOneWidget);
  });

  testWidgets('a failed photo can be LOGGED MANUALLY, not only retried',
      (tester) async {
    // Failed tiles had no onTap: a permanent failure (decode error, coded
    // 400, "no usable result") left Retry all as the only action, which
    // repeats the verdict at another model call each time. The add flow
    // already offers manual logging for failed as well as skipped.
    library.assets = [
      FakeAsset('a3', 'IMG_3.jpg', DateTime(2026, 7, 26, 8), bytesOf(3)),
    ];
    dao.ledger['h3'] = IngestionStatus.failed;
    final manual = <IntakePhoto>[];
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CoverageScreen(
        auditor: auditor,
        processPhoto: (photo) async {
          processed.add(photo);
          return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
        },
        requestPhotoPermission: () async => true,
        initialLookbackDays: 2,
        library: library,
        logManually: (photo) async {
          manual.add(photo);
          // What the meal editor's save does to the ledger.
          dao.ledger[await testHash(photo.bytes)] = IngestionStatus.saved;
          return true;
        },
      ),
    ));
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('retryAllFailed')), findsOneWidget);
    expect(find.text('"全部重试" 会再问一次 AI（同样的错误多半会重现）；点某一行可以手动录入。'),
        findsOneWidget);
    final tile = find.ancestor(
        of: find.text('IMG_3.jpg'), matching: find.byType(ListTile));
    expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.edit_outlined)),
        findsOneWidget);

    await tester.tap(find.text('IMG_3.jpg'));
    await tester.pumpAndSettle();
    expect(manual.single.assetId, 'a3');
    expect(processed, isEmpty,
        reason: 'manual entry must not spend another model call');
    // Re-audited after the save: the photo is accounted for.
    expect(find.byKey(const Key('retryAllFailed')), findsNothing);
  });

  testWidgets('without a manual editor, failed tiles stay inert',
      (tester) async {
    library.assets = [
      FakeAsset('a3', 'IMG_3.jpg', DateTime(2026, 7, 26, 8), bytesOf(3)),
    ];
    dao.ledger['h3'] = IngestionStatus.failed;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(
        find.textContaining('"Retry all" asks the AI again'), findsOneWidget);
  });
}
