/// T48 (usual-foods spec §6, §9): the copy for saved lookup answers, your
/// usual numbers and My usual foods.
///
/// - Every new key is in both ARB files, after `diagConfidenceLine`, with
///   the placeholders §6 gives (and their types in the English metadata).
/// - The English strings carry no Chinese text and no "chat"; the Chinese
///   ones no 对话 or 聊天.
/// - The changed `clearPlacesBody` names the saved answers and the lookups
///   still waiting, and the Chinese quotes the control as 「不是餐厅的」.
/// - `assistFoundSaved` never says "Used": on Claude Plan a saved answer is
///   only a suggestion.
/// - Both files have the same 878 keys, and the generated classes say what
///   the ARB files say (gen-l10n was run).
/// - Keys added or changed after review (fix list U3, U5, C5) follow the
///   same rules; the iOS Off box names the saved answers it also clears.
library;

import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spec §6: the 43 new keys, then the ones review added, and their
/// placeholders ('String' or 'int').
const Map<String, Map<String, String>> _newKeys = {
  // Part 1: saved lookup answers.
  'assistViaSaved': {'provider': 'String', 'date': 'String'},
  'assistContextSaved': {'date': 'String'},
  'assistSearchAgain': {},
  'assistFoundSaved': {'date': 'String'},
  'assistSearchAgainNoChange': {},
  'assistSearchAgainSame': {},
  'assistSearchAgainDiffers': {'kcal': 'String'},
  'restaurantSavedAnswersHint': {},
  'settingsRowClearSavedAnswers': {},
  'clearAnswersTitle': {},
  'clearAnswersBody': {},
  'clearAnswersDone': {},
  'restaurantOffClearAnswers': {},
  // Part 2: your usual numbers.
  'usualItemLine': {'name': 'String', 'ai': 'String', 'mine': 'String'},
  'usualChipMany': {'count': 'int'},
  'usualChipUse': {},
  'usualChipReview': {},
  'usualChipUseLabel': {'name': 'String'},
  'usualCardTitle': {},
  'usualCardFrom': {'name': 'String', 'date': 'String'},
  'usualUseMine': {},
  'usualKeepAi': {},
  'usualUsedSnack': {'before': 'String', 'after': 'String'},
  'usualUndoStale': {},
  // Part 3: My usual foods.
  'addUsual': {},
  'usualNowHeader': {},
  'usualMoreHeader': {},
  'usualRowStats': {'days': 'int', 'day': 'String'},
  'usualLoggedToday': {'time': 'String'},
  'usualScreenHint': {},
  'usualLoggedSnack': {'name': 'String', 'kcal': 'String'},
  'usualLogFailed': {},
  'usualListFailed': {},
  'usualMoreActions': {},
  'usualHide': {},
  'usualHiddenSnack': {},
  'usualHiddenRow': {'count': 'int'},
  'usualUnhide': {},
  'usualEmpty': {},
  'usualAllHidden': {},
  'usualAgainTitle': {},
  'usualAgainBody': {'name': 'String', 'time': 'String'},
  'usualAgainConfirm': {},
  // Added after review: an offer on the macros alone (U3).
  'usualItemLineMacros': {'name': 'String', 'ai': 'String', 'mine': 'String'},
  'usualUsedSnackSame': {},
  // Added after review: what a screen reader says for the logged check
  // (U5).
  'usualLoggedLabel': {},
};

/// How many of [_newKeys] the spec's §6 lists; the rest came from review.
const int _specKeys = 43;

/// The one changed key.
const String _changed = 'clearPlacesBody';

/// The key review changed (C5): the iOS Off dialog's box names the saved
/// answers it also deletes.
const String _changedOff = 'restaurantOffClearPlaces';

/// Each new key's generated getter. A String placeholder gets its own
/// `{name}` back, an int placeholder gets 7, so the output can be compared
/// with the ARB text.
final Map<String, String Function(AppLocalizations l)> _render = {
  'assistViaSaved': (l) => l.assistViaSaved('{provider}', '{date}'),
  'assistContextSaved': (l) => l.assistContextSaved('{date}'),
  'assistSearchAgain': (l) => l.assistSearchAgain,
  'assistFoundSaved': (l) => l.assistFoundSaved('{date}'),
  'assistSearchAgainNoChange': (l) => l.assistSearchAgainNoChange,
  'assistSearchAgainSame': (l) => l.assistSearchAgainSame,
  'assistSearchAgainDiffers': (l) => l.assistSearchAgainDiffers('{kcal}'),
  'restaurantSavedAnswersHint': (l) => l.restaurantSavedAnswersHint,
  'settingsRowClearSavedAnswers': (l) => l.settingsRowClearSavedAnswers,
  'clearAnswersTitle': (l) => l.clearAnswersTitle,
  'clearAnswersBody': (l) => l.clearAnswersBody,
  'clearAnswersDone': (l) => l.clearAnswersDone,
  'restaurantOffClearAnswers': (l) => l.restaurantOffClearAnswers,
  'usualItemLine': (l) => l.usualItemLine('{name}', '{ai}', '{mine}'),
  'usualChipMany': (l) => l.usualChipMany(7),
  'usualChipUse': (l) => l.usualChipUse,
  'usualChipReview': (l) => l.usualChipReview,
  'usualChipUseLabel': (l) => l.usualChipUseLabel('{name}'),
  'usualCardTitle': (l) => l.usualCardTitle,
  'usualCardFrom': (l) => l.usualCardFrom('{name}', '{date}'),
  'usualUseMine': (l) => l.usualUseMine,
  'usualKeepAi': (l) => l.usualKeepAi,
  'usualUsedSnack': (l) => l.usualUsedSnack('{before}', '{after}'),
  'usualUndoStale': (l) => l.usualUndoStale,
  'addUsual': (l) => l.addUsual,
  'usualNowHeader': (l) => l.usualNowHeader,
  'usualMoreHeader': (l) => l.usualMoreHeader,
  'usualRowStats': (l) => l.usualRowStats(7, '{day}'),
  'usualLoggedToday': (l) => l.usualLoggedToday('{time}'),
  'usualScreenHint': (l) => l.usualScreenHint,
  'usualLoggedSnack': (l) => l.usualLoggedSnack('{name}', '{kcal}'),
  'usualLogFailed': (l) => l.usualLogFailed,
  'usualListFailed': (l) => l.usualListFailed,
  'usualMoreActions': (l) => l.usualMoreActions,
  'usualHide': (l) => l.usualHide,
  'usualHiddenSnack': (l) => l.usualHiddenSnack,
  'usualHiddenRow': (l) => l.usualHiddenRow(7),
  'usualUnhide': (l) => l.usualUnhide,
  'usualEmpty': (l) => l.usualEmpty,
  'usualAllHidden': (l) => l.usualAllHidden,
  'usualAgainTitle': (l) => l.usualAgainTitle,
  'usualAgainBody': (l) => l.usualAgainBody('{name}', '{time}'),
  'usualAgainConfirm': (l) => l.usualAgainConfirm,
  'usualItemLineMacros': (l) =>
      l.usualItemLineMacros('{name}', '{ai}', '{mine}'),
  'usualUsedSnackSame': (l) => l.usualUsedSnackSame,
  'usualLoggedLabel': (l) => l.usualLoggedLabel,
  _changed: (l) => l.clearPlacesBody,
  _changedOff: (l) => l.restaurantOffClearPlaces,
};

// The same ranges release_decisions_test.dart uses: CJK radicals through
// unified ideographs, compatibility ideographs, full-width forms, and CJK
// symbols and punctuation (「」, 。, the ideographic space).
final _cjk = RegExp(r'[⺀-鿿豈-﫿＀-￯　-〿]');
final _placeholderRe = RegExp(r'\{(\w+)\}');

/// The message keys in each ARB file: 809 on `main` once #22 merged, 69
/// more with the 1.7.0 iCloud Backup branch (feat/icloud-backup).
const _keyCount = 878;

Directory _appRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  return dir;
}

Map<String, Object?> _arb(String locale) =>
    (jsonDecode(
              File(
                '${_appRoot().path}/lib/l10n/app_$locale.arb',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

List<String> _messageKeys(Map<String, Object?> arb) => [
  for (final k in arb.keys)
    if (!k.startsWith('@')) k,
];

Set<String> _placeholders(String text) => {
  for (final m in _placeholderRe.allMatches(text)) m.group(1)!,
};

void main() {
  final en = _arb('en');
  final zh = _arb('zh');
  final checked = [..._newKeys.keys, _changed, _changedOff];

  test('the spec lists 43 new keys, review added 3, and each has a '
      'generated getter', () {
    expect(_newKeys, hasLength(_specKeys + 3));
    expect(_render.keys.toSet(), {..._newKeys.keys, _changed, _changedOff});
  });

  test('both files have the same 878 keys', () {
    expect(_messageKeys(en), hasLength(_keyCount));
    expect(_messageKeys(zh), hasLength(_keyCount));
    expect(_messageKeys(zh).toSet(), _messageKeys(en).toSet());
  });

  // docs/RELEASING.md tells whoever merges which count to pin; a count
  // changed here and not there sends them the wrong number (it said 807
  // after the merge pinned 809).
  test('docs/RELEASING.md gives the count this test pins', () {
    final releasing = File(
      '${_appRoot().parent.path}/docs/RELEASING.md',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    expect(releasing, contains('$_keyCount on the iCloud Backup branch'));
  });

  test('every new key is in both files, after diagConfidenceLine', () {
    for (final arb in [en, zh]) {
      final keys = _messageKeys(arb);
      final last = keys.indexOf('diagConfidenceLine');
      expect(last, isNonNegative);
      for (final key in _newKeys.keys) {
        expect(keys.indexOf(key), greaterThan(last), reason: key);
        expect(arb[key], isA<String>(), reason: key);
        expect((arb[key] as String).trim(), isNotEmpty, reason: key);
      }
    }
  });

  test('both languages use exactly the placeholders §6 gives', () {
    for (final key in _newKeys.keys) {
      final want = _newKeys[key]!.keys.toSet();
      expect(_placeholders(en[key] as String), want, reason: 'en $key');
      expect(_placeholders(zh[key] as String), want, reason: 'zh $key');
    }
    for (final key in [_changed, _changedOff]) {
      expect(_placeholders(en[key] as String), isEmpty, reason: key);
      expect(_placeholders(zh[key] as String), isEmpty, reason: key);
    }
  });

  test('each new English key says where it is shown, with typed '
      'placeholders', () {
    for (final MapEntry(key: key, value: want) in _newKeys.entries) {
      final meta = en['@$key'];
      expect(meta, isA<Map>(), reason: key);
      meta as Map;
      expect(meta['description'], isA<String>(), reason: key);
      expect((meta['description'] as String).trim(), isNotEmpty, reason: key);
      final placeholders = (meta['placeholders'] as Map?) ?? const {};
      expect(
        {
          for (final MapEntry(key: name, :value) in placeholders.entries)
            name as String: (value as Map)['type'],
        },
        want,
        reason: key,
      );
    }
  });

  test('no Chinese text and no "chat" in English; no 对话 or 聊天 in '
      'Chinese', () {
    for (final key in checked) {
      final e = en[key] as String, z = zh[key] as String;
      expect(_cjk.hasMatch(e), isFalse, reason: '$key: $e');
      expect(e.toLowerCase(), isNot(contains('chat')), reason: key);
      expect(z, isNot(contains('对话')), reason: key);
      expect(z, isNot(contains('聊天')), reason: key);
    }
  });

  test('clearPlacesBody names the saved answers and the waiting lookups', () {
    final e = en[_changed] as String, z = zh[_changed] as String;
    expect(e, contains('the saved lookup answers'));
    expect(e, contains('the lookups still waiting'));
    expect(e, contains('kept only on this phone'));
    expect(z, contains('保存的查询结果'));
    expect(z, contains('还在等待的查询'));
    expect(z, contains('「不是餐厅的」'));
    expect(z, isNot(contains('"')));
  });

  test('the iOS Off box names the saved answers it also clears, in the '
      "Android box's words", () {
    expect(en[_changedOff],
        'Also clear learned places and saved lookup answers');
    expect(zh[_changedOff], '同时清除已记住的地点和保存的查询结果');
    expect(en[_changedOff], endsWith('saved lookup answers'));
    expect(en['restaurantOffClearAnswers'], endsWith('saved lookup answers'));
    expect(zh[_changedOff], endsWith('保存的查询结果'));
    expect(zh['restaurantOffClearAnswers'], endsWith('保存的查询结果'));
  });

  test('assistFoundSaved does not say the answer was used', () {
    final e = en['assistFoundSaved'] as String;
    expect(e, isNot(contains('Used')));
    expect(RegExp(r'\bused\b', caseSensitive: false).hasMatch(e), isFalse);
    expect(e, contains('Search again'));
    expect(zh['assistFoundSaved'], contains('「重新查找」'));
  });

  test('the keys review added say it in the terms the app already uses',
      () {
    // The macro line reads as the kcal line does, with the macros in place
    // of the kcal; the snackbar keeps Use's verb (采用).
    expect(en['usualItemLineMacros'], startsWith('{name}: AI {ai} → your usual'));
    expect(zh['usualItemLineMacros'], startsWith('{name}：AI {ai} → 你平时的'));
    expect(en['usualItemLineMacros'], isNot(contains('kcal')));
    expect(zh['usualItemLineMacros'], isNot(contains('千卡')));
    expect(en['usualUsedSnackSame'], startsWith('Used your usual numbers'));
    expect(zh['usualUsedSnackSame'], startsWith('已采用你平时的数值'));
    // The logged check says what the row's own lines say (usualLoggedToday).
    expect(en['usualLoggedToday'], startsWith(en['usualLoggedLabel'] as String));
    expect(zh['usualLoggedToday'], endsWith(zh['usualLoggedLabel'] as String));
  });

  test('the generated classes say what the ARB files say', () {
    for (final (l, arb) in [
      (AppLocalizationsEn() as AppLocalizations, en),
      (AppLocalizationsZh() as AppLocalizations, zh),
    ]) {
      for (final MapEntry(:key, value: render) in _render.entries) {
        final text = (arb[key] as String)
            .replaceAll('{count}', '7')
            .replaceAll('{days}', '7');
        expect(render(l), text, reason: '${l.localeName} $key');
      }
    }
  });

  test('the placeholders render as the screens fill them', () {
    final e = AppLocalizationsEn(), z = AppLocalizationsZh();
    expect(
      e.assistViaSaved('Claude (server)', '2026-03-02'),
      'via Claude (server) · saved answer from 2026-03-02',
    );
    expect(
      e.usualItemLine('Oatmeal', '300', '350'),
      'Oatmeal: AI 300 → your usual 350 kcal',
    );
    expect(z.usualItemLine('燕麦粥', '300', '350'), '燕麦粥：AI 300 → 你平时的 350 千卡');
    expect(
      e.usualItemLineMacros(
          'Oatmeal', 'P 10g · C 54g · F 6g', 'P 25g · C 40g · F 10g'),
      'Oatmeal: AI P 10g · C 54g · F 6g → your usual P 25g · C 40g · F 10g',
    );
    expect(
      z.usualItemLineMacros('燕麦粥', '蛋 10g · 碳 54g · 脂 6g', '蛋 25g · 碳 40g · 脂 10g'),
      '燕麦粥：AI 蛋 10g · 碳 54g · 脂 6g → 你平时的 蛋 25g · 碳 40g · 脂 10g',
    );
    expect(e.usualUsedSnackSame, 'Used your usual numbers.');
    expect(z.usualUsedSnackSame, '已采用你平时的数值。');
    expect(e.usualChipMany(2), 'Your usual numbers for 2 items');
    expect(e.usualHiddenRow(1), 'Hidden foods (1)');
    expect(z.usualHiddenRow(1), '已隐藏的食物（1）');
    expect(
      e.usualRowStats(9, 'Tuesday, Nov 04'),
      '9 of the last 90 days · last logged Tuesday, Nov 04',
    );
    expect(z.usualRowStats(9, '11月4日 星期二'), '最近 90 天里有 9 天 · 上次 11月4日 星期二');
  });
}
