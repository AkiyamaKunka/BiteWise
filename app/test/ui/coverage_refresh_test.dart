/// Run 7, Settings lane: Photo Coverage.
///
/// - B20: while a bulk run is going, the not-food / failed tiles are inert.
///   Saving a manual meal from one re-ran the audit mid-run, which hid the
///   progress bar and re-enabled Run check and Log all / Retry all, so a
///   second run could be confirmed on top of the first.
/// - U13: a failed photo is not "accounted for" (no success check), and a
///   run that stopped on its LAST photo does not say "the remaining 0
///   photos … run this again later".
/// - The restyle: grouped cards on the page colour, in light and dark, with
///   no overflow at AX5 on an SE.
library;

import 'dart:async';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/coverage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;
import '../support/app_theme_harness.dart';
import 'fakes.dart';

Future<String> _hash(List<int> bytes) async => 'h${bytes.first}';

Future<bool> _allowed(BuildContext _) async => true;

void main() {
  late FakePhotoLibrary library;
  late FakeDao dao;
  late CoverageAuditor auditor;

  setUp(() {
    library = FakePhotoLibrary();
    dao = FakeDao();
    auditor = CoverageAuditor(
      library: library,
      dao: dao,
      hasher: _hash,
      clock: () => DateTime(2026, 7, 26, 12, 0),
    );
  });

  CoverageScreen screen({
    required Future<PhotoOutcome> Function(IntakePhoto) process,
    Future<bool> Function(IntakePhoto)? logManually,
  }) => CoverageScreen(
    auditor: auditor,
    processPhoto: process,
    requestPhotoPermission: () async => true,
    initialLookbackDays: 2,
    ensureConsent: _allowed,
    library: library,
    logManually: logManually,
  );

  Future<void> runCheck(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('runCoverageCheck')));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, Key key) =>
      tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

  testWidgets('B20: tiles are inert while a bulk run is going', (tester) async {
    library.assets = [
      FakeAsset('m1', 'M1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
      FakeAsset('m2', 'M2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
      FakeAsset('s3', 'S3.jpg', DateTime(2026, 7, 26, 10), bytesOf(3)),
    ];
    dao.ledger['h3'] = IngestionStatus.skipped;
    final gate = Completer<void>();
    var manualCalls = 0;
    await pumpApp(
      tester,
      screen(
        process: (photo) async {
          await gate.future;
          dao.ledger[await _hash(photo.bytes)] = IngestionStatus.saved;
          return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
        },
        logManually: (photo) async {
          manualCalls++;
          return true;
        },
      ),
      size: const Size(390, 1600),
    );
    await runCheck(tester);
    expect(
      find.byIcon(Icons.edit_outlined),
      findsOneWidget,
      reason: 'idle: the not-food tile offers manual entry',
    );

    await tester.tap(find.byKey(const Key('logAllMissing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmBulkAction')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('coverageProgress')), findsOneWidget);
    expect(
      find.byIcon(Icons.edit_outlined),
      findsNothing,
      reason: 'mid-run the tiles show no edit affordance',
    );

    await tester.tap(find.text('S3.jpg'), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    expect(manualCalls, 0);
    expect(find.byKey(const Key('coverageProgress')), findsOneWidget);
    expect(enabled(tester, const Key('logAllMissing')), isFalse);
    expect(enabled(tester, const Key('runCoverageCheck')), isFalse);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coverageProgress')), findsNothing);
    expect(enabled(tester, const Key('runCoverageCheck')), isTrue);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  for (final lang in const ['en', 'zh']) {
    final l = lookupAppLocalizations(Locale(lang));

    testWidgets('U13 $lang: failed-only is not a success', (tester) async {
      library.assets = [
        FakeAsset('a3', 'IMG_3.jpg', DateTime(2026, 7, 26, 8), bytesOf(3)),
      ];
      dao.ledger['h3'] = IngestionStatus.failed;
      await pumpApp(
        tester,
        screen(
          process: (_) async =>
              const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'),
        ),
        size: const Size(390, 1200),
        locale: Locale(lang),
      );
      await runCheck(tester);
      final summary = find.byKey(const Key('coverageSummary'));
      expect(
        find.descendant(
          of: summary,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: summary,
          matching: find.byIcon(Icons.info_outline_rounded),
        ),
        findsOneWidget,
      );
      expect(find.text(l.covSummaryFailed(1, 1)), findsOneWidget);
      expect(find.text(l.covAllAccounted(1)), findsNothing);
    });

    testWidgets('U13 $lang: a stop on the last photo names no remainder', (
      tester,
    ) async {
      library.assets = [
        FakeAsset('a1', 'IMG_1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
      ];
      await pumpApp(
        tester,
        Scaffold(
          body: Builder(
            builder: (_) => screen(
              process: (photo) async {
                dao.ledger[await _hash(photo.bytes)] = IngestionStatus.failed;
                return const PhotoOutcome(
                  PhotoOutcomeKind.failed,
                  'The provider rejected the API key.',
                  errorKind: AnalysisErrorKind.rejectedKey,
                );
              },
            ),
          ),
        ),
        size: const Size(390, 1200),
        locale: Locale(lang),
      );
      await runCheck(tester);
      await tester.tap(find.byKey(const Key('logAllMissing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmBulkAction')));
      await tester.pumpAndSettle();
      final snack = tester
          .widget<Text>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(snack, startsWith(l.covStoppedLast(l.covProgLogging, 1, 1, '')));
      if (lang == 'en') {
        expect(snack, contains('rejected the API key'));
        expect(snack, isNot(contains('remaining')));
        expect(snack, isNot(contains('run this again')));
      } else {
        expect(snack, isNot(contains('剩下的')));
      }
      // The failed photo is not a success either.
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });
  }

  testWidgets('a stop with photos left still says how many remain', (
    tester,
  ) async {
    library.assets = [
      FakeAsset('a1', 'IMG_1.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
      FakeAsset('a2', 'IMG_2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
    ];
    await pumpApp(
      tester,
      Scaffold(
        body: screen(
          process: (_) async => const PhotoOutcome(
            PhotoOutcomeKind.failed,
            'offline',
            retryable: true,
            errorKind: AnalysisErrorKind.network,
          ),
        ),
      ),
      size: const Size(390, 1200),
    );
    await runCheck(tester);
    await tester.tap(find.byKey(const Key('logAllMissing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmBulkAction')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The remaining 1 photo was not touched'),
      findsOneWidget,
    );
  });

  for (final dark in const [false, true]) {
    for (final lang in const ['en', 'zh']) {
      testWidgets('$lang ${dark ? 'dark' : 'light'}: AX5 on an SE, no '
          'overflow, cells on the page colour', (tester) async {
        library.assets = [
          FakeAsset('m1', 'IMG_0001.jpg', DateTime(2026, 7, 26, 8), bytesOf(1)),
          FakeAsset('s2', 'IMG_0002.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
          FakeAsset(
            'f3',
            'IMG_0003.jpg',
            DateTime(2026, 7, 26, 10),
            bytesOf(3),
          ),
        ];
        dao.ledger['h2'] = IngestionStatus.skipped;
        dao.ledger['h3'] = IngestionStatus.failed;
        await pumpApp(
          tester,
          screen(
            process: (_) async =>
                const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'),
            logManually: (_) async => false,
          ),
          size: const Size(375, 667),
          scale: 53 / 17,
          locale: Locale(lang),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        // At AX5 the intro alone is taller than the screen.
        await tester.scrollUntilVisible(
          find.byKey(const Key('runCoverageCheck')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.byKey(const Key('runCoverageCheck')));
        await tester.pumpAndSettle();
        await runCheck(tester);
        expect(tester.takeException(), isNull);
        // Top to bottom: never scanned, not food, failed.
        for (final key in const [
          'logAllMissing',
          'reanalyzeAllSkipped',
          'retryAllFailed',
        ]) {
          await tester.scrollUntilVisible(
            find.byKey(Key(key)),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: key);
        }
        // File names wrap at AX5 instead of 'IMG_00…'.
        // Bottom (failed) to top (never scanned).
        for (final name in const ['IMG_0003.jpg', 'IMG_0001.jpg']) {
          final text = find.text(name);
          await tester.scrollUntilVisible(
            text,
            -200,
            scrollable: find.byType(Scrollable).first,
          );
          final p = tester.renderObject<RenderParagraph>(
            find.descendant(of: text, matching: find.byType(RichText)),
          );
          expect(p.didExceedMaxLines, isFalse, reason: name);
        }
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(
          scaffold.backgroundColor,
          dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
        );
      });
    }
  }
}
