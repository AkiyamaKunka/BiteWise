/// Design tokens for the run-7 "Native" refresh: Apple system neutrals for
/// every surface, the terracotta accent, iOS-sized type and a 4-pt grid.
///
/// Why neutrals: on 2026-08-02 the owner called seed-tinted surfaces
/// "pink", and the app moved to Apple's own grouped greys (see
/// widgets/grouped.dart). Material's seed scheme still leaked that tint
/// into dialogs, sheets and placeholders; these tokens are the single
/// source for the surfaces now, and [AppTheme] maps every ColorScheme
/// role onto them so no seed tone survives.
///
/// Every text pair here clears WCAG 4.5:1 and every glyph/boundary pair
/// 3:1, in light, dark and both high-contrast sets — pinned by
/// test/ui/theme_contrast_test.dart. `tertiaryLabel` is for NON-TEXT only
/// (chevrons, legend dots, the average line).
///
/// Accessors never throw: tests and helpers that pump a bare MaterialApp
/// (no extension) get the light/dark defaults by the theme's brightness.
library;

import 'dart:ui' show FontFeature, lerpDouble;

import 'package:flutter/material.dart';

/// Colour tokens. Use `context.colors` (or [AppColors.of]).
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.brightness,
    required this.page,
    required this.cell,
    required this.elevated,
    required this.sheet,
    required this.sheetCell,
    required this.chrome,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.fill,
    required this.track,
    required this.highlight,
    required this.outline,
    required this.scrim,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.danger,
    required this.dangerFill,
    required this.success,
    required this.successFill,
    required this.warning,
    required this.info,
    required this.badgeBrand,
    required this.badgeNeutral,
    required this.badgeInfo,
    required this.badgeDanger,
    required this.badgeSuccess,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.inversePrimary,
    required this.macroChipAlpha,
  });

  final Brightness brightness;

  // Neutrals.
  /// systemGroupedBackground: the page behind grouped cells.
  final Color page;

  /// secondarySystemGroupedBackground: cells and cards on [page].
  final Color cell;

  /// Dialogs, menus, popups and pickers.
  final Color elevated;

  /// Modal sheet background (dark: lifted off the black page).
  final Color sheet;

  /// Cells inside a sheet (see [inSheet]).
  final Color sheetCell;

  /// Tab bar and the scrolled-under large-title bar.
  final Color chrome;
  final Color label;

  /// Secondary text: values, footers, captions, inactive tab labels.
  final Color secondaryLabel;

  /// NON-TEXT ONLY (chevrons, the Typical dot, the average line).
  final Color tertiaryLabel;
  final Color separator;

  /// Quiet control fill (tonal buttons, date pills, placeholders).
  final Color fill;

  /// Progress tracks (ring, macro bars). Decorative: the accent arc
  /// carries the contrast against it.
  final Color track;

  /// The pressed-cell highlight (opaque, iOS style).
  final Color highlight;
  final Color outline;

  /// Modal barrier.
  final Color scrim;

  // Accent.
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color onAccentSoft;

  // Status.
  /// Destructive/error TEXT and glyphs.
  final Color danger;

  /// Destructive FILLS (swipe-delete background) under a white glyph.
  final Color dangerFill;
  final Color success;
  final Color successFill;
  final Color warning;
  final Color info;

  // Row-badge fills, always under a white glyph (3:1 or better).
  final Color badgeBrand;
  final Color badgeNeutral;
  final Color badgeInfo;
  final Color badgeDanger;
  final Color badgeSuccess;

  // Inverse (snackbars, tooltips).
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color inversePrimary;

  /// Alpha of a macro hue used as a chip tint (MacroPalette stays in
  /// widgets/macro_chart.dart).
  final double macroChipAlpha;

  bool get isDark => brightness == Brightness.dark;

  static const AppColors light = AppColors(
    brightness: Brightness.light,
    page: Color(0xFFF2F2F7),
    cell: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    sheet: Color(0xFFF2F2F7),
    sheetCell: Color(0xFFFFFFFF),
    chrome: Color(0xFFF9F9F9),
    label: Color(0xFF000000),
    secondaryLabel: Color(0xFF6C6C70),
    tertiaryLabel: Color(0xFF8A8A8E),
    separator: Color(0xFFC6C6C8),
    fill: Color(0xFFEEEEF0),
    track: Color(0xFFE5E5EA),
    highlight: Color(0xFFD1D1D6),
    outline: Color(0xFF8A8A8E),
    scrim: Color(0x66000000),
    accent: Color(0xFFA64B2A),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFF6EDEA),
    onAccentSoft: Color(0xFF6B2C14),
    danger: Color(0xFFD70015),
    dangerFill: Color(0xFFD70015),
    success: Color(0xFF1F7A35),
    successFill: Color(0xFF248A3D),
    warning: Color(0xFF946200),
    info: Color(0xFF5856D6),
    badgeBrand: Color(0xFFA64B2A),
    badgeNeutral: Color(0xFF7C7C80),
    badgeInfo: Color(0xFF5856D6),
    badgeDanger: Color(0xFFD70015),
    badgeSuccess: Color(0xFF248A3D),
    inverseSurface: Color(0xFF2C2C2E),
    onInverseSurface: Color(0xFFF2F2F7),
    inversePrimary: Color(0xFFF2A07B),
    macroChipAlpha: 0.20,
  );

  static const AppColors dark = AppColors(
    brightness: Brightness.dark,
    page: Color(0xFF000000),
    cell: Color(0xFF1C1C1E),
    elevated: Color(0xFF2C2C2E),
    sheet: Color(0xFF1C1C1E),
    sheetCell: Color(0xFF2C2C2E),
    chrome: Color(0xFF161616),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0xFF98989F),
    tertiaryLabel: Color(0xFF7C7C80),
    separator: Color(0xFF38383A),
    // Also inside sheets: #3A3A3C was measured there and FAILS
    // (secondaryLabel 3.96, danger 4.02).
    fill: Color(0xFF2C2C2E),
    track: Color(0xFF38383A),
    highlight: Color(0xFF3A3A3C),
    outline: Color(0xFF7C7C80),
    scrim: Color(0x99000000),
    accent: Color(0xFFF2A07B),
    // Never white on the dark accent.
    onAccent: Color(0xFF2A1206),
    accentSoft: Color(0xFF3E312D),
    onAccentSoft: Color(0xFFF7C2A8),
    danger: Color(0xFFFF6961),
    dangerFill: Color(0xFFFF453A),
    success: Color(0xFF30D158),
    successFill: Color(0xFF248A3D),
    warning: Color(0xFFFFD60A),
    // 4.94 on cell; never as text on elevated (4.05).
    info: Color(0xFF7D7AFF),
    // Every dark badge measured 1.70:1 before (white on tone-80 pastels).
    badgeBrand: Color(0xFFB9562F),
    badgeNeutral: Color(0xFF636366),
    badgeInfo: Color(0xFF5E5CE6),
    badgeDanger: Color(0xFFFF453A),
    badgeSuccess: Color(0xFF248A3D),
    inverseSurface: Color(0xFFE5E5EA),
    onInverseSurface: Color(0xFF000000),
    inversePrimary: Color(0xFFA64B2A),
    macroChipAlpha: 0.25,
  );

  /// iOS "Increase Contrast" (MaterialApp.highContrastTheme): values only.
  static const AppColors lightHighContrast = AppColors(
    brightness: Brightness.light,
    page: Color(0xFFF2F2F7),
    cell: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    sheet: Color(0xFFF2F2F7),
    sheetCell: Color(0xFFFFFFFF),
    chrome: Color(0xFFF9F9F9),
    label: Color(0xFF000000),
    secondaryLabel: Color(0xFF48484A),
    tertiaryLabel: Color(0xFF8A8A8E),
    separator: Color(0xFF8E8E93),
    fill: Color(0xFFEEEEF0),
    track: Color(0xFFE5E5EA),
    highlight: Color(0xFFD1D1D6),
    outline: Color(0xFF8A8A8E),
    scrim: Color(0x66000000),
    accent: Color(0xFF863A1E),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFF6EDEA),
    onAccentSoft: Color(0xFF6B2C14),
    danger: Color(0xFFA50011),
    dangerFill: Color(0xFFD70015),
    success: Color(0xFF1F7A35),
    successFill: Color(0xFF248A3D),
    warning: Color(0xFF946200),
    info: Color(0xFF5856D6),
    badgeBrand: Color(0xFFA64B2A),
    badgeNeutral: Color(0xFF7C7C80),
    badgeInfo: Color(0xFF5856D6),
    badgeDanger: Color(0xFFD70015),
    badgeSuccess: Color(0xFF248A3D),
    inverseSurface: Color(0xFF2C2C2E),
    onInverseSurface: Color(0xFFF2F2F7),
    inversePrimary: Color(0xFFF2A07B),
    macroChipAlpha: 0.20,
  );

  static const AppColors darkHighContrast = AppColors(
    brightness: Brightness.dark,
    page: Color(0xFF000000),
    cell: Color(0xFF1C1C1E),
    elevated: Color(0xFF2C2C2E),
    sheet: Color(0xFF1C1C1E),
    sheetCell: Color(0xFF2C2C2E),
    chrome: Color(0xFF161616),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0xFFC7C7CC),
    tertiaryLabel: Color(0xFF7C7C80),
    separator: Color(0xFF8D8D93),
    fill: Color(0xFF2C2C2E),
    track: Color(0xFF38383A),
    highlight: Color(0xFF3A3A3C),
    outline: Color(0xFF7C7C80),
    scrim: Color(0x99000000),
    accent: Color(0xFFF7B898),
    onAccent: Color(0xFF2A1206),
    accentSoft: Color(0xFF3E312D),
    onAccentSoft: Color(0xFFF7C2A8),
    danger: Color(0xFFFF8C85),
    dangerFill: Color(0xFFFF453A),
    success: Color(0xFF30D158),
    successFill: Color(0xFF248A3D),
    warning: Color(0xFFFFD60A),
    info: Color(0xFF7D7AFF),
    badgeBrand: Color(0xFFB9562F),
    badgeNeutral: Color(0xFF636366),
    badgeInfo: Color(0xFF5E5CE6),
    badgeDanger: Color(0xFFFF453A),
    badgeSuccess: Color(0xFF248A3D),
    inverseSurface: Color(0xFFE5E5EA),
    onInverseSurface: Color(0xFF000000),
    inversePrimary: Color(0xFFA64B2A),
    macroChipAlpha: 0.25,
  );

  /// The default set for [brightness] (the accessor fallback).
  static AppColors forBrightness(Brightness brightness,
          {bool highContrast = false}) =>
      brightness == Brightness.dark
          ? (highContrast ? darkHighContrast : dark)
          : (highContrast ? lightHighContrast : light);

  /// The tokens in effect at [context]; never null. Without the extension
  /// (a bare MaterialApp in a test) the light/dark set by brightness.
  static AppColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppColors>() ?? forBrightness(theme.brightness);
  }

  /// A copy for content inside a modal sheet: the page becomes the sheet
  /// and cells become [sheetCell] (dark: #2C2C2E on #1C1C1E, so a sheet
  /// over the black page still has visible cells). Idempotent.
  AppColors inSheet() => copyWith(page: sheet, cell: sheetCell);

  @override
  AppColors copyWith({
    Brightness? brightness,
    Color? page,
    Color? cell,
    Color? elevated,
    Color? sheet,
    Color? sheetCell,
    Color? chrome,
    Color? label,
    Color? secondaryLabel,
    Color? tertiaryLabel,
    Color? separator,
    Color? fill,
    Color? track,
    Color? highlight,
    Color? outline,
    Color? scrim,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? onAccentSoft,
    Color? danger,
    Color? dangerFill,
    Color? success,
    Color? successFill,
    Color? warning,
    Color? info,
    Color? badgeBrand,
    Color? badgeNeutral,
    Color? badgeInfo,
    Color? badgeDanger,
    Color? badgeSuccess,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? inversePrimary,
    double? macroChipAlpha,
  }) =>
      AppColors(
        brightness: brightness ?? this.brightness,
        page: page ?? this.page,
        cell: cell ?? this.cell,
        elevated: elevated ?? this.elevated,
        sheet: sheet ?? this.sheet,
        sheetCell: sheetCell ?? this.sheetCell,
        chrome: chrome ?? this.chrome,
        label: label ?? this.label,
        secondaryLabel: secondaryLabel ?? this.secondaryLabel,
        tertiaryLabel: tertiaryLabel ?? this.tertiaryLabel,
        separator: separator ?? this.separator,
        fill: fill ?? this.fill,
        track: track ?? this.track,
        highlight: highlight ?? this.highlight,
        outline: outline ?? this.outline,
        scrim: scrim ?? this.scrim,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        accentSoft: accentSoft ?? this.accentSoft,
        onAccentSoft: onAccentSoft ?? this.onAccentSoft,
        danger: danger ?? this.danger,
        dangerFill: dangerFill ?? this.dangerFill,
        success: success ?? this.success,
        successFill: successFill ?? this.successFill,
        warning: warning ?? this.warning,
        info: info ?? this.info,
        badgeBrand: badgeBrand ?? this.badgeBrand,
        badgeNeutral: badgeNeutral ?? this.badgeNeutral,
        badgeInfo: badgeInfo ?? this.badgeInfo,
        badgeDanger: badgeDanger ?? this.badgeDanger,
        badgeSuccess: badgeSuccess ?? this.badgeSuccess,
        inverseSurface: inverseSurface ?? this.inverseSurface,
        onInverseSurface: onInverseSurface ?? this.onInverseSurface,
        inversePrimary: inversePrimary ?? this.inversePrimary,
        macroChipAlpha: macroChipAlpha ?? this.macroChipAlpha,
      );

  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      page: c(page, other.page),
      cell: c(cell, other.cell),
      elevated: c(elevated, other.elevated),
      sheet: c(sheet, other.sheet),
      sheetCell: c(sheetCell, other.sheetCell),
      chrome: c(chrome, other.chrome),
      label: c(label, other.label),
      secondaryLabel: c(secondaryLabel, other.secondaryLabel),
      tertiaryLabel: c(tertiaryLabel, other.tertiaryLabel),
      separator: c(separator, other.separator),
      fill: c(fill, other.fill),
      track: c(track, other.track),
      highlight: c(highlight, other.highlight),
      outline: c(outline, other.outline),
      scrim: c(scrim, other.scrim),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      accentSoft: c(accentSoft, other.accentSoft),
      onAccentSoft: c(onAccentSoft, other.onAccentSoft),
      danger: c(danger, other.danger),
      dangerFill: c(dangerFill, other.dangerFill),
      success: c(success, other.success),
      successFill: c(successFill, other.successFill),
      warning: c(warning, other.warning),
      info: c(info, other.info),
      badgeBrand: c(badgeBrand, other.badgeBrand),
      badgeNeutral: c(badgeNeutral, other.badgeNeutral),
      badgeInfo: c(badgeInfo, other.badgeInfo),
      badgeDanger: c(badgeDanger, other.badgeDanger),
      badgeSuccess: c(badgeSuccess, other.badgeSuccess),
      inverseSurface: c(inverseSurface, other.inverseSurface),
      onInverseSurface: c(onInverseSurface, other.onInverseSurface),
      inversePrimary: c(inversePrimary, other.inversePrimary),
      macroChipAlpha: lerpDouble(macroChipAlpha, other.macroChipAlpha, t)!,
    );
  }
}

/// One iOS text style: [size]/[line] pt, [weight], Latin [tracking] (pt).
/// The line height is set as `height = line / size` with even leading,
/// so the box is exactly [line] pt at 1.0x and scales with Dynamic Type.
TextStyle appTextRole(TextStyle? base, double size, double line,
    FontWeight weight, double tracking,
    {required String? family,
    List<String>? fallback,
    bool cjk = false,
    bool tabular = false}) {
  return (base ?? const TextStyle()).copyWith(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: size,
    height: line / size,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: weight,
    // Apple's SF tracking table is for Latin; CJK glyphs take none (the
    // zh UI also keeps any typed Latin untracked, as iOS does there).
    letterSpacing: cjk ? 0 : tracking,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

/// Apple text styles Material's TextTheme has no role for.
/// Use `context.type` (or [AppTypography.of]).
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.title2,
    required this.title3,
    required this.callout,
    required this.caption2,
    required this.mutedColor,
  });

  /// 22/28 w700: sheet titles, the report title.
  final TextStyle title2;

  /// 20/25 w600: empty-state titles.
  final TextStyle title3;

  /// 16/21 w400.
  final TextStyle callout;

  /// 11/13 w400: chart labels.
  final TextStyle caption2;

  /// The secondaryLabel colour [muted] applies.
  final Color mutedColor;

  /// [style] in secondaryLabel (replaces `copyWith(color:
  /// onSurfaceVariant)` recolours).
  TextStyle muted(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(color: mutedColor);

  /// Built over [text] (the theme's TextTheme, for its platform families
  /// and colour). [textFamily]/[displayFamily] default to that theme's
  /// bodyLarge/displayLarge families.
  factory AppTypography.from(
    TextTheme text, {
    required Color mutedColor,
    bool cjk = false,
    String? textFamily,
    String? displayFamily,
    List<String>? fallback,
  }) {
    final tf = textFamily ?? text.bodyLarge?.fontFamily;
    final df = displayFamily ?? text.displayLarge?.fontFamily;
    final fb = fallback ?? text.bodyLarge?.fontFamilyFallback;
    final base = text.bodyLarge;
    return AppTypography(
      title2: appTextRole(base, 22, 28, FontWeight.w700, 0.35,
          family: df, fallback: fb, cjk: cjk),
      title3: appTextRole(base, 20, 25, FontWeight.w600, 0.38,
          family: df, fallback: fb, cjk: cjk),
      callout: appTextRole(base, 16, 21, FontWeight.w400, -0.31,
          family: tf, fallback: fb, cjk: cjk),
      caption2: appTextRole(base, 11, 13, FontWeight.w400, 0.06,
          family: tf, fallback: fb, cjk: cjk),
      mutedColor: mutedColor,
    );
  }

  /// The styles in effect at [context]; never null (falls back to a set
  /// built over the current TextTheme).
  static AppTypography of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppTypography>() ??
        AppTypography.from(theme.textTheme,
            mutedColor: AppColors.of(context).secondaryLabel);
  }

  @override
  AppTypography copyWith({
    TextStyle? title2,
    TextStyle? title3,
    TextStyle? callout,
    TextStyle? caption2,
    Color? mutedColor,
  }) =>
      AppTypography(
        title2: title2 ?? this.title2,
        title3: title3 ?? this.title3,
        callout: callout ?? this.callout,
        caption2: caption2 ?? this.caption2,
        mutedColor: mutedColor ?? this.mutedColor,
      );

  @override
  AppTypography lerp(covariant ThemeExtension<AppTypography>? other,
      double t) {
    if (other is! AppTypography) return this;
    return AppTypography(
      title2: TextStyle.lerp(title2, other.title2, t)!,
      title3: TextStyle.lerp(title3, other.title3, t)!,
      callout: TextStyle.lerp(callout, other.callout, t)!,
      caption2: TextStyle.lerp(caption2, other.caption2, t)!,
      mutedColor: Color.lerp(mutedColor, other.mutedColor, t)!,
    );
  }
}

/// Number styles, all with tabular figures so digits don't jitter as
/// values change. Use `context.nums` (or [AppNumerals.of]).
@immutable
class AppNumerals extends ThemeExtension<AppNumerals> {
  const AppNumerals({
    required this.hero,
    required this.large,
    required this.value,
    required this.inline,
    required this.chip,
  });

  /// 34/41 w700: the ring centre, Body weight.
  final TextStyle hero;

  /// 28/34 w700: day-detail and report totals.
  final TextStyle large;

  /// 17/22 w600: History kcal, the emphasized Eaten row, measurements.
  final TextStyle value;

  /// 15/20 w400: Typical and Burn values, deltas.
  final TextStyle inline;

  /// 12/16 w600: kcal and macro chips.
  final TextStyle chip;

  factory AppNumerals.from(
    TextTheme text, {
    bool cjk = false,
    String? textFamily,
    String? displayFamily,
    List<String>? fallback,
  }) {
    final tf = textFamily ?? text.bodyLarge?.fontFamily;
    final df = displayFamily ?? text.displayLarge?.fontFamily;
    final fb = fallback ?? text.bodyLarge?.fontFamilyFallback;
    final base = text.bodyLarge;
    TextStyle n(double size, double line, FontWeight w, double tracking) =>
        appTextRole(base, size, line, w, tracking,
            family: size >= 20 ? df : tf,
            fallback: fb,
            cjk: cjk,
            tabular: true);
    return AppNumerals(
      hero: n(34, 41, FontWeight.w700, 0.40),
      large: n(28, 34, FontWeight.w700, 0.38),
      value: n(17, 22, FontWeight.w600, -0.43),
      inline: n(15, 20, FontWeight.w400, -0.23),
      chip: n(12, 16, FontWeight.w600, 0),
    );
  }

  static AppNumerals of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppNumerals>() ??
        AppNumerals.from(theme.textTheme);
  }

  @override
  AppNumerals copyWith({
    TextStyle? hero,
    TextStyle? large,
    TextStyle? value,
    TextStyle? inline,
    TextStyle? chip,
  }) =>
      AppNumerals(
        hero: hero ?? this.hero,
        large: large ?? this.large,
        value: value ?? this.value,
        inline: inline ?? this.inline,
        chip: chip ?? this.chip,
      );

  @override
  AppNumerals lerp(covariant ThemeExtension<AppNumerals>? other, double t) {
    if (other is! AppNumerals) return this;
    return AppNumerals(
      hero: TextStyle.lerp(hero, other.hero, t)!,
      large: TextStyle.lerp(large, other.large, t)!,
      value: TextStyle.lerp(value, other.value, t)!,
      inline: TextStyle.lerp(inline, other.inline, t)!,
      chip: TextStyle.lerp(chip, other.chip, t)!,
    );
  }
}

/// The 4-pt spacing grid and the named layout constants.
abstract final class AppSpace {
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;

  /// The one side gutter (kGroupInset).
  static const double gutter = 16;
  static const double sectionTop = 20;
  static const double headerToCells = 6;
  static const double cellsToFooter = 6;
  static const double footerSide = 16;
  static const double rowH = 16;
  static const double rowV = 11;
  static const double rowVStacked = 12;
  static const double rowMinHeight = 44;
  static const double badge = 29;
  static const double badgeGap = 12;

  /// Separator inset past a badge: 16 + 29 + 12.
  static const double separatorInsetBadge = 57;

  /// Separator inset for rows without a badge.
  static const double separatorInset = 16;
  static const double cardPadding = 16;
  static const double cardGap = 10;
  static const double groupGap = 20;
  static const double chipH = 8;
  static const double chipV = 3;
  static const double chipGap = 6;

  /// Room left under content for the floating action button.
  static const double fabClearance = 96;
  static const double dialogInset = 24;
  static const double tabBarHeight = 56;

  /// The large-title bar's toolbar row.
  static const double toolbarHeight = 44;
}

/// Corner radii.
abstract final class AppRadius {
  /// Chart bar tops.
  static const double xs = 4;
  static const double badge = 7;

  /// Thumbnails, date/time pills.
  static const double m = 10;

  /// Inputs, popup menus.
  static const double l = 12;
  static const double snack = 14;

  /// Every card and grouped section (kCellRadius).
  static const double cell = 18;

  /// Sheet top corners, dialogs.
  static const double xl = 28;
}

/// Motion durations; zero under Reduce Motion ([AppMotion.of]).
abstract final class AppMotion {
  static const Duration quick = Duration(milliseconds: 150);
  static const Duration standard = Duration(milliseconds: 250);
  static const Duration ring = Duration(milliseconds: 600);
  static const Curve curve = Curves.easeOutCubic;

  /// [d], or zero when the user turned animations off.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false
          ? Duration.zero
          : d;
}

/// `context.colors`, `context.type`, `context.nums`.
extension AppThemeContext on BuildContext {
  AppColors get colors => AppColors.of(this);
  AppTypography get type => AppTypography.of(this);
  AppNumerals get nums => AppNumerals.of(this);
}
