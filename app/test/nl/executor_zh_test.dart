/// The chat executor speaks the APP language, not English (testing loop
/// 2026-10-07): every reply template the executor authors itself — the
/// missing-key refusal, "type something first", the AI-error line, the
/// no-food line, the invalid-index line, the correction summary, the delete
/// staging/confirmation/cancel lines, the "added" line, and (second pass,
/// same loop) the delete/correction refusals, the silent-delete guard, the
/// weight and activity lines, the no-action and failure-tally lines, the
/// blank-chat fallback and the describe-meal multi-meal warning — comes from
/// the ARB, and the staged-delete meal label uses the locale clock (24-hour
/// in Chinese) and 千卡. Model-authored text (chat replies, 💬 reason) is
/// passed through untouched. The English values are pinned byte-identical by
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
  test('delete refusals are Chinese: no meals, no indices, no match', () async {
    final noMeals = await exec.executeParsed(
        [{'intent': 'delete', 'meal_indices': [0]}], '删除', const []);
    expect(noMeals.single.text, '❌ 最近没有记录任何餐，无法删除。');

    dao.seed('白粥', 150);
    final snapshot = await dao.recentMeals();
    final which = await exec.executeParsed([{'intent': 'delete'}], '删除', snapshot);
    expect(which.single.text, '❌ 没听清要删除哪几顿餐，请说得具体一点。');
    expect(which.single.needsDeleteConfirmation, isFalse);

    final noMatch = await exec.executeParsed(
        [{'intent': 'delete', 'meal_indices': [7]}], '删除', snapshot);
    expect(noMatch.single.text, '❌ 在最近的记录里没有找到对应的餐。');
    expect(dao.deletedIds, isEmpty);
  });

  test('correction refusals are Chinese: no meals, silent-delete guard',
      () async {
    final noMeals = await exec.executeParsed(
        [{'intent': 'correction', 'meal_index': 0, 'analysis': roastDuckAnalysis}],
        '改', const []);
    expect(noMeals.single.text, '❌ 最近没有记录任何餐，无法修正。');

    dao.seed('白粥', 150);
    final snapshot = await dao.recentMeals();
    final guarded = await exec.executeParsed(
        [{'intent': 'correction', 'meal_index': 0, 'analysis': {'is_food': false}}],
        '改', snapshot);
    expect(guarded.single.text, startsWith('❌ 这次修正没有给出可用的新分析'));
    expect(guarded.single.text, contains('780 千卡'));
    expect(guarded.single.text, isNot(contains('kcal')));
    expect(dao.updates, isEmpty, reason: 'the guard refuses, it does not write');
  });

  test('weight and activity replies are Chinese with 公斤 / 步 / 公里', () async {
    final weight = await exec.executeParsed(
        [{'intent': 'log_weight', 'weight_kg': 72.5}], '记一下体重', const []);
    expect(dao.savedWeights.single.$2, 72.5);
    expect(weight.single.text, startsWith('⚖️ 已记录 '));
    expect(weight.single.text, endsWith(' 的体重：72.5 公斤。'));
    expect(weight.single.text, isNot(contains('kg')));

    final badWeight = await exec.executeParsed(
        [{'intent': 'log_weight', 'weight_kg': '72.5'}], '记一下体重', const []);
    expect(badWeight.single.text,
        '⚖️ 没有读到有效的体重（30–300 公斤）。试试「我今天 72.5 公斤」。');

    final activity = await exec.executeParsed([
      {'intent': 'log_activity', 'active_calories': 450, 'steps': 8000, 'distance_km': 5},
    ], '跑步', const []);
    expect(dao.savedActivities.single['steps'], 8000);
    expect(activity.single.text,
        startsWith('🏃 已记录活动：450 千卡 · 8,000 步 · 5 公里（'));
    expect(activity.single.text, endsWith('）。'));
    expect(activity.single.text, isNot(contains('kcal')));
    expect(activity.single.text, isNot(contains('steps')));
    expect(activity.single.text, isNot(contains('km')));

    final noActivity = await exec.executeParsed(
        [{'intent': 'log_activity', 'steps': 'many'}], '跑步', const []);
    expect(noActivity.single.text,
        '🏃 没有找到可记录的运动数据。试试「跑了 5 公里，消耗 450 千卡」。');
  });

  test('no-action, failure-tally and blank-chat lines are Chinese', () async {
    final nothing = await exec.executeParsed('just a string', 'x', const []);
    expect(nothing.single.text, startsWith('❌ 我没弄明白该做什么。'));

    dao.seed('白粥', 150);
    dao.seed('面条', 550);
    final snapshot = await dao.recentMeals();
    dao.throwOnUpdate = true;
    final one = await exec.executeParsed(
        [{'intent': 'correction', 'meal_index': 0, 'analysis': roastDuckAnalysis}],
        'x', snapshot);
    expect(one.single.text, '❌ 这个请求失败了，请重试。');

    final all = await exec.executeParsed([
      {'intent': 'correction', 'meal_index': 0, 'analysis': roastDuckAnalysis},
      {'intent': 'correction', 'meal_index': 1, 'analysis': roastDuckAnalysis},
    ], 'x', snapshot);
    expect(all.single.text, '❌ 请求的 2 项操作全部失败，请重试。');

    final some = await exec.executeParsed([
      {'intent': 'correction', 'meal_index': 0, 'analysis': roastDuckAnalysis},
      {'intent': 'chat', 'reply': '还在'},
    ], 'x', snapshot);
    expect(some.first.text, '还在', reason: 'model-authored chat passes through');
    expect(some.last.text, '⚠️ 请求的 2 项操作中有 1 项失败——其余已生效。');

    final blank =
        await exec.executeParsed({'intent': 'chat', 'reply': '  '}, 'x', const []);
    expect(blank.single.text, '我不太明白你的意思。试着描述一顿餐，或者说说要改什么吧！');
  });

  test('describe-meal multi-meal warning is Chinese', () async {
    analyzer.next = {
      'actions': [
        {'intent': 'new_meal', 'analysis': roastDuckAnalysis},
        {'intent': 'new_meal', 'analysis': roastDuckAnalysis},
      ],
    };
    final out = await exec.describeMeal('烧鸭饭和一碗粥');
    expect(out.ok, isTrue);
    expect(out.warning, '这段描述包含 2 顿餐——这里只显示第一顿。其余的请一次描述一顿。');
  });
}
