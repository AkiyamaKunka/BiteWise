// Saved lookup answers and your usual numbers, end to end.
//
// The owner's setup: their own server on Claude Plan, where a lookup's
// answer is a search summary, so the app only ever suggests it. The
// stories run through the app's real parts (harness.dart): the real
// MealAssist with its local state, daily ledger and settings, the real
// usual-foods service reading the same settings, and the real Today,
// editor and Settings screens. Only the lookup's network call is a stub,
// and it counts every request that would have been sent.
//
//   1. Three Mondays at McDonald's and at a local burrito place: who owns
//      a meal (your usual numbers or the lookup), a saved answer used
//      again, Search again, Stop Sharing, the daily cap.
//   2. A year of the same order, on a real folder: how long a found
//      answer and an answer that found nothing are kept.
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart';
import 'package:calorie_tracker/ui/screens/meal_editor_screen.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// A burrito bowl at a local place: a restaurant meal with nothing
/// printed that names a chain.
Map<String, dynamic> burritoBowl(num kcal) => aiSays(
      [foodItem('Burrito bowl', kcal, p: 35, c: 70, f: 22)],
      description: 'Burrito bowl',
      context: 'restaurant',
    );

/// The one food a request asks about.
String orderOf(LookupRequest request) =>
    (request.items.single as Map)['name'] as String;

/// The saved answers as stored: key → entry.
Map<String, Map<String, dynamic>> savedAnswers(MemoryDocStore docs) {
  final text = docs.files[assistCacheDocument];
  if (text == null) return {};
  final entries = (jsonDecode(text) as Map)['entries'] as List;
  return {
    for (final e in entries.cast<Map>())
      e['key'] as String: e.cast<String, dynamic>(),
  };
}

void main() {
  useInProcessSqlite();

  testWidgets('three Mondays: the usual chip while lookups are off, the '
      'lookup owns restaurant meals once on, a saved answer answers the '
      'next visit with no request, Search again keeps a suggestion, Stop '
      'Sharing and the daily cap read no saved answer', (tester) async {
    final l = copyFor(const Locale('en'));
    final phone = await Phone.boot(DateTime(2026, 10, 5, 12, 30));
    addTearDown(phone.shutDown);
    // The assist runs as in the app: it sweeps 5 s after a meal lands or
    // the app comes back, and listens to Settings.
    phone.assist.start();
    try {
      Future<int> photoLands(Map<String, dynamic> reply) async {
        final id = await phone.photo(reply);
        await tester.pumpAndSettle();
        return id;
      }

      Future<void> newDay(DateTime at) async {
        await dismissSnackBar(tester);
        phone.now = at;
        await reopen(tester);
      }

      /// The assist's settle delay passes, and its sweep runs.
      Future<void> sweepRuns() => phone.wait(tester, kAssistSettleDelay);

      Finder card(int id) => find.byKey(ValueKey('meal$id'));
      Finder usualChip(int id) => find.descendant(
          of: card(id), matching: find.byKey(const Key('usualChip')));
      Finder assistChip(int id) => find.descendant(
          of: card(id), matching: find.byKey(const Key('assistChip')));
      Future<void> openEditor(int id, String title) async {
        await tester.tap(
            find.descendant(of: card(id), matching: find.text(title)));
        await tester.pumpAndSettle();
        expect(find.byType(MealEditorScreen), findsOneWidget);
      }

      Future<void> editKcal(int id, String title, String kcal) async {
        await openEditor(id, title);
        await tester.enterText(find.byKey(const Key('itemCal0')), kcal);
        await tester.pump();
        await tester.tap(find.byKey(const Key('saveMealButton')));
        await tester.pumpAndSettle();
      }

      String viaLine() =>
          tester.widget<Text>(find.byKey(const Key('assistVia'))).data!;
      Future<Map<String, dynamic>?> blockOf(int id) async =>
          ((await phone.analysis(id))['assist'] as Map?)
              ?.cast<String, dynamic>();
      const bigMacTitle = 'A Big Mac in its box';
      final chipText = l.assistChipSuggested("McDonald's", '590');
      expect(chipText, "McDonald's publishes 590 kcal — tap to review");

      await pumpApp(tester, phone);

      // ═══ Monday 5 October: lookups off ════════════════════════════════

      // The owner fixes both lunches of the week by hand: the burrito bowl
      // is 700, the Big Mac 600.
      final bowl0 = await photoLands(burritoBowl(620));
      await editKcal(bowl0, 'Burrito bowl', '700');
      phone.now = DateTime(2026, 10, 5, 19, 0);
      final mac0 = await photoLands(bigMacAnalysis());
      await editKcal(mac0, bigMacTitle, '600');
      await sweepRuns();
      expect(phone.lookups.submits, isEmpty);
      // Off reads nothing. (Today itself reads which cards carry the
      // "updated" dot at every reload; that is the only document touched.)
      expect(phone.memory.reads.toSet(), {assistUnseenDocument});

      // ═══ Monday 12 October ════════════════════════════════════════════

      // 12:30, lookups still off: the burrito bowl gets the usual chip.
      await newDay(DateTime(2026, 10, 12, 12, 30));
      final bowl1 = await photoLands(burritoBowl(600));
      expect(
          find.descendant(
              of: usualChip(bowl1),
              matching:
                  find.text(l.usualItemLine('Burrito bowl', '600', '700'))),
          findsOneWidget);
      // A Big Mac in its printed box never does, off or on: a food with a
      // chain's name on it is the lookup's, not the usual numbers'.
      phone.now = DateTime(2026, 10, 12, 12, 35);
      final macOff = await photoLands(bigMacAnalysis());
      expect(usualChip(macOff), findsNothing);
      expect(assistChip(macOff), findsNothing);
      await sweepRuns();
      expect(phone.lookups.submits, isEmpty);
      expect(phone.memory.reads.toSet(), {assistUnseenDocument});
      expect(await blockOf(macOff), isNull);

      // 12:45 The owner turns lookups on (Always) and comes back to Today.
      // The burrito bowl is a restaurant meal, so it is the lookup's now:
      // its usual chip is gone, though nothing printed names a chain and
      // no request is sent for it.
      phone.now = DateTime(2026, 10, 12, 12, 45);
      await phone.turnLookupsOn('always');
      await reopen(tester);
      expect(usualChip(bowl1), findsNothing);
      expect(find.byKey(const Key('usualChip')), findsNothing);

      // The server takes a while: a lookup is a job there, asked about
      // again 10 s later.
      var jobs = 0;
      phone.lookups.onSubmit = (_) async => LookupOutcome(
            kind: LookupOutcomeKind.pending,
            provider: LookupRecipient.claudePlan,
            jobId: 'job_0000000${++jobs}',
          );
      final mac1 = await photoLands(bigMacAnalysis());
      expect(usualChip(mac1), findsNothing);
      expect(assistChip(mac1), findsNothing);
      await sweepRuns();
      // One request: this Big Mac. Not the burrito bowl (nothing printed
      // names a chain), and not the Big Mac of 12:35, logged before the
      // owner agreed to lookups.
      expect(phone.lookups.submits, hasLength(1));
      expect(phone.lookups.submits.single.chainKeys, ['mcdonalds']);
      expect(orderOf(phone.lookups.submits.single), 'Big Mac');
      expect(await blockOf(mac1), isNull);
      expect(assistChip(mac1), findsNothing);

      // Ten seconds later the first answer is there: a suggestion, on the
      // chip. The meal's numbers are not touched.
      await phone.wait(tester, kAssistPollInterval);
      expect(phone.lookups.polls, ['job_00000001']);
      final block1 = (await blockOf(mac1))!;
      expect(block1['status'], AssistStatus.suggested);
      expect(block1['reason'], AssistReason.notGrounded,
          reason: 'Claude Plan: a search summary is only ever suggested');
      expect(block1['grounded'], isFalse);
      expect(block1['provider'], 'claude_plan');
      expect(block1['trigger'], 'always');
      expect(block1.containsKey('fetched_on'), isFalse);
      expect((await phone.analysis(mac1))['total_calories'], 540);
      expect(await phone.corrected(mac1), isFalse);
      expect(find.descendant(of: assistChip(mac1), matching: find.text(chipText)),
          findsOneWidget);
      expect(usualChip(mac1), findsNothing);
      // The answer is kept on the phone.
      final kept = savedAnswers(phone.memory);
      expect(kept, hasLength(1));
      expect((kept.values.single['result'] as Map)['status'], 'found');
      expect(await blockOf(macOff), isNull);
      expect(await blockOf(bowl1), isNull);
      expect(find.byKey(const Key('usualChip')), findsNothing);
      phone.lookups.onSubmit = null;
      const sentMonday = 1;

      // In the editor: who answered, and when.
      await openEditor(mac1, bigMacTitle);
      expect(viaLine(), l.assistVia(l.planShortClaude, '2026-10-12'));
      expect(find.text(l.assistNotGrounded), findsOneWidget);
      expect(find.byKey(const Key('assistUsePublished')), findsOneWidget);
      expect(find.byKey(const Key('assistSearchAgain')), findsNothing);
      expect(find.byKey(const Key('usualOfferCard')), findsNothing);
      await goBack(tester);

      // ═══ Monday 19 October ════════════════════════════════════════════

      // The same order. The saved answer answers it: no request at all.
      await newDay(DateTime(2026, 10, 19, 12, 30));
      final mac2 = await photoLands(bigMacAnalysis());
      await sweepRuns();
      expect(phone.lookups.submits, hasLength(sentMonday),
          reason: 'zero requests for the second visit');
      final block2 = (await blockOf(mac2))!;
      expect(block2['status'], AssistStatus.suggested);
      expect(block2['fetched_on'], '2026-10-12');
      expect(block2['decided_on'], '2026-10-19');
      expect(find.descendant(of: assistChip(mac2), matching: find.text(chipText)),
          findsOneWidget);
      await openEditor(mac2, bigMacTitle);
      expect(viaLine(), l.assistViaSaved(l.planShortClaude, '2026-10-12'));
      expect(viaLine(), 'via Claude (server) · saved answer from 2026-10-12');

      // Search again, and this time the search finds nothing published.
      // The suggestion stays on the meal, the screen says so, and the
      // saved answer is not replaced by the empty one.
      phone.lookups.onSubmit = (_) async => planAnswer(nothingPublished());
      final suggestion = await phone.raw(mac2);
      await tester.tap(find.byKey(const Key('assistSearchAgain')));
      await tester.pumpAndSettle();
      expect(phone.lookups.submits, hasLength(sentMonday + 1));
      expect(find.text(l.assistSearchAgainNoChange), findsOneWidget);
      expect(await phone.raw(mac2), suggestion);
      expect(find.byKey(const Key('assistUsePublished')), findsOneWidget);
      expect(
          (savedAnswers(phone.memory).values.single['result'] as Map)['status'],
          'found');
      phone.lookups.onSubmit = null;
      await dismissSnackBar(tester);
      await goBack(tester);

      // ═══ Monday 26 October ════════════════════════════════════════════

      // The owner opens the new photo before the app has looked it up:
      // Look up restaurant nutrition uses the saved answer, and says so.
      await newDay(DateTime(2026, 10, 26, 12, 30));
      final mac3 = await photoLands(bigMacAnalysis());
      expect(await blockOf(mac3), isNull);
      await openEditor(mac3, bigMacTitle);
      expect(find.text(l.assistLookUp), findsOneWidget);
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(phone.lookups.submits, hasLength(sentMonday + 1),
          reason: 'answered on the phone');
      expect(find.text(l.assistFoundSaved('2026-10-12')), findsOneWidget);
      expect(viaLine(), l.assistViaSaved(l.planShortClaude, '2026-10-12'));
      expect((await blockOf(mac3))!['fetched_on'], '2026-10-12');
      expect((await blockOf(mac3))!['trigger'], 'manual');
      // The next press asks the provider.
      await dismissSnackBar(tester);
      expect(find.byKey(const Key('assistLookUp')), findsNothing);
      await tester.tap(find.byKey(const Key('assistSearchAgain')));
      await tester.pumpAndSettle();
      expect(phone.lookups.submits, hasLength(sentMonday + 2));
      expect(viaLine(), l.assistVia(l.planShortClaude, '2026-10-26'));
      expect((await blockOf(mac3))!.containsKey('fetched_on'), isFalse);
      await goBack(tester);
      final sentBeforeStop = phone.lookups.submits.length;

      // 13:00 Another Big Mac and a burrito bowl land. Before the app
      // looks, the owner opens Settings and stops sharing with the server.
      phone.now = DateTime(2026, 10, 26, 13, 0);
      final mac4 = await photoLands(bigMacAnalysis());
      final bowl3 = await photoLands(burritoBowl(600));
      expect(usualChip(bowl3), findsNothing, reason: 'lookups are still on');
      await pushFromLog(
          tester,
          SettingsScreen(
            settings: phone.store,
            analyzer: phone.ai,
            dao: phone.dao,
            requestPhotoPermission: () async => true,
            changes: phone.settings,
            restaurantAssist: phone.controls,
          ));
      final stopRow = find.byKey(const Key('aiStopSharingRow'));
      await tester.scrollUntilVisible(stopRow, 300,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(stopRow);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('aiStopSharingConfirm')));
      await tester.pumpAndSettle();
      expect(phone.settings.restaurantAssist, 'off');
      expect(phone.settings.restaurantAssistConsentAt, isNull);
      expect(phone.settings.hasAiConsent('server:claude'), isFalse);
      await dismissSnackBar(tester);
      await goBack(tester);

      // Nothing is read and nothing is sent from here on: not by the
      // sweep, and not by a lookup asked for directly.
      phone.memory.reads.clear();
      await sweepRuns();
      await sweepRuns();
      expect(phone.memory.reads, isNot(contains(assistCacheDocument)));
      expect(phone.lookups.submits, hasLength(sentBeforeStop));
      expect(await blockOf(mac4), isNull);
      final refused = await phone.assist.lookupNow(mac4);
      expect(refused.wrote, isFalse);
      expect(refused.fromCache, isFalse);
      expect(refused.code, AssistSkip.consentNeeded);
      expect(phone.memory.reads, isNot(contains(assistCacheDocument)));
      expect(phone.lookups.submits, hasLength(sentBeforeStop));
      expect(await blockOf(mac4), isNull);
      // The saved answers themselves are still on the phone (Stop Sharing
      // keeps them), unread.
      expect(savedAnswers(phone.memory), isNotEmpty);
      // The editor offers no lookup, and with lookups off the burrito
      // bowl has its usual chip back.
      await reopen(tester);
      expect(
          find.descendant(
              of: usualChip(bowl3),
              matching:
                  find.text(l.usualItemLine('Burrito bowl', '600', '700'))),
          findsOneWidget);
      await openEditor(mac4, bigMacTitle);
      expect(find.byKey(const Key('assistLookUp')), findsNothing);
      expect(find.byKey(const Key('editorAssistCard')), findsNothing);
      await goBack(tester);

      // ═══ Tuesday 27 October: the daily cap ════════════════════════════

      // The owner allows sharing and lookups again. Twenty lookups have
      // already been made today (written to the ledger here, as twenty
      // lookups would have).
      await newDay(DateTime(2026, 10, 27, 12, 30));
      await phone.store.setAiConsent('server:claude', granted: true);
      await phone.turnLookupsOn('always');
      for (var i = 0; i < assistDailyCap; i++) {
        expect(phone.budget.tryStartLookup(0), isTrue);
      }
      expect(phone.assist.lookupsToday, assistDailyCap);
      final sentBeforeCap = phone.lookups.submits.length;
      final mac5 = await photoLands(bigMacAnalysis());
      phone.memory.reads.clear();
      await sweepRuns();
      // At the cap the saved answer is not used either.
      expect(await blockOf(mac5), isNull);
      expect(assistChip(mac5), findsNothing);
      expect(phone.memory.reads, isNot(contains(assistCacheDocument)));
      expect(phone.lookups.submits, hasLength(sentBeforeCap));
      await openEditor(mac5, bigMacTitle);
      await tester.tap(find.byKey(const Key('assistLookUp')));
      await tester.pumpAndSettle();
      expect(find.text(l.assistLookupDailyCap), findsOneWidget);
      expect(await blockOf(mac5), isNull);
      expect(phone.memory.reads, isNot(contains(assistCacheDocument)));
      expect(phone.lookups.submits, hasLength(sentBeforeCap));
      await dismissSnackBar(tester);
      await goBack(tester);

      // Wednesday morning: a new day's ledger. Yesterday's Big Mac is
      // still within a day, and the saved answer (Monday's fresh search)
      // answers it with no request.
      await newDay(DateTime(2026, 10, 28, 9, 0));
      await sweepRuns();
      expect(phone.assist.lookupsToday, 0);
      expect((await blockOf(mac5))?['fetched_on'], '2026-10-26');
      expect(phone.lookups.submits, hasLength(sentBeforeCap));
    } finally {
      phone.assist.dispose();
    }
  });

  test('a year of the same order, on a real folder: a found answer is '
      'used for 365 days from the day it was fetched, an answer that found '
      'nothing for 30', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final folder = Directory.systemTemp.createTempSync('e2e_saved_answers');
    addTearDown(() => folder.deleteSync(recursive: true));
    final start = DateTime(2026, 10, 12, 12, 30);
    final phone = await Phone.boot(start, folder: folder);
    addTearDown(phone.shutDown);
    await phone.turnLookupsOn('always');
    // Two orders at McDonald's: the Big Mac, whose numbers are published,
    // and a burger the search finds nothing for.
    Map<String, dynamic> mystery() {
      final a = bigMacAnalysis();
      (a['food_items'] as List).single['name'] = 'Mystery burger';
      return a;
    }

    phone.lookups.onSubmit = (request) async =>
        orderOf(request) == 'Big Mac'
            ? planAnswer(bigMacFound())
            : planAnswer(nothingPublished());

    /// Day [n] of the story at [hour]: both orders are logged and the app
    /// looks them up. How many requests that took, and the two blocks.
    Future<({int sent, Map? mac, Map? burger})> visit(int n,
        {int hour = 12}) async {
      phone.now = DateTime(start.year, start.month, start.day + n, hour, 30);
      final before = phone.lookups.submits.length;
      final mac = await phone.photo(bigMacAnalysis());
      final burger = await phone.photo(mystery());
      await phone.assist.sweep();
      return (
        sent: phone.lookups.submits.length - before,
        mac: (await phone.analysis(mac))['assist'] as Map?,
        burger: (await phone.analysis(burger))['assist'] as Map?,
      );
    }

    final first = await visit(0);
    expect(first.sent, 2);
    expect(first.mac!['status'], AssistStatus.suggested);
    expect(first.mac!.containsKey('fetched_on'), isFalse);
    // The store is a real file in the folder.
    expect(
        File('${folder.path}/bitewise_local/$assistCacheDocument.json')
            .existsSync(),
        isTrue);

    // Day 29: both answered on the phone.
    final day29 = await visit(29);
    expect(day29.sent, 0);
    expect(day29.mac!['fetched_on'], '2026-10-12');
    expect(day29.mac!['status'], AssistStatus.suggested);
    expect(day29.burger!['fetched_on'], '2026-10-12');

    // Day 30, an hour past the 30 days: the empty answer is asked for
    // again (using it on day 29 did not extend it); the found one is not.
    final day30 = await visit(30, hour: 13);
    expect(day30.sent, 1);
    expect(orderOf(phone.lookups.submits.last), 'Mystery burger');
    expect(day30.mac!['fetched_on'], '2026-10-12');
    expect(day30.burger!.containsKey('fetched_on'), isFalse);

    // Day 364 (across two clock changes where there are any): still the
    // answer of 12 October 2026.
    final day364 = await visit(364);
    expect(day364.mac!['fetched_on'], '2026-10-12');
    expect(orderOf(phone.lookups.submits.last), 'Mystery burger');

    // Day 365, an hour past the year: asked for again.
    final before = phone.lookups.submits.length;
    final day365 = await visit(365, hour: 13);
    expect(
        phone.lookups.submits
            .skip(before)
            .where((r) => orderOf(r) == 'Big Mac'),
        hasLength(1));
    expect(day365.mac!.containsKey('fetched_on'), isFalse);
    expect(day365.mac!['decided_on'], '2027-10-12');
  });
}
