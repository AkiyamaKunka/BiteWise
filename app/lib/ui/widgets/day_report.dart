/// The shareable day report — one tall image ("长图") of a day's intake,
/// built for the report-to-my-coach flow (user request 2026-08-02).
///
/// Two halves:
///  * [DayReportCard] — a SYNCHRONOUSLY-painting widget (thumbnails arrive
///    as pre-decoded [ui.Image]s drawn with RawImage; no FutureBuilder, no
///    ImageProvider async) so a single offscreen frame contains everything.
///  * [renderDayReport] — lays the card out in its own detached render
///    tree (the captureFromWidget technique: RenderView + BuildOwner +
///    RenderRepaintBoundary, never touching the live tree), rasterizes at
///    [kReportPixelRatio] and returns PNG bytes.
///
/// Design: the app's own grouped-Apple language on the neutral grouped
/// background — a coach receives the same visual truth the user sees,
/// including the transparent Typical/Burn/Eaten arithmetic and the
/// portion-size assumptions in item names. The image is always light
/// (owner decision O-1) and always carries the absolute date: it is read
/// later, on someone else's phone, often after being saved or forwarded.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';

import '../../core/coerce.dart';
import '../../core/contracts.dart';
import '../format.dart';
import '../l10n.dart';
import '../meal_edit_logic.dart' show isRealIsoDate;
import '../theme/app_theme.dart';
import 'calorie_ring.dart';
import 'grouped.dart' show cellColor, kCellRadius;
import 'macro_chart.dart' show MacroPalette;

/// Logical width of the report; WeChat previews ~3:4 to very tall images
/// fine, and 420 keeps 17pt-class text comfortably readable at 3x.
const double kReportWidth = 420;
const double kReportPixelRatio = 3;

/// The report's date line: the absolute, localized date with its weekday
/// ('Fri, Oct 30, 2026' / '2026年10月30日周五'), never 'Today' (U14). The
/// share flow always reports today, so the relative label made every
/// image read 'Today' once saved or forwarded. A value that is not a real
/// ISO date is shown as stored.
String reportDateLabel(String date, {String? localeName}) {
  if (!isRealIsoDate(date)) return date;
  final parsed = DateTime.tryParse(date);
  if (parsed == null) return date;
  try {
    return DateFormat.yMMMEd(localeName).format(parsed);
  } catch (_) {
    // Date symbols for this locale never loaded (a bare test tree).
    return DateFormat.yMMMEd('en').format(parsed);
  }
}

/// One meal, resolved for synchronous painting.
class ReportMeal {
  const ReportMeal({required this.meal, this.thumb});
  final Meal meal;
  final ui.Image? thumb; // pre-decoded; null = no photo block
}

class DayReportCard extends StatelessWidget {
  const DayReportCard({
    super.key,
    required this.date,
    required this.meals,
    this.typicalKcal,
    this.burnKcal = 0,
  });

  final String date; // YYYY-MM-DD
  final List<ReportMeal> meals;
  final num? typicalKcal;
  final num burnKcal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = AppColors.of(context);
    final palette = MacroPalette.of(context);
    final l = context.l10n;
    final foodMeals =
        meals.where((m) => isFoodMeal(m.meal)).toList(growable: false);
    final totals = todayTotals([for (final m in foodMeals) m.meal]);
    final burn = burnKcal.round();
    final quiet =
        theme.textTheme.bodySmall?.copyWith(color: colors.secondaryLabel);
    return Container(
      width: kReportWidth,
      color: colors.page,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: what this is, and when.
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.reportTitle,
                        style: AppTypography.of(context)
                            .title2
                            .copyWith(color: colors.label)),
                    Text(
                        reportDateLabel(date,
                            localeName:
                                Localizations.maybeLocaleOf(context)
                                    ?.toString()),
                        key: const Key('reportDate'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: colors.secondaryLabel)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(l.kcalAmount(formatKcal(totals.cal)),
                  key: const Key('reportTotal'),
                  style: AppNumerals.of(context)
                      .large
                      .copyWith(color: colors.label)),
            ],
          ),
          const SizedBox(height: 14),
          // The hero: same ring + reconciling arithmetic the app shows.
          _cell(
            context,
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    CalorieRing(
                        eatenKcal: totals.cal,
                        typicalKcal: typicalKcal,
                        burnKcal: burn,
                        size: 116),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.reportMeals(totals.meals), style: quiet),
                          const SizedBox(height: 6),
                          if (typicalKcal != null) ...[
                            ArithmeticRow(
                                label: l.rowTypical,
                                value: '~${formatKcal(typicalKcal!)}',
                                dot: colors.tertiaryLabel),
                            if (burn > 0)
                              ArithmeticRow(
                                  label: l.rowBurn,
                                  value: '+${formatKcal(burn)}',
                                  dot: scheme.tertiary),
                          ],
                          // Eaten is a plain positive figure — the one the
                          // ring's center restates, emphasized like Today's.
                          // It used to carry a leading "−" from when the
                          // rows ended in "= left"; Today dropped that
                          // result row (intake, not a countdown —
                          // 2026-08-06) and the minus was left subtracting
                          // from nothing, so a coach read "Eaten −1,200"
                          // (testing loop 2026-10-07).
                          ArithmeticRow(
                              key: const Key('reportEatenRow'),
                              label: l.rowEaten,
                              value: formatKcal(totals.cal.round()),
                              dot: colors.accent,
                              emphasized: typicalKcal != null),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  MacroTrio(
                    proteinG: totals.protein,
                    carbsG: totals.carbs,
                    fatG: totals.fat,
                    proteinColor: palette.protein,
                    carbsColor: palette.carbs,
                    fatColor: palette.fat,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Every meal, in clock order, with its evidence.
          for (final rm in foodMeals) ...[
            _mealBlock(context, rm),
            const SizedBox(height: 10),
          ],
          if (foodMeals.isEmpty)
            _cell(
              context,
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(l.reportNoMeals,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colors.secondaryLabel)),
              ),
            ),
          const SizedBox(height: 6),
          Center(
            // secondaryLabel, not the outline grey (3.08:1 on the page).
            child: Text(l.reportFooter,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: colors.secondaryLabel)),
          ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, Widget child) => Material(
        color: cellColor(context),
        borderRadius: BorderRadius.circular(kCellRadius),
        clipBehavior: Clip.antiAlias,
        child: child,
      );

  Widget _mealBlock(BuildContext context, ReportMeal rm) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final l = context.l10n;
    final a = rm.meal.analysis;
    final items = safeFoodItems(a);
    final quiet =
        theme.textTheme.bodySmall?.copyWith(color: colors.secondaryLabel);
    return _cell(
      context,
      Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rm.thumb != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: RawImage(
                        image: rm.thumb,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(mealDescription(a, fallback: l.nlUnnamedMeal),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: colors.label)),
                ),
                const SizedBox(width: 8),
                Text(context.clock(rm.meal.time),
                    style: quiet?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '~${l.kcalAmount(displayTotalCalories(a))} · '
              '${l.macroProteinShort} ${displayMacro(a, 'total_protein_g')}g · '
              '${l.macroCarbsShort} ${displayMacro(a, 'total_carbs_g')}g · '
              '${l.macroFatShort} ${displayMacro(a, 'total_fat_g')}g',
              style: quiet,
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  // The meal cards' own item line (zh: a full-width colon).
                  child: Text(
                    '• ${l.mealItemLine('${item['name'] ?? '?'}', l.kcalAmount(displayItemCalories(item['estimated_calories'])))}',
                    style: quiet,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Rasterize [DayReportCard] in a detached render tree → PNG bytes.
///
/// The captureFromWidget technique: everything paints in ONE frame because
/// the card is synchronous by construction. Throws on failure — callers
/// surface a snackbar, never a silent nothing.
///
/// [locale] localizes the report's own labels: the detached tree has no
/// ancestor Localizations scope, so without the explicit wrapper the card
/// would silently render in fallback English even for a zh user.
///
/// The image is always LIGHT, whatever [theme] the caller passes (owner
/// decision O-1): it is read on a coach's phone in that phone's mode, and
/// a dark capture in a light chat read as a black slab. [theme] is kept so
/// callers need not change; reverting O-1 is the one line marked below.
Future<Uint8List> renderDayReport({
  required String date,
  required List<ReportMeal> meals,
  num? typicalKcal,
  num burnKcal = 0,
  ThemeData? theme,
  Locale locale = const Locale('en'),
}) async {
  // O-1. To follow the app's mode again: `theme?.brightness ?? Brightness.light`.
  const brightness = Brightness.light;
  final reportTheme =
      AppTheme.build(brightness, cjk: locale.languageCode == 'zh');
  final boundary = RenderRepaintBoundary();
  final pipelineOwner = PipelineOwner();
  final buildOwner = BuildOwner(focusManager: FocusManager());

  final renderView = RenderView(
    view: WidgetsBinding.instance.platformDispatcher.views.first,
    configuration: ViewConfiguration(
      logicalConstraints: const BoxConstraints(
          minWidth: kReportWidth,
          maxWidth: kReportWidth,
          minHeight: 0,
          maxHeight: double.infinity),
      devicePixelRatio: kReportPixelRatio,
    ),
    child: RenderPositionedBox(
        alignment: Alignment.topCenter, child: boundary),
  );
  pipelineOwner.rootNode = renderView;
  renderView.prepareInitialFrame();

  final element = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: MediaQuery(
      data: const MediaQueryData(
          size: Size(kReportWidth, 2000),
          devicePixelRatio: kReportPixelRatio),
      child: Localizations(
        locale: locale,
        delegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        child: Theme(
          data: reportTheme,
          child: DayReportCard(
              date: date,
              meals: meals,
              typicalKcal: typicalKcal,
              burnKcal: burnKcal),
        ),
      ),
    ),
  ).attachToRenderTree(buildOwner);

  buildOwner
    ..buildScope(element)
    ..finalizeTree();
  pipelineOwner
    ..flushLayout()
    ..flushCompositingBits()
    ..flushPaint();

  final image = await boundary.toImage(pixelRatio: kReportPixelRatio);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('day report: PNG encoding returned null');
    }
    return bytes.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Decode stored thumbnail bytes for synchronous painting.
Future<ui.Image?> decodeThumb(Uint8List? bytes) async {
  if (bytes == null || bytes.isEmpty) return null;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null; // a corrupt thumb must not sink the whole report
  }
}
