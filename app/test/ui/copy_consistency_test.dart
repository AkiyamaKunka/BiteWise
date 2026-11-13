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
///   never ASCII straight quotes (L7) nor curly ones (review r171);
/// - review r171 also: a count of one reads as one; no provider-page
///   footer bills every photo; the iCloud-off footer does not say a new
///   iPhone always loses the meals;
/// - the support page (docs/SUPPORT.md, the store listings' support URL)
///   describes the App Store version, and what only 1.7.0 has waits in
///   docs/RELEASING.md § 12, naming the controls as the app does, saying
///   a backup holds what an export does, and naming the README's and the
///   slides' release lists by their headings.
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/data/db.dart' show kExportTables;
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

  // Review r171: U23 made the API Key page's footer neutral, but the
  // Connection type footer one screen up still said the provider "bills
  // each photo to your account", and the own-server page offered "a
  // pay-per-photo API key" — to a free-tier Gemini or GLM user too.
  test('no provider-page footer says every photo is billed', () {
    for (final text in [en.connectionTypeFooter, en.apiInactiveFooter]) {
      expect(text, isNot(contains('each photo')), reason: text);
      expect(text, isNot(contains('per-photo')), reason: text);
      expect(text, isNot(contains('bills')), reason: text);
    }
    for (final text in [zh.connectionTypeFooter, zh.apiInactiveFooter]) {
      expect(text, isNot(contains('每张照片')), reason: text);
      expect(text, isNot(contains('按张计费')), reason: text);
    }
    expect(en.connectionTypeFooter,
        startsWith('An API key stays on this phone. Some providers have a '
            'free tier; others charge your account for each request.'));
    expect(zh.connectionTypeFooter,
        startsWith('API Key 保存在这台手机上。有的服务商提供免费额度，有的按次向你的账户计费。'));
    // The own-server sentence is unchanged.
    expect(en.connectionTypeFooter,
        endsWith(' Your own server analyzes photos with the AI configured '
            'on it; this phone keeps only its address and upload key.'));
    expect(zh.connectionTypeFooter,
        endsWith('你自己的服务器用它上面配置的 AI 分析照片；这台手机只保存它的地址和上传密钥。'));
    expect(en.apiInactiveFooter,
        'Your own server is currently active. Pick a provider above to '
        'switch to an API key.');
    expect(zh.apiInactiveFooter, '当前使用的是你自己的服务器。在上方选择一家服务商即可切换为 API Key。');
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

  // Review r171: after a bulk action the Chinese snackbar read
  // 记录中完成（3 张照片） or 重试中在第 2/5 张后停止. The label is the
  // action's name said before 完成 / 停止, so in Chinese it is the verb
  // itself; and the English one sent failures to "the Failed list", which
  // the screen calls Failed earlier.
  test('the coverage snackbars name the action and the list as the screen '
      'does', () {
    expect(zh.covDone(zh.covProgLogging, 3), '记录完成（3 张照片）。');
    expect(zh.covDoneFailures(zh.covProgRetrying, 1, 3),
        '重试完成 —— 3 张中有 1 张无法处理（已保留在「之前失败」列表中以便重试）。');
    expect(zh.covStoppedLast(zh.covProgReanalyzing, 2, 5, '原因'),
        '重新分析在第 2/5 张后停止：原因');
    expect(en.covFailedEarlier(3), startsWith('Failed earlier'));
    expect(en.covDoneFailures(en.covProgRetrying, 1, 3),
        'Retrying done — 1 of 3 could not be processed (kept in the Failed '
        'earlier list for retry).');
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

  // Review r171: docs/SUPPORT.md is the support URL of both store listings
  // and describes the App Store version, 1.6.0. Its export list left out
  // activities (1.6.0's export has them), and "uninstall Chopstats; that
  // removes everything it stored on the phone" is not so: iOS can keep
  // Keychain items after an app is deleted. iCloud Backup, the pictures in
  // an export and Choose File… are 1.7.0's, so their text waits in
  // docs/RELEASING.md § 12 until 1.7.0 is in the App Store.
  group('the support page', () {
    String flat(String path) =>
        File(path).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    final support = flat('../docs/SUPPORT.md');
    final releasing = flat('../docs/RELEASING.md');
    const heading = '## 12. When 1.7.0 ships: the support page';
    // § 12 up to the next level-2 heading (" ## " once flattened).
    final s12 = () {
      final at = releasing.indexOf(heading);
      if (at < 0) return '';
      final next = releasing.indexOf(' ## ', at + heading.length);
      return releasing.substring(at, next < 0 ? releasing.length : next);
    }();

    /// The text of § 12 from [from] up to [to].
    String part(String from, String to) {
      final at = s12.indexOf(from);
      if (at < 0) return '';
      final end = s12.indexOf(to, at);
      return s12.substring(at, end < 0 ? s12.length : end);
    }

    test('lists what a 1.6.0 export holds, and what uninstalling leaves',
        () {
      expect(support, contains('workouts and activities'));
      expect(support,
          isNot(contains('that removes everything it stored on the phone')));
      expect(support,
          contains('iOS can keep API keys in the Keychain after an app is '
              'deleted'));
      expect(support,
          contains('first clear each key you entered in Settings › AI '
              'Provider'));
    });

    test('names no 1.7.0 control before 1.7.0 is in the App Store', () {
      for (final label in [
        en.backupRowICloud,
        en.backupRowDelete,
        en.importChooseFile,
      ]) {
        expect(support, isNot(contains(label)), reason: label);
      }
    });

    test('RELEASING.md § 12 holds the 1.7.0 text, with the app\'s labels',
        () {
      expect(releasing, contains(heading));
      for (final label in [
        en.backupRowICloud,
        en.backupRowDelete,
        en.backupTurnOffDelete,
        en.backupTurnOffKeep,
        en.importChooseFile,
        en.importFromClipboard,
        en.settingsRowImport,
        en.settingsRowExport,
        en.settingsSectionData,
      ]) {
        expect(s12, contains(label), reason: label);
      }
      expect(s12, contains('Uninstalling does not delete it'));
      expect(s12, contains('iCloud Drive › Chopstats'));
      expect(s12, contains('app/test/ui/copy_consistency_test.dart'));
    });

    // Review r171, second pass: step 3 said iCloud Backup copies "your
    // meals, weight, body measurements, workouts and meal pictures", right
    // under an export (step 2) that also holds activities, the fitness
    // profile and the processed-photo list. A backup copies every export
    // table (MealsDaoImpl.backupRecordTables) and the same pictures as an
    // export (BackupFileWriter.writeFull), as docs/PRIVACY.md says.
    test('§ 12 says iCloud Backup copies everything an export holds', () {
      // What the page calls each export table.
      const names = {
        'meals': 'meals',
        'photo_ingestions': 'processed photos',
        'body_weight': 'weight',
        'body_measurements': 'body measurements',
        'workouts': 'workouts',
        'activities': 'activities',
        'fitness_profile': 'fitness profile',
      };
      expect(names.keys, unorderedEquals(kExportTables),
          reason: 'a new export table needs its name here and in § 12');
      final export =
          part('2. **Export and import**', '3. **A new bullet after Export**');
      expect(export, isNotEmpty);
      for (final name in [...names.values, 'their pictures']) {
        expect(export, contains(name), reason: name);
      }
      final backup =
          part('3. **A new bullet after Export**', '4. **Delete everything**');
      expect(backup, contains('It copies everything an export holds'));
    });

    // Review r171, second pass: § 12 sent the releaser to "items 1–4" of
    // the README's release-tied lines. That list has seven, and the
    // Android release (5) and the tag under For developers (6) change with
    // 1.7.0 too, so § 12 names each list by its heading, not by numbers.
    test("§ 12 points to the README's and the slides' whole lists", () {
      expect(flat('../README.md'),
          contains('Lines tied to a release. Re-read them when a new App '
              'Store version ships:'));
      expect(flat('../docs/readme/src/README.md'),
          contains('## Slides tied to a release'));
      expect(s12, contains('*Lines tied to a release*'));
      expect(s12, contains('*Slides tied to a release*'));
      expect(s12, isNot(contains(RegExp(r'\bitems? \d'))));
    });
  });
}
