/// Run 7, My usual foods on the app's REAL theme (AppTheme via the
/// harness), in light and dark:
///
/// - A row's ⋯ menu stands off the cell it opens over. In light the menu
///   and the cell are the same white, and the theme drew the menu flat,
///   so "Hide from this list" floated over the row's words with no edge.
/// - The ⋯ glyph is the accent, as the app's other icon buttons are, and
///   dims while pressed on iOS like them. The menu button passed
///   Material's default icon colour (black87, or white in dark).
library;

import 'package:calorie_tracker/ui/screens/usual_foods_screen.dart';
import 'package:calorie_tracker/ui/theme/tokens.dart';
import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
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

Future<void> _pumpScreen(WidgetTester tester,
    {Brightness brightness = Brightness.light}) async {
  final dao = _dao();
  await pumpApp(
      tester,
      UsualFoodsScreen(
          usual: await makeUsualFoods(dao, clock: _clock), now: _clock),
      brightness: brightness);
}

/// The colour the first row's ⋯ glyph is drawn in.
Color? _moreGlyph(WidgetTester tester) => tester
    .widget<RichText>(find.descendant(
        of: find.byType(PopupMenuButton<String>).first,
        matching: find.byType(RichText)))
    .text
    .style
    ?.color;

void main() {
  setUpAll(loadIphoneFonts);

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
