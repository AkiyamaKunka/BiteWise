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
/// - R-F9: the English name is BiteWise everywhere; 筷拍 in Chinese.
/// - R-F7: the privacy policy's third-party and consent section.
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart'
    show kApiKeyChoices, kKnownModels, modelChoiceLabel, noteLabel;
import 'package:flutter_test/flutter_test.dart';

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
        contains('https://github.com/AkiyamaKunka/BiteWise/issues'),
      );
    });

    test('is the support URL of both store listings', () {
      for (final locale in ['en-US', 'zh-Hans']) {
        expect(
          _read('ios/store/metadata/$locale/support_url.txt').trim(),
          'https://github.com/AkiyamaKunka/BiteWise/blob/main/docs/'
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

  group('R-F9: BiteWise', () {
    String? plistString(String plist, String key) => RegExp(
      '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(plist)?.group(1);
    String? stringsValue(String strings, String key) => RegExp(
      '"${RegExp.escape(key)}"\\s*=\\s*"([^"]*)";',
    ).firstMatch(strings)?.group(1);

    for (final target in ['Runner', 'ShareExtension']) {
      test('$target: BiteWise in English, 筷拍 in Chinese', () {
        final plist = _read('ios/$target/Info.plist');
        final en = _read('ios/$target/en.lproj/InfoPlist.strings');
        final zh = _read('ios/$target/zh-Hans.lproj/InfoPlist.strings');
        expect(plistString(plist, 'CFBundleDisplayName'), 'BiteWise');
        expect(stringsValue(en, 'CFBundleDisplayName'), 'BiteWise');
        expect(stringsValue(zh, 'CFBundleDisplayName'), '筷拍');
        for (final text in [plist, en]) {
          expect(text, isNot(contains('Bitewise')));
        }
        expect(
          plistString(plist, 'NSPhotoLibraryUsageDescription'),
          startsWith('BiteWise reads your photo library'),
        );
        expect(
          stringsValue(en, 'NSPhotoLibraryUsageDescription'),
          startsWith('BiteWise reads your photo library'),
        );
      });
    }

    test('the English strings, the policy and the listing', () {
      final arb = _read('lib/l10n/app_en.arb');
      expect(arb, isNot(contains('Bitewise')));
      expect(arb, contains('BiteWise'));
      expect(_readRepo('docs/PRIVACY.md'), isNot(contains('Bitewise')));
      expect(_readRepo('docs/SUPPORT.md'), isNot(contains('Bitewise')));
      for (final file in Directory(
        '${_appRoot().path}/ios/store/metadata',
      ).listSync(recursive: true).whereType<File>()) {
        expect(
          file.readAsStringSync(),
          isNot(contains('Bitewise')),
          reason: file.path,
        );
      }
    });
  });

  group('R-F7: the privacy policy names the third parties', () {
    final policy = _readRepo('docs/PRIVACY.md');

    test('in English and 中文, with the new effective date', () {
      expect(policy, contains('Effective date: 2026-10-29'));
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
          'BiteWise does not sell your data. It shares it only with the AI '
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
}
