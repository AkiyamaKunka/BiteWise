/// The app's ThemeData, built from [AppColors] and the iOS type scale.
///
/// Material 3 underneath, iOS on top: every ColorScheme role is mapped
/// onto the neutral tokens (no seed tone leaks into dialogs, sheets,
/// menus or placeholders), text uses Apple's sizes and tracking on the
/// system fonts, depth comes from the page/cell tone inversion rather
/// than elevation, and presses highlight instead of rippling on iOS.
///
/// Screens pick up most of the look from here alone; the shared
/// components in widgets/grouped.dart and widgets/states.dart do the rest.
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';

import 'tokens.dart';

export 'tokens.dart';

abstract final class AppTheme {
  /// The terracotta the ColorScheme is seeded with (every role is then
  /// overridden; the seed only fills roles Flutter may add later).
  static const Color seed = Color(0xFFA64B2A);

  /// The full theme for [brightness].
  ///
  /// [cjk]: the effective locale is Chinese, so every letterSpacing is 0
  /// (Apple's SF tracking table is for Latin text).
  /// [highContrast]: iOS Increase Contrast (MaterialApp.highContrastTheme).
  /// [debugFontFamily]/[debugFontFallback]: tests measure with the
  /// iPhone's real fonts loaded under a test family name.
  static ThemeData build(
    Brightness brightness, {
    bool cjk = false,
    bool highContrast = false,
    @visibleForTesting String? debugFontFamily,
    @visibleForTesting List<String>? debugFontFallback,
  }) {
    if (debugFontFamily != null || debugFontFallback != null) {
      return _build(brightness, cjk, highContrast, defaultTargetPlatform,
          debugFontFamily, debugFontFallback);
    }
    // One instance per combination: the app rebuilds MaterialApp on every
    // settings change, and an unequal ThemeData (the extensions compare by
    // identity) would restart AnimatedTheme's lerp each time.
    final platform = defaultTargetPlatform;
    return _cache[(brightness, cjk, highContrast, platform)] ??=
        _build(brightness, cjk, highContrast, platform, null, null);
  }

  static final Map<(Brightness, bool, bool, TargetPlatform), ThemeData>
      _cache = {};

  static ThemeData _build(
    Brightness brightness,
    bool cjk,
    bool highContrast,
    TargetPlatform platform,
    String? debugFontFamily,
    List<String>? debugFontFallback,
  ) {
    final c = AppColors.forBrightness(brightness, highContrast: highContrast);
    final scheme = colorSchemeFor(c);
    final ios =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    final base = ThemeData(
      useMaterial3: true,
      platform: platform,
      colorScheme: scheme,
      fontFamily: debugFontFamily,
      fontFamilyFallback: debugFontFallback,
    );
    final t = base.textTheme;
    // Below 20 pt the platform's TEXT family, 20 pt and up its DISPLAY
    // family (CupertinoSystemText / CupertinoSystemDisplay on iOS).
    // Flutter's iOS typography puts titleLarge on Display, so the 17-pt
    // role is switched to Text explicitly here.
    final textFamily = t.bodyLarge?.fontFamily;
    final displayFamily = t.displayLarge?.fontFamily;
    final fallback = t.bodyLarge?.fontFamilyFallback;
    TextStyle role(TextStyle? s, double size, double line, FontWeight w,
            double tracking) =>
        appTextRole(s, size, line, w, tracking,
            family: size >= 20 ? displayFamily : textFamily,
            fallback: fallback,
            cjk: cjk);

    final text = t.copyWith(
      // SliverAppBar.large's expanded title.
      headlineMedium: role(t.headlineMedium, 34, 41, FontWeight.w700, 0.40),
      headlineSmall: role(t.headlineSmall, 28, 34, FontWeight.w700, 0.38),
      displaySmall: role(t.displaySmall, 34, 41, FontWeight.w700, 0.40),
      // Small AppBar titles and the collapsed large title. NEVER set
      // appBarTheme.titleTextStyle: Flutter would then use it for the
      // EXPANDED large title too and shrink every page title to 17 pt.
      titleLarge: role(t.titleLarge, 17, 22, FontWeight.w600, -0.43),
      titleMedium: role(t.titleMedium, 17, 22, FontWeight.w600, -0.43),
      titleSmall: role(t.titleSmall, 15, 20, FontWeight.w600, -0.23),
      bodyLarge: role(t.bodyLarge, 17, 22, FontWeight.w400, -0.43),
      bodyMedium: role(t.bodyMedium, 15, 20, FontWeight.w400, -0.23),
      bodySmall: role(t.bodySmall, 13, 18, FontWeight.w400, -0.08),
      labelLarge: role(t.labelLarge, 15, 20, FontWeight.w600, -0.23),
      labelMedium: role(t.labelMedium, 13, 18, FontWeight.w500, -0.08),
      labelSmall: role(t.labelSmall, 12, 16, FontWeight.w500, 0),
    );
    TextStyle on(TextStyle? s, Color color) =>
        (s ?? const TextStyle()).copyWith(color: color);
    // Button labels: 17/22, semibold for filled/tonal/FAB, regular for
    // text buttons (iOS's prominent vs plain buttons).
    final buttonStrong = text.titleMedium!;
    final buttonPlain = text.bodyLarge!;
    final tabLabel = role(t.labelSmall, 10, 12, FontWeight.w500, 0);

    final splash = ios ? NoSplash.splashFactory : base.splashFactory;
    // iOS plain buttons dim their glyph while pressed instead of laying a
    // tinted overlay; Android keeps Material's ripple and overlay.
    Color? pressDim(Set<WidgetState> s, Color color) {
      if (s.contains(WidgetState.disabled)) {
        return c.label.withValues(alpha: 0.38);
      }
      if (ios && s.contains(WidgetState.pressed)) {
        return color.withValues(alpha: 0.4);
      }
      return color;
    }

    final transparentOverlay =
        ios ? const WidgetStatePropertyAll<Color?>(Colors.transparent) : null;

    OutlineInputBorder field(Color color, double width) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.l),
          borderSide: BorderSide(color: color, width: width),
        );

    return base.copyWith(
      textTheme: text,
      extensions: <ThemeExtension<dynamic>>[
        c,
        AppTypography.from(text,
            mutedColor: c.secondaryLabel,
            cjk: cjk,
            textFamily: textFamily,
            displayFamily: displayFamily,
            fallback: fallback),
        AppNumerals.from(text,
            cjk: cjk,
            textFamily: textFamily,
            displayFamily: displayFamily,
            fallback: fallback),
      ],
      // Apple's grouped inversion: the PAGE is the deeper tone, cells
      // float on it.
      scaffoldBackgroundColor: c.page,
      canvasColor: c.cell,
      cardColor: c.cell,
      dividerColor: c.separator,
      splashFactory: splash,
      highlightColor: ios ? c.highlight : base.highlightColor,
      // iOS push transition + swipe-back on BOTH platforms (scope back to
      // per-platform if the Android edge-swipe double-pop, #83087, bites).
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
      appBarTheme: AppBarThemeData(
        backgroundColor: c.page,
        foregroundColor: c.label,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Small bars only: SliverAppBar always passes its own height.
        toolbarHeight: AppSpace.toolbarHeight,
        centerTitle: true,
        iconTheme: IconThemeData(color: c.accent, size: 22),
        actionsIconTheme: IconThemeData(color: c.accent, size: 22),
        // No titleTextStyle on purpose (see titleLarge above).
      ),
      cardTheme: CardThemeData(
        color: c.cell,
        margin: EdgeInsets.zero,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.cell)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        barrierColor: c.scrim,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl)),
        insetPadding: const EdgeInsets.symmetric(
            horizontal: AppSpace.dialogInset, vertical: AppSpace.dialogInset),
        // iOS alert: a 17-pt semibold title (was M3's 24-pt bold) over
        // body text in the LABEL colour.
        titleTextStyle: on(text.titleLarge, c.label),
        contentTextStyle: on(text.bodyMedium, c.label),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.sheet,
        modalBackgroundColor: c.sheet,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: c.tertiaryLabel,
        dragHandleSize: const Size(36, 5),
        clipBehavior: Clip.antiAlias,
        modalBarrierColor: c.scrim,
        shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.inverseSurface,
        contentTextStyle: on(text.bodyMedium, c.onInverseSurface),
        actionTextColor: c.inversePrimary,
        elevation: 0,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.snack)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.l)),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(c.elevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.l))),
        ),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: c.elevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl)),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: c.elevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl)),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: c.cell,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        // NOTE: applyDefaults fills a field's null enabledBorder from
        // here, so a borderless cell field must also pass enabledBorder,
        // focusedBorder and disabledBorder: InputBorder.none (+ filled:
        // false), not just border: InputBorder.none.
        border: field(c.outline, 1),
        enabledBorder: field(c.outline, 1),
        focusedBorder: field(c.accent, 2),
        errorBorder: field(c.danger, 1),
        focusedErrorBorder: field(c.danger, 2),
        disabledBorder: field(c.separator, 1),
        labelStyle: on(text.bodyLarge, c.secondaryLabel),
        hintStyle: on(text.bodyLarge, c.secondaryLabel),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((s) => on(
            text.bodyLarge,
            s.contains(WidgetState.error)
                ? c.danger
                : s.contains(WidgetState.focused)
                    ? c.accent
                    : c.secondaryLabel)),
        helperStyle: on(text.bodySmall, c.secondaryLabel),
        errorStyle: on(text.bodySmall, c.danger),
        suffixStyle: on(text.bodyLarge, c.secondaryLabel),
      ),
      // Shape, size and text only: FilledButton.tonal keeps its scheme
      // colours (secondaryContainer = fill, label = accent), and the
      // pressed overlay stays M3's (onPrimary / onSecondaryContainer).
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          textStyle: WidgetStatePropertyAll(buttonStrong),
          splashFactory: splash,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor:
              WidgetStateProperty.resolveWith((s) => pressDim(s, c.accent)),
          overlayColor: transparentOverlay,
          textStyle: WidgetStatePropertyAll(buttonPlain),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12)),
          splashFactory: splash,
        ),
      ),
      // The editor's date/time pills: iOS grey capsules, no border.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          side: const WidgetStatePropertyAll(BorderSide.none),
          backgroundColor: WidgetStatePropertyAll(c.fill),
          foregroundColor: WidgetStatePropertyAll(c.label),
          iconColor: WidgetStatePropertyAll(c.secondaryLabel),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.m))),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          textStyle: WidgetStatePropertyAll(buttonPlain),
          splashFactory: splash,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor:
              WidgetStateProperty.resolveWith((s) => pressDim(s, c.accent)),
          overlayColor: transparentOverlay,
          splashFactory: splash,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        splashColor: ios ? Colors.transparent : null,
        // A square round FAB becomes a circle, the extended one a capsule.
        shape: const StadiumBorder(),
        elevation: c.isDark ? 0 : 3,
        focusElevation: c.isDark ? 0 : 3,
        hoverElevation: c.isDark ? 0 : 3,
        highlightElevation: c.isDark ? 0 : 1,
        iconSize: 22,
        extendedTextStyle: buttonStrong,
        extendedPadding: const EdgeInsets.symmetric(horizontal: 20),
        extendedSizeConstraints:
            const BoxConstraints(minHeight: 50, minWidth: 80),
      ),
      navigationBarTheme: NavigationBarThemeData(
        // 56: Flutter clamps tab labels at 1.3x (32 + 4 + 15.6 fits).
        height: AppSpace.tabBarHeight,
        backgroundColor: c.chrome,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        // No pill: iOS tab bars mark the selection with the tint alone
        // (plus the destinations' outlined → filled icon swap).
        indicatorColor: Colors.transparent,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 25,
            color: s.contains(WidgetState.selected)
                ? c.accent
                : c.secondaryLabel)),
        labelTextStyle: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? tabLabel.copyWith(
                    color: c.accent, fontWeight: FontWeight.w600)
                : tabLabel.copyWith(color: c.secondaryLabel)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.track,
        thumbColor: c.accent,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.track,
      ),
      dividerTheme: DividerThemeData(color: c.separator, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: c.secondaryLabel,
        titleTextStyle: on(text.bodyLarge, c.label),
        subtitleTextStyle: on(text.bodySmall, c.secondaryLabel),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: on(text.bodySmall, c.onInverseSurface),
      ),
    );
  }

  /// The ColorScheme over [c]: seeded, then EVERY role overridden so no
  /// seed-derived tint reaches a surface or container.
  static ColorScheme colorSchemeFor(AppColors c) {
    final dark = c.isDark;
    final onStrong = dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    return ColorScheme.fromSeed(seedColor: seed, brightness: c.brightness)
        .copyWith(
      primary: c.accent,
      onPrimary: c.onAccent,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.onAccentSoft,
      primaryFixed: c.accentSoft,
      primaryFixedDim: c.accentSoft,
      onPrimaryFixed: c.onAccentSoft,
      onPrimaryFixedVariant: c.onAccentSoft,
      secondary: c.secondaryLabel,
      onSecondary: onStrong,
      // FilledButton.tonal = an iOS grey button with an accent label.
      secondaryContainer: c.fill,
      onSecondaryContainer: c.accent,
      secondaryFixed: c.fill,
      secondaryFixedDim: c.fill,
      onSecondaryFixed: c.label,
      onSecondaryFixedVariant: c.secondaryLabel,
      tertiary: c.info,
      onTertiary: onStrong,
      tertiaryContainer: c.fill,
      onTertiaryContainer: c.info,
      tertiaryFixed: c.fill,
      tertiaryFixedDim: c.fill,
      onTertiaryFixed: c.info,
      onTertiaryFixedVariant: c.info,
      error: c.danger,
      onError: onStrong,
      errorContainer: dark ? const Color(0xFF3B1113) : const Color(0xFFFFE5E7),
      onErrorContainer:
          dark ? const Color(0xFFFFB4AE) : const Color(0xFF9B0010),
      surface: c.cell,
      onSurface: c.label,
      onSurfaceVariant: c.secondaryLabel,
      surfaceDim: dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
      surfaceBright: dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF),
      surfaceContainerLowest:
          dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      surfaceContainerLow:
          dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
      surfaceContainer:
          dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
      surfaceContainerHigh:
          dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF),
      surfaceContainerHighest:
          dark ? const Color(0xFF2C2C2E) : const Color(0xFFEEEEF0),
      outline: c.outline,
      outlineVariant: c.separator,
      inverseSurface: c.inverseSurface,
      onInverseSurface: c.onInverseSurface,
      inversePrimary: c.inversePrimary,
      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),
      surfaceTint: Colors.transparent,
    );
  }
}

/// Button styles the theme cannot express per call site.
abstract final class AppButtonStyles {
  /// iOS's red alert action: a quiet fill with a danger label (4.65:1 on
  /// the light fill, 4.94:1 in dark dialogs) — so Delete never looks like
  /// Save. For FilledButton.
  static ButtonStyle destructive(BuildContext context) {
    final c = AppColors.of(context);
    return FilledButton.styleFrom(
      backgroundColor: c.fill,
      foregroundColor: c.danger,
      textStyle: Theme.of(context).textTheme.titleMedium,
    );
  }
}
