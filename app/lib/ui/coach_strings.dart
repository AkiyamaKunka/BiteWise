/// Coach-notification strings for the HEADLESS path.
///
/// The WorkManager isolate has no BuildContext, so it cannot use
/// `context.l10n`. These read the SAME generated localization classes the
/// UI uses, selected by the user's saved language preference — one source
/// of wording, two delivery paths.
library;

import 'dart:ui' show PlatformDispatcher;

import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';
import '../l10n/app_localizations_zh.dart';
import '../services/report/coach_summary.dart';

/// [appLanguage] is the persisted 'system' | 'en' | 'zh'.
CoachStrings coachStringsFor(String appLanguage) {
  final l = localizationsFor(appLanguage);
  return CoachStrings(
    title: l.coachTitle,
    titleYesterday: l.coachTitleYesterday,
    empty: l.coachEmpty,
    emptyYesterday: l.coachEmptyYesterday,
    underGoal: l.coachUnderGoal,
    underTypical: l.coachUnderTypical,
    onTarget: l.coachOnTarget,
    overGoal: l.coachOverGoal,
    overTypical: l.coachOverTypical,
    noReference: l.coachNoReference,
    detail: l.coachDetail,
  );
}

AppLocalizations localizationsFor(String appLanguage) {
  if (appLanguage == 'zh') return AppLocalizationsZh();
  if (appLanguage == 'en') return AppLocalizationsEn();
  // 'system': the background isolate still knows the platform locale, so a
  // headless notification matches the UI the user reads.
  final code = PlatformDispatcher.instance.locale.languageCode.toLowerCase();
  return code == 'zh' ? AppLocalizationsZh() : AppLocalizationsEn();
}
