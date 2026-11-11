/// Log › My usual foods (usual foods §4): the meals the user logged on at
/// least 2 of the last 90 days, the ones usually had around this time
/// first. One tap logs that meal again, now, with the numbers it had (the
/// user's own where they set them): zero AI calls, nothing sent, so no AI
/// consent is asked, as for Enter manually. The snackbar has Undo.
///
/// Before a log, a similar meal logged in the last 3 h (say the watcher
/// saved a photo of it) asks "Log it again?" first; that check reads the
/// meals fresh at the tap. Hide from this list takes a meal off it (with
/// Undo), and Hidden foods (n) shows it again.
///
/// The list is worked out once on open (UsualFoods.invalidate: a
/// background save bumps no signal) and does not reorder while open.
///
/// Drawn with run 7's kit (theme/tokens.dart, widgets/grouped.dart,
/// widgets/states.dart): grouped rows on the page colour, the shared
/// loading, failure and empty states, and the app's alert dialog.
library;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../services/usual/usual_foods.dart';
import '../format.dart' show formatKcal;
import '../l10n.dart';
import '../large_text.dart';
import '../theme/app_dialog.dart';
import '../theme/tokens.dart';
import '../widgets/grouped.dart';
import '../widgets/states.dart';
import '../widgets/usual_offer_card.dart'
    show kUsualUndoSnackDuration, showUsualSnack, usualUndoPersists;

/// The Log sheet's row for this screen (in the first section, right after
/// Add from photos); the sheet pops 'usual'. Its badge is the neutral grey
/// (badgeNeutral) of the sheet's other plain ways in: run 7 keeps the
/// brand for photos and indigo for Fix.
GroupedRow usualFoodsRow(BuildContext ctx) => GroupedRow(
      key: const Key('addUsual'),
      icon: Icons.history,
      iconColor: Theme.of(ctx).colorScheme.secondary,
      title: ctx.l10n.addUsual,
      value: ctx.l10n.addManualNote,
      onTap: () => Navigator.of(ctx).pop('usual'),
    );

class UsualFoodsScreen extends StatefulWidget {
  const UsualFoodsScreen({super.key, required this.usual, this.now});

  final UsualFoods usual;

  /// The clock the day labels read; null is the device's (tests inject).
  final DateTime Function()? now;

  @override
  State<UsualFoodsScreen> createState() => _UsualFoodsScreenState();
}

class _UsualFoodsScreenState extends State<UsualFoodsScreen> {
  UsualList? _list;
  bool _loading = true;
  bool _failed = false;

  /// A log (with its "Log it again?" check) is running: every row waits,
  /// so a double tap logs once.
  bool _saving = false;

  /// Meals logged since the screen opened: their rows show a check.
  final Set<String> _logged = {};

  /// Meals hidden since the list was read, and how many listed meals are
  /// hidden in all.
  final Set<String> _hidden = {};
  int _hiddenCount = 0;

  @override
  void initState() {
    super.initState();
    // Fresh on every open: a photo the background run saved bumps no
    // signal (M1).
    widget.usual.invalidate();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.usual.frequentMeals();
      if (!mounted) return;
      setState(() {
        _list = list;
        _hidden.clear();
        _hiddenCount = list.hiddenCount;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    _load();
  }

  DateTime _now() => (widget.now ?? DateTime.now)();

  // ── One tap ──

  Future<void> _log(UsualMeal m) async {
    if (_saving) return;
    final usual = widget.usual;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      Meal? recent;
      try {
        recent = await usual.loggedRecently(m);
      } catch (_) {
        recent = null; // unsure: a failed read never blocks the log
      }
      if (!mounted) return;
      if (recent != null && await _confirmAgain(recent) != true) return;
      if (!mounted) return;
      final UsualLogResult? done;
      try {
        done = await usual.logAgain(m);
      } catch (_) {
        showUsualSnack(
            messenger,
            SnackBar(
                key: const Key('usualLogFailed'),
                content: Text(l.usualLogFailed)));
        return;
      }
      if (done == null) return; // another log was still running
      if (mounted) setState(() => _logged.add(m.key));
      showUsualSnack(messenger, SnackBar(
        key: const Key('usualLoggedSnack'),
        duration: kUsualUndoSnackDuration,
        persist: usualUndoPersists(messenger),
        content: Text(l.usualLoggedSnack(done.title, formatKcal(done.kcal))),
        action: SnackBarAction(
          label: l.assistUndo,
          onPressed: () async {
            var undone = false;
            try {
              undone = await usual.undoLog(done!);
            } catch (_) {}
            if (undone) {
              if (mounted) setState(() => _logged.remove(m.key));
            } else {
              showUsualSnack(
                  messenger,
                  SnackBar(
                      key: const Key('usualUndoStale'),
                      content: Text(l.usualUndoStale)));
            }
          },
        ),
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// "Log it again?" over [recent], a similar meal of the last 3 h.
  Future<bool?> _confirmAgain(Meal recent) => showDialog<bool>(
        context: context,
        builder: (ctx) => appAlertDialog(
          key: const Key('usualAgainDialog'),
          title: Text(ctx.l10n.usualAgainTitle),
          content: Text(ctx.l10n.usualAgainBody(
              usualMealTitle(recent.analysis), ctx.clock(recent.time))),
          actions: [
            TextButton(
                key: const Key('usualAgainCancel'),
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(ctx.l10n.cancel)),
            FilledButton(
                key: const Key('usualAgainConfirm'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(ctx.l10n.usualAgainConfirm)),
          ],
        ),
      );

  // ── Hiding ──

  Future<void> _hide(UsualMeal m) async {
    final usual = widget.usual;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await usual.hide(m);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      if (_hidden.add(m.key)) _hiddenCount++;
    });
    showUsualSnack(messenger, SnackBar(
      key: const Key('usualHiddenSnack'),
      duration: kUsualUndoSnackDuration,
      persist: usualUndoPersists(messenger),
      content: Text(l.usualHiddenSnack),
      action: SnackBarAction(
        label: l.assistUndo,
        onPressed: () async {
          try {
            await usual.unhide(m);
          } catch (_) {
            return;
          }
          if (mounted) {
            setState(() {
              if (_hidden.remove(m.key)) _hiddenCount--;
            });
          }
        },
      ),
    ));
  }

  /// Hidden foods (n): the hidden meals still in the last 90 days, each
  /// with Show again. The list is read again once it closes.
  Future<void> _showHidden() async {
    final usual = widget.usual;
    List<UsualMeal> hidden;
    try {
      hidden = await usual.hiddenMeals();
    } catch (_) {
      hidden = const [];
    }
    if (!mounted) return;
    var changed = false;
    // showGroupedSheet's title is fixed when the sheet opens, and this one
    // counts the meals still hidden, so the route builds the same
    // GroupedSheet itself (as Body's log sheet does).
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => GroupedSheet(
          key: const Key('usualHiddenSheet'),
          title: ctx.l10n.usualHiddenRow(hidden.length),
          children: [
            if (hidden.isNotEmpty)
              GroupedSection(
                separatorInset: AppSpace.separatorInset,
                children: [
                  for (final m in hidden)
                    _HiddenRow(
                      key: ValueKey('usualHidden:${m.key}'),
                      meal: m,
                      onShow: () async {
                        try {
                          await usual.unhide(m);
                        } catch (_) {
                          return;
                        }
                        changed = true;
                        setSheet(() => hidden = [
                              for (final h in hidden)
                                if (h.key != m.key) h,
                            ]);
                        if (hidden.isEmpty && ctx.mounted) {
                          Navigator.of(ctx).pop();
                        }
                      },
                    ),
                ],
              ),
          ],
        ),
      ),
    );
    if (!changed || !mounted) return;
    await _load();
  }

  // ── The screen ──

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: pageColor(context),
      appBar: AppBar(title: Text(l.addUsual)),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    if (_loading) return const LoadingState(key: Key('usualLoading'));
    final list = _list;
    if (_failed || list == null) {
      return ListView(
        padding: const EdgeInsets.only(bottom: AppSpace.s32),
        children: [
          InlineError(
            key: const Key('usualListFailed'),
            message: l.usualListFailed,
            onRetry: _retry,
            retryKey: const Key('usualRetry'),
          ),
        ],
      );
    }
    final around = [
      for (final m in list.around)
        if (!_hidden.contains(m.key)) m,
    ];
    final more = [
      for (final m in list.more)
        if (!_hidden.contains(m.key)) m,
    ];
    final hiddenRow = _hiddenCount > 0
        ? GroupedSection(children: [
            GroupedRow(
              key: const Key('usualHiddenRow'),
              icon: Icons.visibility_off_outlined,
              iconColor: theme.colorScheme.secondary,
              title: l.usualHiddenRow(_hiddenCount),
              onTap: _showHidden,
            ),
          ])
        : null;
    if (around.isEmpty && more.isEmpty) {
      final allHidden = _hiddenCount > 0;
      return ListView(
        padding: const EdgeInsets.only(bottom: AppSpace.s32),
        children: [
          EmptyState(
            key: Key(allHidden ? 'usualAllHidden' : 'usualEmpty'),
            icon: allHidden
                ? Icons.visibility_off_rounded
                : Icons.history_rounded,
            title: allHidden ? l.usualAllHidden : l.usualEmpty,
          ),
          ?hiddenRow,
        ],
      );
    }
    Widget rows(List<UsualMeal> meals) => GroupedSection(
          header: identical(meals, around)
              ? l.usualNowHeader
              : (around.isNotEmpty ? l.usualMoreHeader : null),
          footer: identical(meals, more) || more.isEmpty
              ? l.usualScreenHint
              : null,
          separatorInset: AppSpace.separatorInset,
          children: [
            for (final m in meals)
              _UsualRow(
                key: ValueKey('usualRow:${m.key}'),
                meal: m,
                enabled: !_saving,
                logged: _logged.contains(m.key),
                stats: m.loggedTodayTime != null
                    ? l.usualLoggedToday(context.clock(m.loggedTodayTime!))
                    : l.usualRowStats(
                        m.days90, context.friendlyDay(m.lastDate, now: _now())),
                onTap: () => _log(m),
                onHide: () => _hide(m),
              ),
          ],
        );
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpace.s32),
      children: [
        if (around.isNotEmpty) rows(around),
        if (more.isNotEmpty) rows(more),
        ?hiddenRow,
      ],
    );
  }
}

/// Grams as the meal card writes them: whole, else to 0.1 g.
String _grams(num v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// One meal: its title, the numbers a log writes, how often and when it
/// was last logged; ⋯ holds Hide from this list. A tap logs it (no
/// chevron: nothing opens).
class _UsualRow extends StatelessWidget {
  const _UsualRow({
    super.key,
    required this.meal,
    required this.enabled,
    required this.logged,
    required this.stats,
    required this.onTap,
    required this.onHide,
  });

  final UsualMeal meal;
  final bool enabled;
  final bool logged;
  final String stats;
  final VoidCallback onTap;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final colors = context.colors;
    final n = meal.numbers;
    final numbers = '${l.kcalAmount(formatKcal(n.kcal))} · '
        '${l.macroProteinShort}: ${_grams(n.p)}g · '
        '${l.macroCarbsShort}: ${_grams(n.c)}g · '
        '${l.macroFatShort}: ${_grams(n.f)}g';
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (logged)
          Icon(Icons.check_circle,
              key: const Key('usualLoggedCheck'),
              size: 20,
              color: colors.accent,
              semanticLabel: l.usualLoggedLabel),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz),
          // The theme's icon-button look (accent, dimmed while pressed
          // on iOS), as the app's other icon buttons: the menu button
          // hands its IconButton a colour of its own (black87 or white),
          // which would win over the theme.
          style: theme.iconButtonTheme.style,
          tooltip: l.usualMoreActions,
          enabled: enabled,
          onSelected: (_) => onHide(),
          itemBuilder: (_) => [
            PopupMenuItem<String>(
              key: const Key('usualHide'),
              value: 'hide',
              child: Text(l.usualHide),
            ),
          ],
        ),
      ],
    );
    // At large text the check and ⋯ go under the words, as History's day
    // value and the Hidden foods row's Show again do: beside them they
    // took 20 to 34 pt from a 256-pt column on a 320-pt phone, and at AX5
    // 'Avocado', 'Spaghetti' and 'Pepperoni' broke inside the word.
    final stacked = isLargeText(context);
    return GroupedRow.custom(
      onTap: onTap,
      enabled: enabled,
      showChevron: false,
      trailing: stacked ? null : actions,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meal.title,
              style: theme.textTheme.bodyLarge?.copyWith(color: colors.label)),
          const SizedBox(height: AppSpace.s2),
          Text(numbers,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: colors.secondaryLabel)),
          Text(stats,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.secondaryLabel)),
          if (stacked) actions,
        ],
      ),
    );
  }
}

/// A hidden meal in the Hidden foods sheet, with Show again.
class _HiddenRow extends StatelessWidget {
  const _HiddenRow({super.key, required this.meal, required this.onShow});

  final UsualMeal meal;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final title = Text(meal.title,
        style: Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(color: context.colors.label));
    final show = TextButton(
      key: const Key('usualUnhide'),
      onPressed: onShow,
      child: Text(context.l10n.usualUnhide),
    );
    // At large text the button goes under the title.
    final stacked = isLargeText(context);
    return GroupedRow.custom(
      trailing: stacked ? null : show,
      child: stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, show],
            )
          : title,
    );
  }
}
