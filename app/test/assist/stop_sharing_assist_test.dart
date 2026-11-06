/// Settings › Stop Sharing with … and the restaurant assist, end to end on
/// the REAL settings: AppSettings behind di.dart's SettingsStore adapter,
/// the real lookup router's word on who a lookup would reach (the own
/// server on the Claude plan), and MealAssist wired to them the way di.dart
/// wires it.
///
/// stopRestaurantAssistFor — what the row calls first, before it withdraws
/// the AI consent — makes the settings say Off and no consent AT ONCE:
/// before anything is saved and before the notification. Once the write
/// has landed, the engine has cancelled the call in flight, discards its
/// answer and forgets its pending jobs. Nothing is sent afterwards, and
/// allowing AI analysis again does not bring the lookups back.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_clients.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/clients/server_lookup_client.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/ai_consent.dart' show currentAiConsentRoute;
import 'package:calorie_tracker/ui/di.dart' show createSettingsStore;
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/services.dart' show SettingsStore;
import 'package:calorie_tracker/ui/widgets/restaurant_consent_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/fakes.dart';

final DateTime _now = DateTime(2026, 10, 24, 13, 0);
final DateTime _consentAt = DateTime(2026, 10, 24, 8, 0);
const String _today = '2026-10-24';
const String _url = 'https://www.mcdonalds.com/us/en-us/product/big-mac.html';

class _Keys implements SecureKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

Map<String, dynamic> _bigMac() => {
  'is_food': true,
  'food_items': [
    {
      'name': 'Big Mac',
      'estimated_calories': 540,
      'protein_g': 24,
      'carbs_g': 44,
      'fat_g': 30,
      'brand': "McDonald's",
      'qty': 1,
      'unit': 'sandwich',
    },
  ],
  'total_calories': 540,
  'total_protein_g': 24,
  'total_carbs_g': 44,
  'total_fat_g': 30,
  'meal_description': "A Big Mac in its McDonald's box",
  'estimate_confidence': 'low',
  'restaurant_context': 'restaurant',
  'portion_state': 'whole',
  'order_merchant': '',
};

/// A clean found answer from the own server: written as a suggestion
/// unless it is discarded.
LookupOutcome _done() => LookupOutcome(
  kind: LookupOutcomeKind.done,
  provider: LookupRecipient.claudePlan,
  result: LookupResult.parse({
    'status': 'found',
    'chain_key': 'mcdonalds',
    'restaurant_name': "McDonald's",
    'matches': [
      {
        'item_index': 0,
        'menu_item': 'Big Mac',
        'match_type': 'exact_item',
        'is_drink': false,
        'components': <Object>[],
        'options': [
          {
            'label': '',
            'serving': '1 sandwich',
            'unit': 'sandwich',
            'calories': 590,
            'calories_range': null,
            'protein_g': 25,
            'carbs_g': 46,
            'fat_g': 34,
          },
        ],
      },
    ],
    'source_url': _url,
    'source_title': 'Big Mac: Calories & Nutrition',
    'source_type': 'official_site',
    'source_year': 2026,
    'match_confidence': 0.9,
    'notes': '',
  }, itemCount: 12),
  citedUrls: const [_url],
  evidence: const [
    LookupEvidence(
      url: _url,
      text: 'Big Mac 590 Cal. 25 g protein, 46 g carbs, 34 g fat.',
      verbatim: false,
    ),
  ],
);

const LookupOutcome _pending = LookupOutcome(
  kind: LookupOutcomeKind.pending,
  provider: LookupRecipient.claudePlan,
  jobId: 'job_first_1234',
);

/// Who a lookup would reach is the REAL router's word (from the real
/// settings); what the recipient answers is scripted, and every send is
/// recorded.
class _Lookups implements LookupClient {
  _Lookups(this._router);
  final LookupClient _router;

  final List<LookupRequest> submits = [];
  final List<LookupCancelToken?> tokens = [];
  final List<String> polls = [];
  Future<LookupOutcome> Function(LookupRequest request)? onSubmit;

  @override
  LookupSupport lookupSupport() => _router.lookupSupport();

  @override
  Future<LookupOutcome> submit(
    LookupRequest request, {
    List<String> chainDomains = const [],
    LookupCancelToken? cancel,
    LookupRecipient? expectedRecipient,
    String? expectedRecipientStamp,
  }) async {
    submits.add(request);
    tokens.add(cancel);
    final f = onSubmit;
    return f == null ? _done() : f(request);
  }

  @override
  Future<LookupOutcome> poll(String jobId) async {
    polls.add(jobId);
    return _done();
  }
}

/// The meals store, with a hook before a meal's snapshot is answered: a
/// run's first read, right after the gate that let its lookup through.
class _Dao extends FakeDao {
  void Function(int mealId)? onSnapshot;

  @override
  Future<MealSnapshot?> mealSnapshot(int mealId) {
    onSnapshot?.call(mealId);
    return super.mealSnapshot(mealId);
  }
}

Future<void> _until(bool Function() done, {int ms = 2000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late SharedPreferences prefs;
  late AppSettings settings;
  late SettingsStore store;
  late _Lookups lookups;
  late _Dao dao;
  late AssistLocalState state;
  late Set<int> inUse;
  late List<http.Request> requests;
  late DateTime now;
  final engines = <MealAssist>[];

  /// The engine as di.dart builds it: the mode and the consent read fresh
  /// from the real settings on every decision, and — with [listening] —
  /// told of every change by them.
  MealAssist engine({bool listening = true}) {
    final assist = MealAssist(
      dao: dao,
      lookups: lookups,
      analyzerBusy: ValueNotifier<int>(0),
      pipelineIdle: () => true,
      inUse: inUse.contains,
      budget: AssistDailyBudget(prefs, clock: () => now),
      state: state,
      settings: () => AssistSettingsView(
        mode: AssistMode.fromWire(settings.restaurantAssist),
        useLocation: settings.restaurantAssistLocation,
        consentAt: settings.restaurantAssistConsentAt,
        consentRecipient: settings.restaurantAssistConsentRecipient,
      ),
      settingsChanges: listening ? settings : null,
      inForeground: () => true,
      country: () => 'US',
      // US Central daylight time, wherever the tests run.
      utcOffset: () => const Duration(hours: -5),
      clock: () => now,
      settleDelay: const Duration(milliseconds: 10),
      busyRetry: const Duration(milliseconds: 20),
    );
    engines.add(assist);
    return assist;
  }

  RestaurantAssistControls controlsOf(MealAssist assist) =>
      RestaurantAssistControls(
        lookupSupport: lookups.lookupSupport,
        clearLearnedPlaces: assist.clearLearnedPlaces,
        consentNeeded: assist.consentNeeded,
      );

  int addMeal({String timestamp = '2026-10-24T12:30:00.000'}) => dao.put(
    Meal(
      id: 0,
      date: _today,
      time: '12:30 PM',
      timestamp: timestamp,
      source: MealSource.appWatch,
      analysis: _bigMac(),
    ),
  );

  Map<String, Object?> jobsDocument() {
    final f = File(
      '${root.path}/$localStoreDirName/$assistJobsDocument.json',
    );
    if (!f.existsSync()) return {};
    return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  }

  /// The assist turned on with a consent for the recipient a lookup
  /// reaches now, and the AI consent for the same server given.
  Future<LookupSupport> turnOn() async {
    final support = lookups.lookupSupport();
    expect(support.supported, isTrue);
    await store.updateRestaurantAssist(
      mode: 'auto',
      consentAt: _consentAt,
      consentRecipient: support.recipientStamp,
    );
    await store.setAiConsent(currentAiConsentRoute(store), granted: true);
    expect(restaurantConsentCovers(store, support), isTrue);
    return support;
  }

  setUp(() async {
    now = _now;
    inUse = {};
    requests = [];
    root = Directory.systemTemp.createTempSync('stop_sharing_assist_test');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    settings = await AppSettings.load(prefs: prefs, keyStore: _Keys());
    await settings.setProvider(AiProvider.server);
    await settings.setServerBackend('claude');
    await settings.setServerBaseUrl('https://bitewise.example.test');
    await settings.setServerApiKey('upload-key');
    store = createSettingsStore(settings);
    // The router only says who a lookup would reach: it must never send.
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('', 500);
    });
    lookups = _Lookups(
      ProviderLookupRouter(
        settings,
        client: client,
        serverClient: ServerLookupClient(settings, client: client),
      ),
    );
    dao = _Dao();
    state = AssistLocalState(
      LocalNoBackupStore(
        root: () async => root,
        createMissingDirectory: true,
        clock: () => now,
      ),
      clock: () => now,
    );
  });

  tearDown(() {
    for (final assist in engines) {
      assist.dispose();
    }
    engines.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('Stop Sharing with the own server: Settings say Off and no consent '
      'at once; the call in flight is cancelled, its answer discarded, the '
      'pending job forgotten; nothing is sent afterwards', () async {
    final assist = engine();
    final controls = controlsOf(assist);
    final support = await turnOn();
    expect(support.recipient, LookupRecipient.claudePlan);
    final route = currentAiConsentRoute(store);
    expect(route, 'server:claude');

    // The older meal's lookup is a job the server is running.
    final first = addMeal(timestamp: '2026-10-24T11:00:00.000');
    final id = addMeal();
    lookups.onSubmit = (_) async => _pending;
    inUse.add(id);
    await assist.sweep();
    expect((await state.jobs()).keys, [first]);
    expect(jobsDocument(), isNotEmpty);
    inUse.clear();

    // The newer meal's lookup is in flight.
    final answer = Completer<LookupOutcome>();
    lookups.onSubmit = (_) => answer.future;
    assist.start(observeLifecycle: false);
    final sweep = assist.sweep();
    await _until(() => lookups.submits.length == 2);
    final token = lookups.tokens.last!;
    expect(token.isCancelled, isFalse);

    // ── The row's first step, NOT awaited ──
    var notified = 0;
    settings.addListener(() => notified++);
    final stopping = stopRestaurantAssistFor(store, controls, route);
    // At once: nothing is saved yet and no notification has landed, but
    // the settings every lookup gate reads say Off and no consent.
    expect(notified, 0,
        reason: 'the window the engine closes by itself (should the store '
            'ever notify before it saves, this line goes)');
    expect(settings.restaurantAssist, 'off');
    expect(settings.restaurantAssistConsentAt, isNull);
    expect(settings.restaurantAssistConsentRecipient, isNull);
    expect(restaurantConsentCovers(store, support), isFalse);
    // A lookup asked for right now (the editor's) is refused on the spot.
    final during = assist.lookupNow(first);

    final did = await stopping;
    expect(did, (turnOff: true, forgetConsent: true));
    expect(notified, 1, reason: 'ONE write, one notification');
    // The engine heard it: the call in flight is cancelled, its consent
    // prompt withdrawn.
    expect(token.isCancelled, isTrue);
    expect(assist.consentNeeded.value, isNull);
    expect((await during).code, AssistSkip.consentNeeded);

    // The answer arrives all the same: discarded. The jobs are deleted
    // by the engine's unawaited turnOff: wait for the document to go.
    answer.complete(_done());
    await sweep;
    await _until(() => jobsDocument().isEmpty);
    expect(await state.jobs(), isEmpty);
    expect(dao.assistWrites, isEmpty);
    expect(dao.byId(id).analysis.containsKey('assist'), isFalse);
    expect(dao.byId(first).analysis.containsKey('assist'), isFalse);

    // ── Then the AI consent, as the row does ──
    await store.setAiConsent(route, granted: false);
    expect(store.hasAiConsent(route), isFalse);

    // ── Afterwards: no sweep, no poll, no manual lookup sends anything ──
    now = _now.add(kAssistPollInterval);
    await assist.sweep();
    expect(assist.lastSkip, AssistSkip.off);
    expect((await assist.lookupNow(id)).code, AssistSkip.consentNeeded);
    expect(lookups.submits, hasLength(2), reason: 'the two from before');
    expect(lookups.polls, isEmpty);

    // Saved, not only in memory.
    final reloaded = await AppSettings.load(prefs: prefs, keyStore: _Keys());
    expect(reloaded.restaurantAssist, 'off');
    expect(reloaded.restaurantAssistConsentAt, isNull);
    expect(reloaded.restaurantAssistConsentRecipient, isNull);
    expect(reloaded.hasAiConsent(route), isFalse);

    // Allowing AI analysis again does not bring the lookups back: the
    // assist needs its own consent, asked for again.
    await store.setAiConsent(route, granted: true);
    await assist.sweep();
    expect(settings.restaurantAssist, 'off');
    expect(restaurantConsentCovers(store, support), isFalse);
    expect(lookups.submits, hasLength(2));
    expect(lookups.polls, isEmpty);
    expect(requests, isEmpty);
  });

  // The window the engine's own check closes: the row's write has flipped
  // the settings, its notification has not landed. This engine never hears
  // one at all — the settings themselves must be enough.
  test('a lookup already past its gate when Stop Sharing is confirmed '
      'sends nothing, even before (or without) the notification', () async {
    final assist = engine(listening: false);
    final controls = controlsOf(assist);
    await turnOn();
    final route = currentAiConsentRoute(store);
    final id = addMeal();
    Future<RestaurantAssistStop>? stopping;
    dao.onSnapshot = (_) {
      // The user confirms right now: the run is past its gate.
      stopping ??= stopRestaurantAssistFor(store, controls, route);
    };
    await assist.sweep();
    expect(await stopping, (turnOff: true, forgetConsent: true));
    expect(dao.snapshotReads, [id], reason: 'the gate had let it through');
    expect(lookups.submits, isEmpty);
    expect(lookups.polls, isEmpty);
    expect(assist.lastSkip, AssistSkip.cancelled);
    expect(dao.assistWrites, isEmpty);
    expect(jobsDocument(), isEmpty);

    // The editor's own lookup, the same way.
    await turnOn();
    stopping = null;
    final run = await assist.lookupNow(id);
    expect(await stopping, (turnOff: true, forgetConsent: true));
    expect(run.code, AssistSkip.cancelled);
    expect(lookups.submits, isEmpty);
    expect(requests, isEmpty);
  });

  test('the server address changed since the consent (another host of the '
      'same plan), or is gone: the consent is forgotten all the same',
      () async {
    final assist = engine();
    final controls = controlsOf(assist);
    final before = await turnOn();
    final route = currentAiConsentRoute(store);

    // Another host: the assist is paused for it, the consent names the old
    // one. The AI consent is per plan, so the row is the same row.
    await settings.setServerBaseUrl('https://other.example.test');
    final after = lookups.lookupSupport();
    expect(after.recipientStamp, isNot(before.recipientStamp));
    expect(restaurantConsentCovers(store, after), isFalse);
    expect(currentAiConsentRoute(store), route);
    expect(await stopRestaurantAssistFor(store, controls, route),
        (turnOff: true, forgetConsent: true));
    expect(settings.restaurantAssist, 'off');
    expect(settings.restaurantAssistConsentRecipient, isNull);
    // Back on the first address, nothing covers it either.
    await settings.setServerBaseUrl('https://bitewise.example.test');
    expect(restaurantConsentCovers(store, lookups.lookupSupport()), isFalse);

    // No usable address: no lookup is possible now, but the consent still
    // names this server.
    await turnOn();
    await settings.setServerBaseUrl('');
    expect(lookups.lookupSupport().supported, isFalse);
    expect(await stopRestaurantAssistFor(store, controls, route),
        (turnOff: true, forgetConsent: true));
    expect(settings.restaurantAssist, 'off');
    expect(settings.restaurantAssistConsentRecipient, isNull);
    expect(requests, isEmpty);
  });

  test('a different recipient is left alone: no write, no notification',
      () async {
    final assist = engine();
    final controls = controlsOf(assist);
    final support = await turnOn();
    final stamp = settings.restaurantAssistConsentRecipient;

    // Gemini gets no lookups; another plan on the server is another
    // recipient than the Claude plan the consent names.
    for (final (provider, backend, route) in [
      (AiProvider.gemini, 'claude', 'gemini'),
      (AiProvider.server, 'glm', 'server:glm'),
    ]) {
      await settings.setProvider(provider);
      await settings.setServerBackend(backend);
      expect(currentAiConsentRoute(store), route);
      expect(lookups.lookupSupport().supported, isFalse);
      var notified = 0;
      void count() => notified++;
      settings.addListener(count);
      expect(await stopRestaurantAssistFor(store, controls, route),
          (turnOff: false, forgetConsent: false));
      settings.removeListener(count);
      expect(notified, 0, reason: route);
      expect(settings.restaurantAssist, 'auto', reason: route);
      expect(settings.restaurantAssistConsentRecipient, stamp, reason: route);
      expect(settings.restaurantAssistConsentAt, _consentAt, reason: route);
    }

    // Back on the Claude plan the consent still covers it.
    await settings.setProvider(AiProvider.server);
    await settings.setServerBackend('claude');
    expect(restaurantConsentCovers(store, support), isTrue);
    expect(requests, isEmpty);
  });
}
