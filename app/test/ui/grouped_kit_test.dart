/// The run-7 shared components: grouped kit, states and pickers.
///
/// - RowBadge maps scheme roles to the badge tokens when it PAINTS (dark
///   badges drew a white glyph at 1.70:1), with its `color` field — what
///   tests and call sites read — unchanged (A9).
/// - Tappable cards and custom rows are buttons to VoiceOver (A11).
/// - Sections can be footer-only; separators are one physical pixel.
/// - The large-title bar's collapsed title clears the status bar.
/// - Grouped sheets lift their cells off a dark sheet.
/// - Empty states scroll at the largest text size; pickers clamp text (A6).
library;

import 'dart:ui' show Tristate;

import 'package:calorie_tracker/ui/theme/app_theme.dart';
import 'package:calorie_tracker/ui/widgets/grouped.dart';
import 'package:calorie_tracker/ui/widgets/pickers.dart';
import 'package:calorie_tracker/ui/widgets/small_spinner.dart';
import 'package:calorie_tracker/ui/widgets/states.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';

Widget _page(List<Widget> children) => Scaffold(
      body: ListView(children: children),
    );

void main() {
  group('RowBadge', () {
    for (final (b, brand, danger) in const [
      (Brightness.light, Color(0xFFA64B2A), Color(0xFFD70015)),
      (Brightness.dark, Color(0xFFB9562F), Color(0xFFFF453A)),
    ]) {
      testWidgets('$b: scheme roles paint the badge tokens, the field is '
          'unchanged', (tester) async {
        late ColorScheme scheme;
        await pumpApp(
            tester,
            Scaffold(
              body: Builder(builder: (context) {
                scheme = Theme.of(context).colorScheme;
                return Column(children: [
                  RowBadge(
                      key: const Key('brand'),
                      icon: Icons.photo,
                      color: scheme.primary),
                  RowBadge(
                      key: const Key('danger'),
                      icon: Icons.error,
                      color: scheme.error),
                  RowBadge(
                      key: const Key('neutral'),
                      icon: Icons.edit,
                      color: scheme.secondary),
                  RowBadge(
                      key: const Key('info'),
                      icon: Icons.build,
                      color: scheme.tertiary),
                  const RowBadge(
                      key: Key('custom'),
                      icon: Icons.star,
                      color: Color(0xFF123456)),
                ]);
              }),
            ),
            brightness: b);
        Color painted(String key) => (tester
                .widget<Container>(find.descendant(
                    of: find.byKey(Key(key)), matching: find.byType(Container)))
                .decoration! as BoxDecoration)
            .color!;
        final c = AppColors.forBrightness(b);
        expect(painted('brand'), brand);
        expect(painted('danger'), danger);
        expect(painted('neutral'), c.badgeNeutral);
        expect(painted('info'), c.badgeInfo);
        expect(painted('custom'), const Color(0xFF123456),
            reason: 'any other colour is used as passed');
        expect(tester.widget<RowBadge>(find.byKey(const Key('brand'))).color,
            scheme.primary,
            reason: 'call sites and tests read the role they passed');
        final glyph = tester.widget<Icon>(find.descendant(
            of: find.byKey(const Key('brand')), matching: find.byType(Icon)));
        expect(glyph.color, const Color(0xFFFFFFFF));
      });
    }
  });

  group('GroupedCard', () {
    testWidgets('with onTap: one button node, label not doubled',
        (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpApp(
          tester,
          _page([
            GroupedCard(
              key: const Key('card'),
              padding: const EdgeInsets.all(16),
              onTap: () => taps++,
              child: const Text('Chicken rice bowl'),
            ),
          ]));
      final node = tester.getSemantics(find.text('Chicken rice bowl'));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.label, 'Chicken rice bowl');
      await tester.tap(find.byKey(const Key('card')));
      expect(taps, 1);
      // The padding param wraps the child inside the cell.
      final cell = tester.getRect(find.byKey(const Key('card')));
      final text = tester.getRect(find.text('Chicken rice bowl'));
      expect(text.left - cell.left, kGroupInset + 16);
      handle.dispose();
    });

    testWidgets('without onTap: not a button', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(
          tester,
          _page([
            const GroupedCard(
                key: Key('card'), child: Text('Totals')),
          ]));
      expect(
          tester
              .getSemantics(find.text('Totals'))
              .flagsCollection
              .isButton,
          isFalse);
      handle.dispose();
    });
  });

  group('GroupedSection', () {
    testWidgets('a footer-only section renders no cell', (tester) async {
      await pumpApp(
          tester,
          _page([
            const GroupedSection(
                key: Key('s'),
                footer: 'Keys stay on this phone.',
                children: []),
          ]));
      expect(find.text('Keys stay on this phone.'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('s')), matching: find.byType(Material)),
          findsNothing);
    });

    testWidgets('one-physical-pixel separators in the separator colour, '
        'header and footer in secondaryLabel', (tester) async {
      await pumpApp(
          tester,
          _page([
            const GroupedSection(
              header: 'Photos',
              footer: 'New food photos are logged automatically.',
              children: [
                GroupedRow(title: 'Watch Camera Roll'),
                GroupedRow(title: 'Catch-up window'),
              ],
            ),
          ]),
          devicePixelRatio: 3);
      final divider = tester.widget<Divider>(find.byType(Divider));
      expect(divider.thickness, closeTo(1 / 3, 1e-9));
      expect(divider.color, AppColors.light.separator);
      final header = tester.widget<Text>(find.text('Photos'));
      expect(header.style?.color, AppColors.light.secondaryLabel);
      final footer = tester.widget<Text>(
          find.text('New food photos are logged automatically.'));
      expect(footer.style?.color, AppColors.light.secondaryLabel);
    });
  });

  group('GroupedRow', () {
    testWidgets('44-pt text row; rounded chevron in tertiaryLabel; '
        'subtitle under the title', (tester) async {
      await pumpApp(
          tester,
          _page([
            GroupedSection(separatorInset: 16, children: [
              GroupedRow(
                  key: const Key('row'),
                  title: 'Language',
                  value: 'English',
                  onTap: () {}),
              GroupedRow(
                  key: const Key('sub'),
                  title: 'Thursday, Oct 29',
                  subtitle: const Text('2 meals'),
                  onTap: () {}),
            ]),
          ]));
      expect(tester.getSize(find.byKey(const Key('row'))).height, 44);
      final chevron = tester.widget<Icon>(find
          .descendant(
              of: find.byKey(const Key('row')), matching: find.byType(Icon))
          .last);
      expect(chevron.icon, Icons.chevron_right_rounded);
      expect(chevron.color, AppColors.light.tertiaryLabel);
      final title = tester.getRect(find.text('Thursday, Oct 29'));
      final sub = tester.getRect(find.text('2 meals'));
      expect(sub.top, closeTo(title.bottom + 2, 0.01));
      expect(tester.widget<RichText>(find.descendant(
              of: find.text('2 meals'), matching: find.byType(RichText)))
          .text
          .style
          ?.color, AppColors.light.secondaryLabel);
    });

    testWidgets('.custom: a selected button with the accent checkmark',
        (tester) async {
      final handle = tester.ensureSemantics();
      var picked = '';
      await pumpApp(
          tester,
          _page([
            GroupedSection(separatorInset: 16, children: [
              GroupedRow.custom(
                key: const Key('zh'),
                selected: true,
                onTap: () => picked = 'zh',
                child: const Text('中文'),
              ),
              GroupedRow.custom(
                key: const Key('en'),
                onTap: () => picked = 'en',
                semanticsLabel: 'English language',
                child: const Text('English'),
              ),
            ]),
          ]));
      final zh = tester.getSemantics(find.byKey(const Key('zh')));
      expect(zh.flagsCollection.isButton, isTrue);
      expect(zh.flagsCollection.isSelected, Tristate.isTrue);
      expect(
          find.descendant(
              of: find.byKey(const Key('zh')),
              matching: find.byIcon(Icons.check_rounded)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('zh')),
              matching: find.byIcon(Icons.chevron_right_rounded)),
          findsNothing,
          reason: 'a choice shows its checkmark, not a disclosure chevron');
      expect(tester.getSemantics(find.byKey(const Key('en'))).label,
          'English language');
      await tester.tap(find.byKey(const Key('en')));
      expect(picked, 'en');
      handle.dispose();
    });
  });

  testWidgets('appLargeTitleBar: the collapsed title clears a 59-pt status '
      'bar, page colour at rest, chrome when scrolled under', (tester) async {
    await pumpApp(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: CustomScrollView(
              slivers: [
                appLargeTitleBar(context, title: 'Settings'),
                SliverList.list(children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 44, child: Text('row $i')),
                ]),
              ],
            ),
          ),
        ),
        padding: const EdgeInsets.only(top: 59));
    final bar = find.byType(AppBar);
    expect(tester.getSize(bar).height, 59 + 113.0,
        reason: '44 toolbar + 28 + 41 title, under the inset');
    Color background() => tester
        .widget<Material>(find
            .descendant(of: bar, matching: find.byType(Material))
            .first)
        .color!;
    expect(background(), AppColors.light.page);

    await tester.drag(find.text('row 3'), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.getSize(bar).height, 59 + 44.0);
    final collapsed = find.descendant(
        of: find.byType(NavigationToolbar), matching: find.text('Settings'));
    expect(tester.getRect(collapsed).top, greaterThanOrEqualTo(59),
        reason: 'a bare collapsedHeight of 44 put it under the status bar');
    expect(background(), AppColors.light.chrome);
  });

  testWidgets('a grouped sheet: dark cells #2C2C2E on the #1C1C1E sheet, '
      'title2 heading', (tester) async {
    await pumpApp(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: () => showGroupedSheet<void>(
                context,
                title: 'Language',
                builder: (_) => const GroupedSection(
                  key: Key('section'),
                  separatorInset: 16,
                  children: [GroupedRow(title: 'English')],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
        brightness: Brightness.dark);
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    final cell = tester.widget<Material>(find
        .descendant(
            of: find.byKey(const Key('section')),
            matching: find.byType(Material))
        .first);
    expect(cell.color, const Color(0xFF2C2C2E));
    final sheet = tester.widget<Material>(find
        .descendant(
            of: find.byType(BottomSheet), matching: find.byType(Material))
        .first);
    expect(sheet.color, const Color(0xFF1C1C1E));
    final title = tester.widget<Text>(find.text('Language'));
    expect(title.style?.fontSize, 22);
  });

  group('states', () {
    testWidgets('EmptyState.sliver scrolls at 3.1x on a 375x667 phone',
        (tester) async {
      await loadIphoneFonts();
      for (final locale in const [Locale('en'), Locale('zh')]) {
        await pumpApp(
            tester,
            Builder(
              builder: (context) => Scaffold(
                body: CustomScrollView(slivers: [
                  appLargeTitleBar(context, title: 'History'),
                  const EmptyState.sliver(
                    key: Key('empty'),
                    icon: Icons.bar_chart_rounded,
                    title: 'No meals logged in the past 30 days.',
                    message: 'Meals you log show up here, one row per day, '
                        'with a trend chart on top.',
                  ),
                ]),
              ),
            ),
            size: const Size(375, 667),
            locale: locale,
            scale: 3.1);
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('trend chart'), findsOneWidget);
      }
    });

    testWidgets('EmptyState: header title, decorative icon, tonal action',
        (tester) async {
      final handle = tester.ensureSemantics();
      var tapped = false;
      await pumpApp(
          tester,
          Scaffold(
            body: EmptyState(
              icon: Icons.restaurant_rounded,
              title: 'No meals logged yet today.',
              message: 'Tap Log to add one.',
              actionLabel: 'Log',
              onAction: () => tapped = true,
            ),
          ));
      expect(
          tester
              .getSemantics(find.text('No meals logged yet today.'))
              .flagsCollection
              .isHeader,
          isTrue);
      expect(find.byType(FilledButton), findsOneWidget);
      await tester.tap(find.text('Log'));
      expect(tapped, isTrue);
      final icon = tester.widget<Icon>(find.byIcon(Icons.restaurant_rounded));
      expect(icon.size, 44);
      expect(icon.color, AppColors.light.secondaryLabel);
      handle.dispose();
    });

    testWidgets('InlineError: danger glyph, label text, Retry', (tester) async {
      var retries = 0;
      await pumpApp(
          tester,
          Scaffold(
            body: InlineError(
                message: "Couldn't load your history.",
                onRetry: () => retries++,
                retryKey: const Key('retry')),
          ));
      expect(find.text("Couldn't load your history."), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.error_outline_rounded)).color,
          AppColors.light.danger);
      await tester.tap(find.byKey(const Key('retry')));
      expect(retries, 1);
    });

    testWidgets('AnalyzingOverlay keeps the callers\' keys and is a live '
        'region', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(
          tester,
          const Scaffold(
            body: AnalyzingOverlay(
              label: 'Analyzing…',
              labelKey: Key('photoAnalyzingText'),
              spinnerKey: Key('photoAnalyzing'),
            ),
          ),
          settle: false);
      await tester.pump();
      expect(find.byKey(const Key('photoAnalyzingText')), findsOneWidget);
      expect(find.byKey(const Key('photoAnalyzing')), findsWidgets);
      expect(
          tester
              .getSemantics(find.byKey(const Key('photoAnalyzingText')))
              .flagsCollection
              .isLiveRegion,
          isTrue);
      handle.dispose();
    });
  });

  group('SmallSpinner', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    testWidgets('iOS: the activity indicator at the requested size',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await pumpApp(
          tester,
          const Scaffold(body: Center(child: SmallSpinner(size: 18))),
          settle: false);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(tester.getSize(find.byType(SmallSpinner)), const Size(18, 18));
      expect(
          tester
              .widget<CupertinoActivityIndicator>(
                  find.byType(CupertinoActivityIndicator))
              .radius,
          9);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Android: a thin ring', (tester) async {
      await pumpApp(
          tester, const Scaffold(body: Center(child: SmallSpinner())),
          settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.getSize(find.byType(SmallSpinner)), const Size(16, 16));
    });
  });

  group('pickers clamp the text scale at 1.6x (A6)', () {
    Widget launcher(Future<void> Function(BuildContext) open) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
                key: const Key('open'),
                onPressed: () => open(context),
                child: const Text('open')),
          ),
        );

    testWidgets('date picker at 3.1x, zh and en, 375 pt', (tester) async {
      await loadIphoneFonts();
      for (final locale in const [Locale('zh'), Locale('en')]) {
        await pumpApp(
            tester,
            launcher((c) => showAppDatePicker(
                context: c,
                initialDate: DateTime(2026, 10, 29),
                firstDate: DateTime(2020),
                lastDate: DateTime(2026, 10, 31))),
            size: const Size(375, 667),
            locale: locale,
            scale: 3.1);
        await tester.tap(find.byKey(const Key('open')));
        await tester.pumpAndSettle();
        final grid = tester.element(find.byType(CalendarDatePicker));
        expect(MediaQuery.textScalerOf(grid).scale(1), 1.6);
        expect(tester.takeException(), isNull,
            reason: 'the zh header overflowed by 24 px unclamped');
        expect(find.text('29'), findsWidgets);
        Navigator.of(grid).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('time picker at 3.1x keeps a caller builder', (tester) async {
      var builderRan = false;
      await pumpApp(
          tester,
          launcher((c) => showAppTimePicker(
                context: c,
                initialTime: const TimeOfDay(hour: 21, minute: 30),
                builder: (context, child) {
                  builderRan = true;
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(alwaysUse24HourFormat: true),
                    child: child!,
                  );
                },
              )),
          size: const Size(375, 667),
          scale: 3.1);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(builderRan, isTrue);
      final dialog = tester.element(find.byType(TimePickerDialog));
      expect(MediaQuery.textScalerOf(dialog).scale(1), lessThanOrEqualTo(1.6));
      expect(tester.takeException(), isNull);
    });

    testWidgets('below the clamp nothing changes', (tester) async {
      await pumpApp(
          tester,
          launcher((c) => showAppDatePicker(
              context: c,
              initialDate: DateTime(2026, 10, 29),
              firstDate: DateTime(2020),
              lastDate: DateTime(2026, 10, 31))),
          scale: 1.2);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(
          MediaQuery.textScalerOf(tester.element(find.byType(CalendarDatePicker)))
              .scale(1),
          closeTo(1.2, 1e-9));
    });
  });
}
