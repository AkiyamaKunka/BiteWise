// Run 7 (U25): every cold launch without an AI key opened on Settings, even
// for someone who logs every meal by hand (Enter manually, no AI needed) —
// one extra tap before + Log, on every launch. Key-less installs that have
// never logged anything still land on the Settings onboarding.
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/di.dart';
import 'package:calorie_tracker/ui/refresh_signal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

void main() {
  testWidgets('key-less and nothing logged yet: Settings onboarding',
      (tester) async {
    await tester.pumpWidget(CalorieTrackerApp(
        services: makeServices(settings: FakeSettings(apiKey: ''))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('firstRunCard')), findsOneWidget);
    expect(find.byKey(const Key('addMealFab')), findsNothing);
  });

  testWidgets('key-less but logging by hand: opens on Today with + Log',
      (tester) async {
    final settings = FakeSettings(apiKey: '')..mealLogged = true;
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: settings)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('addMealFab')), findsOneWidget);
    expect(find.byKey(const Key('firstRunCard')), findsNothing);
  });

  testWidgets('the first saved meal is remembered, once', (tester) async {
    final settings = FakeSettings(apiKey: '');
    await tester.pumpWidget(
        CalorieTrackerApp(services: makeServices(settings: settings)));
    await tester.pumpAndSettle();
    expect(settings.mealLogged, isFalse);
    signalMealsChanged();
    await tester.pumpAndSettle();
    expect(settings.mealLogged, isTrue);
    signalMealsChanged();
    await tester.pumpAndSettle();
    expect(settings.markMealLoggedCalls, 1);
    // The tab on screen does not jump: only the next launch changes.
    expect(find.byKey(const Key('firstRunCard')), findsOneWidget);
  });

  test('the flag defaults off and survives a reload', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings =
        await AppSettings.load(prefs: prefs, keyStore: MemoryKeyStore());
    final store = createSettingsStore(settings);
    expect(store.mealLogged, isFalse);
    await store.markMealLogged();
    expect(store.mealLogged, isTrue);
    final reloaded =
        await AppSettings.load(prefs: prefs, keyStore: MemoryKeyStore());
    expect(reloaded.mealLogged, isTrue);
  });
}
