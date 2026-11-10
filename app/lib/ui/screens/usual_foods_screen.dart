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
library;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../../services/usual/usual_foods.dart';
import '../format.dart' show formatKcal;
import '../l10n.dart';
import '../large_text.dart';
import '../widgets/grouped.dart';
import '../widgets/small_spinner.dart';
import '../widgets/usual_offer_card.dart'
    show kUsualUndoSnackDuration, showUsualSnack, usualUndoPersists;

/// The Log sheet's row for this screen (in the first section, right after
/// Add from photos); the sheet pops 'usual'.
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
        builder: (ctx) => AlertDialog(
          key: const Key('usualAgainDialog'),
          scrollable: true,
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
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: groupedBackground(Theme.of(context).colorScheme),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              key: const Key('usualHiddenSheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    ctx.l10n.usualHiddenRow(hidden.length),
                    style: Theme.of(ctx)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (hidden.isNotEmpty)
                  GroupedSection(
                    separatorInset: 16,
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
                const SizedBox(height: 16),
              ],
            ),
          ),
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
      appBar: AppBar(title: Text(l.addUsual)),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(
          key: Key('usualLoading'), child: SmallSpinner(size: 24));
    }
    final list = _list;
    if (_failed || list == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.usualListFailed,
                  key: const Key('usualListFailed'),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                  key: const Key('usualRetry'),
                  onPressed: _retry,
                  child: Text(l.retry)),
            ],
          ),
        ),
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
              iconColor: theme.colorScheme.outline,
              title: l.usualHiddenRow(_hiddenCount),
              onTap: _showHidden,
            ),
          ])
        : null;
    if (around.isEmpty && more.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 8),
            child: Text(
              _hiddenCount > 0 ? l.usualAllHidden : l.usualEmpty,
              key: Key(_hiddenCount > 0 ? 'usualAllHidden' : 'usualEmpty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
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
          separatorInset: 16,
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
      padding: const EdgeInsets.only(bottom: 32),
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
/// was last logged; ⋯ holds Hide from this list.
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
    final scheme = theme.colorScheme;
    final n = meal.numbers;
    final numbers = '${l.kcalAmount(formatKcal(n.kcal))} · '
        '${l.macroProteinShort}: ${_grams(n.p)}g · '
        '${l.macroCarbsShort}: ${_grams(n.c)}g · '
        '${l.macroFatShort}: ${_grams(n.f)}g';
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    return Semantics(
      button: enabled ? true : null,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                16, isLargeText(context) ? 10 : 8, 4, isLargeText(context) ? 10 : 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meal.title, style: theme.textTheme.bodyLarge),
                      Text(numbers,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                      Text(stats, style: muted),
                    ],
                  ),
                ),
                if (logged)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.check_circle,
                        key: const Key('usualLoggedCheck'),
                        size: 20,
                        color: scheme.primary,
                        semanticLabel: l.usualLoggedLabel),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz),
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
            ),
          ),
        ),
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
    final theme = Theme.of(context);
    final title = Text(meal.title, style: theme.textTheme.bodyLarge);
    final show = TextButton(
      key: const Key('usualUnhide'),
      onPressed: onShow,
      child: Text(context.l10n.usualUnhide),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      // At large text the button goes under the title.
      child: isLargeText(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, show],
            )
          : Row(children: [Expanded(child: title), show]),
    );
  }
}
