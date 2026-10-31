// U24: the chat bar went on 2026-07-31, but copy kept pointing at it — the
// Body empty state ('Weight logged by chat … lands here too') and the
// Test This Provider text rows ('chat fixes'). Typed weight and fixes now
// live under Log › Fix or delete a meal; no user-visible string may send
// anyone to a chat.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, String> _values(String path) {
  final arb = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in arb.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}

void main() {
  test('no English string mentions a chat', () {
    final hits = [
      for (final e in _values('lib/l10n/app_en.arb').entries)
        if (RegExp(r'\bchat\b', caseSensitive: false).hasMatch(e.value)) e.key,
    ];
    expect(hits, isEmpty);
  });

  test('no Chinese string mentions a chat (对话 / 聊天)', () {
    final hits = [
      for (final e in _values('lib/l10n/app_zh.arb').entries)
        if (e.value.contains('对话') || e.value.contains('聊天')) e.key,
    ];
    expect(hits, isEmpty);
  });

  test('the diagnostics text rows name the real screens', () {
    final en = _values('lib/l10n/app_en.arb');
    final zh = _values('lib/l10n/app_zh.arb');
    for (final key in const [
      'diagTextOk',
      'diagTextBadDetail',
      'diagTextBadPhotoAlsoFailed',
    ]) {
      expect(en[key], contains(en['addDescribe']), reason: key);
      expect(en[key], contains(en['addFix']), reason: key);
      expect(zh[key], contains(zh['addDescribe']), reason: key);
      expect(zh[key], contains(zh['addFix']), reason: key);
    }
  });
}
