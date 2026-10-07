/// The chat executor speaks the APP language, not English (testing loop
/// 2026-10-07): every reply template the executor authors itself — the
/// missing-key refusal, "type something first", the AI-error line, the
/// no-food line, the invalid-index line, the correction summary, the delete
/// staging/confirmation/cancel lines and the "added" line — comes from the
/// ARB, and the staged-delete meal label uses the locale clock (24-hour in
/// Chinese) and 千卡. Model-authored text (chat replies, 💬 reason) is passed
/// through untouched. The English values are pinned byte-identical by
/// executor_test.dart / delete_confirmation_test.dart; this file pins zh.
library;

import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/nl/executor.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'executor_test.dart' show roastDuckAnalysis;
import 'fakes.dart';

void main() {
  late FakeDao dao;
  late FakeAnalyzer analyzer;
  late AppSettings settings;
  late DefaultNlExecutor exec;

  setUpAll(() => initializeDateFormatting('zh'));

  setUp(() async {
    dao = FakeDao();
    analyzer = FakeAnalyzer();
    settings = await testSettings();
    exec = DefaultNlExecutor(dao, analyzer, settings, l10n: AppLocalizationsZh());
  });

  test('staged delete: Chinese header, 24-hour clock, 千卡, Chinese footer',
      () async {
    dao.seed('白粥', 150, time: '08:00 AM');
    final dinnerId = dao.seed('米饭', 400, time: '07:00 PM');
    final snapshot = await dao.recentMeals();

    final replies = await exec.executeParsed([
      {'intent': 'delete', 'meal_indices': [1], 'reason': '用户要求删除晚饭'},
    ], '删除晚饭', snapshot);

    final r = replies.single;
    expect(r.needsDeleteConfirmation, isTrue);
    expect(r.pendingDeleteIds, [dinnerId]);
    expect(r.text, startsWith('🗑️ 删除 1 顿餐？'));
    expect(r.pendingDeleteLabels.single, contains('米饭'));
    expect(r.pendingDeleteLabels.single, contains('19:00'),
        reason: 'zh clocks are 24-hour');
    expect(r.pendingDeleteLabels.single, contains('~400 千卡'));
    expect(r.text, isNot(contains('PM')));
    expect(r.text, isNot(contains('kcal')));
    expect(r.text, contains('💬 用户要求删除晚饭'), reason: 'reason passes through');
    expect(r.text, endsWith('此操作无法撤销。'));

    // Cancel and confirm lines.
    expect(await exec.confirmPendingDelete(const []), '👍 已取消——没有删除任何记录。');
    final done = await exec.confirmPendingDelete([dinnerId]);
    expect(done, startsWith('🗑️ 已删除 1 顿餐：'));
    expect(done, contains('19:00'));
    expect(dao.deletedIds, [dinnerId]);
  });

  test('correction summary is Chinese with 千卡 on both sides', () async {
    dao.seed('白粥', 150, time: '08:00 AM');
    dao.seed('面条', 550, time: '12:30 PM');
    final snapshot = await dao.recentMeals();
    final replies = await exec.executeParsed([
      {'intent': 'correction', 'meal_index': 1, 'reason': '第二顿改为烧鸭饭', 'analysis': roastDuckAnalysis},
    ], '第二顿是烧鸭饭', snapshot);
    final text = replies.single.text;
    expect(text, startsWith('✏️ 已修正第 2 顿餐！'));
    expect(text, contains('面条 → 烧鸭饭'));
    expect(text, contains('🔥 550 千卡 → 780 千卡（+230）'));
    expect(text, contains('💬 第二顿改为烧鸭饭'));
    expect(text, isNot(contains('kcal')));
  });

  test('invalid index, no food, type-first and AI-error lines are Chinese',
      () async {
    dao.seed('白粥', 150);
    final snapshot = await dao.recentMeals();
    final bad = await exec.executeParsed(
        [{'intent': 'correction', 'meal_index': 7, 'analysis': roastDuckAnalysis}],
        'x', snapshot);
    expect(bad.single.text, '❌ 餐次编号无效（7）。你最近有 1 顿餐。');

    final noFood = await exec.executeParsed(
        [{'intent': 'new_meal', 'analysis': {'is_food': false}}], 'x', snapshot);
    expect(noFood.single.text, '🚫 这段描述里没有识别出食物。');

    expect((await exec.describeMeal('   ')).error, '先输入你吃了什么。');

    analyzer.next = null; // transport/parse failure folded to null
    expect((await exec.handleText('hi')).single.text, '❌ 联系 AI 失败，请重试。');
    expect((await exec.describeMeal('two eggs')).error, '❌ 联系 AI 失败，请重试。');
  });

  test('added-meal header is Chinese; model-authored chat passes through',
      () async {
    final added = await exec.executeParsed(
        [{'intent': 'new_meal', 'analysis': roastDuckAnalysis}], 'x', const []);
    expect(added.single.text, startsWith('✅ 已添加手动记录的一餐：'));
    final chat = await exec.executeParsed(
        [{'intent': 'chat', 'reply': 'Sure thing!'}], 'x', const []);
    expect(chat.single.text, 'Sure thing!');
  });

  test('missing key refusal is Chinese and names Settings', () async {
    SharedPreferences.setMockInitialValues(const {});
    final keyless = await AppSettings.load(
        prefs: await SharedPreferences.getInstance(), keyStore: MemoryKeyStore());
    await keyless.setProvider(AiProvider.qwen);
    final e = DefaultNlExecutor(dao, analyzer, keyless, l10n: AppLocalizationsZh());
    final text = (await e.handleText('记一杯拿铁')).single.text;
    expect(text, contains('Qwen'));
    expect(text, contains('「设置」'));
    expect(text, isNot(contains('Settings')));
    expect(analyzer.lastPrompt, isNull);
  });

  test('without an injected l10n the language follows the live setting',
      () async {
    final live = DefaultNlExecutor(dao, analyzer, settings);
    dao.seed('白粥', 150);
    final snapshot = await dao.recentMeals();
    final action = [{'intent': 'correction', 'meal_index': 9, 'analysis': roastDuckAnalysis}];
    await settings.setAppLanguage('en');
    expect((await live.executeParsed(action, 'x', snapshot)).single.text,
        '❌ Invalid meal index (9). You have 1 recent meals.');
    await settings.setAppLanguage('zh'); // switched at runtime, same executor
    expect((await live.executeParsed(action, 'x', snapshot)).single.text,
        '❌ 餐次编号无效（9）。你最近有 1 顿餐。');
  });
}
