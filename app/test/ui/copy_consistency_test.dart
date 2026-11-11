/// Copy that must agree with itself (run 7, U23):
/// - the + Log sheet and the no-action reply teach the phrasing the Fix
///   screen recommends (name the food), never meal numbers — those count
///   across the last 7 days, so "meal 2" can rewrite yesterday's lunch;
/// - the API Key page's footer does not say every photo is billed right
///   under the free-tier rows;
/// - the Today empty state names Watch Camera Roll exactly as Settings
///   does, and offers the no-AI path too;
/// - plain emphasis instead of ALL CAPS in the strings that shouted.
library;

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();
  final locales = <String, AppLocalizations>{'en': en, 'zh': zh};

  final mealNumber = RegExp(
      r'\bmeal\s*\d|\bfirst meal\b|第\s*[一二三四五六七八九十\d]+\s*[餐顿]');

  test('the Log sheet and the no-action reply name the food, not a number',
      () {
    for (final MapEntry(key: tag, value: l) in locales.entries) {
      for (final text in [l.addFixFooter, l.nlNoActions]) {
        expect(mealNumber.hasMatch(text), isFalse, reason: '$tag: $text');
      }
    }
    expect(en.addFixFooter, contains('the noodles were roast duck rice'));
    expect(zh.addFixFooter, contains('那碗面其实是烧鸭饭'));
  });

  test('the provider footer does not bill every photo beside a free tier',
      () {
    expect(en.apiProviderFooter, isNot(contains('every photo')));
    expect(en.apiProviderFooter, isNot(contains('billed')));
    expect(en.apiProviderFooter, contains('free tier'));
    expect(en.apiProviderFooter, contains('stays on this phone'));
    expect(zh.apiProviderFooter, isNot(contains('每张照片都是')));
    expect(zh.apiProviderFooter, isNot(contains('按张计费')));
    expect(zh.apiProviderFooter, contains('免费额度'));
  });

  test('the Today empty state names Watch Camera Roll as Settings does', () {
    for (final MapEntry(key: tag, value: l) in locales.entries) {
      expect(l.todayEmptyHint, contains(l.settingsRowWatch), reason: tag);
      expect(l.todayEmptyHint, contains(l.fabLog), reason: tag);
    }
    expect(en.todayEmptyHint, contains('by hand'));
    expect(zh.todayEmptyHint, contains('手动输入'));
  });

  test('no ALL-CAPS emphasis in the strings that used it', () {
    final shouting = RegExp(r'\b[A-Z]{3,}\b');
    for (final text in [
      en.leftoverPickPhoto,
      en.settingsDataFooter,
      en.diagPhotoTempFail,
      en.diagPhotoPermFail,
      en.diagQuotaPaused,
      en.diagFixRecopyKey,
      en.covLimitedAccess,
      en.apiProviderFooter,
    ]) {
      final words = shouting
          .allMatches(text)
          .map((m) => m[0]!)
          .where((w) => w != 'API')
          .toList();
      expect(words, isEmpty, reason: text);
    }
  });
}
