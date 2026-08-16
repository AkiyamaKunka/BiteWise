/// The daily coach notification's CONTENT — pure, so every sentence the
/// user reads on their lock screen is unit-tested (user request
/// 2026-08-06).
///
/// Reference: the Settings calorie GOAL when the user set one, otherwise
/// the typical-day median the Today screen already shows. Tone: coach —
/// motivating, concrete, and never shaming. A high day is framed as one
/// day inside a week, because a tracker that scolds gets uninstalled.
library;

/// Which number today is being measured against — the wording differs
/// ("your goal" reads as a promise you made; "your usual" as a habit).
enum CoachReference { goal, typical, none }

class CoachSummary {
  const CoachSummary({
    required this.title,
    required this.body,
    required this.eaten,
    required this.deltaKcal,
    required this.reference,
  });

  final String title;
  final String body;
  final int eaten;

  /// eaten − reference. Negative = under (a cut), positive = over.
  /// Zero when there is nothing to compare against.
  final int deltaKcal;
  final CoachReference reference;
}

/// The strings the builder needs, injected so the pure layer never imports
/// Flutter's l10n (the headless WorkManager path has no BuildContext).
class CoachStrings {
  const CoachStrings({
    required this.title,
    required this.titleYesterday,
    required this.empty,
    required this.underGoal,
    required this.underTypical,
    required this.onTarget,
    required this.overGoal,
    required this.overTypical,
    required this.noReference,
    required this.detail,
  });

  /// (kcal) → "Today: 2,180 kcal"
  final String Function(String kcal) title;

  /// (kcal) → "Yesterday: 2,180 kcal". Used when a throttled background run
  /// delivers the summary after midnight; "Today" would then name the wrong
  /// day (2026-08-16 — an Honor device ran the 30-minute job at 1–6 hour
  /// intervals, so a 23:34 slot was routinely first seen at 00:52).
  final String Function(String kcal) titleYesterday;
  final String empty;

  /// (delta) → the coach line for a day under the reference.
  final String Function(String delta) underGoal;
  final String Function(String delta) underTypical;
  final String onTarget;
  final String Function(String delta) overGoal;
  final String Function(String delta) overTypical;

  /// No goal and too few logged days for a median yet.
  final String noReference;

  /// (meals, protein) → "4 meals · 118 g protein"
  final String Function(String meals, String protein) detail;
}

/// Anything inside this band reads as "on target" — a 40 kcal miss is
/// noise in an estimate, and calling it a deficit would be theatre.
const int kOnTargetBandKcal = 100;

/// Build the notification. [goalKcal] 0/null = unset; [typicalKcal] null
/// until the median exists (≥2 prior days).
CoachSummary buildCoachSummary({
  required num eatenKcal,
  required int mealCount,
  required num proteinG,
  int? goalKcal,
  int? typicalKcal,
  required CoachStrings strings,
  required String Function(num) formatKcal,
  /// The summary covers the previous day (a late catch-up run).
  bool forYesterday = false,
}) {
  final eaten = _finite(eatenKcal).round();
  final goal = (goalKcal != null && goalKcal > 0) ? goalKcal : null;
  final typical =
      (typicalKcal != null && typicalKcal > 0) ? typicalKcal : null;
  final reference = goal ?? typical;
  final kind = goal != null
      ? CoachReference.goal
      : (typical != null ? CoachReference.typical : CoachReference.none);

  final title = (forYesterday ? strings.titleYesterday : strings.title)(
      formatKcal(eaten));

  if (mealCount <= 0) {
    return CoachSummary(
      title: title,
      body: strings.empty,
      eaten: eaten,
      deltaKcal: 0,
      reference: kind,
    );
  }

  final detail = strings.detail(
      '$mealCount', formatKcal(_finite(proteinG).round()));

  if (reference == null) {
    return CoachSummary(
      title: title,
      body: '${strings.noReference}\n$detail',
      eaten: eaten,
      deltaKcal: 0,
      reference: CoachReference.none,
    );
  }

  final delta = eaten - reference;
  final String line;
  if (delta.abs() <= kOnTargetBandKcal) {
    line = strings.onTarget;
  } else if (delta < 0) {
    final under = formatKcal(-delta);
    line = kind == CoachReference.goal
        ? strings.underGoal(under)
        : strings.underTypical(under);
  } else {
    final over = formatKcal(delta);
    line = kind == CoachReference.goal
        ? strings.overGoal(over)
        : strings.overTypical(over);
  }

  return CoachSummary(
    title: title,
    body: '$line\n$detail',
    eaten: eaten,
    deltaKcal: delta,
    reference: kind,
  );
}

/// Hostile numbers must never reach a lock screen (the same rule the rest
/// of the app follows): NaN/Infinity read as 0.
num _finite(num v) => (v is double && !v.isFinite) ? 0 : v;
