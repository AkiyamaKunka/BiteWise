/// The delete-confirmation modal flow (spec §4.5): the executor stages a
/// delete → the UI shows a modal listing the labels → Delete calls
/// confirmPendingDelete with the staged ids; Cancel calls nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/fix_meal_screen.dart';

import 'fakes.dart';

// The correction bar moved off Today into FixMealScreen (2026-07-31);
// the modal contract is unchanged.
Future<void> _pumpTodayAndSend(
    WidgetTester tester, FakeExecutor executor, String text) async {
  await tester.pumpWidget(MaterialApp(
    home: FixMealScreen(executor: executor),
  ));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('fixMealField')), text);
  await tester.tap(find.byKey(const Key('fixMealSend')));
  await tester.pumpAndSettle();
}

void main() {
  final stagedReply = NlReply(
    'Deleting 2 meals as requested.',
    needsDeleteConfirmation: true,
    pendingDeleteIds: const [7, 9],
    pendingDeleteLabels: const [
      'Pizza (2026-07-17 12:10 PM, ~800 kcal)',
      'Cola (2026-07-17 12:12 PM, ~150 kcal)',
    ],
  );

  testWidgets('confirm calls confirmPendingDelete with the staged ids',
      (tester) async {
    final executor = FakeExecutor()
      ..nextReplies = [stagedReply]
      ..confirmResult = 'Deleted 2 meal(s).';

    await _pumpTodayAndSend(tester, executor, 'delete meal 0 and 1');

    expect(executor.handledTexts, ['delete meal 0 and 1']);
    // Modal lists every staged label + the warning (spec §4.5).
    expect(find.text('Delete meals?'), findsOneWidget);
    expect(find.textContaining('Pizza (2026-07-17 12:10 PM, ~800 kcal)'),
        findsOneWidget);
    expect(find.textContaining('Cola (2026-07-17 12:12 PM, ~150 kcal)'),
        findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    // Nothing deleted before confirmation.
    expect(executor.confirmedDeletes, isEmpty);

    await tester.tap(find.byKey(const Key('nlDeleteConfirm')));
    await tester.pumpAndSettle();

    expect(executor.confirmedDeletes, [
      [7, 9]
    ]);
    // The executor's result is surfaced.
    expect(find.text('Deleted 2 meal(s).'), findsOneWidget);
  });

  testWidgets('cancel never calls confirmPendingDelete', (tester) async {
    final executor = FakeExecutor()..nextReplies = [stagedReply];

    await _pumpTodayAndSend(tester, executor, 'delete everything');

    expect(find.text('Delete meals?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nlDeleteCancel')));
    await tester.pumpAndSettle();

    expect(executor.confirmedDeletes, isEmpty);
    expect(find.text('Delete meals?'), findsNothing);
  });

  testWidgets('plain replies render as a snackbar, no modal', (tester) async {
    final executor = FakeExecutor()
      ..nextReplies = [const NlReply('Logged 72.5 kg for 2026-07-17.')];

    await _pumpTodayAndSend(tester, executor, 'I weigh 72.5 kg');

    expect(find.text('Delete meals?'), findsNothing);
    expect(find.text('Logged 72.5 kg for 2026-07-17.'), findsOneWidget);
    expect(executor.confirmedDeletes, isEmpty);
  });

  // "Applied this session" (本次已应用) used to list EVERY request, written
  // before the replies were read — a cancelled delete or a refusal showed
  // as applied while the meal was still on Today (loop find 2026-10-07).
  group('Applied this session lists only requests that changed something',
      () {
    testWidgets('a cancelled delete is listed nowhere', (tester) async {
      final executor = FakeExecutor()..nextReplies = [stagedReply];

      await _pumpTodayAndSend(tester, executor, 'delete the pizza');
      await tester.tap(find.byKey(const Key('nlDeleteCancel')));
      await tester.pumpAndSettle();

      expect(executor.confirmedDeletes, isEmpty);
      expect(find.text('Applied this session'), findsNothing);
      expect(find.text('• delete the pizza'), findsNothing);
    });

    testWidgets('a confirmed delete is listed', (tester) async {
      final executor = FakeExecutor()..nextReplies = [stagedReply];

      await _pumpTodayAndSend(tester, executor, 'delete the pizza');
      // Not applied while the modal is still asking.
      expect(find.text('• delete the pizza'), findsNothing);
      await tester.tap(find.byKey(const Key('nlDeleteConfirm')));
      await tester.pumpAndSettle();

      expect(find.text('Applied this session'), findsOneWidget);
      expect(find.text('• delete the pizza'), findsOneWidget);
    });

    testWidgets('a refusal or error reply is not listed', (tester) async {
      final executor = FakeExecutor()
        ..nextReplies = [
          const NlReply('❌ Invalid meal index: 9 (there are 3 meals).'),
        ];

      await _pumpTodayAndSend(tester, executor, 'make meal 9 a salad');

      expect(find.text('❌ Invalid meal index: 9 (there are 3 meals).'),
          findsOneWidget);
      expect(find.text('Applied this session'), findsNothing);
      expect(find.text('• make meal 9 a salad'), findsNothing);
    });

    testWidgets('an applied reply is listed, newest first', (tester) async {
      final executor = FakeExecutor()
        ..nextReplies = [
          const NlReply('Logged 72.5 kg for 2026-07-17.', applied: true),
        ];

      await _pumpTodayAndSend(tester, executor, 'I weigh 72.5 kg');
      executor.nextReplies = [const NlReply("Didn't catch which meals.")];
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'delete that one');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();

      expect(find.text('Applied this session'), findsOneWidget);
      expect(find.text('• I weigh 72.5 kg'), findsOneWidget);
      expect(find.text('• delete that one'), findsNothing);
    });

    testWidgets('a compound request counts when any part changed something',
        (tester) async {
      final executor = FakeExecutor()
        ..nextReplies = [
          const NlReply('Corrected meal #1', applied: true),
          stagedReply,
        ];

      await _pumpTodayAndSend(tester, executor, 'fix lunch, drop the cola');
      await tester.tap(find.byKey(const Key('nlDeleteCancel')));
      await tester.pumpAndSettle();

      expect(find.text('• fix lunch, drop the cola'), findsOneWidget);
    });

    testWidgets('zh: a cancelled delete never shows 本次已应用', (tester) async {
      final executor = FakeExecutor()..nextReplies = [stagedReply];

      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FixMealScreen(executor: executor),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('fixMealField')), '删除披萨这一餐');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nlDeleteCancel')));
      await tester.pumpAndSettle();

      expect(find.text('本次已应用'), findsNothing);
      expect(find.text('• 删除披萨这一餐'), findsNothing);

      // The same request confirmed IS applied.
      await tester.enterText(
          find.byKey(const Key('fixMealField')), '删除披萨这一餐');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nlDeleteConfirm')));
      await tester.pumpAndSettle();

      expect(find.text('本次已应用'), findsOneWidget);
      expect(find.text('• 删除披萨这一餐'), findsOneWidget);
    });
  });

  // The field used to be cleared as soon as the executor returned, so an
  // AI-contact error ("please try again") left nothing to try again with
  // (loop find 2026-10-08). It now clears only when something changed —
  // the same condition as "Applied this session".
  group('the typed request survives a reply that changed nothing', () {
    String fieldText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('fixMealField')))
        .controller!
        .text;

    testWidgets('an AI-contact error keeps the text for a retry',
        (tester) async {
      final executor = FakeExecutor()
        ..nextReplies = [
          const NlReply('❌ Error contacting AI. Please try again.'),
        ];

      await _pumpTodayAndSend(tester, executor, 'delete the first meal');

      expect(find.text('❌ Error contacting AI. Please try again.'),
          findsOneWidget);
      expect(fieldText(tester), 'delete the first meal');

      // Retrying sends the same request again without retyping it.
      executor.nextReplies = [
        const NlReply('Corrected meal #1', applied: true),
      ];
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      expect(executor.handledTexts,
          ['delete the first meal', 'delete the first meal']);
      expect(fieldText(tester), isEmpty);
    });

    testWidgets('an applied reply clears the field', (tester) async {
      final executor = FakeExecutor()
        ..nextReplies = [
          const NlReply('Logged 72.5 kg for 2026-07-17.', applied: true),
        ];

      await _pumpTodayAndSend(tester, executor, 'I weigh 72.5 kg');

      expect(fieldText(tester), isEmpty);
    });

    testWidgets('a cancelled delete keeps the text; a confirmed one clears it',
        (tester) async {
      final executor = FakeExecutor()..nextReplies = [stagedReply];

      await _pumpTodayAndSend(tester, executor, 'delete the pizza');
      await tester.tap(find.byKey(const Key('nlDeleteCancel')));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'delete the pizza');

      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nlDeleteConfirm')));
      await tester.pumpAndSettle();
      expect(executor.confirmedDeletes, [
        [7, 9]
      ]);
      expect(fieldText(tester), isEmpty);
    });

    testWidgets('zh: 联系 AI 失败 keeps the typed correction', (tester) async {
      final executor = FakeExecutor()
        ..nextReplies = [const NlReply('❌ 联系 AI 失败，请重试。')];

      await tester.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FixMealScreen(executor: executor),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('fixMealField')), '午饭的米饭只吃了一半');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();

      expect(find.text('❌ 联系 AI 失败，请重试。'), findsOneWidget);
      expect(fieldText(tester), '午饭的米饭只吃了一半');
      expect(find.text('本次已应用'), findsNothing);
    });
  });
}
