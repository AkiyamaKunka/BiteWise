/// The owner's first-submission decisions (2026-10-29, docs/RELEASING.md
/// "First submission — owner steps in order"), pinned where they live in
/// files rather than in widgets:
///
/// - R-F8: App Privacy answer B — Photos or Videos, Health and Other User
///   Content, App Functionality only, not linked, no tracking — mirrored in
///   the app's privacy manifest; the share extension declares nothing.
/// - R-F14: docs/SUPPORT.md is the support URL: iPhone-only, and its one
///   email address is the one the owner chose (2026-10-29).
/// - R-F11: the English strings carry no Chinese text and no
///   mainland-China / VPN advice.
/// - R-F9: the English name is Chopstats everywhere (renamed from BiteWise
///   2026-10-29); 筷拍 in Chinese.
/// - R-F7: the privacy policy's third-party and consent section.
/// - Google Play (2026-11-13, docs/RELEASING.md § 6): the listing pack in
///   app/android/store/ within Play's limits and with Google's health
///   disclaimer, the graphics Play accepts, the What's new texts, the
///   themed icon and the Android 12+ splash, release.yml's play_track and
///   its v*-only tag trigger (decision 4: android-v* tags start no run),
///   CI builds that never use the Aliyun mirrors (C44), § 6's corrected
///   answers, and the policy's "Who we are".
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart'
    show kApiKeyChoices, kKnownModels, modelChoiceLabel, noteLabel;
import 'package:calorie_tracker/ui/theme/tokens.dart' show AppColors;
import 'package:flutter_test/flutter_test.dart';

import 'support/store_listing_files.dart';

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

String _read(String pathFromApp) =>
    File('${_appRoot().path}/$pathFromApp').readAsStringSync();

String _readRepo(String pathFromRepo) =>
    File('${_appRoot().parent.path}/$pathFromRepo').readAsStringSync();

/// A small XML property-list reader (dict, array, key, string, integer,
/// real, true, false; comments skipped) — enough for the manifests, and
/// runs where `plutil` does not (the Linux CI).
Object? parsePlist(String xml) => _PlistReader(xml).document();

class _PlistReader {
  _PlistReader(String xml) {
    final body = xml
        .replaceAll(RegExp(r'<\?xml[^>]*\?>'), '')
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>'), '')
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    for (final m in RegExp(
      r'<(/?)([A-Za-z]+)[^>]*?(/?)>|([^<]+)',
    ).allMatches(body)) {
      if (m.group(4) != null) {
        _tokens.add(('text', m.group(4)!));
      } else if (m.group(1) == '/') {
        _tokens.add(('close', m.group(2)!));
      } else if (m.group(3) == '/') {
        _tokens.add(('empty', m.group(2)!));
      } else {
        _tokens.add(('open', m.group(2)!));
      }
    }
  }

  final List<(String, String)> _tokens = [];
  int _i = 0;

  void _skipSpace() {
    while (_i < _tokens.length &&
        _tokens[_i].$1 == 'text' &&
        _tokens[_i].$2.trim().isEmpty) {
      _i++;
    }
  }

  (String, String) _peek() {
    _skipSpace();
    return _tokens[_i];
  }

  (String, String) _next() {
    _skipSpace();
    return _tokens[_i++];
  }

  String _textUntil(String tag) {
    final buf = StringBuffer();
    while (_tokens[_i].$1 == 'text') {
      buf.write(_tokens[_i++].$2);
    }
    final close = _tokens[_i++];
    if (close != ('close', tag)) throw FormatException('want </$tag>: $close');
    return buf
        .toString()
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  Object? document() {
    final open = _next();
    if (open != ('open', 'plist')) throw FormatException('no <plist>: $open');
    final value = _value();
    if (_next() != ('close', 'plist')) throw const FormatException('</plist>');
    _skipSpace();
    if (_i != _tokens.length) throw const FormatException('trailing content');
    return value;
  }

  Object? _value() {
    final (kind, tag) = _next();
    if (kind == 'empty') {
      return switch (tag) {
        'true' => true,
        'false' => false,
        'array' => <Object?>[],
        'dict' => <String, Object?>{},
        'string' => '',
        _ => throw FormatException('<$tag/>'),
      };
    }
    if (kind != 'open') throw FormatException('unexpected $kind $tag');
    switch (tag) {
      case 'dict':
        final map = <String, Object?>{};
        while (_peek() != ('close', 'dict')) {
          if (_next() != ('open', 'key')) throw const FormatException('<key>');
          final key = _textUntil('key');
          if (map.containsKey(key)) throw FormatException('duplicate $key');
          map[key] = _value();
        }
        _next();
        return map;
      case 'array':
        final list = <Object?>[];
        while (_peek() != ('close', 'array')) {
          list.add(_value());
        }
        _next();
        return list;
      case 'string':
        return _textUntil('string');
      case 'integer':
        return int.parse(_textUntil('integer').trim());
      case 'real':
        return double.parse(_textUntil('real').trim());
      default:
        throw FormatException('<$tag>');
    }
  }
}

const _collectedTypes = [
  'NSPrivacyCollectedDataTypePhotosorVideos',
  'NSPrivacyCollectedDataTypeHealth',
  'NSPrivacyCollectedDataTypeOtherUserContent',
];

/// Chinese, Japanese and full-width characters.
final _cjk = RegExp(r'[⺀-鿿豈-﫿＀-￯　-〿]');

/// Characters as Play counts them: one per Unicode code point, full-width
/// and half-width alike (answer/9866151). A file's final newline is not
/// part of the pasted text.
int _playLength(String fileText) =>
    fileText.replaceFirst(RegExp(r'\n$'), '').runes.length;

/// (width, height, bit depth, colour type) from a PNG's IHDR chunk; colour
/// type 6 is RGBA (with 8-bit depth: "32-bit"), 2 is RGB ("24-bit").
(int, int, int, int) _pngHeader(File file) {
  final b = file.readAsBytesSync();
  expect(b.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      reason: '${file.path} is not a PNG');
  expect(String.fromCharCodes(b.sublist(12, 16)), 'IHDR', reason: file.path);
  int u32(int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
  return (u32(16), u32(20), b[24], b[25]);
}

/// GitHub Actions' filter pattern for a tag (`*` matches anything but `/`,
/// `**` anything), enough for the patterns release.yml uses.
bool _githubTagMatches(String pattern, String tag) {
  final re = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        re.write('.*');
        i++;
      } else {
        re.write('[^/]*');
      }
    } else {
      re.write(RegExp.escape(c));
    }
  }
  re.write(r'$');
  return RegExp(re.toString()).hasMatch(tag);
}

void main() {
  group('R-F8: App Privacy answer B in the manifests', () {
    test('the plist reader reads what it should', () {
      expect(
        parsePlist(
          '<?xml version="1.0"?><plist version="1.0"><dict>'
          '<key>a</key><array><string>x &amp; y</string><true/></array>'
          '<!-- note --><key>b</key><dict/><key>c</key><integer>3'
          '</integer></dict></plist>',
        ),
        {
          'a': ['x & y', true],
          'b': <String, Object?>{},
          'c': 3,
        },
      );
      expect(
        () => parsePlist('<plist><dict><key>a</key></dict></plist>'),
        throwsFormatException,
      );
    });

    test('Runner declares exactly Photos or Videos, Health and Other User '
        'Content — App Functionality, not linked, no tracking', () {
      final manifest =
          parsePlist(_read('ios/Runner/PrivacyInfo.xcprivacy'))
              as Map<String, Object?>;
      expect(manifest['NSPrivacyTracking'], isFalse);
      expect(manifest['NSPrivacyTrackingDomains'], isEmpty);
      final types = (manifest['NSPrivacyCollectedDataTypes'] as List)
          .cast<Map<String, Object?>>();
      expect(
        types.map((t) => t['NSPrivacyCollectedDataType']),
        unorderedEquals(_collectedTypes),
      );
      for (final t in types) {
        expect(
          t.keys,
          unorderedEquals([
            'NSPrivacyCollectedDataType',
            'NSPrivacyCollectedDataTypeLinked',
            'NSPrivacyCollectedDataTypeTracking',
            'NSPrivacyCollectedDataTypePurposes',
          ]),
        );
        expect(
          t['NSPrivacyCollectedDataTypeLinked'],
          isFalse,
          reason: '${t['NSPrivacyCollectedDataType']}: not linked',
        );
        expect(
          t['NSPrivacyCollectedDataTypeTracking'],
          isFalse,
          reason: '${t['NSPrivacyCollectedDataType']}: no tracking',
        );
        expect(t['NSPrivacyCollectedDataTypePurposes'], [
          'NSPrivacyCollectedDataTypePurposeAppFunctionality',
        ]);
      }
    });

    // The share extension sends nothing itself: it copies the shared photo
    // into the App Group container and opens the app, which asks for
    // consent and does the sending. So its own manifest declares no
    // collected data; the app's covers the data.
    test('the share extension declares none: the app does the sending', () {
      final manifest =
          parsePlist(_read('ios/ShareExtension/PrivacyInfo.xcprivacy'))
              as Map<String, Object?>;
      expect(manifest['NSPrivacyTracking'], isFalse);
      expect(manifest['NSPrivacyCollectedDataTypes'], isEmpty);
      final swift = _read('ios/ShareExtension/ShareViewController.swift');
      for (final network in ['URLSession', 'URLRequest', 'NWConnection']) {
        expect(
          swift,
          isNot(contains(network)),
          reason: 'the extension must not send anything itself',
        );
      }
    });

    test('RELEASING § 4.3 gives the same answers, click by click', () {
      final releasing = _readRepo('docs/RELEASING.md');
      // Line breaks in the Markdown are not part of the wording.
      final section = releasing
          .substring(
            releasing.indexOf('### 4.3 App Privacy'),
            releasing.indexOf('### 4.4 Review submission checklist'),
          )
          .replaceAll(RegExp(r'\s+'), ' ');
      for (final key in _collectedTypes) {
        expect(section, contains(key));
      }
      for (final label in [
        'Photos or Videos',
        'Health',
        'Other User Content',
        'App Functionality',
        'Yes, we collect data from this app',
        'Publish',
      ]) {
        expect(section, contains(label));
      }
    });

    // One rule for every row: what the app attaches by itself is declared
    // as what it is; what the user types is Other User Content, whatever it
    // is about. Fix's prompt turns a typed weight or workout into an entry
    // (log_weight / log_activity), so the rows must not say "nothing sends
    // workouts" or lean on a typed weight for Health (review 2026-10-29).
    test('§ 4.3 counts typed weights and workouts as Other User Content', () {
      final releasing = _readRepo('docs/RELEASING.md');
      final section = releasing.substring(
        releasing.indexOf('### 4.3 App Privacy'),
        releasing.indexOf('### 4.4 Review submission checklist'),
      );
      String row(String start) {
        final rows = section
            .split('\n')
            .where((l) => l.startsWith('| $start'))
            .toList();
        expect(rows, hasLength(1), reason: 'one § 4.3 row for $start');
        return rows.single;
      }

      final prompt = _readRepo('shared/prompts/text_handler_prompt.txt');
      expect(prompt, contains('"log_weight"'));
      expect(prompt, contains('"log_activity"'));

      final health = row('Health & Fitness → **Health**');
      expect(health, isNot(contains('typed')));
      final fitness = row('Health & Fitness → Fitness');
      expect(fitness, contains('**No**'));
      expect(fitness, isNot(contains('nothing sends')));
      expect(fitness, contains('Other User Content'));
      final other = row('User Content → **Other User Content**');
      expect(other, contains('weight'));
      expect(other, contains('workout'));
      // The manifest follows the table: Fitness stays undeclared.
      expect(
        _read('ios/Runner/PrivacyInfo.xcprivacy'),
        isNot(contains('NSPrivacyCollectedDataTypeFitness')),
      );
    });
  });

  group('R-F14: the support page', () {
    final support = _readRepo('docs/SUPPORT.md');

    test('is iPhone-only: no Android, APK, Telegram or VPN', () {
      for (final word in [
        'android',
        'apk',
        'telegram',
        'vpn',
        'google play',
        'play store',
        'sideload',
        'termux',
      ]) {
        expect(support.toLowerCase(), isNot(contains(word)), reason: word);
      }
    });

    test('names exactly the support address the owner chose', () {
      final emails = RegExp(
        r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+',
      ).allMatches(support).map((m) => m.group(0)).toSet();
      expect(emails, {'junjia.wang.me@gmail.com'});
      expect(support, isNot(contains('owner to choose')));
      expect(
        support,
        contains('https://github.com/AkiyamaKunka/Chopstats/issues'),
      );
    });

    test('is the support URL of both store listings', () {
      for (final locale in ['en-US', 'zh-Hans']) {
        expect(
          _read('ios/store/metadata/$locale/support_url.txt').trim(),
          'https://github.com/AkiyamaKunka/Chopstats/blob/main/docs/'
          'SUPPORT.md',
          reason: locale,
        );
      }
    });
  });

  group('R-F11: neutral English', () {
    // Provider brand names may carry their Chinese name; nothing else may.
    const brandNames = ['深度求索', '通义千问', '豆包', '智谱'];
    // Where a provider PROCESSES the data is a privacy disclosure, not
    // reachability advice: the consent dialog keeps it.
    const disclosures = {'aiConsentChinaNote'};
    final mainlandOrVpn = RegExp(
      r'\bvpn\b|mainland|\bchina\b|chinese|hong kong|firewall',
      caseSensitive: false,
    );

    final en = (jsonDecode(_read('lib/l10n/app_en.arb')) as Map)
        .cast<String, Object?>();

    test('no English string carries Chinese text', () {
      for (final MapEntry(:key, :value) in en.entries) {
        if (key.startsWith('@')) continue;
        var text = value as String;
        for (final brand in brandNames) {
          text = text.replaceAll(brand, '');
        }
        expect(_cjk.hasMatch(text), isFalse, reason: '$key: $value');
      }
    });

    test('no English string gives mainland-China or VPN advice', () {
      for (final MapEntry(:key, :value) in en.entries) {
        if (key.startsWith('@') || disclosures.contains(key)) continue;
        expect(
          mainlandOrVpn.hasMatch(value as String),
          isFalse,
          reason: '$key: $value',
        );
      }
      expect(
        AppLocalizationsEn().aiConsentChinaNote('DeepSeek'),
        contains('mainland China'),
        reason: 'the processing-location disclosure stays',
      );
    });

    test('the API key page: no reachability notes, no 免费 in English; '
        'Chinese unchanged', () {
      final en = AppLocalizationsEn();
      final zh = AppLocalizationsZh();
      for (final (id, _, tag) in kApiKeyChoices) {
        final note = noteLabel(en, tag) ?? '';
        expect(_cjk.hasMatch(note), isFalse, reason: id);
        expect(mainlandOrVpn.hasMatch(note), isFalse, reason: id);
      }
      expect(noteLabel(en, 'vpn'), isNull);
      expect(noteLabel(en, 'direct'), isNull);
      expect(noteLabel(zh, 'vpn'), '需要 VPN');
      expect(noteLabel(zh, 'freeDirect'), '免费 · 中国直连');
      for (final MapEntry(key: provider, value: models)
          in kKnownModels.entries) {
        for (final (id, label) in models) {
          final shown = modelChoiceLabel(en, label);
          expect(_cjk.hasMatch(shown), isFalse, reason: '$provider $id');
          expect(shown, isNot(contains('{')), reason: '$provider $id');
        }
      }
      final glm = kKnownModels['glm']!.first.$2;
      expect(modelChoiceLabel(en, glm), 'glm-4.6v-flash — FREE, default');
      expect(modelChoiceLabel(zh, glm), 'glm-4.6v-flash — FREE 免费, default');
    });
  });

  group('R-F9: Chopstats', () {
    // 2026-10-29: "BiteWise" is shared by a dozen live US App Store apps,
    // so the English name became Chopstats (no same-name US app, no live
    // USPTO mark); 筷拍 stays. The repository kept its old name until
    // 2026-11-09, when it became AkiyamaKunka/Chopstats too (GitHub
    // redirects the old links, which the 1.5.0 build still opens).
    const repoUrl = 'github.com/AkiyamaKunka/Chopstats';
    void expectNoOldName(String text, {String? reason}) {
      final rest = text.replaceAll(repoUrl, '');
      expect(rest, isNot(contains('BiteWise')), reason: reason);
      expect(rest, isNot(contains('Bitewise')), reason: reason);
    }

    String? plistString(String plist, String key) => RegExp(
      '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(plist)?.group(1);
    String? stringsValue(String strings, String key) => RegExp(
      '"${RegExp.escape(key)}"\\s*=\\s*"([^"]*)";',
    ).firstMatch(strings)?.group(1);

    for (final target in ['Runner', 'ShareExtension']) {
      test('$target: Chopstats in English, 筷拍 in Chinese', () {
        final plist = _read('ios/$target/Info.plist');
        final en = _read('ios/$target/en.lproj/InfoPlist.strings');
        final zh = _read('ios/$target/zh-Hans.lproj/InfoPlist.strings');
        expect(plistString(plist, 'CFBundleDisplayName'), 'Chopstats');
        expect(stringsValue(en, 'CFBundleDisplayName'), 'Chopstats');
        expect(stringsValue(zh, 'CFBundleDisplayName'), '筷拍');
        for (final text in [plist, en]) {
          expectNoOldName(text);
        }
        expect(
          plistString(plist, 'NSPhotoLibraryUsageDescription'),
          startsWith('Chopstats reads your photo library'),
        );
        expect(
          stringsValue(en, 'NSPhotoLibraryUsageDescription'),
          startsWith('Chopstats reads your photo library'),
        );
      });
    }

    test('the English strings, the policy and the listing', () {
      final arb = _read('lib/l10n/app_en.arb');
      expectNoOldName(arb);
      expect(arb, contains('Chopstats'));
      expectNoOldName(_readRepo('docs/PRIVACY.md'));
      expectNoOldName(_readRepo('docs/SUPPORT.md'));
      expectNoOldName(_read('lib/ui/app.dart'));
      // The listing's own files, not a checkout's .DS_Store (binary) or
      // git mergetool's .orig (see store_listing_files.dart).
      final listing = storeListingFiles(
        Directory('${_appRoot().path}/ios/store/metadata'),
        recursive: true,
      );
      expect(listing, isNotEmpty);
      for (final file in listing) {
        expectNoOldName(file.readAsStringSync(), reason: file.path);
      }
      for (final locale in ['en-US', 'zh-Hans']) {
        expect(
          _read('ios/store/metadata/$locale/name.txt').trim(),
          'Chopstats · 筷拍',
        );
      }
    });
  });

  group('R-F7: the privacy policy names the third parties', () {
    final policy = _readRepo('docs/PRIVACY.md');

    test('in English and 中文, with the new effective date', () {
      // The merge of PR #19 (restaurant lookup) changed the policy again,
      // and so did its "Which meals" bullet, rewritten on 2026-11-05 for
      // the auto_branding trigger, and the usual-foods PR on 2026-11-07
      // (saved lookup answers kept up to a year; My usual foods). The date
      // and this pin are set by hand, and again to the merge date when PR
      // #19 merges, when the usual-foods PR merges and when PR #22 merges
      // (docs/RELEASING.md): a 3-way merge keeps the older date without a
      // conflict. PR #19 and the usual-foods PR both merged on 2026-11-09;
      // the 1.6.0 review fixes, which also name the maker of the OpenRouter
      // model a lookup goes to, merged on 2026-11-10; run 7 (PR #22: the
      // day before's meals with a photo taken before 4 a.m., under the
      // consent text that says so) merged on 2026-11-11, and so did the
      // 1.7.0 iCloud Backup (PR #36: the iCloud Backup section). Review
      // r171 changed it on 2026-11-13: activities in what an export holds,
      // and that iOS can keep API keys in the Keychain after uninstalling.
      // If that branch merges on a later day, set the date and this pin to
      // the merge date.
      expect(policy, contains('Effective date: 2026-11-13'));
      expect(policy, contains('### Third parties and your consent'));
      expect(policy, contains('### 第三方与你的同意'));
      expect(policy, contains('Stop Sharing with …'));
      expect(policy, contains('停止发送给 …'));
      // Own-server wording, not the plan's old name.
      expect(policy, contains('**Your own server**'));
      expect(policy, isNot(contains('**Claude Plan**')));
      // No promise that every provider protects data the same way.
      for (final claim in ['equal protection', 'same protection', '同等保护']) {
        expect(policy, isNot(contains(claim)));
      }
    });

    // 1.7.0 iCloud Backup: the policy says where the copy lives, what is
    // never in it, that the developer cannot see it, and how to delete it,
    // in both languages.
    test('iCloud Backup: own iCloud, never the keys, deletable', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      expect(policy, contains('### iCloud Backup (iPhone)'));
      expect(policy, contains('### iCloud 备份（iPhone）'));
      expect(flat, contains('**What is never copied:** API keys'));
      expect(flat, contains('**绝不会复制的内容**：API Key'));
      expect(flat, contains('the developer cannot see them and runs no server'));
      expect(flat, contains('开发者看不到它们'));
      expect(flat, contains('nothing is uploaded until you answer it'));
      expect(flat, contains('在你回答之前不会上传任何内容'));
      expect(flat, contains('uninstalling the app does not delete it'));
      expect(flat, contains('卸载应用不会删除它'));
      expect(flat, contains('Apart from the copy **iCloud Backup** keeps'));
    });

    // The section names the recipient, so it must not open by saying the
    // data is shared with no one (review 2026-10-29).
    test('says who it shares with, never "with anyone"', () {
      final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
      for (final claim in [
        'share it with anyone',
        'shared with anyone',
        'with no one',
        '不会与任何人分享',
        '不与任何人分享',
      ]) {
        expect(flat, isNot(contains(claim)));
      }
      expect(
        flat,
        contains(
          'Chopstats does not sell your data. It shares it only with the AI '
          'recipient you set up under Settings › AI Provider',
        ),
      );
      expect(
        policy,
        contains(
          '筷拍不会出售你的数据，'
          '只会把它发送给你在 设置 › AI 服务 里设置的那个 AI 接收方',
        ),
      );
    });

    test('Describe sends no meals; Fix sends the last 7 days', () {
      expect(policy, contains('today\'s date. No other meals are sent.'));
      expect(policy, contains('不发送其他餐食'));
      final en = AppLocalizationsEn().aiConsentBody('X');
      expect(en, contains('• what you type to describe a meal\n'));
      expect(
        en,
        contains(
          '• what you type to fix a meal, with your meals '
          'from the last 7 days',
        ),
      );
      final zh = AppLocalizationsZh().aiConsentBody('X');
      expect(zh, contains('• 你为描述一餐输入的文字\n'));
      expect(zh, contains('• 你为修正餐食输入的文字，连同最近 7 天的餐食'));
    });
  });
  group('Google Play listing (app/android/store/metadata)', () {
    const locales = ['en-US', 'zh-CN'];
    String listing(String locale, String name) =>
        _read('android/store/metadata/$locale/$name.txt');

    test("title, short and full descriptions fit Play's limits", () {
      for (final locale in locales) {
        final title = listing(locale, 'title');
        final short = listing(locale, 'short_description');
        final full = listing(locale, 'full_description');
        expect(title.trim(), 'Chopstats · 筷拍', reason: locale);
        expect(_playLength(title), lessThanOrEqualTo(30), reason: locale);
        expect(_playLength(short), inInclusiveRange(10, 80), reason: locale);
        expect(_playLength(full), inInclusiveRange(500, 4000), reason: locale);
        // Google's advice for the short description: no special characters
        // (the title's single · is fine there), no closing period.
        expect(short, isNot(contains('·')), reason: locale);
        expect(short.trim(), isNot(endsWith('.')), reason: locale);
      }
      expect(_playLength('筷拍\n'), 2, reason: 'one per character');
    });

    // The Health Content and Services policy (answer/16679511): Google's
    // disclaimer in the description, word for word, and the reminder to
    // consult a healthcare professional.
    test("the full descriptions end with Google's health disclaimer", () {
      final en = listing('en-US', 'full_description')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      expect(
          en,
          contains('Chopstats is not a medical device and does not diagnose, '
              'treat, cure, or prevent any medical condition.'));
      expect(
          en,
          endsWith('Consult a healthcare professional for medical advice, '
              'diagnosis, or treatment.'));
      final zh = listing('zh-CN', 'full_description').trim();
      expect(zh, contains('筷拍不是医疗器械，不能诊断、治疗、治愈或预防任何疾病。'));
      expect(zh, endsWith('如需医疗建议、诊断或治疗，请咨询医疗专业人员。'));
    });

    // Android facts only; nothing the first Play build lacks (decision 1:
    // no Watch Camera Roll on Play), nothing about the sideload channel,
    // and no claim nobody can check.
    test('says nothing iPhone-only, sideload-only or unverifiable', () {
      final banned = RegExp(
        r'github|\bapk\b|sideload|telegram|\bvpn\b|\bios\b|iphone|keychain|'
        r'apple maps|camera roll|glasses|photo coverage|\b174\b|%|#1|\bbest\b|'
        r'accura|worldwide|监控相册|眼镜|钥匙串|照片覆盖|准确率',
        caseSensitive: false,
      );
      for (final locale in locales) {
        for (final name in ['title', 'short_description', 'full_description']) {
          expect(banned.firstMatch(listing(locale, name))?.group(0), isNull,
              reason: '$locale/$name');
        }
      }
    });

    test("names the app's controls as the app does", () {
      final en = AppLocalizationsEn();
      final zh = AppLocalizationsZh();
      final enText = listing('en-US', 'full_description');
      final zhText = listing('zh-CN', 'full_description');
      expect(enText, contains(en.addUsual));
      expect(enText, contains(en.settingsSectionRestaurant));
      expect(zhText, contains(zh.addUsual));
      expect(zhText, contains('「${zh.settingsSectionRestaurant}」'));
    });

    // The zh text quotes examples and control names in 「」, as the app and
    // the policy's 中文 half do: no ASCII or curly double quotes.
    test('zh-CN quotes in 「」 only', () {
      for (final name in ['title', 'short_description', 'full_description']) {
        final text = listing('zh-CN', name);
        for (final quote in ['"', '“', '”']) {
          expect(text, isNot(contains(quote)), reason: '$name $quote');
        }
      }
      final full = listing('zh-CN', 'full_description');
      for (final example in [
        '米饭（~150 克）',
        '那碗面其实是烧鸭饭',
        '一碗牛肉面加一个鸡蛋',
        'two eggs and toast with butter',
        '素食',
        '家常菜，少油',
      ]) {
        expect(full, contains('「$example」'), reason: example);
      }
    });

    test('the answers files hold no key and no email address', () {
      for (final name in ['app_content.md', 'data_safety.md']) {
        final text = _read('android/store/$name');
        expect(RegExp(r'AIza[0-9A-Za-z_-]{20,}').hasMatch(text), isFalse,
            reason: '$name: a Google API key');
        expect(RegExp(r'\bsk-[A-Za-z0-9-]{8,}').hasMatch(text), isFalse,
            reason: '$name: an API key');
        expect(
            RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]').hasMatch(text),
            isFalse,
            reason: '$name: an email address');
      }
      expect(_read('android/store/app_content.md'),
          contains("<the demo key from the owner's release notes>"));
    });

    // Data safety by Google's definitions (answer/10787469): anything sent
    // off the phone is collected; not ephemeral; the exemptions named.
    test("data_safety.md answers by Google's definitions", () {
      final text =
          _read('android/store/data_safety.md').replaceAll(RegExp(r'\s+'), ' ');
      for (final type in [
        '**Photos and videos › Photos**',
        '**Health and fitness › Health info**',
        '**Health and fitness › Fitness info**',
        '**App activity › Other user-generated content**',
        '**Location › Approximate location**',
      ]) {
        expect(text, contains(type), reason: type);
      }
      expect(text, contains('**Shared:** No'));
      expect(text, contains('**Processed ephemerally:** No'));
      expect(text, contains('**App functionality** only'));
      expect(text, contains('My app does not allow users to create an account'));
      expect(text, contains('a specific user-initiated action'));
      expect(text,
          contains("a prominent in-app disclosure and the user's consent"));
    });
  });

  group("Play What's new (app/android/whatsnew)", () {
    test('both texts exist, fit 500 characters and point nowhere else', () {
      for (final locale in ['en-US', 'zh-CN']) {
        final text = _read('android/whatsnew/whatsnew-$locale');
        expect(text.trim(), isNotEmpty, reason: locale);
        expect(text.runes.length, lessThanOrEqualTo(500), reason: locale);
        expect(
            RegExp(r'github|\bapk\b|release notes|发布说明|camera roll|监控相册',
                    caseSensitive: false)
                .firstMatch(text)
                ?.group(0),
            isNull,
            reason: locale);
      }
    });
  });

  group('Play graphics, the themed icon and the Android 12+ splash', () {
    test('icon-512 is a 512 x 512 32-bit PNG of at most 1024 KB', () {
      final icon =
          File('${_appRoot().path}/android/store/graphics/icon-512.png');
      expect(_pngHeader(icon), (512, 512, 8, 6));
      expect(icon.lengthSync(), lessThanOrEqualTo(1024 * 1024));
    });

    test('the feature graphics are 1024 x 500 24-bit PNGs, no alpha', () {
      for (final name in ['feature-graphic.png', 'feature-graphic-zh-CN.png']) {
        final f = File('${_appRoot().path}/android/store/graphics/$name');
        expect(_pngHeader(f), (1024, 500, 8, 2), reason: name);
      }
    });

    test('the shot list asks for what Play accepts', () {
      final shots = _read('android/store/screenshots/SHOTS.md')
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(shots, contains('at least 4 portrait shots, 9:16, 1080×1920'));
      expect(shots, contains('24-bit PNG with no alpha'));
    });

    // Android 13+ themed icons need a monochrome layer (lint
    // MonochromeLauncherIcon). flutter_launcher_icons writes it from
    // pubspec.yaml, from the layers scripts/play_graphics.py --launcher
    // makes out of assets/app_icon.png.
    test('the adaptive icon has its monochrome layer at every density', () {
      final xml =
          _read('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
      expect(xml, contains('<monochrome>'));
      expect(xml, contains('@drawable/ic_launcher_monochrome'));
      final pubspec = _read('pubspec.yaml');
      expect(pubspec,
          contains('adaptive_icon_foreground: assets/app_icon_foreground.png'));
      expect(pubspec,
          contains('adaptive_icon_monochrome: assets/app_icon_monochrome.png'));
      for (final name in ['app_icon_foreground.png', 'app_icon_monochrome.png']) {
        expect(_pngHeader(File('${_appRoot().path}/assets/$name')),
            (1024, 1024, 8, 6),
            reason: name);
      }
      const sizes = {
        'mdpi': 108,
        'hdpi': 162,
        'xhdpi': 216,
        'xxhdpi': 324,
        'xxxhdpi': 432,
      };
      for (final MapEntry(key: density, value: px) in sizes.entries) {
        for (final layer in ['foreground', 'monochrome']) {
          final f = File('${_appRoot().path}/android/app/src/main/res/'
              'drawable-$density/ic_launcher_$layer.png');
          expect(_pngHeader(f), (px, px, 8, 6), reason: '$density $layer');
        }
      }
    });

    // Android 12+ draws its own splash screen from the launch theme: the
    // app's page colour, light and dark, instead of Theme.Light's white.
    test('the Android 12+ splash uses the page colours', () {
      String argb(int v) =>
          '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
      final light = argb(AppColors.light.page.toARGB32());
      final dark = argb(AppColors.dark.page.toARGB32());
      expect(light, '#FFF2F2F7');
      expect(dark, '#FF000000');
      for (final (folder, colour) in [
        ('values-v31', light),
        ('values-night-v31', dark),
      ]) {
        final xml = _read('android/app/src/main/res/$folder/styles.xml');
        expect(xml, contains('<style name="LaunchTheme"'), reason: folder);
        expect(
            xml,
            contains('<item name="android:windowSplashScreenBackground">'
                '$colour</item>'),
            reason: folder);
        expect(xml,
            contains('<item name="android:colorBackground">$colour</item>'),
            reason: folder);
        expect(xml, isNot(contains('<style name="NormalTheme"')),
            reason: folder);
      }
    });
  });

  group('release.yml: tags, Play tracks and the Gradle mirrors', () {
    final workflow = _readRepo('.github/workflows/release.yml');

    // Decision 4 (2026-11-13): Android 1.7.0 ships with a hand-made GitHub
    // Release under android-v1.7.0, so v1.7.0 stays free for the iPhone.
    // That tag must start no run: the only push trigger is tags v*.
    test('only v* tags start a run, so android-v* tags start none', () {
      final on = RegExp(r'^on:\n((?:[ \t]+.*\n|\n)*)', multiLine: true)
          .firstMatch(workflow)!
          .group(1)!;
      final push = RegExp(r'^  push:\n((?:    .*\n)*)', multiLine: true)
          .firstMatch(on)!
          .group(1)!;
      expect(push.trim().split('\n').map((l) => l.trim()).toList(),
          ['tags:', "- 'v*'"]);
      expect(on, isNot(contains('pull_request')));
      expect(_githubTagMatches('v*', 'v1.7.0'), isTrue);
      expect(_githubTagMatches('v*', 'v1.7.0+207'), isTrue);
      expect(_githubTagMatches('v*', 'android-v1.7.0'), isFalse);
      // The plan job treats only refs/tags/v* as a tag build.
      expect(workflow,
          contains(r'if [[ "$GITHUB_REF" == refs/tags/v* ]]; then'));
    });

    test('Run workflow can send the bundle to the closed test; tag pushes '
        'stay on internal', () {
      const input = '''
      play_track:
        description: Play track the bundle goes to when PLAY_SERVICE_ACCOUNT_JSON is set (alpha = the closed test; a tag push always uses internal)
        type: choice
        options:
          - internal
          - alpha
        default: internal
''';
      expect(workflow, contains(input));
      expect(
          workflow,
          contains(r"tracks: ${{ github.event_name == 'workflow_dispatch' && "
              r"inputs.play_track || 'internal' }}"));
      expect(RegExp(r'^\s*tracks:', multiLine: true).allMatches(workflow),
          hasLength(1));
      expect(workflow, contains('status: completed'));
    });

    // C44: the owner's Mac needs the Aliyun mirrors; CI must never use
    // them (GitHub Actions sets CI=true). Every mirror line sits inside the
    // guarded block, in both Gradle files.
    test('the Aliyun mirrors are for local builds only', () {
      for (final (file, flag) in [
        ('android/settings.gradle.kts', 'useMirror'),
        ('android/build.gradle.kts', 'useAliyunMirror'),
      ]) {
        final text = _read(file);
        expect(text, contains('System.getenv("CI") != "true"'), reason: file);
        expect(
            text,
            contains(
                'providers.gradleProperty("chopstats.noMirror").orNull != "true"'),
            reason: file);
        final guarded =
            RegExp('if \\($flag\\) \\{\\n((?:[ \\t]+maven \\{[^\\n]*\\n)+)')
                .firstMatch(text);
        expect(guarded, isNotNull, reason: file);
        final inside = 'maven.aliyun.com'.allMatches(guarded!.group(1)!).length;
        expect(inside, greaterThan(0), reason: file);
        expect('maven.aliyun.com'.allMatches(text), hasLength(inside),
            reason: '$file: an Aliyun repository outside the guard');
      }
    });
  });

}
