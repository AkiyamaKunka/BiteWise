// Settings › Your Data: what Android's own backup holds (privacy lane
// item 4), Google's health reminder on both platforms (Health Content and
// Services policy: apps remind users to consult a professional; the full
// disclaimer is for the store description).
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/backup/file_pick_channel.dart';
import 'package:calorie_tracker/ui/screens/settings/data_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_theme_harness.dart' show pumpApp;
import 'fakes.dart';

class _NoPicker implements FilePicker {
  @override
  Future<PickedFiles> pickJsonFiles() async => const PickedFiles([]);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final zh = lookupAppLocalizations(const Locale('zh'));

  Future<void> pump(WidgetTester tester,
          {String platform = 'android',
          Locale locale = const Locale('en')}) =>
      pumpApp(
          tester,
          Scaffold(
            body: ListView(children: [
              DataSection(
                dao: FakeDao(),
                onOpenPrivacyPolicy: () {},
                platform: platform,
                androidBackupNote: platform == 'android',
                filePicker: _NoPicker(),
              ),
            ]),
          ),
          locale: locale,
          size: const Size(390, 1400));

  group('the Android footer says what Android\'s backup holds', () {
    test('the log may go to the Google account; the keys do not; Save to '
        'Device is the way to move phones', () {
      final e = en.backupAndroidFooter;
      expect(e, contains('Google account'));
      expect(e, contains('not your API keys'));
      expect(e, contains('Save to Device'));
      expect(e, contains('Import merges'));
      final z = zh.backupAndroidFooter;
      expect(z, contains('Google 账户'));
      expect(z, contains('不包括 API 密钥'));
      expect(z, contains('保存到设备'));
      expect(z, contains('导入会合并'));
    });

    testWidgets('shown on Android', (tester) async {
      await pump(tester);
      expect(find.text(en.backupAndroidFooter), findsOneWidget);
    });
  });

  group('the health reminder', () {
    test('a short "not medical advice — ask a professional" line, both '
        'languages', () {
      expect(en.settingsHealthReminder,
          'Chopstats is not medical advice. For decisions about your health '
          'or diet, consult a healthcare professional.');
      expect(zh.settingsHealthReminder,
          '筷拍不提供医疗建议。涉及健康或饮食的决定，请咨询医疗专业人士。');
    });

    for (final platform in ['android', 'ios']) {
      for (final (locale, l) in [
        (const Locale('en'), en),
        (const Locale('zh'), zh),
      ]) {
        testWidgets('under Your Data on $platform (${locale.languageCode})',
            (tester) async {
          await pump(tester, platform: platform, locale: locale);
          final line = find.byKey(const Key('healthReminder'));
          expect(line, findsOneWidget);
          expect(
              find.descendant(
                  of: line, matching: find.text(l.settingsHealthReminder)),
              findsOneWidget);
          // Its own line, under the section, not inside its footer.
          expect(
              tester.getTopLeft(line).dy,
              greaterThan(tester
                  .getTopLeft(find.byKey(const Key('privacyPolicyRow')))
                  .dy));
        });
      }
    }
  });
}
