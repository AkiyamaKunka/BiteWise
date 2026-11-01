/// Run 7 add-flow and editor refresh, on the app's REAL theme (AppTheme via
/// the harness): the + Log sheet, the photo grid and its result dialog,
/// Describe, Fix-a-meal, the chat delete confirmation and the editor's
/// delete dialog and pickers.
///
/// Also the bugs fixed with it: the quota-pause dialog offered a Retry
/// that could only fail (B8), a missing key read "Analysis failed" (U2),
/// every failure ended "If this IS food…" (U12), Fix-a-meal errors were a
/// 4-second snackbar (U11), Describe's error landed under the keyboard
/// (A15) and the grid capped thumbnails at 320 px (U28).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/outcome_kind.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/outcome_text.dart' show dayTimeLabel;
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/fix_meal_screen.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart';
import 'package:calorie_tracker/ui/widgets/pickers.dart';
import 'package:calorie_tracker/ui/widgets/reply_note.dart';
import 'package:calorie_tracker/ui/widgets/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

const _en = Locale('en');
const _zh = Locale('zh');

AppLocalizations _l(Locale locale) => lookupAppLocalizations(locale);

IntakePhoto _photo(String id) => IntakePhoto(
    Uint8List.fromList(List.filled(16, 3)), id, '$id.jpg',
    capturedAt: DateTime(2026, 7, 30, 12));

/// A button that opens the + Log sheet, as the Today FAB does.
class _SheetHost extends StatelessWidget {
  const _SheetHost(this.services);
  final UiServices services;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const Key('openSheet'),
            onPressed: () => openAddFlow(context, services),
            child: const Text('open'),
          ),
        ),
      );
}

Color _badgeFill(WidgetTester tester, String rowKey) {
  final box = tester.widget<Container>(find.descendant(
      of: find.descendant(
          of: find.byKey(Key(rowKey)), matching: find.byType(RowBadge)),
      matching: find.byType(Container)));
  return (box.decoration! as BoxDecoration).color!;
}

Meal _meal() => Meal(
      id: 1,
      date: '2026-07-24',
      time: '01:30 PM',
      timestamp: '2026-07-24T13:30:00.000',
      source: 'app_photo',
      imageHash: 'h1',
      analysis: const {
        'is_food': true,
        'meal_description': 'Chicken salad',
        'total_calories': 450,
        'total_protein_g': 50,
        'total_carbs_g': 12,
        'total_fat_g': 22,
      },
    );

/// The AddPhotoScreen with one photo whose pick returns [outcome].
Future<void> _pickWith(
  WidgetTester tester,
  PhotoOutcome outcome, {
  Locale locale = _en,
  FakeSettings? settings,
}) async {
  final services = makeServices(
      settings: settings,
      picker: FakePicker()..photos = [_photo('a0')],
      processPhoto: (_) async => outcome);
  await pumpApp(tester, AddPhotoScreen(services: services), locale: locale);
  await tester.tap(find.byKey(const Key('recentPhoto0')));
  await tester.pumpAndSettle();
}

String _dialogText(WidgetTester tester) {
  final dialog = find.byType(AlertDialog);
  return find
      .descendant(of: dialog, matching: find.byType(Text))
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .join('\n');
}

void main() {
  setUpAll(loadIphoneFonts);

  group('the + Log sheet', () {
    testWidgets('a title2 heading; badges by role: Fix is indigo, not red',
        (tester) async {
      await pumpApp(tester, _SheetHost(makeServices()));
      await tester.tap(find.byKey(const Key('openSheet')));
      await tester.pumpAndSettle();

      final l = _l(_en);
      final title = tester.widget<Text>(find.text(l.addSheetTitle));
      expect(title.style?.fontSize, 22);
      expect(title.style?.fontWeight, FontWeight.w700);
      expect(title.style?.color, AppColors.light.label);

      expect(_badgeFill(tester, 'addFixMeal'), AppColors.light.badgeInfo);
      expect(_badgeFill(tester, 'addFixMeal'),
          isNot(AppColors.light.badgeDanger));
      expect(_badgeFill(tester, 'addManually'), AppColors.light.badgeNeutral);
      expect(_badgeFill(tester, 'addFromText'), AppColors.light.badgeNeutral);
      expect(_badgeFill(tester, 'addLeftover'), AppColors.light.badgeNeutral);
      expect(_badgeFill(tester, 'addFromPhotos'), AppColors.light.badgeBrand);
    });

    testWidgets('dark: a #1C1C1E sheet with #2C2C2E cells (not #1C1C1E cells '
        'on black)', (tester) async {
      await pumpApp(tester, _SheetHost(makeServices()),
          brightness: Brightness.dark);
      await tester.tap(find.byKey(const Key('openSheet')));
      await tester.pumpAndSettle();

      final sheet = tester.widget<Material>(find
          .descendant(
              of: find.byType(BottomSheet), matching: find.byType(Material))
          .first);
      expect(sheet.color, const Color(0xFF1C1C1E));
      final cells = tester.widget<Material>(find
          .descendant(
              of: find.byType(GroupedSection).first,
              matching: find.byType(Material))
          .first);
      expect(cells.color, const Color(0xFF2C2C2E));
      expect(_badgeFill(tester, 'addFixMeal'), AppColors.dark.badgeInfo);
    });

    for (final locale in [_en, _zh]) {
      testWidgets('AX5 on an SE (${locale.languageCode}): no overflow, and '
          'the last row scrolls into reach', (tester) async {
        final services = makeServices();
        await pumpApp(tester, _SheetHost(services),
            size: const Size(375, 667),
            scale: 53 / 17,
            locale: locale,
            padding: const EdgeInsets.only(top: 20));
        await tester.tap(find.byKey(const Key('openSheet')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.byKey(const Key('addFixMeal')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('addFixMeal')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(FixMealScreen), findsOneWidget);
      });
    }
  });

  group('the photo grid', () {
    testWidgets('no photos: the shared empty state', (tester) async {
      final services = makeServices(picker: FakePicker()..photos = const []);
      await pumpApp(tester, AddPhotoScreen(services: services));

      final empty = tester.widget<EmptyState>(find.byType(EmptyState));
      expect(empty.icon, Icons.photo_library_rounded);
      expect(find.text(_l(_en).addNoPhotos), findsOneWidget);
    });

    testWidgets('thumbnails are not capped at 320 px (U28)', (tester) async {
      final services =
          makeServices(picker: FakePicker()..photos = [_photo('a0')]);
      await pumpApp(tester, AddPhotoScreen(services: services));

      final image = tester.widget<Image>(find.descendant(
          of: find.byKey(const Key('recentPhoto0')),
          matching: find.byType(Image)));
      expect(image.image, isA<MemoryImage>(),
          reason: 'a ResizeImage would re-soften the PhotoKit thumbnail');
    });

    testWidgets('the analyzing overlay is the shared one, still a live '
        'region under its old keys', (tester) async {
      final handle = tester.ensureSemantics();
      final gate = Completer<PhotoOutcome>();
      final services = makeServices(
          picker: FakePicker()..photos = [_photo('a0')],
          processPhoto: (_) => gate.future);
      await pumpApp(tester, AddPhotoScreen(services: services));
      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pump();

      expect(find.byType(AnalyzingOverlay), findsOneWidget);
      expect(find.byKey(const Key('photoAnalyzing')), findsWidgets);
      expect(tester.getSemantics(find.byKey(const Key('photoAnalyzingText'))),
          isSemantics(label: 'Analyzing…', isLiveRegion: true));
      final label =
          tester.widget<Text>(find.byKey(const Key('photoAnalyzingText')));
      expect(label.style?.color, AppColors.light.label,
          reason: 'label colour on the elevated capsule, not white on scrim');

      gate.complete(const PhotoOutcome(PhotoOutcomeKind.saved, 'ok'));
      await tester.pumpAndSettle();
      handle.dispose();
    });
  });

  group('the result dialog', () {
    const quotaPaused = PhotoOutcome(
        PhotoOutcomeKind.failed, 'Gemini quota exhausted — paused.',
        retryable: true, errorKind: AnalysisErrorKind.quotaPaused);

    for (final locale in [_en, _zh]) {
      final l = _l(locale);
      testWidgets('quota pause (${locale.languageCode}): no Retry that can '
          'only fail; names the pause and when it ends (B8)', (tester) async {
        final until = DateTime.now().add(const Duration(hours: 6));
        await _pickWith(tester, quotaPaused,
            locale: locale, settings: FakeSettings()..quotaPauseUntil = until);

        expect(find.byKey(const Key('retryAnalysisButton')), findsNothing);
        expect(find.byKey(const Key('logManuallyButton')), findsOneWidget);
        final text = _dialogText(tester);
        expect(text,
            contains(l.outcomeQuotaPausedPickMsg(dayTimeLabel(l, until))));
        for (final stale in [
          'tap Retry', 'retried later', '点“重试”', '自动重试',
          'If this IS food', '确实是食物',
        ]) {
          expect(text, isNot(contains(stale)));
        }
      });
    }

    testWidgets('quota pause with no end time known: the plain variant',
        (tester) async {
      await _pickWith(tester, quotaPaused);
      expect(_dialogText(tester),
          contains(_l(_en).outcomeQuotaPausedPickMsgNoTime));
      expect(find.byKey(const Key('retryAnalysisButton')), findsNothing);
    });

    for (final (locale, kind) in [
      (_en, AnalysisErrorKind.noApiKey),
      (_zh, AnalysisErrorKind.noApiKey),
      (_en, AnalysisErrorKind.noServerKey),
    ]) {
      final l = _l(locale);
      testWidgets('${kind.name} (${locale.languageCode}): "AI isn\'t set up '
          'yet", not "Analysis failed" (U2)', (tester) async {
        await _pickWith(
            tester,
            PhotoOutcome(PhotoOutcomeKind.failed, 'no key',
                retryable: true, errorKind: kind),
            locale: locale);

        expect(find.text(l.outcomeNotSetUp), findsOneWidget);
        expect(find.text(l.outcomeFailed), findsNothing);
        expect(find.byKey(const Key('retryAnalysisButton')), findsNothing);
        expect(find.byKey(const Key('logManuallyButton')), findsOneWidget);
        final text = _dialogText(tester);
        expect(text, contains(l.outcomeLogManuallyFailedHint));
        expect(text, isNot(contains(l.outcomeLogManuallyHint)));
      });
    }

    // A saved own-server address that will not parse ('http://host:5OOO',
    // or no http:// in front) reports noServerKey too, but the server IS
    // set up: the title said "AI isn't set up yet" over a body saying the
    // address has a typo (run-7 review UIS-1).
    for (final locale in [_en, _zh]) {
      final l = _l(locale);
      testWidgets('a bad server address (${locale.languageCode}): "check '
          'your server address", no Retry that can only fail', (tester) async {
        const message = 'Check your server address in Settings — it is not '
            'a valid web address.';
        await _pickWith(
            tester,
            PhotoOutcome(PhotoOutcomeKind.failed, message,
                retryable: true, errorKind: classifyAnalysisError(message)),
            locale: locale);

        expect(find.text(l.outcomeCheckServer), findsOneWidget);
        expect(find.text(l.outcomeNotSetUp), findsNothing);
        expect(_dialogText(tester), contains(l.errBadServerAddress));
        expect(find.byKey(const Key('retryAnalysisButton')), findsNothing);
        expect(find.byKey(const Key('logManuallyButton')), findsOneWidget);
      });
    }

    for (final locale in [_en, _zh]) {
      final l = _l(locale);
      testWidgets('a transient failure (${locale.languageCode}) keeps '
          '"Analysis failed" and Retry, with the neutral hint (U12)',
          (tester) async {
        await _pickWith(
            tester,
            const PhotoOutcome(PhotoOutcomeKind.failed, 'rate limited',
                retryable: true,
                errorKind: AnalysisErrorKind.rateLimited,
                detail: 'rate limited'),
            locale: locale);

        expect(find.text(l.outcomeFailed), findsOneWidget);
        expect(find.byKey(const Key('retryAnalysisButton')), findsOneWidget);
        final text = _dialogText(tester);
        expect(text, contains(l.outcomeLogManuallyFailedHint));
        expect(text, isNot(contains(l.outcomeLogManuallyHint)));
      });

      testWidgets('not food (${locale.languageCode}) still says "if this IS '
          'food"', (tester) async {
        await _pickWith(
            tester,
            const PhotoOutcome(PhotoOutcomeKind.skipped, 'not food'),
            locale: locale);
        final text = _dialogText(tester);
        expect(text, contains(l.outcomeLogManuallyHint));
        expect(text, isNot(contains(l.outcomeLogManuallyFailedHint)));
      });
    }

    testWidgets('the dialog scrolls as a whole at AX5 on an SE (A1)',
        (tester) async {
      final services = makeServices(
          picker: FakePicker()..photos = [_photo('a0')],
          processPhoto: (_) async => quotaPaused);
      await pumpApp(tester, AddPhotoScreen(services: services),
          size: const Size(375, 667), scale: 53 / 17, locale: _zh);
      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
          isTrue);
      expect(find.byKey(const Key('logManuallyButton')).hitTestable(),
          findsOneWidget);
    });
  });

  group('Describe a meal', () {
    testWidgets('the error is a note on a cell, scrolled into view above '
        'the keyboard (A15)', (tester) async {
      // The user scrolled down to the button and tapped it; the error is
      // inserted where the button was — at the bottom edge, so mostly
      // under the keyboard until the page scrolls to it.
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      final executor = FakeExecutor()
        ..nextDescribe = const DescribeOutcome(
            error: 'Could not reach the AI service. Check the connection '
                'and try again.');
      await pumpApp(
          tester,
          AddTextScreen(
              executor: executor, dao: FakeDao(), settings: FakeSettings()),
          size: const Size(375, 667),
          scale: 2.0);
      await tester.enterText(find.byKey(const Key('addTextField')), 'eggs');
      await tester.pumpAndSettle(); // the field's own caret scroll
      // The user scrolled the page to the end, where the button is.
      final page = tester
          .state<ScrollableState>(find
              .descendant(
                  of: find.byType(SingleChildScrollView),
                  matching: find.byType(Scrollable))
              .first)
          .position;
      page.jumpTo(page.maxScrollExtent);
      await tester.pump();
      await tester.tap(find.byKey(const Key('addTextSend')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final error = tester.getRect(find.byType(ReplyNote));
      final bar = tester.getRect(find.byType(AppBar));
      expect(error.top, greaterThanOrEqualTo(bar.bottom - 0.5),
          reason: 'not scrolled up under the app bar');
      expect(error.bottom, lessThanOrEqualTo(667 - 260 + 0.5),
          reason: 'the whole note is above the keyboard');
      // No glyph of its own here, so the note draws one.
      expect(
          find.descendant(
              of: find.byType(ReplyNote),
              matching: find.byIcon(Icons.error_outline_rounded)),
          findsOneWidget);
    });

    testWidgets('a reply with its own ❌ gets no second glyph; the note is a '
        'live region', (tester) async {
      final handle = tester.ensureSemantics();
      final executor = FakeExecutor()
        ..nextDescribe = const DescribeOutcome(
            error: '❌ No Gemini API key yet — add one in Settings to use '
                'text logging.');
      await pumpApp(
          tester,
          AddTextScreen(
              executor: executor, dao: FakeDao(), settings: FakeSettings()));
      await tester.enterText(find.byKey(const Key('addTextField')), 'eggs');
      await tester.tap(find.byKey(const Key('addTextSend')));
      await tester.pumpAndSettle();

      expect(
          find.descendant(
              of: find.byType(ReplyNote),
              matching: find.byIcon(Icons.error_outline_rounded)),
          findsNothing);
      final node = tester.getSemantics(find.byKey(const Key('addTextError')));
      expect(node.label, startsWith('❌ No Gemini API key'));
      expect(node, isSemantics(isLiveRegion: true));
      handle.dispose();
    });

    for (final (name, screen, field, label) in [
      (
        'Describe',
        AddTextScreen(
            executor: FakeExecutor(), dao: FakeDao(), settings: FakeSettings()),
        'addTextField',
        _l(_zh).describeLabel,
      ),
      (
        'Fix',
        FixMealScreen(executor: FakeExecutor(), settings: FakeSettings()),
        'fixMealField',
        _l(_zh).fixLabel,
      ),
    ]) {
      testWidgets('$name at AX5 (zh): the floating label is not clipped '
          'under the app bar', (tester) async {
        await pumpApp(tester, screen,
            size: const Size(375, 667), scale: 53 / 17, locale: _zh);
        await tester.enterText(find.byKey(Key(field)), '两个肉包');
        await tester.pumpAndSettle();
        final top = tester.getRect(find.text(label)).top;
        final bar = tester.getRect(find.byType(AppBar));
        expect(top, greaterThanOrEqualTo(bar.bottom - 0.5));
      });
    }

    test('leadsWithGlyph knows status pictographs from text', () {
      for (final s in ['❌ x', '⏸️ x', '🚫 x', '⚠️ x', '  ✅ ok']) {
        expect(ReplyNote.leadsWithGlyph(s), isTrue, reason: s);
      }
      for (final s in ['No key', '还没有设置', '「今天」', '', '42 kcal']) {
        expect(ReplyNote.leadsWithGlyph(s), isFalse, reason: s);
      }
    });
  });

  group('Fix a meal', () {
    Future<FakeExecutor> pumpFix(WidgetTester tester, List<NlReply> replies,
        {Locale locale = _en}) async {
      final executor = FakeExecutor()..nextReplies = replies;
      await pumpApp(
          tester, FixMealScreen(executor: executor, settings: FakeSettings()),
          locale: locale);
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'the noodles were rice');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      return executor;
    }

    testWidgets('an error that changed nothing stays on the page, not a '
        '4-second snackbar (U11)', (tester) async {
      const error =
          '❌ The provider rejected the API key. Check the key in Settings.';
      final executor = await pumpFix(tester, const [NlReply(error)]);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text(error), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(const Key('fixMealNote')), findsOneWidget);

      // A request that changes something clears it.
      executor.nextReplies = const [NlReply('Corrected meal #1', applied: true)];
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      expect(find.text(error), findsNothing);
      expect(find.byKey(const Key('fixMealNote')), findsNothing);
    });

    testWidgets('zh: a refusal stays inline; the applied part still says '
        'so in a snackbar', (tester) async {
      await pumpFix(
          tester,
          const [
            NlReply('已修改第 1 餐', applied: true),
            NlReply('没找到第 9 餐。'),
          ],
          locale: _zh);
      expect(find.widgetWithText(SnackBar, '已修改第 1 餐'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(ReplyNote), matching: find.text('没找到第 9 餐。')),
          findsOneWidget);
      // Its own glyph: none in the text, so the note draws one.
      expect(
          find.descendant(
              of: find.byType(ReplyNote),
              matching: find.byIcon(Icons.error_outline_rounded)),
          findsOneWidget);
    });

    testWidgets('the instructions sit under the field, as Describe\'s help '
        'does', (tester) async {
      await pumpApp(tester,
          FixMealScreen(executor: FakeExecutor(), settings: FakeSettings()));
      final l = _l(_en);
      final field = tester.getRect(find.byKey(const Key('fixMealField')));
      final intro = tester.getRect(find.text(l.fixIntro));
      final button = tester.getRect(find.byKey(const Key('fixMealSend')));
      expect(intro.top, greaterThanOrEqualTo(field.bottom));
      expect(button.top, greaterThan(intro.bottom));
      expect(tester.widget<Text>(find.text(l.fixIntro)).style?.color,
          AppColors.light.secondaryLabel);
    });

    for (final brightness in Brightness.values) {
      testWidgets('the chat delete confirm is iOS\'s red action, the warning '
          'a danger footnote (${brightness.name})', (tester) async {
        final executor = FakeExecutor()
          ..nextReplies = const [
            NlReply('Deleting 1 meal.',
                needsDeleteConfirmation: true,
                pendingDeleteIds: [7],
                pendingDeleteLabels: ['Pizza (12:10 PM, ~800 kcal)']),
          ];
        await pumpApp(tester,
            FixMealScreen(executor: executor, settings: FakeSettings()),
            brightness: brightness);
        await tester.enterText(
            find.byKey(const Key('fixMealField')), 'delete the pizza');
        await tester.tap(find.byKey(const Key('fixMealSend')));
        await tester.pumpAndSettle();

        final colors = brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light;
        final confirm =
            tester.widget<FilledButton>(find.byKey(const Key('nlDeleteConfirm')));
        expect(confirm.style?.foregroundColor?.resolve({}), colors.danger);
        expect(confirm.style?.backgroundColor?.resolve({}), colors.fill);
        final warning = tester.widget<Text>(find.text(_l(_en).nlCannotUndo));
        expect(warning.style?.color, colors.danger);
        expect(warning.style?.fontSize, 13);
        expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
            isTrue);
      });
    }
  });

  group('the meal editor', () {
    for (final brightness in Brightness.values) {
      testWidgets('the delete confirm resolves to the danger colour '
          '(${brightness.name})', (tester) async {
        final dao = FakeDao()..seed(_meal());
        await pumpApp(
            tester, MealEditorScreen(dao: dao, meal: dao.meals.first),
            brightness: brightness);
        await tester.tap(find.byKey(const Key('deleteMealButton')));
        await tester.pumpAndSettle();

        final colors = brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light;
        final confirm = tester
            .widget<FilledButton>(find.byKey(const Key('confirmDeleteMeal')));
        expect(confirm.style?.foregroundColor?.resolve({}), colors.danger);
        expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
            isTrue);

        // Cancel deletes nothing (the style change is only a style).
        await tester.tap(find.text(_l(_en).cancel));
        await tester.pumpAndSettle();
        expect(dao.meals, hasLength(1));
      });
    }

    testWidgets('the date and time pickers clamp their text at 1.6x (AX5)',
        (tester) async {
      await pumpApp(
          tester,
          MealEditorScreen(
              dao: FakeDao(), now: () => DateTime(2026, 7, 24, 19, 5)),
          size: const Size(375, 667),
          scale: 53 / 17,
          locale: _zh);

      await tester.ensureVisible(find.byKey(const Key('editorDateButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editorDateButton')));
      await tester.pumpAndSettle();
      final date = tester.element(find.byType(DatePickerDialog));
      expect(MediaQuery.textScalerOf(date).scale(10),
          closeTo(10 * kPickerMaxTextScale, 0.01));
      await tester.tap(find.text(MaterialLocalizations.of(date).cancelButtonLabel));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('editorTimeButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editorTimeButton')));
      await tester.pumpAndSettle();
      final time = tester.element(find.byType(TimePickerDialog));
      expect(MediaQuery.textScalerOf(time).scale(10),
          closeTo(10 * kPickerMaxTextScale, 0.01));
    });
  });
}
