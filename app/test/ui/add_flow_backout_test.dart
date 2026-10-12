// Backing out of 记录 mid-analysis (2026-10-12). The AppBar back button
// stays live under the analyzing overlay; once the screen is gone the
// dialog that words the verdict is gone too, and process() announces only
// saves, leftover deductions and permanent failures. Not food, duplicate,
// already logged, still analyzing and a transient failure used to vanish
// without a word. They now reach the app's root snackbar exactly once,
// through the same filter the share sheet uses (unannouncedOutcome).
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _food = AnalysisOutcome(
    analysis: {
      'is_food': true,
      'meal_description': 'Noodles',
      'total_calories': 500
    },
    isFood: true,
    wall: Duration.zero);

class _Case {
  const _Case(this.name, this.kind,
      {this.analysis = _food, this.duplicate = false, this.ledger});
  final String name;
  final PhotoOutcomeKind kind;
  final AnalysisOutcome analysis;
  final bool duplicate;
  final IngestionStatus? ledger;
}

/// The app shell in miniature: a root ScaffoldMessenger, the pipeline's
/// notify and the services' announceOutcome both wording the outcome in
/// zh (di.dart builds ONE such sink for both).
class _Harness {
  _Harness(_Case c) {
    analyzer.nextPhotoOutcome = c.analysis;
    dao.duplicatePhoto = c.duplicate;
    if (c.ledger != null) dao.ledger['h1'] = c.ledger!;
    final pipeline = PhotoPipeline(
        dao: dao, analyzer: analyzer, notify: sink, hasher: (_) async => 'h1');
    picker.photos = [
      IntakePhoto(Uint8List.fromList(List.filled(16, 3)), 'a0', 'a0.jpg',
          capturedAt: DateTime(2026, 10, 12, 12))
    ];
    services = makeServices(
        dao: dao,
        analyzer: analyzer,
        picker: picker,
        // The gate holds every kind — duplicate and the ledger refusals
        // return before the analyzer — until the user has backed out.
        processPhoto: (p) => run = () async {
          await gate.future;
          return pipeline.enqueue(p);
        }(),
        announceOutcome: sink);
  }

  final gate = Completer<void>();
  Future<PhotoOutcome>? run;
  final analyzer = FakeAnalyzer();
  final dao = FakeDao();
  final picker = FakePicker();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final navigator = GlobalKey<NavigatorState>();
  final AppLocalizations zh = AppLocalizationsZh();
  final said = <String>[];
  late final UiServices services;

  void sink(PhotoOutcome o) {
    final text = outcomeSnackbar(zh, o);
    said.add(text);
    messenger.currentState!.showSnackBar(SnackBar(content: Text(text)));
  }

  /// Let the analysis finish. Real async: a save makes its thumbnail on
  /// a compute() isolate, which fake time never runs.
  Future<void> finish(WidgetTester tester) async {
    PhotoOutcome? done;
    run!.then((o) => done = o);
    gate.complete();
    for (var i = 0; i < 200 && done == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(done, isNotNull, reason: 'the analysis never finished');
    outcome = done;
    await tester.pumpAndSettle();
  }

  PhotoOutcome? outcome;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        scaffoldMessengerKey: messenger,
        navigatorKey: navigator,
        home: const Scaffold(body: Text('home'))));
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => AddPhotoScreen(services: services)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recentPhoto0')));
    await tester.pump();
    expect(find.byKey(const Key('photoAnalyzing')), findsOneWidget);
  }
}

void main() {
  const transient = AnalysisOutcome(
      error: 'Provider rate/spend limit hit — will retry later.',
      retryable: true,
      wall: Duration.zero);
  final zh = AppLocalizationsZh();

  for (final (c, expected) in [
    (
      const _Case('not food', PhotoOutcomeKind.skipped,
          analysis: AnalysisOutcome(
              analysis: {'is_food': false}, isFood: false, wall: Duration.zero)),
      zh.outcomeNotFoodMsg
    ),
    (
      const _Case('duplicate', PhotoOutcomeKind.duplicate, duplicate: true),
      zh.outcomeDuplicateMsg
    ),
    (
      const _Case('already logged', PhotoOutcomeKind.alreadyTracked,
          ledger: IngestionStatus.saved),
      zh.outcomeAlreadyTrackedMsg
    ),
    (
      const _Case('still analyzing', PhotoOutcomeKind.inFlight,
          ledger: IngestionStatus.processing),
      zh.outcomeInFlightMsg
    ),
    (
      const _Case('transient failure', PhotoOutcomeKind.failed,
          analysis: transient),
      '这张照片没能分析（服务正在限流）—— 请稍后重新选择它。'
    ),
  ]) {
    testWidgets('backing out mid-analysis still says it: ${c.name}',
        (tester) async {
      final h = _Harness(c);
      await h.open(tester);
      // The AppBar back button is reachable under the overlay — and must
      // stay so: no PopScope traps the user on a 60 s spinner.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);

      await h.finish(tester);

      expect(h.said, [expected],
          reason: 'exactly one root snackbar, in the app language');
      expect(find.text(expected), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.outcome!.kind, c.kind);
    });
  }

  for (final c in [
    const _Case('saved', PhotoOutcomeKind.saved),
    const _Case('permanent failure', PhotoOutcomeKind.failed,
        analysis: AnalysisOutcome(
            error: 'Gemini rejected the image.', wall: Duration.zero)),
  ]) {
    testWidgets('backing out adds NOTHING for a kind process() already '
        'announced: ${c.name}', (tester) async {
      final h = _Harness(c);
      await h.open(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await h.finish(tester);

      expect(h.outcome!.kind, c.kind);
      expect(h.said, hasLength(1),
          reason: 'process() said it once; the add flow must not repeat it');
      expect(find.byType(SnackBar), findsOneWidget);
    });
  }

  testWidgets('staying on the screen: the dialog says it, no snackbar',
      (tester) async {
    final h = _Harness(const _Case('transient', PhotoOutcomeKind.failed,
        analysis: transient));
    await h.open(tester);
    await h.finish(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('分析失败'), findsOneWidget);
    expect(h.said, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });
}
