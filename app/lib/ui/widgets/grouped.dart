/// Apple-style grouped inset lists — the Settings restructure's foundation.
///
/// Anatomy per Apple's HIG and the iOS Settings app (2026 pass): sections
/// are inset rounded cards on a *grouped* background, headers are quiet
/// sentence-case captions, and FOOTERS carry the helper sentence that
/// Material screens scatter as inline paragraphs. Rows are ≥44pt with a
/// 29pt icon badge, label, trailing value, and a chevron when they
/// disclose. Forms live one level down (progressive disclosure): the root
/// shows STATE, subpages hold controls.
///
/// Hand-rolled rather than CupertinoListSection so both platforms render
/// identically inside MaterialApp. Colours, type and radii come from the
/// design tokens (theme/tokens.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../large_text.dart';
import '../theme/tokens.dart';

/// Apple's ACTUAL neutral system values, not seed-derived: deriving these
/// from the clay scheme tinted every page pink (user verdict 2026-08-02).
/// Clay stays the ACCENT; surfaces are neutral — which is also exactly
/// how Apple does it (systemGroupedBackground #F2F2F7 / #000000).
/// Prefer [pageColor], which also knows when it is inside a sheet.
Color groupedBackground(ColorScheme scheme) =>
    AppColors.forBrightness(scheme.brightness).page;

/// secondarySystemGroupedBackground: the cells (#FFFFFF / #1C1C1E).
/// Prefer [cellColor], which also knows when it is inside a sheet.
Color cellBackground(ColorScheme scheme) =>
    AppColors.forBrightness(scheme.brightness).cell;

/// The page colour at [context] (the sheet colour inside a grouped sheet).
Color pageColor(BuildContext context) => AppColors.of(context).page;

/// The cell colour at [context] (#FFFFFF / #1C1C1E; inside a grouped
/// sheet #FFFFFF / #2C2C2E, so dark cells stay visible on the sheet).
Color cellColor(BuildContext context) => AppColors.of(context).cell;

/// One physical pixel: Apple's hairline separator.
double hairlineWidth(BuildContext context) =>
    1 / MediaQuery.devicePixelRatioOf(context);

/// Shared cell geometry — ONE gutter, ONE radius everywhere.
const double kGroupInset = AppSpace.gutter;
const double kCellRadius = AppRadius.cell;

/// A standalone grouped cell (hero cards, meal cards): same geometry and
/// background as a GroupedSection's cell stack, with an optional tap whose
/// highlight always clips to the cell radius.
class GroupedCard extends StatelessWidget {
  const GroupedCard({
    super.key,
    required this.child,
    this.onTap,
    this.margin = const EdgeInsets.fromLTRB(kGroupInset, 12, kGroupInset, 0),
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  /// Inside the cell, around [child] (cards use 16; MealCard keeps 12).
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final content =
        padding == EdgeInsets.zero ? child : Padding(padding: padding, child: child);
    final tap = onTap;
    Widget card = Material(
      color: colors.cell,
      borderRadius: BorderRadius.circular(kCellRadius),
      clipBehavior: Clip.antiAlias,
      child: tap == null
          ? content
          : InkWell(
              highlightColor: colors.highlight,
              onTap: () {
                HapticFeedback.selectionClick();
                tap();
              },
              child: content,
            ),
    );
    // A bare InkWell only adds a tap action: VoiceOver read a tappable
    // card (a Today meal) as static text, never 'button' (A11).
    if (tap != null) {
      card = Semantics(button: true, container: true, child: card);
    }
    return Padding(padding: margin, child: card);
  }
}

/// One inset grouped section: optional header, rounded cell stack with
/// hairline separators, optional footer. With no [children] and a
/// [footer] it renders the footer alone (an explanation under a group
/// that has no rows of its own).
class GroupedSection extends StatelessWidget {
  const GroupedSection({
    super.key,
    this.header,
    this.footer,
    this.separatorInset = AppSpace.separatorInsetBadge,
    required this.children,
  });

  final String? header;

  /// 57 aligns past an icon badge; rows WITHOUT badges pass 16 so the
  /// hairline aligns with their text (Apple's rule: label-aligned).
  final double separatorInset;

  /// Apple puts explanations UNDER the group, small and quiet — not inside
  /// rows and not as paragraphs between fields.
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hairline = hairlineWidth(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          kGroupInset, AppSpace.sectionTop, kGroupInset, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.only(
                  left: AppSpace.rowH, bottom: AppSpace.headerToCells),
              // iOS 26 dropped the all-caps footnote headers: sentence
              // case, a size up, semibold.
              child: Semantics(
                header: true,
                child: Text(
                  header!,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: colors.secondaryLabel),
                ),
              ),
            ),
          if (children.isNotEmpty)
            Material(
              color: colors.cell,
              borderRadius: BorderRadius.circular(kCellRadius),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0)
                      Padding(
                        // Separator inset aligns with the label, past the
                        // icon badge (16 + 29 + 12).
                        padding: EdgeInsets.only(left: separatorInset),
                        child: Divider(
                            height: hairline,
                            thickness: hairline,
                            color: colors.separator),
                      ),
                    children[i],
                  ],
                ],
              ),
            ),
          if (footer != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpace.footerSide,
                  children.isEmpty && header == null
                      ? 0
                      : AppSpace.cellsToFooter,
                  AppSpace.footerSide,
                  0),
              child: Text(
                footer!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.secondaryLabel),
              ),
            ),
        ],
      ),
    );
  }
}

/// The 29pt rounded-square icon badge every iOS Settings row leads with.
///
/// [color] is what the call site asked for — usually a scheme role. The
/// fill PAINTED is resolved at render time: primary → badgeBrand,
/// secondary → badgeNeutral, tertiary → badgeInfo, error → badgeDanger,
/// any other colour as passed. Dark mode's tone-80 roles put the white
/// glyph at 1.70:1; the badge tokens keep it at 3:1 or better (A9).
class RowBadge extends StatelessWidget {
  const RowBadge({super.key, required this.icon, required this.color});
  final IconData icon;
  final Color color;

  /// The fill [RowBadge] paints for [color] at [context].
  static Color fillFor(BuildContext context, Color color) {
    final scheme = Theme.of(context).colorScheme;
    final c = AppColors.of(context);
    if (color == scheme.primary) return c.badgeBrand;
    if (color == scheme.secondary) return c.badgeNeutral;
    if (color == scheme.tertiary) return c.badgeInfo;
    if (color == scheme.error) return c.badgeDanger;
    return color;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppSpace.badge,
      height: AppSpace.badge,
      decoration: BoxDecoration(
        color: fillFor(context, color),
        borderRadius: BorderRadius.circular(AppRadius.badge),
      ),
      child: Icon(icon, size: 18, color: const Color(0xFFFFFFFF)),
    );
  }
}

/// One grouped row: badge · title · value · chevron/trailing. ≥44pt,
/// selection haptic on tap (Apple's interactions are FELT, not only seen).
class GroupedRow extends StatelessWidget {
  const GroupedRow({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
    this.showChevron,
    this.destructive = false,
    this.enabled = true,
    this.linkUrl,
    this.subtitle,
  })  : child = null,
        selected = false,
        semanticsLabel = null;

  /// The row frame — padding, minimum height, press highlight, haptic,
  /// chevron and Semantics(button, selected) — around bespoke [child]
  /// content (History days, Body days, checkmark choices in a sheet).
  ///
  /// [selected] marks the row selected for screen readers and, when no
  /// [trailing] is given, shows the accent checkmark. [semanticsLabel]
  /// replaces what the content would read.
  const GroupedRow.custom({
    super.key,
    required Widget this.child,
    this.onTap,
    this.showChevron,
    this.selected = false,
    this.semanticsLabel,
    this.trailing,
    this.enabled = true,
  })  : icon = null,
        iconColor = null,
        title = '',
        value = null,
        destructive = false,
        linkUrl = null,
        subtitle = null;

  final IconData? icon;
  final Color? iconColor;
  final String title;

  /// The current state, shown where iOS shows it: right side, secondary.
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Defaults to true when [onTap] is set and no custom [trailing].
  final bool? showChevron;
  final bool destructive;
  final bool enabled;

  /// Set when the row opens a web page: screen readers announce it as a
  /// link (to this address) instead of a button.
  final Uri? linkUrl;

  /// Optional second line, 2 pt under the title (bodySmall, secondary).
  final Widget? subtitle;

  /// [GroupedRow.custom]'s content.
  final Widget? child;
  final bool selected;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final tappable = enabled && onTap != null;
    final custom = child;
    final checkmark = custom != null && selected && trailing == null;
    final chevron = showChevron ??
        (onTap != null && trailing == null && !checkmark);
    // Accessibility text sizes: the value moves UNDER the title and both
    // wrap, the way iOS Settings lays its cells out there. Side by side,
    // the value's cap plus the chevron left a 2-glyph title 77 pt at AX5,
    // so the root Settings read '后…  系统已关闭' and 'AI…  Claud…'
    // (2026-10-10, test/ui/large_text_overflow_test.dart).
    final stacked = isLargeText(context);

    final Widget body;
    if (custom != null) {
      body = semanticsLabel == null ? custom : ExcludeSemantics(child: custom);
    } else {
      final titleColor = destructive
          ? colors.danger
          : enabled
              ? colors.label
              : colors.label.withValues(alpha: 0.38);
      final titleStyle =
          theme.textTheme.bodyLarge?.copyWith(color: titleColor);
      final valueStyle =
          theme.textTheme.bodyLarge?.copyWith(color: colors.secondaryLabel);
      final sub = subtitle == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.secondaryLabel),
                child: subtitle!,
              ),
            );
      if (stacked) {
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: titleStyle),
            ?sub,
            if (value != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(value!, style: valueStyle),
              ),
          ],
        );
      } else {
        final titleText = Text(
          title,
          style: titleStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        body = Row(
          children: [
            Expanded(
              child: sub == null
                  ? titleText
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [titleText, sub],
                    ),
            ),
            if (value != null) ...[
              const SizedBox(width: 12),
              // NOT Flexible: a flex value would split the row 50/50
              // with the title and truncate "Backfill Lookback" beside
              // a five-character value. The cap keeps a runaway value
              // from crushing the title instead.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  value!,
                  style: valueStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ],
        );
      }
    }

    // A bare InkWell only adds a tap action: VoiceOver read navigation
    // rows as static text, never 'button'.
    return Semantics(
      button: tappable && linkUrl == null ? true : null,
      link: tappable && linkUrl != null ? true : null,
      linkUrl: tappable ? linkUrl : null,
      selected: custom != null && selected ? true : null,
      label: semanticsLabel,
      child: InkWell(
        onTap: !tappable
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(minHeight: AppSpace.rowMinHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.rowH),
            child: Row(
              children: [
                if (icon != null) ...[
                  RowBadge(icon: icon!, color: iconColor ?? theme.colorScheme.primary),
                  const SizedBox(width: AppSpace.badgeGap),
                ],
                // The vertical margins belong to the TEXT, as in UIKit's
                // list cells: 22 + 2 x 11 = 44 pt, and the 29-pt badge or a
                // switch sits centred in that height instead of adding its
                // own margins (badge rows would grow to 51 pt).
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        vertical:
                            stacked ? AppSpace.rowVStacked : AppSpace.rowV),
                    child: body,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
                if (checkmark) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check_rounded, size: 20, color: colors.accent),
                ],
                if (chevron) ...[
                  const SizedBox(width: 6),
                  ExcludeSemantics(
                    child: Icon(Icons.chevron_right_rounded,
                        size: 20, color: colors.tertiaryLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A grouped toggle row: iOS-style switch, haptic on change.
class GroupedToggleRow extends StatelessWidget {
  const GroupedToggleRow({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    required this.value,
    required this.onChanged,
    this.switchKey,
  });

  final IconData? icon;
  final Color? iconColor;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Key on the SWITCH itself — existing tests find toggles by key.
  final Key? switchKey;

  @override
  Widget build(BuildContext context) {
    // One screen-reader node, as SwitchListTile does: unmerged, the title
    // was one stop and an unnamed switch another, so the state was never
    // read with the name it belongs to.
    return MergeSemantics(
      child: GroupedRow(
        icon: icon,
        iconColor: iconColor,
        title: title,
        showChevron: false,
        trailing: Switch.adaptive(
          key: switchKey,
          value: value,
          onChanged: (v) {
            HapticFeedback.selectionClick();
            onChanged(v);
          },
        ),
        onTap: () => onChanged(!value),
      ),
    );
  }
}

/// Scaffold for a grouped subpage (the disclosure targets): grouped
/// background + iOS-style large-title collapsing header.
class GroupedPage extends StatelessWidget {
  const GroupedPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageColor(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          appLargeTitleBar(context, title: title),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [...children, const SizedBox(height: 32)],
            ),
          ),
        ],
      ),
    );
  }
}

/// The iOS large-title bar every tab and subpage uses: a 44-pt toolbar,
/// a 34-pt bold title under it that collapses into the toolbar on scroll,
/// the page colour at rest and the chrome colour once content scrolls
/// under it.
///
/// Flutter adds the status-bar inset to a `.large` bar ONLY when
/// collapsedHeight is null, so the inset is added here by hand — a bare 44
/// put the collapsed bar under the status bar. The expanded height follows
/// the title's own (clamped, 1.34x) text scale: 113 pt at the default size
/// (Material's default was 152). That height holds ONE title line, so the
/// title never wraps: a title too wide for the screen shrinks to fit, as a
/// wrapped second line pushed the first up under the clip ("Your own
/// server" on a 375-402 pt iPhone at large text lost half its first line).
Widget appLargeTitleBar(
  BuildContext context, {
  Key? key,
  required String title,
  List<Widget>? actions,
  Widget? leading,
}) {
  final colors = AppColors.of(context);
  final top = MediaQuery.paddingOf(context).top;
  final titleScale =
      (MediaQuery.textScalerOf(context).scale(34) / 34).clamp(1.0, 1.34);
  return SliverAppBar.large(
    key: key,
    title: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(title, maxLines: 1, softWrap: false)),
    leading: leading,
    actions: actions,
    toolbarHeight: AppSpace.toolbarHeight,
    collapsedHeight: top + AppSpace.toolbarHeight,
    expandedHeight: AppSpace.toolbarHeight + 28 + 41 * titleScale,
    backgroundColor: WidgetStateColor.resolveWith((states) =>
        states.contains(WidgetState.scrolledUnder)
            ? colors.chrome
            : colors.page),
    surfaceTintColor: Colors.transparent,
    scrolledUnderElevation: 0,
  );
}

/// A modal sheet in the grouped style: the theme's handle and sheet
/// colour, a title2 heading, and [builder]'s content on in-sheet cells
/// (#FFFFFF light / #2C2C2E dark, so a dark sheet's rows stay visible).
/// Scrolls when taller than the screen; lifts above the keyboard.
Future<T?> showGroupedSheet<T>(
  BuildContext context, {
  String? title,
  String? subtitle,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  RouteSettings? routeSettings,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: true,
      routeSettings: routeSettings,
      builder: (context) => GroupedSheet(
        title: title,
        subtitle: subtitle,
        children: [Builder(builder: builder)],
      ),
    );

/// The body of a grouped sheet (see [showGroupedSheet]). [children] see
/// the in-sheet colours ([AppColors.inSheet]), so GroupedSection and
/// GroupedCard draw sheet cells inside it.
class GroupedSheet extends StatelessWidget {
  const GroupedSheet({
    super.key,
    this.title,
    this.subtitle,
    required this.children,
  });
  final String? title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final type = AppTypography.of(context);
    final inSheet = colors.inSheet();
    return Padding(
      // The keyboard: the sheet's content rises above it.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Semantics(
                    header: true,
                    child: Text(title!,
                        style: type.title2.copyWith(color: colors.label)),
                  ),
                ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(subtitle!,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: colors.secondaryLabel)),
                ),
              Theme(
                data: theme.copyWith(extensions: [
                  ...theme.extensions.values
                      .where((e) => e is! AppColors),
                  inSheet,
                ]),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
