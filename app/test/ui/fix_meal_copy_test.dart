/// The Fix-a-meal screen may only promise what the chat can do. Its intro
/// used to say "change, move, or delete" (改、要挪或要删), but the executor
/// has no move intent: a correction carries no date or time and only ever
/// rewrites the analysis, so "move the noodles to yesterday" came back as
/// a no-op "Corrected!" with the meal still on today (loop find
/// 2026-10-08). Moving a meal is the editor's job (date and time pickers),
/// so the intro now points there, naming the real tab labels.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/fix_meal_screen.dart';

import 'fakes.dart';

Future<String> _introShown(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: FixMealScreen(executor: FakeExecutor()),
  ));
  await tester.pumpAndSettle();
  final l10n = lookupAppLocalizations(locale);
  expect(find.text(l10n.fixIntro), findsOneWidget);
  return l10n.fixIntro;
}

void main() {
  testWidgets('English intro offers change or delete, sends moves to the '
      'editor', (tester) async {
    final intro = await _introShown(tester, const Locale('en'));
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(intro, startsWith('Say what to change or delete'));
    expect(intro, isNot(contains('change, move, or delete')));
    // The pointer names the tabs as the user sees them.
    expect(intro, contains(l10n.tabToday));
    expect(intro, contains(l10n.tabHistory));
    expect(intro, contains('date or time'));
  });

  testWidgets('Chinese intro offers 改/删 only, sends 挪 to the editor',
      (tester) async {
    final intro = await _introShown(tester, const Locale('zh'));
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(intro, startsWith('说出要改或要删的内容'));
    expect(intro, isNot(contains('要挪')));
    expect(intro, contains('「${l10n.tabToday}」'));
    expect(intro, contains('「${l10n.tabHistory}」'));
    expect(intro, contains('修改日期或时间'));
  });
}
