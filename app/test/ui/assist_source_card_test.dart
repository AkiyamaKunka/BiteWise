/// The restaurant assist on screen (design R7b): the meal card's chip and
/// dot, the editor's source card in its applied, suggested, stale and
/// context-only states (en and zh), what can never be a link, and the
/// 'Which restaurant?' search over BiteWise's own chain table only.
library;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/core/shared_generated.dart' show sharedUsChains;
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/assist_view.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:calorie_tracker/ui/widgets/assist_source_card.dart';
import 'package:calorie_tracker/ui/widgets/chain_picker_sheet.dart';
import 'package:calorie_tracker/ui/widgets/meal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/assist_fixtures.dart';
import 'fakes.dart';

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
  locale: Locale(lang),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

final AppLocalizations _en = AppLocalizationsEn();
final AppLocalizations _zh = AppLocalizationsZh();

/// [analysis] with its block's source and notes replaced.
Map<String, dynamic> _withSource(
  Map<String, dynamic> analysis, {
  Object? url,
  String? notes,
}) {
  final block = Map<String, dynamic>.from(analysis['assist'] as Map);
  block['source'] = {...(block['source'] as Map), 'url': url};
  if (notes != null) block['notes'] = notes;
  return Map<String, dynamic>.from(analysis)..['assist'] = block;
}

void main() {
  group('AssistView', () {
    test('applied, suggested, stale and context-only, read from the block', () {
      expect(AssistView.of(bigMacAnalysis()).kind, AssistViewKind.none);
      final applied = AssistView.of(appliedBigMac());
      expect(applied.kind, AssistViewKind.applied);
      expect(applied.chainKey, 'mcdonalds');
      expect(applied.brandName, "McDonald's");
      expect(applied.items.single.menuItem, 'Big Mac');
      expect(applied.items.single.calories, 590);
      expect(
        applied.sourceUrl,
        'https://mcdonalds.com/us/en-us/product/big-mac.html',
      );
      expect(applied.sourceHost, 'mcdonalds.com');
      expect(applied.sourceOfficial, isTrue);
      expect(applied.grounded, isTrue);
      expect(applied.provider, 'anthropic');
      expect(applied.decidedOn, '2026-10-24');

      final suggested = AssistView.of(suggestedBigMac());
      expect(suggested.kind, AssistViewKind.suggested);
      expect(suggested.grounded, isFalse);
      expect(suggested.provider, 'claude_plan');

      expect(
        AssistView.of(editedFirstItem(appliedBigMac(), 600)).kind,
        AssistViewKind.appliedStale,
      );
      expect(
        AssistView.of(editedFirstItem(suggestedBigMac(), 600)).kind,
        AssistViewKind.suggestedStale,
      );
      final context = AssistView.of(contextOnlyBigMac());
      expect(context.kind, AssistViewKind.contextOnly);
      expect(context.brandName, isEmpty);
      expect(context.chainKey, isNull);
      expect(context.items, isEmpty);
    });

    test('the chip, en and zh, only while the stamps hold', () {
      expect(
        AssistView.of(appliedBigMac()).chipText(_en),
        "McDonald's numbers used for 1 item(s)",
      );
      expect(
        AssistView.of(appliedBigMac()).chipText(_zh),
        '已采用 麦当劳 公布的数值（1 项）',
      );
      expect(
        AssistView.of(suggestedBigMac()).chipText(_en),
        "McDonald's publishes 590 kcal — tap to review",
      );
      expect(
        AssistView.of(suggestedBigMac()).chipText(_zh),
        '麦当劳 公布为 590 千卡 — 点按查看',
      );
      for (final a in [
        bigMacAnalysis(),
        editedFirstItem(appliedBigMac(), 600),
        editedFirstItem(suggestedBigMac(), 600),
        contextOnlyBigMac(),
        revertAssist(appliedBigMac())!,
      ]) {
        expect(AssistView.of(a).chipText(_en), isNull);
      }
    });

    // Review 2026-10-25 (PROBE6): a suggestion never said why it was not
    // applied, and listed none of the sizes it stores.
    test('why a suggestion was not used, its sizes, and the chip of a '
        'shared plate', () {
      final shared = AssistView.of(suggestedSharedBigMac());
      expect(shared.reason, AssistReason.portionNotWhole);
      expect(shared.acceptNeedsConfirm, isTrue);
      expect(
        shared.whyText(_en),
        'The photo looked shared or partly eaten — the published number is '
        'one whole serving.',
      );
      expect(shared.whyText(_zh), '照片看起来是分享的或没吃完 — 公布的数值是一整份。');
      expect(shared.chipText(_en), "McDonald's: 590 kcal for a whole serving");
      expect(shared.chipText(_zh), '麦当劳：整份 590 千卡');

      final fries = AssistView.of(suggestedFriesSizes());
      expect(fries.reason, AssistReason.sizeAmbiguous);
      expect(fries.acceptNeedsConfirm, isTrue);
      expect(fries.items.single.sizes.map((z) => z.calories), [230, 320, 480]);
      expect(
        assistSizesText(_en, fries.items.single),
        'Published sizes: Small 230 kcal · Medium 320 kcal · Large 480 kcal',
      );
      expect(
        assistSizesText(_zh, fries.items.single),
        '公布的份量：Small 230 千卡 · Medium 320 千卡 · Large 480 千卡',
      );

      // Claude Plan's plain suggestion: nothing to add (the grounding line
      // says it), no confirm.
      final plain = AssistView.of(suggestedBigMac());
      expect(plain.reason, AssistReason.notGrounded);
      expect(plain.whyText(_en), isNull);
      expect(plain.acceptNeedsConfirm, isFalse);
      expect(assistSizesText(_en, plain.items.single), isNull);

      // An applied or stale block says nothing of the kind.
      expect(AssistView.of(appliedBigMac()).whyText(_en), isNull);
      final stale = AssistView.of(
        editedFirstItem(suggestedSharedBigMac(), 600),
      );
      expect(stale.whyText(_en), isNull);
      expect(stale.acceptNeedsConfirm, isFalse);

      // Every reason line, en and zh.
      for (final (reason, en, zh) in [
        (AssistReason.combo, 'combo', '套餐'),
        (AssistReason.closestItem, 'closest menu item', '最接近'),
        (AssistReason.unitMismatch, 'published serving', '公布的份量'),
        (AssistReason.declinedBefore, 'turned these numbers down', '拒绝过'),
      ]) {
        final a = suggestedBigMac();
        (a['assist'] as Map)['reason'] = reason;
        final v = AssistView.of(a);
        expect(v.whyText(_en), contains(en), reason: reason);
        expect(v.whyText(_zh), contains(zh), reason: reason);
      }
      // A reason that is not a code is no reason.
      final hostile = suggestedBigMac();
      (hostile['assist'] as Map)['reason'] = '<b>portion_not_whole</b>';
      expect(AssistView.of(hostile).reason, isEmpty);
    });

    test('the place step named the chain: only then can Correct teach the '
        'spot', () {
      expect(AssistView.of(appliedBigMac()).namedByPlace, isFalse);
      expect(AssistView.of(appliedBigMacAtSpot()).namedByPlace, isTrue);
      expect(AssistView.of(suggestedBigMacAtSpot()).namedByPlace, isTrue);
    });

    test('a hostile source is never a link; notes stay plain text', () {
      for (final url in [
        'javascript:alert(1)',
        'http://www.mcdonalds.com/us/en-us/product/big-mac.html',
        'https://www.mcdönalds.com/menu',
        'https://user:pw@mcdonalds.com/menu',
        'https://mcdonalds.com:8443/menu',
        'https://192.168.1.1/menu',
        42,
        null,
      ]) {
        final v = AssistView.of(_withSource(appliedBigMac(), url: url));
        expect(v.sourceUrl, isNull, reason: '$url');
        expect(v.sourceHost, isNull, reason: '$url');
      }
      final notes = AssistView.of(
        _withSource(
          appliedBigMac(),
          url: assistMcdUrl,
          notes:
              'See <a href="https://evil.example">here</a>\u202e '
              '${'x' * 400}',
        ),
      ).notes;
      expect(notes, isNot(contains('<')));
      expect(notes.contains('\u202e'), isFalse);
      expect(notes.runes.length, lessThanOrEqualTo(kAssistNotesMax));
    });

    test('an imported block is re-checked: junk numbers and names', () {
      final a = appliedBigMac();
      final block = Map<String, dynamic>.from(a['assist'] as Map);
      block['chain_key'] = 'joes_diner';
      block['brand_name'] = "<b>Joe's</b>\u0007";
      block['provider'] = 'Evil Corp';
      block['decided_on'] = 'yesterday';
      block['matches'] = [
        {
          ...(block['matches'] as List).first as Map,
          'menu_item': 'Big\u0000Mac <script>',
          'published': {'calories': 590.5, 'protein_g': -3, 'fat_g': 'x'},
        },
      ];
      final v = AssistView.of(Map<String, dynamic>.from(a)..['assist'] = block);
      expect(v.chainKey, isNull);
      expect(v.brandName, isNot(contains('<')));
      expect(v.provider, isEmpty);
      expect(v.decidedOn, isEmpty);
      expect(v.items.single.menuItem, isNot(contains('<')));
      expect(v.items.single.calories, isNull);
      expect(v.items.single.proteinG, isNull);
      expect(v.items.single.fatG, isNull);
      expect(AssistView.of({'assist': 'applied'}).kind, AssistViewKind.none);
      expect(AssistView.of('junk').kind, AssistViewKind.none);
    });

    test('provider labels as Settings names them', () {
      expect(assistProviderLabel(_en, 'claude_plan'), 'Claude Plan');
      expect(assistProviderLabel(_zh, 'claude_plan'), 'Claude 订阅');
      expect(assistProviderLabel(_en, 'anthropic'), 'Claude');
      expect(assistProviderLabel(_en, 'openrouter'), 'OpenRouter');
      expect(assistProviderLabel(_en, 'gemini'), '');
    });
  });

  group('AssistSourceCard', () {
    testWidgets('applied (en): items, numbers, source, provider, grounding '
        'and the four answers', (tester) async {
      final opened = <String>[];
      var used = 0;
      await tester.pumpWidget(
        _app(
          AssistSourceCard(
            view: AssistView.of(appliedBigMac(notes: 'Regular size.')),
            onUseEstimate: () => used++,
            onWrongRestaurant: () {},
            onNotRestaurant: () {},
            onCorrect: () {},
            onOpenSource: opened.add,
          ),
        ),
      );
      expect(find.text("McDonald's"), findsOneWidget);
      expect(find.text('Published numbers in use'), findsOneWidget);
      expect(find.text('Big Mac'), findsOneWidget);
      expect(find.text('Regular · 1 sandwich'), findsOneWidget);
      expect(find.text('590 kcal · P 25 g · C 46 g · F 34 g'), findsOneWidget);
      expect(find.text('Source: mcdonalds.com'), findsOneWidget);
      expect(find.byKey(const Key('assistSourceNotOfficial')), findsNothing);
      expect(find.text('via Claude · 2026-10-24'), findsOneWidget);
      expect(find.text('Number found on the source page'), findsOneWidget);
      expect(find.text('Regular size.'), findsOneWidget);
      for (final k in [
        'assistUseEstimate',
        'assistWrongRestaurant',
        'assistNotRestaurant',
        'assistCorrect',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(find.byKey(const Key('assistUsePublished')), findsNothing);
      await tester.tap(find.byKey(const Key('assistSourceLink')));
      expect(opened, ['https://mcdonalds.com/us/en-us/product/big-mac.html']);
      await tester.tap(find.byKey(const Key('assistUseEstimate')));
      expect(used, 1);
    });

    testWidgets('applied (zh)', (tester) async {
      await tester.pumpWidget(
        _app(
          AssistSourceCard(
            view: AssistView.of(appliedBigMac()),
            onUseEstimate: () {},
            onWrongRestaurant: () {},
            onNotRestaurant: () {},
            onCorrect: () {},
          ),
          lang: 'zh',
        ),
      );
      expect(find.text('麦当劳'), findsOneWidget);
      expect(find.text('已采用公布的数值'), findsOneWidget);
      expect(find.text('590 千卡 · 蛋 25 g · 碳 46 g · 脂 34 g'), findsOneWidget);
      expect(find.text('来源：mcdonalds.com'), findsOneWidget);
      expect(find.text('通过 Claude · 2026-10-24'), findsOneWidget);
      expect(find.text('数值见于来源页面'), findsOneWidget);
      expect(find.text('改用 AI 估算'), findsOneWidget);
      expect(find.text('不是这家'), findsOneWidget);
      expect(find.text('不是餐厅的'), findsOneWidget);
      expect(find.text('没错'), findsOneWidget);
    });

    testWidgets('suggested (en and zh): Use published numbers, not the AI '
        'estimate; not confirmed on the source page', (tester) async {
      for (final (lang, use, grounding, via) in [
        (
          'en',
          'Use published numbers',
          'Not confirmed on the source page',
          'via Claude Plan · 2026-10-24',
        ),
        ('zh', '采用公布数值', '未在来源页面确认', '通过 Claude 订阅 · 2026-10-24'),
      ]) {
        await tester.pumpWidget(
          _app(
            AssistSourceCard(
              view: AssistView.of(suggestedBigMac()),
              onUseEstimate: () {},
              onAccept: () {},
              onWrongRestaurant: () {},
              onNotRestaurant: () {},
              onCorrect: () {},
            ),
            lang: lang,
          ),
        );
        expect(find.text(use), findsOneWidget, reason: lang);
        expect(find.text(grounding), findsOneWidget, reason: lang);
        expect(find.text(via), findsOneWidget, reason: lang);
        expect(find.byKey(const Key('assistUseEstimate')), findsNothing);
        expect(
          find.byKey(const Key('assistCorrect')),
          findsNothing,
          reason: 'accepting is the confirmation',
        );
      }
    });

    testWidgets('stale stamps: a note replaces Use AI estimate (en, zh)', (
      tester,
    ) async {
      for (final (lang, note) in [
        (
          'en',
          'This meal was changed after the restaurant numbers were '
              'used.',
        ),
        ('zh', '使用餐厅数值后，这餐又被修改过。'),
      ]) {
        await tester.pumpWidget(
          _app(
            AssistSourceCard(
              view: AssistView.of(editedFirstItem(appliedBigMac(), 600)),
              onUseEstimate: () {},
              onWrongRestaurant: () {},
              onNotRestaurant: () {},
            ),
            lang: lang,
          ),
        );
        expect(find.text(note), findsOneWidget, reason: lang);
        expect(find.byKey(const Key('assistUseEstimate')), findsNothing);
      }
      // A stale suggestion can only be looked up again.
      await tester.pumpWidget(
        _app(
          AssistSourceCard(
            view: AssistView.of(editedFirstItem(suggestedBigMac(), 600)),
            onAccept: () {},
            onWrongRestaurant: () {},
            onLookUp: () {},
          ),
        ),
      );
      expect(
        find.text('This meal was changed after this suggestion.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('assistUsePublished')), findsNothing);
      expect(find.byKey(const Key('assistWrongRestaurant')), findsNothing);
      expect(find.byKey(const Key('assistLookUp')), findsOneWidget);
    });

    testWidgets('a suggestion says why it was not used and lists the '
        'published sizes (en, zh)', (tester) async {
      for (final (lang, why, sizes) in [
        (
          'en',
          "The photo doesn't show which size. Check the published sizes "
              'before using these numbers.',
          'Published sizes: Small 230 kcal · Medium 320 kcal · Large 480 kcal',
        ),
        (
          'zh',
          '照片看不出是哪种份量。使用这些数值前，请先核对公布的各个份量。',
          '公布的份量：Small 230 千卡 · Medium 320 千卡 · Large 480 千卡',
        ),
      ]) {
        await tester.pumpWidget(
          _app(
            AssistSourceCard(
              view: AssistView.of(suggestedFriesSizes()),
              onAccept: () {},
            ),
            lang: lang,
          ),
        );
        expect(find.byKey(const Key('assistWhy')), findsOneWidget);
        expect(find.text(why), findsOneWidget, reason: lang);
        expect(find.text(sizes), findsOneWidget, reason: lang);
      }
      // Applied numbers list no sizes and no reason.
      await tester.pumpWidget(
        _app(AssistSourceCard(view: AssistView.of(appliedBigMac()))),
      );
      expect(find.byKey(const Key('assistWhy')), findsNothing);
      expect(find.byKey(const Key('assistSizes')), findsNothing);
    });

    testWidgets('context only names no restaurant (en, zh)', (tester) async {
      for (final (lang, text) in [
        ('en', 'No published nutrition found — AI estimate kept'),
        ('zh', '未找到公布的营养信息 — 保留 AI 估算'),
      ]) {
        await tester.pumpWidget(
          _app(
            AssistSourceCard(
              view: AssistView.of(contextOnlyBigMac()),
              onLookUp: () {},
            ),
            lang: lang,
          ),
        );
        expect(find.text(text), findsOneWidget, reason: lang);
        expect(find.textContaining('McDonald'), findsNothing);
        expect(find.textContaining('麦当劳'), findsNothing);
        expect(find.byKey(const Key('assistSourceLink')), findsNothing);
        expect(find.byKey(const Key('assistLookUp')), findsOneWidget);
      }
    });

    testWidgets('a hostile source shows no link; URL-bearing notes are '
        'plain text', (tester) async {
      final opened = <String>[];
      for (final url in [
        'javascript:alert(1)',
        'http://www.mcdonalds.com/us/en-us/product/big-mac.html',
        'https://www.mcdönalds.com/menu',
      ]) {
        await tester.pumpWidget(
          _app(
            AssistSourceCard(
              view: AssistView.of(
                _withSource(
                  appliedBigMac(),
                  url: url,
                  notes: 'More at https://evil.example/nutrition',
                ),
              ),
              onOpenSource: opened.add,
            ),
          ),
        );
        expect(
          find.byKey(const Key('assistSourceLink')),
          findsNothing,
          reason: url,
        );
        expect(find.textContaining('Source:'), findsNothing, reason: url);
        final notes = find.byKey(const Key('assistNotes'));
        expect(
          tester.widget<Text>(notes).data,
          'More at https://evil.example/nutrition',
        );
        expect(
          find.ancestor(of: notes, matching: find.byType(InkWell)),
          findsNothing,
        );
        await tester.tap(notes);
      }
      expect(opened, isEmpty);
    });

    testWidgets('busy or unsaved typing: every answer waits', (tester) async {
      await tester.pumpWidget(
        _app(
          AssistSourceCard(
            view: AssistView.of(appliedBigMac()),
            editFirst: true,
            onUseEstimate: () {},
            onWrongRestaurant: () {},
            onNotRestaurant: () {},
            onCorrect: () {},
          ),
        ),
      );
      expect(
        find.text('Save your changes first to use these buttons.'),
        findsOneWidget,
      );
      for (final k in ['assistUseEstimate', 'assistWrongRestaurant']) {
        final b = tester.widget<ButtonStyleButton>(find.byKey(Key(k)));
        expect(b.onPressed, isNull, reason: k);
      }
    });
  });

  group('MealCard', () {
    testWidgets('the chip while the stamps hold, and the unseen dot', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(MealCard(meal: assistMeal(appliedBigMac()), assistUnseen: true)),
      );
      expect(
        find.text("McDonald's numbers used for 1 item(s)"),
        findsOneWidget,
      );
      expect(find.byKey(const Key('assistUnseenDot')), findsOneWidget);
      expect(
        find.bySemanticsLabel('Updated from restaurant numbers'),
        findsOneWidget,
      );

      await tester.pumpWidget(
        _app(MealCard(meal: assistMeal(suggestedBigMac()))),
      );
      expect(
        find.text("McDonald's publishes 590 kcal — tap to review"),
        findsOneWidget,
      );
      expect(find.byKey(const Key('assistUnseenDot')), findsNothing);

      await tester.pumpWidget(
        _app(MealCard(meal: assistMeal(suggestedBigMac())), lang: 'zh'),
      );
      expect(find.text('麦当劳 公布为 590 千卡 — 点按查看'), findsOneWidget);

      for (final a in [
        editedFirstItem(appliedBigMac(), 600),
        contextOnlyBigMac(),
        bigMacAnalysis(),
      ]) {
        await tester.pumpWidget(
          _app(MealCard(meal: assistMeal(a), assistUnseen: true)),
        );
        expect(find.byKey(const Key('assistChip')), findsNothing);
        expect(find.byKey(const Key('assistUnseenDot')), findsNothing);
      }
    });

    testWidgets('Today: the dot goes once the meal is opened', (tester) async {
      final dao = FakeDao();
      final now = DateTime.now();
      final today =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final id = dao.put(
        Meal(
          id: 0,
          date: today,
          time: '12:30 PM',
          timestamp: '${today}T12:30:00.000',
          source: MealSource.appWatch,
          analysis: appliedBigMac(),
        ),
      );
      final assist = FakeAssist(dao)..unseenIds = {id};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TodayScreen(
              dao: dao,
              executor: FakeExecutor(),
              restaurantAssist: assist.controls(),
              settings: FakeSettings(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistUnseenDot')), findsOneWidget);
      await tester.tap(find.byKey(const Key('assistChip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editorAssistCard')), findsOneWidget);
      expect(assist.seen, [id]);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assistUnseenDot')), findsNothing);
    });
  });

  group('chain picker', () {
    test('only names from the chain table; a search filters them', () {
      final keys = {for (final c in sharedUsChains) c.key};
      final all = chainPickerMatches('');
      expect(all, hasLength(sharedUsChains.length));
      expect(all.every((c) => keys.contains(c.key)), isTrue);
      expect(
        chainPickerMatches('mcd').map((c) => c.key),
        contains('mcdonalds'),
      );
      expect(chainPickerMatches("mcdonald's").first.key, 'mcdonalds');
      expect(chainPickerMatches('麦当', zh: true).map((c) => c.key), [
        'mcdonalds',
      ]);
      expect(
        chainPickerMatches('mcd', exclude: 'mcdonalds').map((c) => c.key),
        isNot(contains('mcdonalds')),
      );
      expect(chainPickerMatches('zzzzqqq'), isEmpty);
    });

    testWidgets('the sheet lists table rows only and returns the key', (
      tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => picked = await showChainPickerSheet(
                  context,
                  exclude: 'mcdonalds',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Which restaurant?'), findsOneWidget);
      final keys = {for (final c in sharedUsChains) c.key};
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
        final k = (tile.key as ValueKey<String>).value;
        expect(k.startsWith('chainPick-'), isTrue);
        expect(keys.contains(k.substring('chainPick-'.length)), isTrue);
      }
      await tester.enterText(
        find.byKey(const Key('chainPickerSearch')),
        'mcdonald',
      );
      await tester.pump();
      expect(
        find.byKey(const Key('chainPick-mcdonalds')),
        findsNothing,
        reason: 'the chain just called wrong is not offered',
      );
      await tester.enterText(
        find.byKey(const Key('chainPickerSearch')),
        'burger king',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chainPick-burger_king')));
      await tester.pumpAndSettle();
      expect(picked, 'burger_king');

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('chainPickerSearch')),
        'zzzzqqq',
      );
      await tester.pump();
      expect(find.text('No chain matches.'), findsOneWidget);
    });
  });
}
