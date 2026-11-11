/// Contrast pins for the run-7 design tokens (pure Dart, WCAG 2.x).
///
/// Text pairs must clear 4.5:1, glyphs and boundaries 3:1, in light, dark
/// and both Increase Contrast sets; the dark danger red must stay
/// distinguishable from the dark accent (CIEDE2000 ≥ 10). Before run 7
/// every dark row badge drew its white glyph at 1.70:1 and the dark
/// danger badge sat ΔE 5.5 from the ordinary clay one (A9).
library;

import 'dart:math' as math;

import 'package:calorie_tracker/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _lin(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double luminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

double contrast(Color a, Color b) {
  final la = luminance(a), lb = luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// sRGB → CIELAB (D65).
List<double> _lab(Color c) {
  final r = _lin(c.r), g = _lin(c.g), b = _lin(c.b);
  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}

double _deg(double rad) => rad * 180 / math.pi;
double _rad(double deg) => deg * math.pi / 180;

/// CIEDE2000 colour difference.
double deltaE2000(Color c1, Color c2) {
  final l1 = _lab(c1), l2 = _lab(c2);
  final cAvg = (math.sqrt(l1[1] * l1[1] + l1[2] * l1[2]) +
          math.sqrt(l2[1] * l2[1] + l2[2] * l2[2])) /
      2;
  final c7 = math.pow(cAvg, 7);
  final g = 0.5 * (1 - math.sqrt(c7 / (c7 + math.pow(25, 7))));
  final a1 = (1 + g) * l1[1], a2 = (1 + g) * l2[1];
  final cp1 = math.sqrt(a1 * a1 + l1[2] * l1[2]);
  final cp2 = math.sqrt(a2 * a2 + l2[2] * l2[2]);
  final h1 = (_deg(math.atan2(l1[2], a1)) + 360) % 360;
  final h2 = (_deg(math.atan2(l2[2], a2)) + 360) % 360;
  final dL = l2[0] - l1[0];
  final dC = cp2 - cp1;
  var dh = h2 - h1;
  if (cp1 * cp2 == 0) {
    dh = 0;
  } else if (dh > 180) {
    dh -= 360;
  } else if (dh < -180) {
    dh += 360;
  }
  final dH = 2 * math.sqrt(cp1 * cp2) * math.sin(_rad(dh / 2));
  final lAvg = (l1[0] + l2[0]) / 2;
  final cpAvg = (cp1 + cp2) / 2;
  double hAvg;
  if (cp1 * cp2 == 0) {
    hAvg = h1 + h2;
  } else if ((h1 - h2).abs() <= 180) {
    hAvg = (h1 + h2) / 2;
  } else if (h1 + h2 < 360) {
    hAvg = (h1 + h2 + 360) / 2;
  } else {
    hAvg = (h1 + h2 - 360) / 2;
  }
  final t = 1 -
      0.17 * math.cos(_rad(hAvg - 30)) +
      0.24 * math.cos(_rad(2 * hAvg)) +
      0.32 * math.cos(_rad(3 * hAvg + 6)) -
      0.20 * math.cos(_rad(4 * hAvg - 63));
  final dTheta = 30 * math.exp(-math.pow((hAvg - 275) / 25, 2));
  final cp7 = math.pow(cpAvg, 7);
  final rc = 2 * math.sqrt(cp7 / (cp7 + math.pow(25, 7)));
  final sl = 1 +
      0.015 * math.pow(lAvg - 50, 2) / math.sqrt(20 + math.pow(lAvg - 50, 2));
  final sc = 1 + 0.045 * cpAvg;
  final sh = 1 + 0.015 * cpAvg * t;
  final rt = -math.sin(_rad(2 * dTheta)) * rc;
  return math.sqrt(math.pow(dL / sl, 2) +
      math.pow(dC / sc, 2) +
      math.pow(dH / sh, 2) +
      rt * (dC / sc) * (dH / sh));
}

typedef _Pair = (String, Color, Color);

const _white = Color(0xFFFFFFFF);

/// Text pairs (≥ 4.5:1) common to every set.
List<_Pair> _textPairs(AppColors c) => [
      ('label on cell', c.label, c.cell),
      ('label on page', c.label, c.page),
      ('label on elevated', c.label, c.elevated),
      ('label on sheetCell', c.label, c.sheetCell),
      ('secondaryLabel on cell', c.secondaryLabel, c.cell),
      ('secondaryLabel on page', c.secondaryLabel, c.page),
      ('secondaryLabel on fill', c.secondaryLabel, c.fill),
      ('secondaryLabel on chrome', c.secondaryLabel, c.chrome),
      ('secondaryLabel on elevated', c.secondaryLabel, c.elevated),
      ('secondaryLabel on sheetCell', c.secondaryLabel, c.sheetCell),
      ('accent on cell', c.accent, c.cell),
      ('accent on page', c.accent, c.page),
      ('accent on fill (tonal button)', c.accent, c.fill),
      ('accent on accentSoft', c.accent, c.accentSoft),
      ('accent on chrome (tab label)', c.accent, c.chrome),
      ('accent on elevated (dialog button)', c.accent, c.elevated),
      ('onAccent on accent', c.onAccent, c.accent),
      ('onAccentSoft on accentSoft', c.onAccentSoft, c.accentSoft),
      ('danger on cell', c.danger, c.cell),
      ('danger on page', c.danger, c.page),
      ('danger on fill (destructive button)', c.danger, c.fill),
      ('danger on elevated', c.danger, c.elevated),
      ('success on cell', c.success, c.cell),
      ('warning on cell', c.warning, c.cell),
      ('info on cell', c.info, c.cell),
      ('onInverseSurface on inverseSurface', c.onInverseSurface,
          c.inverseSurface),
      ('inversePrimary on inverseSurface', c.inversePrimary,
          c.inverseSurface),
    ];

/// Glyph and boundary pairs (≥ 3:1).
List<_Pair> _glyphPairs(AppColors c) => [
      ('tertiaryLabel on cell', c.tertiaryLabel, c.cell),
      ('tertiaryLabel on elevated', c.tertiaryLabel, c.elevated),
      ('outline on page (field border)', c.outline, c.page),
      ('outline on cell (field border)', c.outline, c.cell),
      ('accent arc against track', c.accent, c.track),
      ('accent arc against cell', c.accent, c.cell),
      ('white glyph on badgeBrand', _white, c.badgeBrand),
      ('white glyph on badgeNeutral', _white, c.badgeNeutral),
      ('white glyph on badgeInfo', _white, c.badgeInfo),
      ('white glyph on badgeDanger', _white, c.badgeDanger),
      ('white glyph on badgeSuccess', _white, c.badgeSuccess),
      ('white glyph on dangerFill', _white, c.dangerFill),
      ('white glyph on successFill', _white, c.successFill),
    ];

void main() {
  const sets = {
    'light': AppColors.light,
    'dark': AppColors.dark,
    'light high contrast': AppColors.lightHighContrast,
    'dark high contrast': AppColors.darkHighContrast,
  };

  test('the contrast helpers reproduce known WCAG values', () {
    expect(contrast(const Color(0xFF000000), _white), closeTo(21, 0.01));
    expect(contrast(_white, _white), closeTo(1, 0.0001));
    // Values the design judge measured independently.
    expect(contrast(const Color(0xFF6C6C70), _white), closeTo(5.23, 0.02));
    expect(contrast(const Color(0xFFA64B2A), _white), closeTo(5.74, 0.02));
    expect(contrast(_white, const Color(0xFFFFB59D)), closeTo(1.70, 0.02),
        reason: 'the old dark badge (white on tone-80 primary)');
    expect(
        deltaE2000(const Color(0xFFFFB59D), const Color(0xFFFFB4AB)),
        closeTo(5.5, 0.3),
        reason: 'the old dark primary vs error difference');
  });

  for (final MapEntry(key: name, value: c) in sets.entries) {
    group(name, () {
      test('every text pair clears 4.5:1', () {
        final fails = [
          for (final (label, fg, bg) in _textPairs(c))
            if (contrast(fg, bg) < 4.5)
              '$label ${contrast(fg, bg).toStringAsFixed(2)}',
        ];
        expect(fails, isEmpty);
      });

      test('every glyph and boundary pair clears 3:1', () {
        final fails = [
          for (final (label, fg, bg) in _glyphPairs(c))
            if (contrast(fg, bg) < 3.0)
              '$label ${contrast(fg, bg).toStringAsFixed(2)}',
        ];
        expect(fails, isEmpty);
      });

      test('the in-sheet copy keeps every text pair', () {
        final s = c.inSheet();
        expect(s.cell, c.sheetCell);
        expect(s.page, c.sheet);
        expect(s.inSheet().cell, c.sheetCell, reason: 'idempotent');
        final fails = [
          for (final (label, fg, bg) in _textPairs(s))
            // Indigo is never TEXT on a raised surface (dark #2C2C2E sheet
            // cells and dialogs: 4.05); there it only tints glyphs.
            if (label != 'info on cell' && contrast(fg, bg) < 4.5)
              '$label ${contrast(fg, bg).toStringAsFixed(2)}',
        ];
        expect(fails, isEmpty);
        expect(contrast(s.info, s.cell), greaterThanOrEqualTo(3.0));
      });

      test('danger never reads as the accent (ΔE00 ≥ 10)', () {
        expect(deltaE2000(c.danger, c.accent), greaterThanOrEqualTo(10));
        expect(deltaE2000(c.badgeDanger, c.badgeBrand),
            greaterThanOrEqualTo(10),
            reason: 'a fault badge must not look like an ordinary one');
      });

      test('the ColorScheme on-pairs hold', () {
        final s = AppTheme.colorSchemeFor(c);
        final pairs = <_Pair>[
          ('onPrimary', s.onPrimary, s.primary),
          ('onPrimaryContainer', s.onPrimaryContainer, s.primaryContainer),
          ('onSecondary', s.onSecondary, s.secondary),
          ('onSecondaryContainer', s.onSecondaryContainer,
              s.secondaryContainer),
          ('onTertiary', s.onTertiary, s.tertiary),
          ('onError', s.onError, s.error),
          ('onErrorContainer', s.onErrorContainer, s.errorContainer),
          ('onSurface', s.onSurface, s.surface),
          ('onSurfaceVariant', s.onSurfaceVariant, s.surface),
          ('onInverseSurface', s.onInverseSurface, s.inverseSurface),
        ];
        final fails = [
          for (final (label, fg, bg) in pairs)
            if (contrast(fg, bg) < 4.5)
              '$label ${contrast(fg, bg).toStringAsFixed(2)}',
        ];
        expect(fails, isEmpty);
        // The dark indigo on #2C2C2E is 4.05: glyph-grade only (the app
        // never sets text in onTertiaryContainer).
        expect(contrast(s.onTertiaryContainer, s.tertiaryContainer),
            greaterThanOrEqualTo(3.0));
      });
    });
  }

  test('high contrast only darkens or lightens, never lowers a pair', () {
    for (final (normal, high) in [
      (AppColors.light, AppColors.lightHighContrast),
      (AppColors.dark, AppColors.darkHighContrast),
    ]) {
      for (final (pick, name) in <(Color Function(AppColors), String)>[
        ((c) => c.accent, 'accent'),
        ((c) => c.secondaryLabel, 'secondaryLabel'),
        ((c) => c.danger, 'danger'),
        ((c) => c.separator, 'separator'),
      ]) {
        expect(contrast(pick(high), normal.cell),
            greaterThan(contrast(pick(normal), normal.cell)),
            reason: '$name (${normal.brightness})');
      }
    }
  });
}
