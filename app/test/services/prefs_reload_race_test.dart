// A choice or a count made while a prefs.reload() is on its way is kept
// (2026-11-10).
//
// The app engine has ONE SharedPreferences instance. Other code on it
// calls reload() while the app is in use: recordLateImportPass after every
// late-import pass (launch, resume, every library change), the background
// watermark, each photo's deferred note. reload() is
// `await getAll(); cache.clear(); cache.addAll(reply)`: a write made while
// the reply is on its way reaches the platform store, and is then wiped
// from the Dart cache when the older reply lands. UsualChoices (Hide, Keep
// AI estimate) and AssistDailyBudget (the 20-a-day lookup cap) used to
// read that cache on every use, so the choice came back undone — and the
// next one, built from the stale cache and written whole, erased it from
// storage for good — and a counted lookup was uncounted again.
//
// The default mock store answers in a microtask and cannot show this; the
// store here answers the way a method channel does.
import 'dart:async';

import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart'
    show LookupCost;
import 'package:calorie_tracker/services/photo/photo_changes.dart';
import 'package:calorie_tracker/services/usual/usual_choices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/types.dart';

/// The platform store as a phone has it: a getAll answers with what was
/// stored WHEN IT WAS HANDLED, and the answer reaches Dart a moment later
/// ([gate]). Messages are handled in the order they were sent.
class _SlowReplyStore extends InMemorySharedPreferencesStore {
  _SlowReplyStore() : super.empty();

  /// What the platform holds now (prefixed keys).
  final Map<String, Object> data = {};

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    data[key] = value;
    return super.setValue(valueType, key, value);
  }

  Completer<void>? gate;

  @override
  Future<Map<String, Object>> getAll() async {
    final snapshot = await super.getAll(); // handled now
    final g = gate;
    if (g != null) await g.future; // the reply is still on its way
    return snapshot;
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    final snapshot = await super.getAllWithParameters(parameters);
    final g = gate;
    if (g != null) await g.future;
    return snapshot;
  }
}

void main() {
  late _SlowReplyStore store;
  late SharedPreferences prefs;

  setUp(() async {
    store = _SlowReplyStore();
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    prefs = await SharedPreferences.getInstance();
  });

  /// Runs [during] while a late-import pass records itself — the real
  /// recordLateImportPass, its reload's reply on its way — then lets the
  /// reply land.
  Future<void> whileReloading(FutureOr<void> Function() during) async {
    store.gate = Completer<void>();
    final pass = recordLateImportPass(const LateImportReport('ok'));
    await pumpEventQueue(); // the reload's getAll is handled; reply pending
    await during();
    await pumpEventQueue(); // the write reaches the platform store
    store.gate!.complete();
    store.gate = null;
    await pass;
  }

  String? storedChoices() =>
      store.data['flutter.$usualChoicesPrefsKey'] as String?;

  group('UsualChoices', () {
    const first = '0123456789abcdef';
    const second = 'fedcba9876543210';

    test('Hide tapped while a reload is on its way stays hidden', () async {
      final choices = UsualChoices(prefs);
      await whileReloading(() => choices.hide(first));
      expect(storedChoices(), contains(first),
          reason: 'the hide reached the platform store');
      expect(prefs.getString(usualChoicesPrefsKey), isNull,
          reason: 'the race itself: the older reply wiped the shared cache');
      expect(choices.view().isHidden(first), isTrue,
          reason: 'the row must not come back');
    });

    test('the next choice keeps the one before it in the stored value',
        () async {
      final choices = UsualChoices(prefs);
      await whileReloading(() => choices.hide(first));
      await choices.hide(second);
      await pumpEventQueue();
      expect(storedChoices(), allOf(contains(first), contains(second)));
      // A restart reads both.
      await prefs.reload();
      final again = UsualChoices(prefs).view();
      expect(again.hidden, {first, second});
    });

    test('Undo after such a hide shows the row again, for good', () async {
      final choices = UsualChoices(prefs);
      await whileReloading(() => choices.hide(first));
      await choices.unhide(first);
      await pumpEventQueue();
      expect(choices.view().isHidden(first), isFalse);
      expect(storedChoices(), isNot(contains(first)),
          reason: 'an unhide that found nothing in the stale cache wrote '
              'nothing, and the hide came back with the next reload');
      await prefs.reload();
      expect(choices.view().isHidden(first), isFalse);
      expect(UsualChoices(prefs).view().isHidden(first), isFalse);
    });

    test('Keep AI estimate tapped while a reload is on its way is kept',
        () async {
      final now = DateTime.utc(2026, 11, 10, 12);
      final choices = UsualChoices(prefs, clock: () => now);
      await whileReloading(() => choices.decline(42, [first]));
      expect(choices.view().mealDeclined(42, now: now), isTrue);
      await choices.decline(43, [second]);
      await pumpEventQueue();
      await prefs.reload();
      final again = UsualChoices(prefs, clock: () => now).view();
      expect({for (final d in again.declined) d.mealId}, {42, 43});
    });
  });

  group('AssistDailyBudget', () {
    var now = DateTime(2026, 11, 10, 12);
    setUp(() => now = DateTime(2026, 11, 10, 12));

    test('a lookup counted while a reload is on its way stays counted: the '
        'cap lets no extra one through', () async {
      final budget = AssistDailyBudget(prefs, cap: 1, clock: () => now);
      await whileReloading(() {
        expect(budget.tryStartLookup(0), isTrue); // lookup 1 of 1
        expect(budget.capReached, isTrue);
      });
      expect(prefs.getString(assistDailyPrefsKey), isNull,
          reason: 'the race itself: the older reply wiped the shared cache');
      expect(budget.capReached, isTrue);
      expect(budget.tryStartLookup(0), isFalse,
          reason: 'a second lookup on a cap of 1');
      expect(budget.lookupsToday, 1);
    });

    test('what a lookup cost, recorded while a reload is on its way, still '
        'counts against the dollar ceiling', () async {
      final budget =
          AssistDailyBudget(prefs, maxUsdPerDay: 0.10, clock: () => now);
      expect(budget.tryStartLookup(0.06), isTrue);
      await whileReloading(
          () => budget.recordSpend(const LookupCost(estimatedUsd: 0.06)));
      expect(budget.tryStartLookup(0.05), isFalse, reason: '0.06 + 0.05');
      // The next write carries the whole day, and a restart reads it.
      expect(budget.tryStartLookup(0.03), isTrue);
      await pumpEventQueue();
      await prefs.reload();
      final again =
          AssistDailyBudget(prefs, maxUsdPerDay: 0.10, clock: () => now);
      expect(again.lookupsToday, 2);
      expect(again.tryStartLookup(0.05), isFalse,
          reason: 'the 0.06 spent is in the stored value');
    });

    test('a new local day still starts from zero, and a restart keeps the '
        'day\'s count', () async {
      final budget = AssistDailyBudget(prefs, cap: 2, clock: () => now);
      await whileReloading(() => budget.tryStartLookup(0));
      expect(budget.tryStartLookup(0), isTrue);
      expect(budget.capReached, isTrue);
      await pumpEventQueue();
      await prefs.reload();
      expect(AssistDailyBudget(prefs, cap: 2, clock: () => now).capReached,
          isTrue);
      now = DateTime(2026, 11, 11, 0, 1);
      expect(budget.lookupsToday, 0);
      expect(budget.tryStartLookup(0), isTrue);
    });
  });
}
