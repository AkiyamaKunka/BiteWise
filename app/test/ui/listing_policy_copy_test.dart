/// Copy outside the app that must follow the app (review r171, second
/// pass):
/// - the zh App Store listing (ios/store/metadata/zh-Hans) quotes nothing
///   in ASCII straight quotes, and names the app's controls in 「」 as
///   app_zh.arb spells them (README.zh-CN rule 1). Its examples sit in
///   “”, as README.zh-CN's do. The owner pastes this text into App Store
///   Connect, so a fix here has to be pasted there too.
library;

import 'dart:io';

import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final zh = AppLocalizationsZh();

  group('the zh App Store listing', () {
    final dir = Directory('ios/store/metadata/zh-Hans');
    final description =
        File('${dir.path}/description.txt').readAsStringSync();

    test('quotes nothing in ASCII straight quotes', () {
      final files = dir.listSync().whereType<File>().toList();
      expect(files, isNotEmpty);
      for (final f in files) {
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
}
