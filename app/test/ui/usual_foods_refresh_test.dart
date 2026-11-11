/// Run 7, My usual foods on the app's REAL theme (AppTheme via the
/// harness), in light and dark:
///
/// - A row's ⋯ menu stands off the cell it opens over. In light the menu
///   and the cell are the same white, and the theme drew the menu flat,
///   so "Hide from this list" floated over the row's words with no edge.
/// - The ⋯ glyph is the accent, as the app's other icon buttons are, and
///   dims while pressed on iOS like them. The menu button passed
///   Material's default icon colour (black87, or white in dark).
/// - At the largest text size the Logged check and ⋯ go under a row's
///   words, as History's day value does. Beside them they left the words
///   180 to 200 pt on a 320 pt phone, and English names broke inside a
///   word ('Avocad / o', 'Pepper / oni').
library;

import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart';
import 'fakes.dart';

/// Saturday 2026-11-07, 12:30 PM.
DateTime _clock() => DateTime(2026, 11, 7, 12, 30);

/// Avocado toast on two mornings, a chicken salad on two lunches.
FakeDao _dao() {
  final dao = FakeDao();
  var id = 10;
  for (final (date, time, name, kcal) in [
    ('2026-11-03', '07:40 AM', 'Avocado toast', 380),
    ('2026-11-05', '07:45 AM', 'Avocado toast', 380),
    ('2026-11-04', '12:15 PM', 'Chicken salad', 450),
    ('2026-11-06', '12:40 PM', 'Chicken salad', 450),
  ]) {
    dao.seed(foodMeal(
        id: id++,
        date: date,
        time: time,
        description: name,
        items: [foodItem(name, kcal, p: 12, c: 40, f: 20)]));
  }
  return dao;
}

/// [names], each logged on two mornings: each one a usual food.
FakeDao _mornings(List<String> names) {
  final dao = FakeDao();
  var id = 10;
  for (final name in names) {
    for (final date in const ['2026-11-03', '2026-11-05']) {
      dao.seed(foodMeal(
          id: id++,
          date: date,
          time: '07:40 AM',
          description: name,
          items: [foodItem(name, 380, p: 12, c: 40, f: 20)]));
    }
  }
  return dao;
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  FakeDao? dao,
  Brightness brightness = Brightness.light,
  Size size = const Size(390, 844),
  double scale = 1.0,
  Locale locale = const Locale('en'),
}) async {
  final d = dao ?? _dao();
  await pumpApp(
      tester,
      UsualFoodsScreen(
          usual: await makeUsualFoods(d, clock: _clock), now: _clock),
      brightness: brightness,
      size: size,
      scale: scale,
      locale: locale);
}

/// The My usual foods row titled [title].
Finder _row(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('usualRow:')));

/// Logs [title] with one tap and lets its snackbar go.
Future<void> _logIt(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('usualLoggedCheck')), findsOneWidget);
  ScaffoldMessenger.of(tester.element(find.byType(UsualFoodsScreen)))
      .removeCurrentSnackBar();
  await tester.pumpAndSettle();
}

/// [row]'s words: its title, numbers and stats lines.
Iterable<Rect> _textRects(WidgetTester tester, Finder row) => find
    .descendant(of: row, matching: find.byType(Text))
    .evaluate()
    .map((e) => tester.getRect(find.byWidget(e.widget)));

/// The colour the first row's ⋯ glyph is drawn in.
Color? _moreGlyph(WidgetTester tester) => tester
    .widget<RichText>(find.descendant(
        of: find.byType(PopupMenuButton<String>).first,
        matching: find.byType(RichText)))
    .text
    .style
    ?.color;

/// No English word in [row]'s lines is broken across two lines.
void _expectWholeWords(WidgetTester tester, Finder row) {
  for (final text
      in find.descendant(of: row, matching: find.byType(Text)).evaluate()) {
    final p = tester.renderObject<RenderParagraph>(find.descendant(
        of: find.byWidget(text.widget), matching: find.byType(RichText)));
    final plain = p.text.toPlainText();
    var start = 0;
    for (final word in plain.split(' ')) {
      final tops = p
          .getBoxesForSelection(TextSelection(
              baseOffset: start, extentOffset: start + word.length))
          .map((b) => b.top)
          .toSet();
      expect(tops.length, lessThanOrEqualTo(1),
          reason: '"$word" in "$plain" is broken across lines');
      start += word.length + 1;
    }
  }
}

void main() {
  setUpAll(loadIphoneFonts);

  group('AX5 on a 320 pt phone', () {
    const en = [
      'Avocado toast',
      'Pepperoni pizza',
      'Grilled chicken salad with quinoa and avocado',
    ];
    const zh = ['牛油果吐司', '意式辣香肠披萨', '藜麦牛油果烤鸡沙拉'];
    for (final (locale, names) in const [
      (Locale('en'), en),
      (Locale('zh'), zh),
    ]) {
      testWidgets('${locale.languageCode}: the check and ⋯ sit under the '
          'words, which keep the full width', (tester) async {
        await _pumpScreen(tester,
            dao: _mornings(names),
            size: const Size(320, 568),
            scale: 53 / 17,
            locale: locale);
        // The first one logged: its row shows the Logged check too.
        await _logIt(tester, names.first);
        expect(tester.takeException(), isNull);
        for (final name in names) {
          final row = _row(name);
          final more = find.descendant(
              of: row, matching: find.byType(PopupMenuButton<String>));
          await tester.scrollUntilVisible(more, 200,
              scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          // Where a line breaks depends on the font: without the iPhone
          // fonts (Linux CI) the fallback glyphs wrap elsewhere, so only
          // the layout below is checked there.
          if (locale.languageCode == 'en' && haveIphoneFonts) {
            _expectWholeWords(tester, row);
          }
          final rowRect = tester.getRect(row);
          final words = _textRects(tester, row).toList();
          expect(words, hasLength(3), reason: 'title, numbers, stats');
          final wordsBottom =
              words.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
          final actions = [
            more,
            if (name == names.first)
              find.descendant(
                  of: row,
                  matching: find.byKey(const Key('usualLoggedCheck'))),
          ];
          for (final f in actions) {
            final r = tester.getRect(f);
            expect(r.top, greaterThanOrEqualTo(wordsBottom),
                reason: '$name: under the words');
            expect(r.bottom, lessThanOrEqualTo(rowRect.bottom));
            expect(r.left, greaterThanOrEqualTo(rowRect.left));
          }
        }
      });
    }

    testWidgets('the default size keeps the check and ⋯ beside the words',
        (tester) async {
      await _pumpScreen(tester, dao: _mornings(en));
      await _logIt(tester, en.first);
      final row = _row(en.first);
      final wordsRight = _textRects(tester, row)
          .map((r) => r.right)
          .reduce((a, b) => a > b ? a : b);
      for (final f in [
        find.descendant(
            of: row, matching: find.byType(PopupMenuButton<String>)),
        find.descendant(
            of: row, matching: find.byKey(const Key('usualLoggedCheck'))),
      ]) {
        expect(tester.getRect(f).left, greaterThanOrEqualTo(wordsRight));
      }
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('the ⋯ glyph is the accent, like the app\'s other icon '
        'buttons (${brightness.name})', (tester) async {
      await _pumpScreen(tester, brightness: brightness);
      final colors = AppColors.forBrightness(brightness);
      expect(_moreGlyph(tester), colors.accent);
      // The theme's own icon buttons resolve to the same.
      final theme = Theme.of(tester.element(find.byType(UsualFoodsScreen)));
      expect(theme.iconButtonTheme.style?.foregroundColor?.resolve({}),
          colors.accent);
    });
  }

  testWidgets('iOS: the ⋯ glyph dims while pressed, as the other icon '
      'buttons do', (tester) async {
    // Passing only an accent iconColor would draw it right at rest but
    // never dim it: an explicit colour wins over the theme's states.
    await _pumpScreen(tester);
    final accent = AppColors.light.accent;
    expect(_moreGlyph(tester), accent);
    final press = await tester.startGesture(
        tester.getCenter(find.byType(PopupMenuButton<String>).first));
    // In a list the press registers after the tap-or-scroll timeout; the
    // dim then fades in.
    await tester.pump(kPressTimeout);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_moreGlyph(tester), accent.withValues(alpha: 0.4));
    await press.cancel();
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final brightness in Brightness.values) {
    testWidgets('the ⋯ menu stands off the cell it opens over '
        '(${brightness.name})', (tester) async {
      await _pumpScreen(tester, brightness: brightness);
      await tester.tap(find.byTooltip('More actions').first);
      await tester.pumpAndSettle();
      final menu = tester.widget<Material>(find
          .ancestor(
              of: find.text('Hide from this list'),
              matching: find.byType(Material))
          .first);
      final colors = AppColors.forBrightness(brightness);
      expect(menu.color, colors.elevated);
      if (brightness == Brightness.light) {
        // The same white as the cell: only a shadow draws its edge.
        expect(colors.elevated, colors.cell);
        expect(menu.elevation, greaterThan(0),
            reason: 'a flat white menu on a white cell has no edge');
        expect(menu.shadowColor?.a, 1);
      } else {
        // A step lighter than the cell, flat as dark's other surfaces.
        expect(colors.elevated, isNot(colors.cell));
        expect(menu.elevation, 0);
      }
    });
  }
}
