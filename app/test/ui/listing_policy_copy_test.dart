/// Copy outside the app that must follow the app (review r171, second
/// pass):
/// - the zh App Store listing (ios/store/metadata/zh-Hans) quotes nothing
///   in ASCII straight quotes, and names the app's controls in 「」 as
///   app_zh.arb spells them (README.zh-CN rule 1). Its examples sit in
///   “” as README.zh-CN's do, except the typed fix on line 6, which sits
///   in 「」 as README.zh-CN's typed fixes do (the app and the policy's
///   中文 half quote every example in 「」; one style for all of them is
///   still the owner's to pick). The owner pastes this text into App
///   Store Connect, so a fix here has to be pasted there too.
/// - the privacy policy (docs/PRIVACY.md) lists everything an export holds
///   in both halves, says what uninstalling leaves in the iOS Keychain as
///   docs/SUPPORT.md does, and its 中文 half names controls in 「」 with no
///   ASCII straight quotes. release_decisions_test pins its effective date.
library;

import 'dart:io';

import 'package:calorie_tracker/data/db.dart' show kExportTables;
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/store_listing_files.dart';

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();

  group('the zh App Store listing', () {
    final dir = Directory('ios/store/metadata/zh-Hans');
    final description =
        File('${dir.path}/description.txt').readAsStringSync();

    test('quotes nothing in ASCII straight quotes', () {
      final files = storeListingFiles(dir);
      expect(files, isNotEmpty);
      for (final f in files) {
        expect(f.readAsStringSync(), isNot(contains('"')), reason: f.path);
      }
    });

    // Review r171, second pass: the check above read every file in the
    // folder, so on a checkout with Finder's .DS_Store (git-ignored) it
    // failed to decode it, and the description.txt.orig git mergetool
    // leaves after a conflict failed it on the old quotes. CI's checkout
    // has neither.
    test('reads the listing files only, not what Finder, an editor or a '
        'merge leaves beside them', () {
      final tmp = Directory.systemTemp.createTempSync('listing_files_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final locale = Directory('${tmp.path}/zh-Hans')..createSync();
      // A .DS_Store header (Bud1), then bytes that are not UTF-8.
      const binary = [0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31, 0xff, 0xfe, 0x80];
      for (final d in [tmp, locale]) {
        File('${d.path}/description.txt').writeAsStringSync('例如“素食”');
        File('${d.path}/description.txt.orig').writeAsStringSync('例如"素食"');
        File('${d.path}/description.txt~').writeAsStringSync('例如"素食"');
        for (final name in [
          '.DS_Store',
          '._description.txt',
          '.description.txt.swp',
        ]) {
          File('${d.path}/$name').writeAsBytesSync(binary);
        }
      }
      String rel(File f) => f.path.substring(tmp.path.length + 1);
      expect(storeListingFiles(locale).map(rel), ['zh-Hans/description.txt']);
      final all = storeListingFiles(tmp, recursive: true);
      expect(all.map(rel),
          unorderedEquals(['description.txt', 'zh-Hans/description.txt']));
      for (final f in all) {
        expect(f.readAsStringSync(), isNot(contains('"')), reason: f.path);
      }
    });

    test('names the controls in 「」, as the app does', () {
      // Apple's Photos app, then Settings' Watch Camera Roll row, twice,
      // and the Restaurant nutrition section.
      expect(description, contains('从「照片」应用分享进来'));
      expect('「${zh.settingsRowWatch}」'.allMatches(description),
          hasLength(2));
      expect(description,
          contains('唯一的例外是「${zh.settingsSectionRestaurant}」'));
    });

    test('quotes its examples in “”', () {
      for (final example in [
        '米饭（~150 克）',
        '一碗牛肉面加一个鸡蛋',
        'two eggs and toast with butter',
        '素食',
        '家常菜，少油',
      ]) {
        expect(description, contains('“$example”'), reason: example);
      }
    });
  });

  group('the privacy policy', () {
    final policy = File('../docs/PRIVACY.md').readAsStringSync();
    final enHalf = policy.substring(0, policy.indexOf('## 中文'));
    final zhHalf = policy.substring(policy.indexOf('## 中文'));
    String flat(String text) => text.replaceAll(RegExp(r'\s+'), ' ');

    /// [half] from [heading] up to the next level-3 heading, flattened.
    String section(String half, String heading) {
      final at = half.indexOf(heading);
      if (at < 0) return '';
      final end = half.indexOf('\n### ', at + heading.length);
      return flat(half.substring(at, end < 0 ? half.length : end));
    }

    // Review r171: the export bullet left out activities, which every
    // export holds (BackupFileWriter.writeFull writes each kExportTables
    // table) and the iCloud Backup section lists.
    test('lists everything an export holds, in English and 中文', () {
      // What each half calls each export table.
      const enNames = {
        'meals': 'meals',
        'photo_ingestions': 'the processed-photo list',
        'body_weight': 'weight',
        'body_measurements': 'body measurements',
        'workouts': 'workouts',
        'activities': 'activities',
        'fitness_profile': 'fitness profile',
      };
      const zhNames = {
        'meals': '餐食',
        'photo_ingestions': '已处理照片列表',
        'body_weight': '体重',
        'body_measurements': '身体围度',
        'workouts': '运动记录',
        'activities': '活动',
        'fitness_profile': '健身档案',
      };
      for (final names in [enNames, zhNames]) {
        expect(names.keys, unorderedEquals(kExportTables),
            reason: 'a new export table needs its name here and in the '
                'policy');
      }
      final enExport = section(enHalf, '### Export, import and backups');
      final zhExport = section(zhHalf, '### 导出、导入与备份');
      for (final name in [...enNames.values, 'the meal pictures']) {
        expect(enExport, contains(name), reason: name);
      }
      for (final name in [...zhNames.values, '餐食图片']) {
        expect(zhExport, contains(name), reason: name);
      }
      // The records on the phone, the first bullet of the policy.
      expect(section(enHalf, '### What stays on your phone'),
          contains('workouts, activities and fitness profile'));
      expect(section(zhHalf, '### 留在你手机上的数据'),
          contains('运动记录、活动和健身档案'));
    });

    // Review r171: "uninstall the app to delete everything it stored on
    // the phone" is not so on iPhone, where Keychain items can outlive the
    // app; docs/SUPPORT.md already says how to remove the keys first.
    test('says uninstalling can leave API keys in the Keychain, in English '
        'and 中文', () {
      final enDelete = section(enHalf, '### Deleting your data');
      final zhDelete = section(zhHalf, '### 删除数据');
      expect(enDelete, isNot(contains('everything it stored on the phone')));
      expect(zhDelete, isNot(contains('保存的全部数据')));
      expect(
          enDelete,
          contains('iOS can keep API keys in the Keychain after an app is '
              'deleted, so to remove them too, first clear each key you '
              'entered in Settings › ${en.settingsRowAiProvider} (and the '
              '**${en.serverUploadKeyLabel}** under *${en.subPageTitle}*).'));
      expect(
          zhDelete,
          contains('iOS 可能会在应用删除后仍把 API Key 留在钥匙串中，所以如果也要'
              '删除它们，请先在 设置 › ${zh.settingsRowAiProvider} 里清除你填写的'
              '每一个 Key（以及「${zh.subPageTitle}」里的'
              '「**${zh.serverUploadKeyLabel}**」）。'));
    });

    // Review r171: four terms in the 中文 half sat in ASCII straight
    // quotes; two of them are controls, now named as the app names them.
    test('the 中文 half quotes nothing in ASCII straight quotes, and names '
        'the controls as the app does', () {
      expect(zhHalf, isNot(contains('"')));
      expect(flat(zhHalf), contains('你用「${zh.assistNotRestaurant}」标记过的地点'));
      expect(flat(zhHalf), contains('用于「${zh.tabToday}」页面'));
      // The English half names the same control.
      expect(flat(enHalf),
          contains('the spots you marked as "${en.assistNotRestaurant}"'));
    });
  });
}
