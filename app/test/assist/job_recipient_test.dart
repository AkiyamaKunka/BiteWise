/// A lookup job belongs to the recipient it was sent to (release-candidate
/// review of 1.6.0, privacy).
///
/// 'assist_jobs' keeps a job the own server still runs (with its job id)
/// and a meal's retry record, with what the lookup found then: the chains
/// around the photo (`place`), the user's pick, whether the editor started
/// it. The records carried no recipient, so after the user switched the AI
/// service and agreed to the new one's consent sheet, the next sweep
///
///   * handed the server's job id to the ACTIVE client's poll — a direct
///     provider answers "no jobs" (kind unsupported), which the engine read
///     as "this recipient cannot look up": Anthropic was held for an hour,
///     the job kept, and the same again every hour for up to 24 h, while
///     the lookups the user had just agreed to silently did nothing;
///   * between two own servers, polled server A's job id at server B and
///     then resubmitted the kept request there — with the kept `place`
///     (chains found near the photo), whatever the location answer given
///     for B.
///
/// Now every record carries its recipient (LookupSupport.recipientStamp),
/// and a record of another recipient — or without one — is forgotten
/// before anything reads it: by the sweep and by the editor's lookup.
library;

import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/assist_places_store.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/photo_location.dart';
import 'package:calorie_tracker/services/places/places.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/fakes.dart';

final DateTime _now = DateTime(2026, 10, 24, 13, 0);

const LookupSupport _anthropic = LookupSupport(
  supported: true,
  recipient: LookupRecipient.anthropic,
  locationAllowed: true,
);
const LookupSupport _serverA = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: true,
  recipientHostTag: 'aaaaaaaa',
);
const LookupSupport _serverB = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: true,
  recipientHostTag: 'bbbbbbbb',
);

Map<String, dynamic> _bigMac({String brand = "McDonald's", bool gps = false}) =>
    {
      'is_food': true,
      'food_items': [
        {
          'name': 'Big Mac',
          'estimated_calories': 540,
          'protein_g': 24,
          'carbs_g': 44,
          'fat_g': 30,
          'brand': brand,
          'qty': 1,
          'unit': 'sandwich',
        },
      ],
      'total_calories': 540,
      'total_protein_g': 24,
      'total_carbs_g': 44,
      'total_fat_g': 30,
      'meal_description': 'A burger on a tray',
      'estimate_confidence': 'low',
      'restaurant_context': 'restaurant',
      'portion_state': 'whole',
      'order_merchant': '',
      if (gps)
        'capture': {'has_gps': true, 'gps_acc_m': 10, 'gps_fix_delta_s': 3},
    };

/// The lookup client of whichever recipient is active: everything it is
/// asked is recorded. A submit fails for good (nothing is written for the
/// meal); a poll answers [onPoll].
class _Client implements LookupClient {
  _Client(this.support, {LookupOutcome? onPoll})
      : onPoll = onPoll ??
            // What HttpLookupClient.poll answers: direct lookups have no
            // jobs.
            LookupOutcome(
                kind: LookupOutcomeKind.unsupported,
                provider: support.recipient,
                failure: const LookupFailure(LookupFailureCode.badRequest,
                    transient: false, message: 'direct lookups have no jobs'));

  final LookupSupport support;
  final LookupOutcome onPoll;
  final List<LookupRequest> submits = [];
  final List<String> polls = [];

  @override
  LookupSupport lookupSupport() => support;

  @override
  Future<LookupOutcome> submit(LookupRequest request,
      {List<String> chainDomains = const [],
      LookupCancelToken? cancel,
      LookupRecipient? expectedRecipient,
      String? expectedRecipientStamp}) async {
    submits.add(request);
    return LookupOutcome(
        kind: LookupOutcomeKind.failed,
        provider: support.recipient,
        failure: const LookupFailure(LookupFailureCode.malformedReply,
            transient: false));
  }

  @override
  Future<LookupOutcome> poll(String jobId) async {
    polls.add(jobId);
    return onPoll;
  }
}

class _Source implements AssetLocationSource {
  final List<String> asked = [];
  @override
  Future<({double latitude, double longitude})?> assetLatLng(
      String assetId) async {
    asked.add(assetId);
    return (latitude: 40.758896, longitude: -73.985130);
  }
}

class _Places implements PlaceResolver {
  int calls = 0;
  @override
  Future<NearbyFood> nearbyFood(PhotoPoint point,
      {int radiusM = 100,
      Set<PlaceCategory> categories = defaultFoodCategories}) async {
    calls++;
    return const NearbyFood(PlacesStatus.ok, places: [
      NearbyPlace(
          name: "McDonald's",
          category: PlaceCategory.restaurant,
          distanceM: 8,
          countryCode: 'US'),
    ]);
  }
}

class _Harness {
  _Harness(this.dao, this.state, this.assist, this.lookups, this.source,
      this.places);
  final FakeDao dao;
  final AssistLocalState state;
  final MealAssist assist;
  final _Client lookups;
  final _Source source;
  final _Places places;
}

Future<_Harness> _harness(
  _Client lookups, {
  required AssistSettingsView settings,
  bool withLocation = false,
}) async {
  final root = Directory.systemTemp.createTempSync('job_recipient');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LocalNoBackupStore(
      root: () async => root, createMissingDirectory: true, clock: () => _now);
  final state = AssistLocalState(store, clock: () => _now);
  final dao = FakeDao();
  final source = _Source();
  final places = _Places();
  final assist = MealAssist(
    dao: dao,
    lookups: lookups,
    analyzerBusy: ValueNotifier<int>(0),
    pipelineIdle: () => true,
    inUse: (_) => false,
    budget: AssistDailyBudget(prefs, clock: () => _now),
    state: state,
    settings: () => settings,
    inForeground: () => true,
    country: () => 'US',
    utcOffset: () => const Duration(hours: -5),
    location: withLocation ? PhotoLocationReader(source, enabled: true) : null,
    places: withLocation ? places : null,
    placesStore:
        withLocation ? AssistPlacesStore(store, clock: () => _now) : null,
    clock: () => _now,
  );
  addTearDown(assist.dispose);
  return _Harness(dao, state, assist, lookups, source, places);
}

Meal _meal(String time, Map<String, dynamic> analysis,
        {String asset = 'asset-1'}) =>
    Meal(
      id: 0,
      date: '2026-10-24',
      time: time,
      timestamp: '2026-10-24T$time:00.000',
      source: MealSource.appPhoto,
      fileId: asset,
      analysis: analysis,
    );

/// The editor's lookup of [analysis], left running on [recipient]'s server
/// at 11:05 ("Still looking. Open this meal again in a minute.").
AssistJob _editorJob(Map<String, dynamic> analysis,
    {required String? recipient, AssistPlaceContext? place}) {
  final request = composeAssistRequest(assistBase(analysis),
      country: 'US', chains: place?.chains ?? const []);
  return AssistJob(
    jobId: 'job_server_12345',
    reqHash: lookupRequestHash(request),
    at: DateTime(2026, 10, 24, 11, 5),
    nextAt: DateTime(2026, 10, 24, 11, 5, 10),
    manual: true,
    country: 'US',
    place: place,
    recipient: recipient,
  );
}

void main() {
  test('a job the own server still runs is not polled at the direct '
      'provider the user switched to, and does not hold it', () async {
    final h = await _harness(
      _Client(_anthropic),
      // 12:00 — switched to Anthropic and agreed to its consent sheet.
      settings: AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: DateTime(2026, 10, 24, 12, 0),
        consentRecipient: 'anthropic',
      ),
    );
    final older = h.dao.put(_meal('11:00', _bigMac()));
    expect(
        await h.state.putJob(
            older, _editorJob(_bigMac(), recipient: 'claude_plan:aaaaaaaa')),
        isTrue);

    await h.assist.sweep();
    // 12:30 — a new branded restaurant meal, logged after the consent.
    h.dao.put(_meal('12:30', _bigMac(), asset: 'asset-2'));
    await h.assist.sweep();

    expect(
        {
          'job ids polled at Anthropic': h.lookups.polls,
          'last skip': h.assist.lastSkip,
          'lookups sent for the new meal': h.lookups.submits.length,
          'server job still kept': (await h.state.jobs()).containsKey(older),
        },
        {
          'job ids polled at Anthropic': <String>[],
          'last skip': isNot(AssistSkip.unavailable),
          'lookups sent for the new meal': 1,
          'server job still kept': false,
        });
  });

  test('the editor\'s lookup of that meal on the new provider is an '
      'ordinary new lookup: no poll, one submit', () async {
    final h = await _harness(
      _Client(_anthropic),
      settings: AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: DateTime(2026, 10, 24, 12, 0),
        consentRecipient: 'anthropic',
      ),
    );
    final older = h.dao.put(_meal('11:00', _bigMac()));
    await h.state.putJob(
        older, _editorJob(_bigMac(), recipient: 'claude_plan:aaaaaaaa'));

    final run = await h.assist.lookupNow(older);
    expect(h.lookups.polls, isEmpty);
    expect(h.lookups.submits, hasLength(1));
    expect(run.code, isNot(AssistSkip.unsupported));
    expect(run.code, isNot(AssistSkip.pending));
    expect((await h.state.jobs()).containsKey(older), isFalse);
  });

  test('another own server: A\'s job id is not polled at B, and the chains '
      'A\'s lookup found near the photo are not sent to B, which was '
      'answered "Brand only"', () async {
    // The server no longer knows the job: the engine would resubmit.
    final h = await _harness(
      _Client(_serverB,
          onPoll: const LookupOutcome(
              kind: LookupOutcomeKind.pending,
              provider: LookupRecipient.claudePlan)),
      // 12:00 — the server address changed; Brand only for the new one.
      settings: AssistSettingsView(
        mode: AssistMode.auto,
        useLocation: false,
        consentAt: DateTime(2026, 10, 24, 12, 0),
        consentRecipient: 'claude_plan:bbbbbbbb',
      ),
      withLocation: true,
    );
    // An unbranded burger with GPS: only the location named its chain.
    final analysis = _bigMac(brand: '', gps: true);
    final older = h.dao.put(_meal('11:00', analysis));
    await h.state.putJob(
        older,
        _editorJob(analysis,
            recipient: 'claude_plan:aaaaaaaa',
            place: const AssistPlaceContext(
                chains: ['mcdonalds'], picked: 'mcdonalds', verified: true)));

    await h.assist.sweep();
    expect(
        {
          'A\'s job ids polled at B': h.lookups.polls,
          'chains sent to B': [for (final r in h.lookups.submits) r.chainKeys],
          'photo positions read': h.source.asked,
          'Apple Maps queries': h.places.calls,
          'A\'s job still kept': (await h.state.jobs()).containsKey(older),
        },
        {
          'A\'s job ids polled at B': <String>[],
          'chains sent to B': <List<String>>[],
          'photo positions read': <String>[],
          'Apple Maps queries': 0,
          'A\'s job still kept': false,
        });
  });

  test('a record without a recipient is forgotten, never polled', () async {
    final h = await _harness(
      _Client(_serverA,
          onPoll: const LookupOutcome(
              kind: LookupOutcomeKind.pending,
              provider: LookupRecipient.claudePlan,
              jobId: 'job_server_12345')),
      settings: AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: DateTime(2026, 10, 24, 10, 0),
        consentRecipient: 'claude_plan:aaaaaaaa',
      ),
    );
    final older = h.dao.put(_meal('11:00', _bigMac()));
    await h.state.putJob(older, _editorJob(_bigMac(), recipient: null));
    await h.assist.sweep();
    expect(h.lookups.polls, isEmpty);
    expect((await h.state.jobs())[older]?.jobId, isNot('job_server_12345'));
  });

  test('the same recipient still collects its own job: polled, kept while '
      'pending, and what the engine writes carries the stamp', () async {
    final h = await _harness(
      _Client(_serverA,
          onPoll: const LookupOutcome(
              kind: LookupOutcomeKind.pending,
              provider: LookupRecipient.claudePlan,
              jobId: 'job_server_12345')),
      settings: AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: DateTime(2026, 10, 24, 12, 0),
        consentRecipient: 'claude_plan:aaaaaaaa',
      ),
    );
    final older = h.dao.put(_meal('11:00', _bigMac()));
    await h.state.putJob(
        older, _editorJob(_bigMac(), recipient: 'claude_plan:aaaaaaaa'));
    await h.assist.sweep();
    expect(h.lookups.polls, ['job_server_12345']);
    expect(h.lookups.submits, isEmpty);
    final kept = (await h.state.jobs())[older];
    expect(kept?.jobId, 'job_server_12345');
    expect(kept?.manual, isTrue);
    expect(kept?.recipient, 'claude_plan:aaaaaaaa');
  });

  test('a poll answered "no such thing as a job" forgets the record and '
      'does not hold the recipient', () async {
    // Cannot happen once records carry their recipient; the engine's
    // answer to it is kept right all the same.
    final h = await _harness(
      _Client(_anthropic),
      settings: AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: DateTime(2026, 10, 24, 10, 0),
        consentRecipient: 'anthropic',
      ),
    );
    final older = h.dao.put(_meal('11:00', _bigMac()));
    await h.state
        .putJob(older, _editorJob(_bigMac(), recipient: 'anthropic'));
    await h.assist.sweep();
    expect(h.lookups.polls, ['job_server_12345']);
    expect((await h.state.jobs()).containsKey(older), isFalse);
    expect(h.assist.lastSkip, isNot(AssistSkip.unavailable));

    // The recipient is not held: the next meal is looked up at once.
    h.dao.put(_meal('12:30', _bigMac(), asset: 'asset-2'));
    await h.assist.sweep();
    expect(h.lookups.submits, isNotEmpty);
  });
}
