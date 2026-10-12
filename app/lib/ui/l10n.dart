/// Localization access with an English fallback.
///
/// `context.l10n` instead of `AppLocalizations.of(context)`: widget tests
/// pump bare MaterialApps without delegates, and the ~15 existing suites
/// must keep passing untouched — a missing Localizations scope resolves to
/// English rather than throwing. Production always has the delegates, so
/// the fallback never fires there.
library;

import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';
import 'format.dart' show displayClock, friendlyHistoryDay, isoDate;
import 'meal_edit_logic.dart' show formatClock;

export '../l10n/app_localizations.dart' show AppLocalizations;

extension L10nX on BuildContext {
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      AppLocalizationsEn();

  String? get _localeName => Localizations.maybeLocaleOf(this)?.toString();

  /// Locale-aware history day label: 今天/Today, else the locale's dated
  /// weekday pattern. The pure fallback-free half lives in format.dart.
  String friendlyDay(String date, {DateTime? now}) => friendlyHistoryDay(
        date,
        now: now,
        localeName: _localeName,
        pattern: l10n.historyDayPattern,
        todayLabel: l10n.tabToday,
      );

  /// Locale-aware meal clock over the stored `%I:%M %p` string.
  String clock(String raw) => displayClock(raw, localeName: _localeName);

  /// When a photo was taken, for a screen reader: day + clock in the
  /// app's own wording (今天 20:05 / 'Today 08:05 PM'), so a grid of
  /// look-alike thumbnails can be told apart without seeing them.
  String photoTakenAt(DateTime t, {DateTime? now}) {
    final local = t.toLocal();
    return '${friendlyDay(isoDate(local), now: now)} '
        '${clock(formatClock(local))}';
  }
}

/// The switcher's choices: settings value → display name resolver.
/// 'system' follows the OS; explicit values force the app language.
Locale? localeForSetting(String appLanguage) => switch (appLanguage) {
      'en' => const Locale('en'),
      'zh' => const Locale('zh'),
      _ => null, // system
    };
