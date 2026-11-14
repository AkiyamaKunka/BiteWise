/// Display formatting for dates and times (L2). DISPLAY ONLY: storage
/// keeps ISO dates ('2026-10-29'), the meal clock ('%I:%M %p') and the
/// report time ('HH:mm') exactly as they are.
///
/// Before run 7 the app showed about five formats side by side: ISO dates
/// in Body, the editor and the sheets ('2026-10-3 / 0' at large text),
/// raw '21:30' in Settings next to '09:30 PM' meal times, and nothing
/// honoured the device's 24-Hour Time switch.
///
/// Meal times keep `context.clock` (format.dart displayClock), which since
/// the Android push follows the same 24-Hour Time switch: '4:56 AM' or
/// '04:56' in English, 24-hour in Chinese.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'meal_edit_logic.dart' show isRealIsoDate;

abstract final class AppFormats {
  static String? _localeName(BuildContext context) =>
      Localizations.maybeLocaleOf(context)?.toString();

  static bool _zh(BuildContext context) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh';

  /// A time of day the iOS way: English follows the device's 24-Hour Time
  /// switch ('9:30 PM' / '21:30'); Chinese is always 24-hour ('21:30'),
  /// like the meal times beside it.
  static String time(BuildContext context, TimeOfDay t) =>
      MaterialLocalizations.of(context).formatTimeOfDay(t,
          alwaysUse24HourFormat:
              _zh(context) || MediaQuery.alwaysUse24HourFormatOf(context));

  /// [time] over a stored 'HH:mm' string (the report time); anything
  /// unparseable is shown as stored.
  static String hm(BuildContext context, String hhmm) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
    if (m == null) return hhmm;
    final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
    if (h > 23 || min > 59) return hhmm;
    return time(context, TimeOfDay(hour: h, minute: min));
  }

  /// A short date: 'Oct 29' / '10月29日' (DateFormat.MMMd), with the year
  /// when it is not this year ('Oct 29, 2025' / '2025年10月29日') so an old
  /// entry is never mistaken for a recent one. A value that is not a real
  /// ISO date is shown as stored (poison rows degrade, never throw).
  static String shortDate(BuildContext context, String iso, {DateTime? now}) {
    if (!isRealIsoDate(iso)) return iso;
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final sameYear = d.year == (now ?? DateTime.now()).year;
    final locale = _localeName(context);
    try {
      return (sameYear ? DateFormat.MMMd(locale) : DateFormat.yMMMd(locale))
          .format(d);
    } catch (_) {
      // A locale whose date symbols were never loaded (no localization
      // delegates): English rather than a crash.
      return (sameYear ? DateFormat.MMMd('en') : DateFormat.yMMMd('en'))
          .format(d);
    }
  }
}
