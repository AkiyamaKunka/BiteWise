/// Copy that must agree with itself (run 7, U23):
/// - the + Log sheet and the no-action reply teach the phrasing the Fix
///   screen recommends (name the food), never meal numbers — those count
///   across the last 7 days, so "meal 2" can rewrite yesterday's lunch;
/// - the API Key page's footer does not say every photo is billed right
///   under the free-tier rows;
/// - the Today empty state names Watch Camera Roll exactly as Settings
///   does, and offers the no-AI path too;
/// - plain emphasis instead of ALL CAPS in the strings that shouted;
/// - Chinese quotes a button name or an example in corner brackets 「」,
///   never ASCII straight quotes (L7).
library;

import 'dart:convert';
import 'dart:io';

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
      for (final text in [l.addFixFooter, l.nlNoActions, l.nlCorrectionUnusable]) {
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

  // Review r171: Log all on one never-scanned photo asked "Log 1 photo?",
  // then said "Logging done (1 photos)."; the summary card read "1 logged
  // as meals · … · 1 leftover photos", and Fix with one recent meal said
  // "You have 1 recent meals."
  test('a count of one reads as one', () {
    expect(en.covDone(en.covProgLogging, 1), 'Logging done (1 photo).');
    expect(en.covDone(en.covProgLogging, 3), 'Logging done (3 photos).');
    expect(en.covLoggedAsMeals(1), '1 logged as a meal');
    expect(en.covLoggedAsMeals(0), '0 logged as meals');
    expect(en.covLoggedAsMeals(5), '5 logged as meals');
    expect(en.covLeftoverCount(1),
        '1 leftover photo (deducted from its meal)');
    expect(en.covLeftoverCount(2),
        '2 leftover photos (deducted from their meal)');
    expect(en.nlInvalidMealIndex('3', 1),
        '❌ Invalid meal index (3). You have 1 recent meal.');
    expect(en.nlInvalidMealIndex('9', 4),
        '❌ Invalid meal index (9). You have 4 recent meals.');
    // Chinese has no plural forms: unchanged.
    expect(zh.covDone('记录', 1), '记录完成（1 张照片）。');
    expect(zh.covLoggedAsMeals(1), '已记录 1 餐');
    expect(zh.covLeftoverCount(1), '1 张剩菜照片（已从原餐扣除）');
    expect(zh.nlInvalidMealIndex('3', 1), '❌ 餐次编号无效（3）。你最近有 1 顿餐。');
  });

  // Review r171: the footer shown while iCloud Backup copies nothing said
  // the meals "would not come back … on a new iPhone". The meal database
  // is in the iPhone's own backups (only the local store is excluded), so
  // a new iPhone restored from one, or given this one's data by a
  // transfer, does get them back.
  test('the iCloud Backup off footer says when a new iPhone loses the meals',
      () {
    expect(en.backupICloudFooterOff,
        startsWith('Nothing is being copied to iCloud Drive, so your meals '
            'would not come back after a reinstall, or on a new iPhone that '
            "does not get this iPhone's data from a backup or a transfer."));
    expect(zh.backupICloudFooterOff,
        startsWith('现在没有任何内容复制到 iCloud 云盘，所以重新安装筷拍后，'
            '或者在没有从这台 iPhone 的备份恢复或传输数据的新 iPhone 上，'
            '你的餐食都不会回来。'));
    // Still points to an export first (backup_settings_test).
    expect(en.backupICloudFooterOff, contains('export a file'));
    expect(zh.backupICloudFooterOff, contains('导出'));

    // The fact the copy rests on: the one folder kept out of device
    // backups is the local store, and the database lives elsewhere.
    final appDelegate =
        File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect('isExcludedFromBackup = true'.allMatches(appDelegate),
        hasLength(1));
    expect(appDelegate, contains('func prepareLocalStore('));
    expect(File('lib/data/db.dart').readAsStringSync(),
        contains(r"'${await getDatabasesPath()}/$kDatabaseFileName'"));
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

  // L7 (run 7) turned the zh ASCII quotes into 「」 in nine strings; the
  // restaurant consent's Brand only bullet (PR #19) and the Fix screen's
  // intro and hint were missed (review 2026-11-11, round 2).
  test('Chinese quotes in corner brackets, never ASCII straight quotes', () {
    final arb = jsonDecode(File('lib/l10n/app_zh.arb').readAsStringSync())
        as Map<String, dynamic>;
    final straight = [
      for (final e in arb.entries)
        if (!e.key.startsWith('@') &&
            e.value is String &&
            (e.value as String).contains('"'))
          e.key,
    ];
    expect(straight, isEmpty);
    expect(zh.restaurantConsentBrandOnly,
        startsWith('「${zh.restaurantConsentBrandOnlyButton}」'));
    expect(zh.fixIntro, contains('（「那碗面」、「早餐」、「600 千卡那个」）'));
    expect(zh.fixHint, '例如：「那碗面其实是烧鸭饭」\n或「删除刚才那杯咖啡」');
  });

  // Review r171 (2026-11-12): the check above sees only ASCII quotes, so
  // fifteen control names still sat in curly quotes — Test This Provider
  // read 「测试当前服务」 in six strings and “测试当前服务” in three, and
  // autoScanPausedBilling and errLeftoverUnsure are new on main.
  test('Chinese quotes in corner brackets, never curly quotes either', () {
    final arb = jsonDecode(File('lib/l10n/app_zh.arb').readAsStringSync())
        as Map<String, dynamic>;
    final curly = [
      for (final e in arb.entries)
        if (!e.key.startsWith('@') &&
            e.value is String &&
            (e.value as String).contains(RegExp('[“”]')))
          e.key,
    ];
    expect(curly, isEmpty);

    // Each bracketed name is the control's own label, so the two cannot
    // drift apart unnoticed.
    final fromPhotos = '「${zh.fabLog} › ${zh.addFromPhotos}」';
    expect(zh.autoScanPausedKey('9:00'), contains('「${zh.testProvider}」'));
    for (final text in [
      zh.autoScanPausedRegion('OpenAI', '9:00'),
      zh.autoScanPausedBilling('OpenAI', '9:00'),
    ]) {
      expect(text, contains('「${zh.testProvider}」'));
      expect(text, contains(fromPhotos));
    }
    expect(zh.errLeftoverUnsure, contains('「${zh.addLeftover}」'));
    expect(zh.diagVerdictOk, contains('「${zh.covAnalyzeAgain}」'));
    for (final text in [
      zh.diagTextOk,
      zh.diagTextBadDetail,
      zh.diagTextBadPhotoAlsoFailed,
    ]) {
      expect(text, contains('「${zh.addDescribe}」'));
      expect(text, contains('「${zh.addFix}」'));
    }
    expect(zh.serverLoginFooter, contains('「${zh.connectClaude}」'));
    expect(zh.outcomeRetryLaterMsg('超时'), contains('「${zh.retry}」'));
    expect(zh.diagConfidenceIntro, contains('「${zh.restaurantModeAuto}」'));
    expect(zh.diagPhotoNotFood,
        contains('「${zh.diagGlassesOutcomeNotFood}」'));
    // Labels shown with a value after them are named without it: the
    // 之前失败（3） header and the background scans' 最后一步：… line.
    expect(zh.covFailedEarlier(3), startsWith('之前失败'));
    expect(zh.covDoneFailures('重试', 1, 3), contains('「之前失败」'));
    expect(zh.diagBgRunKilled('读取照片'), contains('最后一步：'));
    expect(zh.diagBgRunsIntro, contains('「最后一步」'));
  });
}
