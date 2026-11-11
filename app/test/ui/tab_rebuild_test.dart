// Run 7 (P4): a tab tap rebuilt all four IndexedStack screens, visible or
// not — the hidden Body screen re-derived its whole history on every tap.
// Only the selected tab rebuilds now, and it still rebuilds IN the tap
// frame: a units change made in Settings must be on Body's first frame,
// not after its (async) reload lands.
import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/screens/body_screen.dart';
import 'package:calorie_tracker/ui/screens/history_screen.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Body's weights arrive a little later, as sqflite's do on a device.
class _SlowBodyDao extends FakeDao {
  @override
  Future<List<WeightEntry>> listBodyWeights(
      String startDate, String endDate) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return super.listBodyWeights(startDate, endDate);
  }
}

Finder _navTab(String label) => find.descendant(
    of: find.byType(NavigationBar), matching: find.text(label));

T _tab<T extends Widget>(WidgetTester tester) =>
    tester.widget<T>(find.byType(T, skipOffstage: false));

void main() {
  testWidgets('a tab tap rebuilds only the tab it selects', (tester) async {
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: FakeSettings())));
    await tester.pumpAndSettle();
    final today = _tab<TodayScreen>(tester);
    final history = _tab<HistoryScreen>(tester);
    final body = _tab<BodyScreen>(tester);
    final settings = _tab<SettingsScreen>(tester);

    await tester.tap(_navTab('History'));
    await tester.pump();
    expect(identical(_tab<HistoryScreen>(tester), history), isFalse,
        reason: 'the selected tab rebuilds in the tap frame');
    expect(identical(_tab<TodayScreen>(tester), today), isTrue);
    expect(identical(_tab<BodyScreen>(tester), body), isTrue);
    expect(identical(_tab<SettingsScreen>(tester), settings), isTrue);
    await tester.pumpAndSettle();

    final historyNow = _tab<HistoryScreen>(tester);
    await tester.tap(_navTab('Body'));
    await tester.pump();
    expect(identical(_tab<BodyScreen>(tester), body), isFalse);
    expect(identical(_tab<HistoryScreen>(tester), historyNow), isTrue);
    expect(identical(_tab<TodayScreen>(tester), today), isTrue);
    expect(identical(_tab<SettingsScreen>(tester), settings), isTrue);
    await tester.pumpAndSettle();

    await tester.tap(_navTab('Today'));
    await tester.pump();
    expect(identical(_tab<TodayScreen>(tester), today), isFalse);
    expect(find.byKey(const Key('addMealFab')), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a units change made in Settings is on Body\'s first frame',
      (tester) async {
    final dao = _SlowBodyDao();
    final date = DateTime.now().toIso8601String().substring(0, 10);
    dao.weightsByDate[date] = WeightEntry(date, 81.6, source: 'manual');
    final settings = FakeSettings();
    await tester.pumpWidget(CalorieTrackerApp(
        services: makeServices(dao: dao, settings: settings)));
    await tester.pumpAndSettle();
    String headline() => tester
        .widget<Text>(find.byKey(const Key('bodyWeightHeadline')))
        .data!;

    await tester.tap(_navTab('Body'));
    await tester.pumpAndSettle();
    expect(headline(), '81.6');

    await tester.tap(_navTab('Settings'));
    await tester.pumpAndSettle();
    await settings.update(units: 'imperial');
    await tester.pump();

    await tester.tap(_navTab('Body'));
    await tester.pump(); // the tap frame: the reload still waits on the DAO
    expect(headline(), '179.9', reason: 'no stale kg frame before the reload');
    await tester.pumpAndSettle();
    expect(headline(), '179.9');
  });
}
