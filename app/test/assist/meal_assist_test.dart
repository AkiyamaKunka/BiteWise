/// services/assist/meal_assist.dart — the restaurant assist's engine, brand
/// path (design R6b): the preconditions (Off, the pipeline, the analyzer,
/// the foreground, the consent's recipient, the daily cap), eligibility
/// (24 h, the consent time, corrected, in use, the miss list), the triggers,
/// the compare-and-set write and its miss counting, Undo, Off cancelling
/// the call in flight, the Claude Plan job kept for the next sweep, the
/// snackbar wording, and a decision log without names or places. And the
/// consent read again at the send: Settings that stopped the lookups after
/// a run's gate (Stop Sharing, before its notification lands) send nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/ui/outcome_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/fakes.dart';

final DateTime _now = DateTime(2026, 10, 24, 13, 0);
final DateTime _consentAt = DateTime(2026, 10, 24, 8, 0);
const String _today = '2026-10-24';
const String _url = 'https://www.mcdonalds.com/us/en-us/product/big-mac.html';

const LookupSupport _anthropic = LookupSupport(
  supported: true,
  recipient: LookupRecipient.anthropic,
  locationAllowed: true,
);
const LookupSupport _openrouter = LookupSupport(
  supported: true,
  recipient: LookupRecipient.openrouter,
  locationAllowed: true,
);
const LookupSupport _claudePlan = LookupSupport(
  supported: true,
  recipient: LookupRecipient.claudePlan,
  locationAllowed: false,
  recipientHostTag: 'abcd1234',
);

Map<String, dynamic> _bigMac({
  String? confidence = 'low',
  String? context = 'restaurant',
  String brand = "McDonald's",
  String merchant = '',
  String description = "A Big Mac in its McDonald's box",
}) => {
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
  'meal_description': description,
  'estimate_confidence': ?confidence,
  'restaurant_context': ?context,
  'portion_state': 'whole',
  'order_merchant': merchant,
};

Map<String, dynamic> _found({String chainKey = 'mcdonalds'}) => {
  'status': 'found',
  'chain_key': chainKey,
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
};

LookupOutcome _done({
  Map<String, dynamic>? json,
  LookupRecipient provider = LookupRecipient.anthropic,
  bool verbatim = true,
}) => LookupOutcome(
  kind: LookupOutcomeKind.done,
  provider: provider,
  result: LookupResult.parse(json ?? _found(), itemCount: 12),
  citedUrls: const [_url],
  evidence: [
    LookupEvidence(
      url: _url,
      text: 'Big Mac 590 Cal. 25 g protein, 46 g carbs, 34 g fat.',
      verbatim: verbatim,
    ),
  ],
);

LookupOutcome _failed(LookupFailureCode code, {required bool transient}) =>
    LookupOutcome(
      kind: LookupOutcomeKind.failed,
      provider: LookupRecipient.anthropic,
      failure: LookupFailure(code, transient: transient),
    );

class _Dao extends FakeDao {
  int listings = 0;

  /// Called with the listing's number (1-based) before it is answered: a
  /// test plays a user who turns the mode Off right then.
  void Function(int n)? onList;

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) {
    listings++;
    onList?.call(listings);
    return super.mealsBetween(startDate, endDate);
  }

  /// Called before a meal's snapshot is answered — a run's first read,
  /// right after the gate that let its lookup through: a test plays
  /// Settings changing right then, before any notification lands.
  void Function(int mealId)? onSnapshot;

  @override
  Future<MealSnapshot?> mealSnapshot(int mealId) {
    onSnapshot?.call(mealId);
    return super.mealSnapshot(mealId);
  }

  /// Rewrites meal [id] in place the way another writer would, keeping
  /// corrected as it was.
  void rewrite(int id, Map<String, dynamic> Function(Map<String, dynamic>) f) {
    final i = meals.indexWhere((m) => m.id == id);
    final m = meals[i];
    meals[i] = Meal(
      id: m.id,
      date: m.date,
      time: m.time,
      timestamp: m.timestamp,
      source: m.source,
      imageHash: m.imageHash,
      fileId: m.fileId,
      analysis: f(Map<String, dynamic>.from(m.analysis)),
      corrected: m.corrected,
    );
  }
}

class _Lookups implements LookupClient {
  LookupSupport support = _anthropic;
  final List<LookupRequest> submits = [];
  final List<
    ({
      List<String> domains,
      LookupRecipient? recipient,
      String? stamp,
      LookupCancelToken? cancel,
    })
  >
  args = [];
  final List<String> polls = [];

  /// The answer to the next submit (default: a clean found answer).
  Future<LookupOutcome> Function(LookupRequest request)? onSubmit;
  Future<LookupOutcome> Function(String jobId)? onPoll;

  int supportReads = 0;

  @override
  LookupSupport lookupSupport() {
    supportReads++;
    return support;
  }

  @override
  Future<LookupOutcome> submit(
    LookupRequest request, {
    List<String> chainDomains = const [],
    LookupCancelToken? cancel,
    LookupRecipient? expectedRecipient,
    String? expectedRecipientStamp,
  }) async {
    submits.add(request);
    args.add((
      domains: chainDomains,
      recipient: expectedRecipient,
      stamp: expectedRecipientStamp,
      cancel: cancel,
    ));
    final f = onSubmit;
    return f == null ? _done() : f(request);
  }

  @override
  Future<LookupOutcome> poll(String jobId) async {
    polls.add(jobId);
    final f = onPoll;
    return f == null ? _done(provider: LookupRecipient.claudePlan) : f(jobId);
  }
}

/// The F1 store, with a hook awaited before each write lands: a test plays
/// a user who turns the mode Off while the assist writes its records.
class _HookStore extends LocalNoBackupStore {
  _HookStore(Directory root, DateTime Function() clock)
    : super(root: () async => root, createMissingDirectory: true, clock: clock);

  Future<void> Function(String name)? beforeWrite;

  /// Called with each document's name before it is read.
  void Function(String name)? beforeRead;

  @override
  Future<Map<String, Object?>> read(String name, {int? version}) {
    beforeRead?.call(name);
    return super.read(name, version: version);
  }

  @override
  Future<bool> write(
    String name,
    Map<String, Object?> document, {
    required int version,
  }) async {
    final hook = beforeWrite;
    if (hook != null) await hook(name);
    return super.write(name, document, version: version);
  }
}

class _Harness {
  _Harness(this.root, this.prefs);

  final Directory root;
  final SharedPreferences prefs;
  final _Dao dao = _Dao();
  final _Lookups lookups = _Lookups();
  final ValueNotifier<int> busy = ValueNotifier<int>(0);
  final ValueNotifier<int> settingsChanges = ValueNotifier<int>(0);
  final ValueNotifier<int> mealsChanged = ValueNotifier<int>(0);
  final Set<int> inUse = {};
  final List<AssistAppliedNotice> notices = [];
  bool idle = true;
  bool foreground = true;
  int signals = 0;
  DateTime now = _now;
  AssistSettingsView settings = AssistSettingsView(
    mode: AssistMode.auto,
    consentAt: _consentAt,
    consentRecipient: 'anthropic',
  );

  late final AssistDailyBudget budget = AssistDailyBudget(
    prefs,
    clock: () => now,
  );
  late final _HookStore store = _HookStore(root, () => now);
  late final AssistLocalState state = AssistLocalState(store, clock: () => now);

  /// Called on every meals-changed signal the assist sends.
  void Function()? onSignal;

  late final MealAssist assist = MealAssist(
    dao: dao,
    lookups: lookups,
    analyzerBusy: busy,
    pipelineIdle: () => idle,
    inUse: inUse.contains,
    budget: budget,
    state: state,
    settings: () => settings,
    settingsChanges: settingsChanges,
    mealsChanged: mealsChanged,
    onMealsChanged: () {
      signals++;
      onSignal?.call();
      mealsChanged.value++;
    },
    onApplied: notices.add,
    inForeground: () => foreground,
    country: () => 'US',
    // US Central daylight time: the meal country's time-zone veto stays
    // out of the way wherever the tests run (CI's clock is UTC).
    utcOffset: () => const Duration(hours: -5),
    clock: () => now,
    settleDelay: const Duration(milliseconds: 10),
    busyRetry: const Duration(milliseconds: 20),
  );

  int add(
    Map<String, dynamic> analysis, {
    String date = _today,
    String timestamp = '2026-10-24T12:30:00.000',
    String source = MealSource.appWatch,
    bool corrected = false,
  }) => dao.put(
    Meal(
      id: 0,
      date: date,
      time: '12:30 PM',
      timestamp: timestamp,
      source: source,
      analysis: analysis,
      corrected: corrected,
    ),
  );

  Map<String, dynamic> analysisOf(int id) => dao.byId(id).analysis;

  void setSettings(AssistSettingsView s) {
    settings = s;
    settingsChanges.value++;
  }

  Map<String, Object?> document(String name) {
    final f = File('${root.path}/$localStoreDirName/$name.json');
    if (!f.existsSync()) return {};
    return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  }
}

/// One line of the trigger rule's truth table: null means "any value".
typedef _TriggerLine = ({
  AssistMode mode,
  Set<String>? conf,
  Set<String>? ctx,
  bool? brand,
  bool? merchant,
  AssistTrigger? trigger,
  int rows,
});

Future<void> _until(bool Function() done, {int ms = 2000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root;
  late _Harness h;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('meal_assist_test');
    SharedPreferences.setMockInitialValues({});
    h = _Harness(root, await SharedPreferences.getInstance());
  });
  tearDown(() {
    h.assist.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('the brand path', () {
    test('a low-confidence restaurant meal with a printed brand is looked '
        'up, applied, announced, marked unseen and signalled', () async {
      final id = h.add(_bigMac());
      await h.assist.sweep();

      expect(h.lookups.submits, hasLength(1));
      final request = h.lookups.submits.single;
      expect(request.chainKeys, ['mcdonalds']);
      expect(request.items.single, {
        'name': 'Big Mac',
        'qty': 1,
        'unit': 'sandwich',
        'brand': "McDonald's",
      });
      expect(request.body['country'], 'US');
      expect(request.body.containsKey('lang'), isFalse);
      final args = h.lookups.args.single;
      expect(args.domains, ['mcdonalds.com']);
      expect(args.recipient, LookupRecipient.anthropic);
      expect(args.stamp, 'anthropic');
      expect(args.cancel, isNotNull);

      final a = h.analysisOf(id);
      expect(h.dao.byId(id).corrected, isFalse, reason: 'never corrected');
      expect((a['assist'] as Map)['status'], AssistStatus.applied);
      expect((a['assist'] as Map)['trigger'], 'auto_low_confidence');
      expect((a['assist'] as Map)['evidence'], 'item_brand');
      final item = (a['food_items'] as List).single as Map;
      expect(item['estimated_calories'], 590);
      expect(item['published'], isTrue);
      expect(item['name'], 'Big Mac', reason: 'names never change');
      expect(a['meal_description'], "A Big Mac in its McDonald's box");
      expect(a['total_calories'], 590);

      final n = h.notices.single;
      expect(n.mealId, id);
      expect(n.chainKey, 'mcdonalds');
      expect(n.brandName, "McDonald's");
      expect((n.oldKcal, n.newKcal), (540, 590));
      expect(await h.state.unseen(), {id});
      expect(h.signals, 1);

      final log = await h.state.decisions();
      expect(log.single.code, 'applied');
      expect((log.single.oldKcal, log.single.newKcal), (540, 590));
      expect(log.single.provider, 'anthropic');
    });

    test('Undo restores exactly: the original numbers, a declined record, '
        'no dot', () async {
      final original = _bigMac();
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect(await h.notices.single.undo(), isTrue);

      final a = h.analysisOf(id);
      final block = a['assist'] as Map;
      expect(block['status'], AssistStatus.declined);
      expect(block['reason'], AssistReason.userDeclined);
      expect(block.containsKey('matches'), isFalse);
      expect(Map.of(a)..remove('assist'), equals(original));
      expect(h.dao.byId(id).corrected, isFalse);
      expect(await h.state.unseen(), isEmpty);
      expect((await h.state.decisions()).last.code, AssistReason.userDeclined);
      // Nothing to undo twice.
      expect(await h.assist.undo(id), isFalse);
    });

    test('Undo after the user changed the meal writes nothing', () async {
      final id = h.add(_bigMac());
      await h.assist.sweep();
      h.dao.rewrite(id, (a) {
        final items = [
          for (final e in a['food_items'] as List)
            Map<String, dynamic>.from(e as Map)..['estimated_calories'] = 600,
        ];
        return a
          ..['food_items'] = items
          ..['total_calories'] = 600;
      });
      final before = jsonEncode(h.analysisOf(id));
      expect(await h.notices.single.undo(), isFalse);
      expect(jsonEncode(h.analysisOf(id)), before);
    });

    test('a request in Chinese asks for Chinese notes', () async {
      final zh = MealAssist(
        dao: h.dao,
        lookups: h.lookups,
        analyzerBusy: h.busy,
        pipelineIdle: () => true,
        inUse: (_) => false,
        budget: h.budget,
        state: h.state,
        settings: () => h.settings,
        repliesInChinese: () => true,
        country: () => 'US',
        utcOffset: () => const Duration(hours: -5),
        clock: () => h.now,
      );
      h.add(_bigMac());
      await zh.sweep();
      zh.dispose();
      expect(h.lookups.submits.single.body['lang'], 'zh');
    });

    test('a suggestion is recorded without touching the numbers, the dot or '
        'the snackbar', () async {
      final id = h.add(_bigMac());
      // Grounded only by text that is not the page's own: suggestion.
      h.lookups.onSubmit = (_) async => _done(verbatim: false);
      await h.assist.sweep();
      final a = h.analysisOf(id);
      expect((a['assist'] as Map)['status'], AssistStatus.suggested);
      expect((a['assist'] as Map)['reason'], AssistReason.notGrounded);
      expect(a['total_calories'], 540);
      expect(h.notices, isEmpty);
      expect(await h.state.unseen(), isEmpty);
      expect(h.signals, 1, reason: 'the card shows the suggestion');
      expect((await h.state.decisions()).single.code, AssistReason.notGrounded);
    });

    test('a rejected lookup (a chain never asked about) writes nothing and '
        'is not asked again', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async =>
          _done(json: _found(chainKey: 'burger_king'));
      await h.assist.sweep();
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
      expect(
        (await h.state.decisions()).single.code,
        AssistReason.chainNotRequested,
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test('a meal already looked up (any assist block) is never looked up '
        'again', () async {
      h.add(_bigMac());
      await h.assist.sweep();
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });
  });

  group('preconditions', () {
    test('Off: zero calls, not even a read', () async {
      h.settings = const AssistSettingsView();
      h.add(_bigMac());
      h.assist.start(observeLifecycle: false);
      h.settingsChanges.value++; // e.g. the language
      h.mealsChanged.value++;
      await h.assist.sweep();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.polls, isEmpty);
      expect(
        h.lookups.supportReads,
        0,
        reason: 'the lookup client is never even asked',
      );
      expect(h.dao.listings, 0);
      expect(h.dao.snapshotReads, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.off);
    });

    test('no work while the pipeline is busy, an analyzer call is in flight '
        'or the app is in the background', () async {
      h.add(_bigMac());
      h.idle = false;
      await h.assist.sweep();
      expect(h.assist.lastSkip, AssistSkip.pipelineBusy);
      h.idle = true;
      h.busy.value = 1;
      await h.assist.sweep();
      expect(h.assist.lastSkip, AssistSkip.analyzerBusy);
      h.busy.value = 0;
      h.foreground = false;
      await h.assist.sweep();
      expect(h.assist.lastSkip, AssistSkip.background);
      expect(h.lookups.submits, isEmpty);
      expect(h.dao.listings, 0);

      h.foreground = true;
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test('the pipeline turning busy between two meals stops the sweep before '
        'the next lookup', () async {
      h.add(_bigMac());
      h.add(_bigMac(), timestamp: '2026-10-24T11:00:00.000');
      h.lookups.onSubmit = (_) async {
        h.idle = false; // a photo arrived while the first lookup ran
        return _done();
      };
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.assist.lastSkip, AssistSkip.pipelineBusy);
    });

    test('busy: it tries again by itself', () async {
      h.add(_bigMac());
      h.idle = false;
      await h.assist.sweep();
      h.idle = true;
      await _until(() => h.lookups.submits.isNotEmpty);
    });

    test('an unsupported provider makes zero calls', () async {
      h.lookups.support = const LookupSupport.unsupported('no_search_tool');
      h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.unsupported);
    });

    test('a recipient change pauses and asks for consent; the answer '
        'resumes', () async {
      h.lookups.support = _openrouter;
      h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.consentNeeded);
      expect(
        h.assist.consentNeeded.value?.recipient,
        LookupRecipient.openrouter,
      );

      h.assist.start(observeLifecycle: false);
      h.setSettings(
        AssistSettingsView(
          mode: AssistMode.auto,
          consentAt: _consentAt,
          consentRecipient: 'openrouter',
        ),
      );
      expect(h.assist.consentNeeded.value, isNull);
      await _until(() => h.lookups.submits.isNotEmpty);
      expect(h.lookups.args.single.stamp, 'openrouter');
    });

    test('the provider switched after the consent check: the router refuses, '
        'the assist pauses', () async {
      h.add(_bigMac());
      h.add(_bigMac(), timestamp: '2026-10-24T11:00:00.000');
      h.lookups.onSubmit = (_) async {
        h.lookups.support = _openrouter;
        return LookupOutcome.consentChanged(
          LookupRecipient.anthropic,
          LookupRecipient.openrouter,
        );
      };
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1), reason: 'the sweep stops');
      expect(
        h.assist.consentNeeded.value?.recipient,
        LookupRecipient.openrouter,
      );
      expect(h.dao.assistWrites, isEmpty);
    });

    test('no consent at all: paused', () async {
      h.settings = const AssistSettingsView(mode: AssistMode.always);
      h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(
        h.assist.consentNeeded.value?.recipient,
        LookupRecipient.anthropic,
      );
    });

    test('the daily cap stops the sweep', () async {
      SharedPreferences.setMockInitialValues({
        assistDailyPrefsKey: jsonEncode({'date': _today, 'count': 20}),
      });
      h = _Harness(root, await SharedPreferences.getInstance());
      h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.dailyCap);
      expect(h.assist.lookupsToday, 20);
      expect(h.assist.dailyCap, assistDailyCap);
    });
  });

  group('eligibility', () {
    test('24 h: a meal logged 25 h ago is not looked up', () async {
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: DateTime(2026, 10, 1),
        consentRecipient: 'anthropic',
      );
      h.add(
        _bigMac(),
        date: '2026-10-23',
        timestamp: '2026-10-23T11:59:00.000',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      h.add(
        _bigMac(),
        date: '2026-10-23',
        timestamp: '2026-10-23T13:30:00.000',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test('a meal logged before the consent is not looked up', () async {
      h.add(_bigMac(), timestamp: '2026-10-24T07:59:00.000');
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
    });

    test('corrected, text and manual meals are not looked up; a picked photo '
        'is', () async {
      h.add(_bigMac(), corrected: true);
      h.add(_bigMac(), source: MealSource.manualText);
      h.add(_bigMac(), source: MealSource.appManual);
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      h.add(_bigMac(), source: MealSource.appPhoto);
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test('a meal in use is skipped', () async {
      final id = h.add(_bigMac());
      h.inUse.add(id);
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      h.inUse.clear();
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test(
      'opened while the lookup ran: the result is dropped and counted',
      () async {
        final id = h.add(_bigMac());
        h.lookups.onSubmit = (_) async {
          h.inUse.add(id);
          return _done();
        };
        await h.assist.sweep();
        expect(h.dao.assistWrites, isEmpty);
        expect(h.analysisOf(id).containsKey('assist'), isFalse);
        expect((await h.state.misses())[id], 1);
      },
    );

    test('an edit during a lookup: dropped, a miss counted; two misses and '
        'the meal is skipped', () async {
      final id = h.add(_bigMac());
      var n = 0;
      h.lookups.onSubmit = (_) async {
        n++;
        h.dao.rewrite(id, (a) => a..['meal_description'] = 'Edited $n');
        return _done();
      };
      await h.assist.sweep();
      expect(h.dao.assistWrites, isEmpty);
      expect(h.dao.compareMisses, 1);
      expect((await h.state.misses())[id], 1);
      expect(h.analysisOf(id)['meal_description'], 'Edited 1');
      expect((await h.state.decisions()).single.code, AssistSkip.casMiss);

      // No cached answer (R6c): the next sweep asks again.
      await h.state.clearCache();
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2));
      expect((await h.state.misses())[id], assistMissesBeforeDenylist);

      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2), reason: 'denylisted');
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
    });
  });

  group('triggers', () {
    // Owner decision 2026-11-05: medium confidence is no longer "never".
    // A medium restaurant or takeout meal that shows a chain's printed
    // brand — this fixture's default — is looked up as auto_branding (the
    // group after this one); without a printed chain it still is not.
    // Unknown and high confidence never trigger, printed brand or not.
    test('When unsure: unknown or high confidence never triggers, even with '
        'a printed brand', () async {
      h.add(_bigMac(confidence: null));
      h.add(_bigMac(confidence: 'high'));
      h.add(_bigMac(confidence: 'unsure'));
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
    });

    test('When unsure: medium confidence without a printed chain never '
        'triggers', () async {
      h.add(_bigMac(confidence: 'medium', brand: ''));
      h.add(_bigMac(confidence: 'medium', brand: 'Coca-Cola'));
      h.add(_bigMac(confidence: 'medium', brand: '', merchant: "Joe's Diner"));
      h.add(_bigMac(confidence: 'medium', context: 'takeout', brand: ''));
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.dao.snapshotReads, isEmpty, reason: 'no run was started');
    });

    test('low + home, packaged or unknown never triggers', () async {
      h.add(_bigMac(context: 'home'));
      h.add(_bigMac(context: 'packaged'));
      h.add(_bigMac(context: 'unknown'));
      h.add(_bigMac(context: null));
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
    });

    test('Always skips only the confidence check: home without an item brand '
        'is skipped, with one it is looked up', () async {
      h.settings = AssistSettingsView(
        mode: AssistMode.always,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      // A receipt merchant is not an item's own brand.
      h.add(_bigMac(context: 'home', brand: '', merchant: "McDonald's"));
      h.add(_bigMac(context: 'unknown', brand: ''));
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);

      final id = h.add(_bigMac(context: 'home', confidence: 'high'));
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      // decideAssist keeps a home meal at a suggestion.
      final block = h.analysisOf(id)['assist'] as Map;
      expect(block['status'], AssistStatus.suggested);
      expect(block['trigger'], 'always');
      expect(block['reason'], AssistReason.contextNotRestaurant);
    });

    test('takeout takes the brand path only', () async {
      h.add(_bigMac(context: 'takeout', brand: ''));
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty, reason: 'no printed chain');
      h.add(
        _bigMac(context: 'takeout', brand: '', merchant: "McDonald's #2381"),
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      final body = h.lookups.submits.single.body;
      expect(h.lookups.submits.single.chainKeys, ['mcdonalds']);
      expect(
        body['order_merchant'],
        "McDonald's",
        reason: 'the canonical name, never the receipt text',
      );
    });

    test('a restaurant meal without a printed brand waits for the location '
        'path: no call', () async {
      h.add(_bigMac(brand: ''));
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
    });

    test('assistTriggerFor', () {
      Map<String, dynamic> a(String? c, String? ctx, {String brand = ''}) =>
          _bigMac(confidence: c, context: ctx, brand: brand);
      expect(assistTriggerFor(a('low', 'restaurant'), AssistMode.off), isNull);
      expect(
        assistTriggerFor(a('low', 'restaurant'), AssistMode.auto),
        AssistTrigger.autoLowConfidence,
      );
      expect(
        assistTriggerFor(a('low', 'takeout'), AssistMode.auto),
        AssistTrigger.autoLowConfidence,
      );
      expect(
        assistTriggerFor(a('medium', 'restaurant'), AssistMode.auto),
        isNull,
      );
      // Medium with a printed chain: an item's own brand, or the receipt
      // or order screen's merchant (owner decision 2026-11-05).
      expect(
        assistTriggerFor(
          a('medium', 'restaurant', brand: "McDonald's"),
          AssistMode.auto,
        ),
        AssistTrigger.autoBranding,
      );
      expect(
        assistTriggerFor(
          _bigMac(
            confidence: 'medium',
            context: 'takeout',
            brand: '',
            merchant: "McDonald's #2381",
          ),
          AssistMode.auto,
        ),
        AssistTrigger.autoBranding,
      );
      expect(
        assistTriggerFor(a('high', 'restaurant'), AssistMode.always),
        AssistTrigger.always,
      );
      expect(assistTriggerFor(a(null, 'home'), AssistMode.always), isNull);
      expect(
        assistTriggerFor(
          a(null, 'packaged', brand: 'Starbucks'),
          AssistMode.always,
        ),
        AssistTrigger.always,
      );
      expect(assistTriggerFor('junk', AssistMode.always), isNull);
    });

    // The rule as its table: every line is one row of the design's truth
    // table (mode, confidence, context, an item's printed brand, a receipt
    // or order-screen merchant → trigger; null = any value), with the
    // number of analyses it covers. Written out here on its own, not
    // derived from the code: 3 modes × 4 confidences × 5 contexts × 2 × 2
    // = 240 analyses, each matching exactly one line.
    test('assistTriggerFor: the whole truth table, 240 analyses', () {
      const eatenOut = {'restaurant', 'takeout'};
      const elsewhere = {'packaged', 'home', 'unknown'};
      const auto = AssistMode.auto;
      const always = AssistMode.always;
      const lowTrigger = AssistTrigger.autoLowConfidence;
      const branding = AssistTrigger.autoBranding;
      final table = <_TriggerLine>[
        (
          mode: AssistMode.off,
          conf: null,
          ctx: null,
          brand: null,
          merchant: null,
          trigger: null,
          rows: 80,
        ),
        (
          mode: auto,
          conf: {'low'},
          ctx: eatenOut,
          brand: null,
          merchant: null,
          trigger: lowTrigger,
          rows: 8,
        ),
        // The six new rows.
        (
          mode: auto,
          conf: {'medium'},
          ctx: eatenOut,
          brand: true,
          merchant: null,
          trigger: branding,
          rows: 4,
        ),
        (
          mode: auto,
          conf: {'medium'},
          ctx: eatenOut,
          brand: false,
          merchant: true,
          trigger: branding,
          rows: 2,
        ),
        (
          mode: auto,
          conf: {'medium'},
          ctx: eatenOut,
          brand: false,
          merchant: false,
          trigger: null,
          rows: 2,
        ),
        (
          mode: auto,
          conf: {'high', 'unknown'},
          ctx: eatenOut,
          brand: null,
          merchant: null,
          trigger: null,
          rows: 16,
        ),
        (
          mode: auto,
          conf: null,
          ctx: elsewhere,
          brand: null,
          merchant: null,
          trigger: null,
          rows: 48,
        ),
        (
          mode: always,
          conf: null,
          ctx: eatenOut,
          brand: null,
          merchant: null,
          trigger: AssistTrigger.always,
          rows: 32,
        ),
        (
          mode: always,
          conf: null,
          ctx: elsewhere,
          brand: true,
          merchant: null,
          trigger: AssistTrigger.always,
          rows: 24,
        ),
        (
          mode: always,
          conf: null,
          ctx: elsewhere,
          brand: false,
          merchant: null,
          trigger: null,
          rows: 24,
        ),
      ];
      final covered = List<int>.filled(table.length, 0);
      final counts = <AssistMode, Map<AssistTrigger?, int>>{};
      var analyses = 0;
      for (final mode in AssistMode.values) {
        for (final conf in ['low', 'medium', 'high', 'unknown']) {
          for (final ctx in [...eatenOut, ...elsewhere]) {
            for (final brand in [true, false]) {
              for (final merchant in [true, false]) {
                analyses++;
                final why = '$mode $conf $ctx brand=$brand merchant=$merchant';
                final lines = [
                  for (final (i, line) in table.indexed)
                    if (line.mode == mode &&
                        (line.conf?.contains(conf) ?? true) &&
                        (line.ctx?.contains(ctx) ?? true) &&
                        (line.brand ?? brand) == brand &&
                        (line.merchant ?? merchant) == merchant)
                      i,
                ];
                expect(lines, hasLength(1), reason: 'one table line: $why');
                covered[lines.single]++;
                final got = assistTriggerFor(
                  _bigMac(
                    // Unknown confidence: the reply did not say.
                    confidence: conf == 'unknown' ? null : conf,
                    context: ctx,
                    brand: brand ? "McDonald's" : '',
                    merchant: merchant ? "McDonald's #2381" : '',
                  ),
                  mode,
                );
                expect(got, table[lines.single].trigger, reason: why);
                final byMode = counts.putIfAbsent(mode, () => {});
                byMode[got] = (byMode[got] ?? 0) + 1;
              }
            }
          }
        }
      }
      expect(analyses, 240);
      expect(covered, [for (final line in table) line.rows]);
      expect(counts[AssistMode.off], {null: 80});
      expect(counts[auto], {lowTrigger: 8, branding: 6, null: 66});
      expect(counts[always], {AssistTrigger.always: 56, null: 24});
    });

    test('assistTriggerFor: one analysis for each line of the table', () {
      AssistTrigger? t(
        AssistMode mode,
        String? conf,
        String? ctx, {
        String brand = '',
        String merchant = '',
      }) => assistTriggerFor(
        _bigMac(
          confidence: conf,
          context: ctx,
          brand: brand,
          merchant: merchant,
        ),
        mode,
      );
      const off = AssistMode.off;
      const auto = AssistMode.auto;
      const always = AssistMode.always;
      const mcd = "McDonald's";
      const receipt = "McDonald's #2381";
      // Off: never, whatever the meal shows.
      expect(
        t(off, 'low', 'restaurant', brand: mcd, merchant: receipt),
        isNull,
      );
      // When unsure, low: restaurant or takeout, printed chain or not.
      expect(t(auto, 'low', 'takeout'), AssistTrigger.autoLowConfidence);
      // When unsure, medium + an item's printed brand (new).
      expect(
        t(auto, 'medium', 'restaurant', brand: mcd),
        AssistTrigger.autoBranding,
      );
      // When unsure, medium + the receipt's merchant alone (new).
      expect(
        t(auto, 'medium', 'takeout', merchant: receipt),
        AssistTrigger.autoBranding,
      );
      // When unsure, medium, nothing printed names a chain.
      expect(t(auto, 'medium', 'restaurant'), isNull);
      // When unsure, high or unknown: never, printed chain or not.
      expect(
        t(auto, 'high', 'restaurant', brand: mcd, merchant: receipt),
        isNull,
      );
      expect(t(auto, null, 'takeout', brand: mcd, merchant: receipt), isNull);
      // When unsure, not a restaurant or takeout meal: never — a branded
      // supermarket drink, a home meal with a branded sauce, an unknown
      // context, at any confidence.
      expect(
        t(auto, 'medium', 'packaged', brand: mcd, merchant: receipt),
        isNull,
      );
      expect(t(auto, 'medium', 'home', brand: mcd, merchant: receipt), isNull);
      expect(t(auto, 'low', 'unknown', brand: mcd, merchant: receipt), isNull);
      expect(t(auto, 'medium', null, brand: mcd, merchant: receipt), isNull);
      // Always: restaurant or takeout, whatever the confidence — and still
      // stamped "always", never auto_branding.
      expect(
        t(always, 'medium', 'restaurant', brand: mcd),
        AssistTrigger.always,
      );
      expect(t(always, 'high', 'takeout'), AssistTrigger.always);
      // Always, elsewhere: only with an item's own printed brand.
      expect(t(always, 'medium', 'home', brand: mcd), AssistTrigger.always);
      expect(t(always, 'medium', 'home', merchant: receipt), isNull);
    });

    // The inputs are read as the stored analysis is read everywhere else
    // (core/coerce.dart; estimate_confidence_test.dart has every spelling)
    // and as the request composer reads them: a few rows through the rule.
    test('assistTriggerFor reads the stored fields as the coercions and the '
        'request composer do', () {
      AssistTrigger? auto(Map<String, dynamic> a) =>
          assistTriggerFor(a, AssistMode.auto);
      Map<String, dynamic> withConfidence(Object? value) => {
        ..._bigMac(),
        'estimate_confidence': value,
      };
      // Medium, as a model may write it.
      for (final medium in <Object>['Medium', ' medium ', '中', 0.5, 0.34]) {
        expect(
          auto(withConfidence(medium)),
          AssistTrigger.autoBranding,
          reason: '$medium',
        );
      }
      for (final low in <Object>['低', 0.1]) {
        expect(
          auto(withConfidence(low)),
          AssistTrigger.autoLowConfidence,
          reason: '$low',
        );
      }
      // High, and everything that reads as unknown: a numeric string, a
      // bool, a number outside 0..1, free text.
      for (final never in <Object?>['高', 0.9, '0.5', true, 1.5, 'unsure']) {
        expect(auto(withConfidence(never)), isNull, reason: '$never');
      }

      // The context, case and spaces aside; an invalid one is unknown.
      Map<String, dynamic> withContext(Object? value) => {
        ..._bigMac(confidence: 'medium'),
        'restaurant_context': value,
      };
      expect(auto(withContext('Restaurant')), AssistTrigger.autoBranding);
      expect(auto(withContext(' takeout ')), AssistTrigger.autoBranding);
      expect(auto(withContext('bar')), isNull);
      expect(auto(withContext(7)), isNull);

      // A printed brand counts only when it names a chain of OUR table…
      expect(auto(_bigMac(confidence: 'medium', brand: 'Coca-Cola')), isNull);
      expect(
        auto(_bigMac(confidence: 'medium', brand: '', merchant: "Joe's Diner")),
        isNull,
      );
      // …and only on the items a request can name: the first 12.
      Map<String, dynamic> manyItems(int brandedAt) => {
        ..._bigMac(confidence: 'medium', brand: ''),
        'food_items': [
          for (var i = 0; i < 13; i++)
            {
              'name': 'Item $i',
              'estimated_calories': 100,
              'brand': i == brandedAt ? "McDonald's" : '',
            },
        ],
      };
      expect(auto(manyItems(11)), AssistTrigger.autoBranding);
      expect(auto(manyItems(12)), isNull, reason: 'the 13th item is not sent');
    });
  });

  // Owner decision 2026-11-05: "When unsure" also looks up a restaurant or
  // takeout meal the AI was fairly sure about (medium) when a chain's brand
  // is printed on an item or names the receipt's merchant. The lookup, the
  // gates, the decision rules, the cache and the counters are the ones
  // every lookup uses; only the block's trigger says auto_branding.
  // (meal_assist_location_test.dart pins that this lookup never takes the
  // location path.)
  group('auto_branding: When unsure, a fairly sure meal with a printed '
      'chain', () {
    Map<String, dynamic> medium({
      String? context = 'restaurant',
      String brand = "McDonald's",
      String merchant = '',
    }) => _bigMac(
      confidence: 'medium',
      context: context,
      brand: brand,
      merchant: merchant,
    );
    Map blockOf(int id) => h.analysisOf(id)['assist'] as Map;

    for (final context in ['restaurant', 'takeout']) {
      test("a $context meal with an item's printed brand: looked up, "
          'applied, announced, marked unseen', () async {
        final id = h.add(medium(context: context));
        await h.assist.sweep();

        expect(h.lookups.submits, hasLength(1));
        final request = h.lookups.submits.single;
        expect(request.chainKeys, ['mcdonalds']);
        expect(request.body['country'], 'US');
        expect(h.lookups.args.single.stamp, 'anthropic');
        // Nothing about why it ran is sent: not the trigger, not the
        // confidence, not the context.
        expect(request.body.keys.toSet(), {
          'items',
          'order_merchant',
          'chains',
          'country',
        });
        final sent = request.toJson();
        for (final unsent in ['auto_branding', 'medium', context]) {
          expect(sent, isNot(contains(unsent)), reason: unsent);
        }

        final block = blockOf(id);
        expect(block['status'], AssistStatus.applied);
        expect(block['trigger'], 'auto_branding');
        expect(block['evidence'], 'item_brand');
        expect(h.analysisOf(id)['total_calories'], 590);
        expect(h.dao.byId(id).corrected, isFalse);
        final n = h.notices.single;
        expect((n.mealId, n.oldKcal, n.newKcal), (id, 540, 590));
        expect(await h.state.unseen(), {id});
        final log = await h.state.decisions();
        expect(log.single.code, 'applied');
        expect((log.single.oldKcal, log.single.newKcal), (540, 590));
      });

      test('a $context meal whose only printed chain is the receipt\'s '
          'merchant: looked up, a suggestion at most', () async {
        final id = h.add(
          medium(context: context, brand: '', merchant: "McDonald's #2381"),
        );
        await h.assist.sweep();

        expect(h.lookups.submits, hasLength(1));
        final request = h.lookups.submits.single;
        expect(request.chainKeys, ['mcdonalds']);
        expect(
          request.body['order_merchant'],
          "McDonald's",
          reason: 'the canonical name, never the receipt text',
        );
        final block = blockOf(id);
        expect(block['status'], AssistStatus.suggested);
        expect(block['trigger'], 'auto_branding');
        expect(block['evidence'], 'order_merchant');
        expect(block['reason'], AssistReason.orderMerchantOnly);
        expect(h.analysisOf(id)['total_calories'], 540, reason: 'untouched');
        expect(h.notices, isEmpty);
        expect(await h.state.unseen(), isEmpty);
      });
    }

    test('never without a printed chain, never outside restaurant and '
        'takeout, never at high or unknown confidence', () async {
      // Medium, restaurant or takeout, but nothing names a chain of ours.
      h.add(medium(brand: ''));
      h.add(medium(brand: 'Coca-Cola'));
      h.add(medium(brand: '', merchant: "Joe's Diner"));
      h.add(medium(context: 'takeout', brand: ''));
      // Medium with a printed chain, but not a restaurant or takeout meal:
      // a branded supermarket drink, a home meal with a branded sauce.
      for (final context in ['home', 'packaged', 'unknown', null]) {
        h.add(medium(context: context));
        h.add(medium(context: context, brand: '', merchant: "McDonald's"));
        h.add(medium(context: context, merchant: "McDonald's #2381"));
      }
      // A printed chain at a restaurant, but not medium (or low).
      for (final confidence in ['high', null, 'unsure']) {
        h.add(_bigMac(confidence: confidence));
        h.add(_bigMac(confidence: confidence, merchant: "McDonald's #2381"));
      }
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.polls, isEmpty);
      expect(h.dao.snapshotReads, isEmpty, reason: 'no run was started');
      expect(h.dao.assistWrites, isEmpty);
      expect(await h.state.decisions(), isEmpty);
    });

    test('the other modes are unchanged: Off reads nothing; Always looks '
        'the same meal up as "always"', () async {
      h.settings = const AssistSettingsView();
      final id = h.add(medium());
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.supportReads, 0);
      expect(h.dao.listings, 0);
      expect(h.dao.snapshotReads, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.off);

      h.settings = AssistSettingsView(
        mode: AssistMode.always,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(blockOf(id)['trigger'], 'always');
      expect(blockOf(id)['status'], AssistStatus.applied);
    });

    test('Claude Plan: looked up on the own server, only ever a '
        'suggestion', () async {
      h.lookups.support = _claudePlan;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      // The server's text is a search summary, not the page's own.
      h.lookups.onSubmit = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      final id = h.add(medium());
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.lookups.args.single.recipient, LookupRecipient.claudePlan);
      expect(h.lookups.args.single.stamp, 'claude_plan:abcd1234');
      final block = blockOf(id);
      expect(block['status'], AssistStatus.suggested);
      expect(block['reason'], AssistReason.notGrounded);
      expect(block['trigger'], 'auto_branding');
      expect(block['provider'], 'claude_plan');
      expect(h.analysisOf(id)['total_calories'], 540);
      expect(h.notices, isEmpty);
      expect(await h.state.unseen(), isEmpty);
    });

    test('the cache and the 6 h rule are keyed by chain and items, never by '
        'trigger: a low-confidence answer serves the same meal at medium, '
        'and a refusal holds for it', () async {
      final first = h.add(_bigMac());
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(blockOf(first)['trigger'], 'auto_low_confidence');
      expect(blockOf(first)['status'], AssistStatus.applied);

      // The same items ten minutes later, the AI fairly sure this time.
      h.now = _now.add(const Duration(minutes: 10));
      final second = h.add(medium(), timestamp: '2026-10-24T12:40:00.000');
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1), reason: 'a cache hit');
      expect(blockOf(second)['trigger'], 'auto_branding');
      expect(blockOf(second)['status'], AssistStatus.suggested);
      expect(blockOf(second)['reason'], AssistReason.repeat);
      expect(h.analysisOf(second)['total_calories'], 540);
      expect(h.notices, hasLength(1), reason: 'no second snackbar');

      // The user turns the first one down: those numbers for those items
      // are only ever suggested again, whatever triggers the lookup.
      expect(await h.notices.single.undo(), isTrue);
      h.now = _now.add(const Duration(minutes: 20));
      final third = h.add(medium(), timestamp: '2026-10-24T12:50:00.000');
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1), reason: 'still the cache');
      expect(blockOf(third)['trigger'], 'auto_branding');
      expect(blockOf(third)['status'], AssistStatus.suggested);
      expect(blockOf(third)['reason'], AssistReason.declinedBefore);
      expect(h.analysisOf(third)['total_calories'], 540);
      expect(h.notices, hasLength(1));
      // What is kept holds no trigger at all.
      for (final name in [
        assistCacheDocument,
        assistJobsDocument,
        assistDecisionsDocument,
      ]) {
        final kept = jsonEncode(h.document(name));
        expect(kept, isNot(contains('auto_')), reason: name);
        expect(kept, isNot(contains('trigger')), reason: name);
      }
    });

    // Settings' Stop Sharing (Off and the consent forgotten in one write)
    // stops these lookups like every other: the consent is read again at
    // the send (MealAssist._maySend), whatever the trigger.
    test('Settings stopped the lookups after its gate, before any '
        'notification: nothing is sent, a pending job is not polled', () async {
      const stopped = AssistSettingsView();
      h.lookups.support = _claudePlan;
      final allowed = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      h.settings = allowed;
      final id = h.add(medium());
      h.dao.onSnapshot = (_) => h.settings = stopped;
      await h.assist.sweep();
      expect(h.dao.snapshotReads, [id], reason: 'the gate let it through');
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.polls, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.cancelled);
      expect(h.dao.assistWrites, isEmpty);
      expect(await h.state.jobs(), isEmpty);
      expect(await h.state.misses(), isEmpty, reason: "not the meal's fault");

      // Allowed again, its lookup becomes a job on the server…
      h.dao.onSnapshot = null;
      h.settings = allowed;
      h.lookups.onSubmit = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
        jobId: 'job_abcdef12',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect((await h.state.jobs())[id]?.jobId, 'job_abcdef12');

      // …which is not polled, and not sent again, once stopped.
      h.now = _now.add(kAssistPollInterval);
      h.dao.onSnapshot = (_) => h.settings = stopped;
      await h.assist.sweep();
      expect(h.lookups.polls, isEmpty);
      expect(h.lookups.submits, hasLength(1));
      expect(h.assist.lastSkip, AssistSkip.cancelled);
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
    });

    // Every gate an automatic lookup passes is checked before the trigger
    // matters, so the new trigger can open none of them. Each test holds
    // one gate shut for a medium meal with a printed brand, then shows the
    // same harness looking a meal up once the gate is open.
    group('passes the same gates as every automatic lookup', () {
      Future<void> expectNothing(int id) async {
        expect(h.lookups.submits, isEmpty);
        expect(h.lookups.polls, isEmpty);
        expect(h.dao.assistWrites, isEmpty);
        expect(h.analysisOf(id).containsKey('assist'), isFalse);
        expect(await h.state.jobs(), isEmpty);
      }

      Future<void> expectLookedUpNow() async {
        await h.assist.sweep();
        expect(h.lookups.submits, hasLength(1));
      }

      final allowed = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );

      test('Off', () async {
        h.settings = const AssistSettingsView();
        final id = h.add(medium());
        await h.assist.sweep();
        await expectNothing(id);
        expect(h.assist.lastSkip, AssistSkip.off);
        expect(h.lookups.supportReads, 0);
        h.settings = allowed;
        await expectLookedUpNow();
      });

      test('no consent', () async {
        h.settings = const AssistSettingsView(mode: AssistMode.auto);
        final id = h.add(medium());
        await h.assist.sweep();
        await expectNothing(id);
        expect(h.assist.lastSkip, AssistSkip.consentNeeded);
        expect(
          h.assist.consentNeeded.value?.recipient,
          LookupRecipient.anthropic,
        );
        h.settings = allowed;
        await expectLookedUpNow();
      });

      test('a consent stamped for another recipient: the assist pauses and '
          'asks', () async {
        h.lookups.support = _openrouter;
        final id = h.add(medium());
        await h.assist.sweep();
        await expectNothing(id);
        expect(h.assist.lastSkip, AssistSkip.consentNeeded);
        expect(
          h.assist.consentNeeded.value?.recipient,
          LookupRecipient.openrouter,
        );
        h.lookups.support = _anthropic;
        await expectLookedUpNow();
      });

      test('the app in the background', () async {
        h.foreground = false;
        final id = h.add(medium());
        await h.assist.sweep();
        await expectNothing(id);
        expect(h.assist.lastSkip, AssistSkip.background);
        expect(h.dao.listings, 0);
        h.foreground = true;
        await expectLookedUpNow();
      });

      test('the photo pipeline busy', () async {
        h.idle = false;
        final id = h.add(medium());
        await h.assist.sweep();
        await expectNothing(id);
        expect(h.assist.lastSkip, AssistSkip.pipelineBusy);
        h.idle = true;
        await expectLookedUpNow();
      });

      test('an analyzer call in flight', () async {
        h.busy.value = 1;
        final id = h.add(medium());
        await h.assist.sweep();
        await expectNothing(id);
        expect(h.assist.lastSkip, AssistSkip.analyzerBusy);
        h.busy.value = 0;
        await expectLookedUpNow();
      });

      test('the daily cap reached', () async {
        SharedPreferences.setMockInitialValues({
          assistDailyPrefsKey: jsonEncode({'date': _today, 'count': 20}),
        });
        h = _Harness(root, await SharedPreferences.getInstance());
        final id = h.add(medium());
        await h.assist.sweep();
        await expectNothing(id);
        expect(h.assist.lastSkip, AssistSkip.dailyCap);
        expect(h.assist.lookupsToday, assistDailyCap);
        // Tomorrow's count starts at zero.
        h.now = DateTime(2026, 10, 25, 9, 0);
        h.add(
          medium(),
          date: '2026-10-25',
          timestamp: '2026-10-25T08:30:00.000',
        );
        await expectLookedUpNow();
      });

      test('a meal logged before the consent', () async {
        final id = h.add(medium(), timestamp: '2026-10-24T07:59:00.000');
        await h.assist.sweep();
        await expectNothing(id);
        h.add(medium(), timestamp: '2026-10-24T08:01:00.000');
        await expectLookedUpNow();
      });

      test('a meal logged 25 h ago', () async {
        h.settings = AssistSettingsView(
          mode: AssistMode.auto,
          consentAt: DateTime(2026, 10, 1),
          consentRecipient: 'anthropic',
        );
        final id = h.add(
          medium(),
          date: '2026-10-23',
          timestamp: '2026-10-23T11:59:00.000',
        );
        await h.assist.sweep();
        await expectNothing(id);
        h.add(
          medium(),
          date: '2026-10-23',
          timestamp: '2026-10-23T13:30:00.000',
        );
        await expectLookedUpNow();
      });

      test('a corrected meal, a text meal, a manual meal', () async {
        final ids = [
          h.add(medium(), corrected: true),
          h.add(medium(), source: MealSource.manualText),
          h.add(medium(), source: MealSource.appManual),
        ];
        await h.assist.sweep();
        for (final id in ids) {
          await expectNothing(id);
        }
        h.add(medium(), source: MealSource.appPhoto);
        await expectLookedUpNow();
      });

      test('a meal open in a screen', () async {
        final id = h.add(medium());
        h.inUse.add(id);
        await h.assist.sweep();
        await expectNothing(id);
        h.inUse.clear();
        await expectLookedUpNow();
      });
    });
  });

  group('Off', () {
    test(
      'cancels the call in flight, discards its result and forgets jobs',
      () async {
        h.lookups.support = _claudePlan;
        h.settings = AssistSettingsView(
          mode: AssistMode.auto,
          consentAt: _consentAt,
          consentRecipient: 'claude_plan:abcd1234',
        );
        final first = h.add(_bigMac(), timestamp: '2026-10-24T11:00:00.000');
        final id = h.add(_bigMac());
        // The older meal's lookup is a job the server is running.
        h.lookups.onSubmit = (_) async => const LookupOutcome(
          kind: LookupOutcomeKind.pending,
          provider: LookupRecipient.claudePlan,
          jobId: 'job_first_1234',
        );
        h.inUse.add(id);
        await h.assist.sweep();
        expect((await h.state.jobs()).keys, [first]);
        h.inUse.clear();

        final answer = Completer<LookupOutcome>();
        h.lookups.onSubmit = (_) => answer.future;
        h.assist.start(observeLifecycle: false);
        final sweep = h.assist.sweep();
        await _until(() => h.lookups.submits.length == 2);
        final token = h.lookups.args.last.cancel!;
        expect(token.isCancelled, isFalse);

        h.setSettings(const AssistSettingsView());
        expect(token.isCancelled, isTrue);
        answer.complete(_done(provider: LookupRecipient.claudePlan));
        await sweep;
        await _until(() => h.document(assistJobsDocument).isEmpty);
        expect(h.dao.assistWrites, isEmpty);
        expect(h.analysisOf(id).containsKey('assist'), isFalse);
        expect(await h.state.jobs(), isEmpty);
        expect(h.notices, isEmpty);
      },
    );

    // Review 2026-10-25 (PROBE1/P1): the answer had arrived and passed the
    // generation check; Off landed while the 6 h rule's meals were read.
    test('Off after the answer arrived, during the 6 h-rule read: nothing '
        'is written — no meal change, no dot, no snackbar', () async {
      final id = h.add(_bigMac());
      h.assist.start(observeLifecycle: false);
      // Listing 1 is the sweep's own; listing 2 is _decide's recent read.
      h.dao.onList = (n) {
        if (n == 2) h.setSettings(const AssistSettingsView());
      };
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1), reason: 'the answer arrived');
      expect(h.dao.assistWrites, isEmpty);
      expect(h.analysisOf(id)['total_calories'], 540);
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
      expect(await h.state.unseen(), isEmpty);
      expect(h.notices, isEmpty);
    });

    test(
      'a cached answer: Off during the decision\'s read writes nothing',
      () async {
        h.add(_bigMac());
        // The answer is kept, as a suggestion (no 6 h rule on the next meal).
        h.lookups.onSubmit = (_) async => _done(verbatim: false);
        await h.assist.sweep();
        final second = h.add(_bigMac(), timestamp: '2026-10-24T12:45:00.000');
        h.assist.start(observeLifecycle: false);
        final base = h.dao.listings;
        h.dao.onList = (n) {
          if (n == base + 2) h.setSettings(const AssistSettingsView());
        };
        await h.assist.sweep();
        expect(h.lookups.submits, hasLength(1), reason: 'a cache hit');
        expect(h.analysisOf(second).containsKey('assist'), isFalse);
      },
    );

    test('Settings say Off before their notification lands: an automatic '
        'result is discarded all the same', () async {
      final id = h.add(_bigMac());
      // No start(): nobody listens, so only the fresh read can tell.
      h.dao.onList = (n) {
        if (n == 2) h.settings = const AssistSettingsView();
      };
      await h.assist.sweep();
      expect(h.dao.assistWrites, isEmpty);
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
    });

    test('Off while a failed try is logged: no retry record outlives it, and '
        'no "unavailable" is written', () async {
      h.assist.start(observeLifecycle: false);
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async =>
          _failed(LookupFailureCode.network, transient: true);
      h.store.beforeWrite = (name) async {
        if (name == assistDecisionsDocument &&
            h.settings.mode != AssistMode.off) {
          h.setSettings(const AssistSettingsView());
        }
      };
      await h.assist.sweep();
      await _until(() => h.settings.mode == AssistMode.off);
      expect(await h.state.jobs(), isEmpty, reason: 'offline kept no job');
      expect(h.document(assistJobsDocument), isEmpty);

      // The last try of a meal: 'unavailable' is not written either.
      h.store.beforeWrite = null;
      h.setSettings(
        AssistSettingsView(
          mode: AssistMode.auto,
          consentAt: _consentAt,
          consentRecipient: 'anthropic',
        ),
      );
      await h.assist.sweep();
      await h.state.putJob(
        id,
        AssistJob(
          reqHash: '0123456789abcdef',
          at: _now,
          nextAt: _now,
          attempts: assistMaxRetries,
        ),
      );
      h.lookups.onSubmit = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.busy,
        provider: LookupRecipient.anthropic,
        failure: LookupFailure(LookupFailureCode.server, transient: true),
      );
      h.store.beforeWrite = (name) async {
        if (name == assistDecisionsDocument &&
            h.settings.mode != AssistMode.off) {
          h.setSettings(const AssistSettingsView());
        }
      };
      h.now = _now.add(const Duration(minutes: 10));
      await h.assist.sweep();
      expect(h.dao.assistWrites, isEmpty);
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
    });
  });

  // Settings' Stop Sharing turns the mode Off and forgets the assist's
  // consent in ONE settings write (stopRestaurantAssistFor). The settings
  // say so at once; the notification that cancels a run lands only once
  // the write is saved. A run already past its gate must send nothing in
  // between: the consent is read again at the send (MealAssist._maySend).
  // No start() in these tests: nobody listens, so only that read can tell.
  group('Settings stopped the lookups after the gate, before any '
      'notification', () {
    const stopped = AssistSettingsView(); // Off, the consent forgotten
    const pendingJob = LookupOutcome(
      kind: LookupOutcomeKind.pending,
      provider: LookupRecipient.claudePlan,
      jobId: 'job_abcdef12',
    );
    // The server no longer knows the job: pending without a job id.
    const lostJob = LookupOutcome(
      kind: LookupOutcomeKind.pending,
      provider: LookupRecipient.claudePlan,
    );

    void onClaudePlan({AssistMode mode = AssistMode.auto}) {
      h.lookups.support = _claudePlan;
      h.settings = AssistSettingsView(
        mode: mode,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
    }

    /// The harness's engine with one more seam: [beforeSend] runs when a
    /// run composes its request — after the meal's snapshot was read and
    /// checked, with nothing but the answer cache (automatic runs only)
    /// left before the send.
    MealAssist engine(void Function() beforeSend) {
      final assist = MealAssist(
        dao: h.dao,
        lookups: h.lookups,
        analyzerBusy: h.busy,
        pipelineIdle: () => h.idle,
        inUse: h.inUse.contains,
        budget: h.budget,
        state: h.state,
        settings: () => h.settings,
        inForeground: () => h.foreground,
        country: () => 'US',
        repliesInChinese: () {
          beforeSend();
          return false;
        },
        utcOffset: () => const Duration(hours: -5),
        clock: () => h.now,
      );
      addTearDown(assist.dispose);
      return assist;
    }

    test('Off and no consent right after the gate: an automatic lookup '
        'sends nothing and writes nothing; allowed again, it is looked '
        'up', () async {
      final id = h.add(_bigMac());
      final allowed = h.settings;
      h.dao.onSnapshot = (_) => h.settings = stopped;
      await h.assist.sweep();
      expect(h.dao.snapshotReads, [id], reason: 'the gate let it through');
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.polls, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.cancelled);
      expect(h.dao.assistWrites, isEmpty);
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
      expect(await h.state.jobs(), isEmpty);
      expect(await h.state.misses(), isEmpty, reason: "not the meal's fault");
      expect(await h.state.decisions(), isEmpty);
      expect(h.assist.consentNeeded.value, isNull);
      expect(h.signals, 0);

      h.dao.onSnapshot = null;
      h.settings = allowed;
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
    });

    test('the same at the send itself, after the snapshot and its check: '
        'nothing is sent', () async {
      final id = h.add(_bigMac());
      var composed = 0;
      final assist = engine(() {
        composed++;
        expect(h.dao.snapshotReads, [id]);
        h.settings = stopped;
      });
      await assist.sweep();
      expect(composed, 1, reason: 'the run got as far as its request');
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.polls, isEmpty);
      expect(assist.lastSkip, AssistSkip.cancelled);
      expect(h.dao.assistWrites, isEmpty);
      expect(await h.state.jobs(), isEmpty);
      expect(await h.state.misses(), isEmpty);
    });

    test('stopped right after the gate, the run reads nothing more: not '
        'even the answer cache', () async {
      h.add(_bigMac());
      final read = <String>[];
      h.store.beforeRead = read.add;
      h.dao.onSnapshot = (_) {
        read.clear(); // the sweep's own reads (misses, jobs) came before
        h.settings = stopped;
      };
      await h.assist.sweep();
      expect(read, isEmpty);
      expect(h.lookups.submits, isEmpty);
    });

    test('a pending job is not polled (not even its id is sent) and not '
        'sent again', () async {
      onClaudePlan();
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => pendingJob;
      await h.assist.sweep();
      expect((await h.state.jobs())[id]?.jobId, 'job_abcdef12');

      h.now = _now.add(kAssistPollInterval);
      h.dao.onSnapshot = (_) => h.settings = stopped;
      await h.assist.sweep();
      expect(h.lookups.polls, isEmpty);
      expect(h.lookups.submits, hasLength(1));
      expect(h.assist.lastSkip, AssistSkip.cancelled);
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
    });

    test('stopped while a poll runs, and the server lost the job: it is '
        'not sent again, and the run ends cancelled, not pending', () async {
      onClaudePlan();
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => pendingJob;
      await h.assist.sweep();
      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async {
        h.settings = stopped;
        return lostJob;
      };
      await h.assist.sweep();
      expect(h.lookups.polls, ['job_abcdef12']);
      expect(h.lookups.submits, hasLength(1), reason: 'no resubmit');
      expect(h.assist.lastSkip, AssistSkip.cancelled);
      expect(h.dao.assistWrites, isEmpty);
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
    });

    test("the same for the editor's own job: its poll loop is told "
        'cancelled, so it stops asking', () async {
      // The editor's lookup ignores the mode: only the consent decides.
      onClaudePlan(mode: AssistMode.off);
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => pendingJob;
      expect((await h.assist.lookupNow(id)).code, AssistSkip.pending);
      expect((await h.state.jobs())[id]?.manual, isTrue);

      h.lookups.onPoll = (_) async {
        h.settings = stopped;
        return lostJob;
      };
      final run = await h.assist.lookupNow(id);
      expect(run.code, AssistSkip.cancelled);
      expect(run.wrote, isFalse);
      expect(h.lookups.polls, ['job_abcdef12']);
      expect(h.lookups.submits, hasLength(1), reason: 'no resubmit');
    });

    test("the editor's lookup: the consent forgotten after its check — "
        'cancelled, nothing sent', () async {
      final id = h.add(_bigMac());
      h.inUse.add(id); // the editor holds it
      h.dao.onSnapshot = (_) => h.settings = stopped;
      final run = await h.assist.lookupNow(id);
      expect(run.code, AssistSkip.cancelled);
      expect(run.wrote, isFalse);
      expect(h.lookups.submits, isEmpty);
      expect(h.dao.assistWrites, isEmpty);

      // And at the send itself: a manual run has no await left before it.
      h.dao.onSnapshot = null;
      h.settings = AssistSettingsView(
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      final assist = engine(() => h.settings = stopped);
      final again = await assist.lookupNow(id);
      expect(again.code, AssistSkip.cancelled);
      expect(h.lookups.submits, isEmpty);
    });

    test('a consent stamped for another recipient, or another server, '
        'covers nothing here: nothing sent', () async {
      h.add(_bigMac());
      h.dao.onSnapshot = (_) => h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'openrouter',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.cancelled);

      // The own server: the consent now names another host.
      onClaudePlan();
      h.dao.onSnapshot = (_) => h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:ffffffff',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.polls, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.cancelled);
    });

    test("the mode row's own Off (the consent kept) before its "
        'notification: an automatic lookup is not sent; the editor\'s own '
        'still is', () async {
      final id = h.add(_bigMac());
      final off = AssistSettingsView(
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      h.dao.onSnapshot = (_) => h.settings = off;
      await h.assist.sweep();
      expect(h.lookups.submits, isEmpty);
      expect(h.assist.lastSkip, AssistSkip.cancelled);

      final run = await h.assist.lookupNow(id);
      expect(run.code, AssistSkip.applied);
      expect(h.lookups.submits, hasLength(1));
    });

    test('a change that keeps the consent for this recipient does not stop '
        'the send (another mode, a fresh consent time)', () async {
      final id = h.add(_bigMac());
      h.dao.onSnapshot = (_) => h.settings = AssistSettingsView(
        mode: AssistMode.always,
        consentAt: _consentAt.add(const Duration(hours: 1)),
        consentRecipient: 'anthropic',
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.lookups.args.single.stamp, 'anthropic');
      expect((h.analysisOf(id)['assist'] as Map)['status'], 'applied');
    });
  });

  group('Claude Plan jobs', () {
    setUp(() {
      h.lookups.support = _claudePlan;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
    });

    test('pending: the job is kept and polled on the next sweep; the answer '
        '(a search summary, not page text) is a suggestion', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
        jobId: 'job_abcdef12',
      );
      await h.assist.sweep();
      expect(h.lookups.args.single.stamp, 'claude_plan:abcd1234');
      final jobs = await h.state.jobs();
      expect(jobs[id]?.jobId, 'job_abcdef12');
      expect(
        jobs[id]?.reqHash,
        lookupRequestHash(composeAssistRequest(_bigMac(), country: 'US')),
      );
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
      // Not polled again before its next poll is due (R6c: every 10 s).
      await h.assist.sweep();
      expect(h.lookups.polls, isEmpty);

      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      await h.assist.sweep();
      expect(h.lookups.polls, ['job_abcdef12']);
      expect(h.lookups.submits, hasLength(1), reason: 'polled, not resent');
      final block = h.analysisOf(id)['assist'] as Map;
      expect(block['status'], AssistStatus.suggested);
      expect(block['provider'], 'claude_plan');
      expect(await h.state.jobs(), isEmpty);
    });

    test('a job the server lost is submitted again', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
        jobId: 'job_abcdef12',
      );
      await h.assist.sweep();
      h.now = _now.add(kAssistPollInterval);
      h.lookups.onPoll = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
      );
      h.lookups.onSubmit = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      await h.assist.sweep();
      expect(h.lookups.polls, hasLength(1));
      expect(h.lookups.submits, hasLength(2));
      expect(
        (h.analysisOf(id)['assist'] as Map)['status'],
        AssistStatus.suggested,
      );
    });

    test('a job for a meal whose request changed is not polled', () async {
      final id = h.add(_bigMac());
      h.lookups.onSubmit = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
        jobId: 'job_abcdef12',
      );
      await h.assist.sweep();
      h.dao.rewrite(id, (a) {
        final items = [
          for (final e in a['food_items'] as List)
            Map<String, dynamic>.from(e as Map)..['name'] = 'Quarter Pounder',
        ];
        return a..['food_items'] = items;
      });
      h.lookups.onSubmit = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.pending,
        provider: LookupRecipient.claudePlan,
        jobId: 'job_second_99',
      );
      h.now = _now.add(kAssistPollInterval);
      await h.assist.sweep();
      expect(h.lookups.polls, isEmpty);
      expect(h.lookups.submits, hasLength(2));
      expect((await h.state.jobs())[id]?.jobId, 'job_second_99');
    });
  });

  group('failures', () {
    test('a transient failure backs off the next sweeps', () async {
      h.add(_bigMac());
      h.lookups.onSubmit = (_) async =>
          _failed(LookupFailureCode.network, transient: true);
      await h.assist.sweep();
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.assist.lastSkip, AssistSkip.backoff);
      h.now = _now.add(kAssistTransientBackoff + const Duration(seconds: 1));
      h.lookups.onSubmit = null;
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2));
    });

    test('an old server or a rejected key holds the recipient until the '
        'recipient changes', () async {
      h.add(_bigMac());
      h.lookups.onSubmit = (_) async => const LookupOutcome(
        kind: LookupOutcomeKind.serverOutdated,
        provider: LookupRecipient.anthropic,
      );
      await h.assist.sweep();
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      expect(h.assist.lastSkip, AssistSkip.unavailable);
      h.assist.start(observeLifecycle: false);
      h.lookups.onSubmit = null;
      // An unrelated setting (the language, a photo's bookkeeping): held.
      h.settingsChanges.value++;
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(1));
      // Another recipient, consented to: asked again.
      h.lookups.support = _openrouter;
      h.setSettings(
        AssistSettingsView(
          mode: AssistMode.auto,
          consentAt: _consentAt,
          consentRecipient: 'openrouter',
        ),
      );
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2));

      final second = h.add(_bigMac(), timestamp: '2026-10-24T12:45:00.000');
      // Not the cached answer for the same items (R6c): a lookup.
      await h.state.clearCache();
      h.lookups.onSubmit = (_) async =>
          _failed(LookupFailureCode.auth, transient: false);
      await h.assist.sweep();
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(3));
      expect(
        (await h.state.misses())[second],
        isNull,
        reason: 'not the meal\'s fault',
      );
    });

    test(
      'a failure for this meal only denylists it and the sweep goes on',
      () async {
        final a = h.add(_bigMac());
        final b = h.add(_bigMac(), timestamp: '2026-10-24T11:00:00.000');
        h.lookups.onSubmit = (r) async => h.lookups.submits.length == 1
            ? _failed(LookupFailureCode.malformedReply, transient: false)
            : _done();
        await h.assist.sweep();
        expect(h.lookups.submits, hasLength(2));
        expect((await h.state.misses())[a], assistMissesBeforeDenylist);
        expect(
          (h.analysisOf(b)['assist'] as Map)['status'],
          AssistStatus.applied,
        );
        final codes = [for (final e in await h.state.decisions()) e.code];
        expect(codes, ['lookup_malformed_reply', 'applied']);
      },
    );
  });

  group('the sweep', () {
    test('single-flight: concurrent calls share one lookup', () async {
      h.add(_bigMac());
      final answer = Completer<LookupOutcome>();
      h.lookups.onSubmit = (_) => answer.future;
      final one = h.assist.sweep();
      final two = h.assist.sweep();
      await _until(() => h.lookups.submits.isNotEmpty);
      final three = h.assist.sweep();
      answer.complete(_done());
      await Future.wait([one, two, three]);
      expect(h.lookups.submits, hasLength(1));
      // The first pass lists the meals and reads them again for its
      // decision; the one more pass the later calls asked for lists them
      // once and finds nothing left to do.
      expect(h.dao.listings, 3);
    });

    test('a meals-changed signal sweeps after the settle delay; the '
        "assist's own write does not", () async {
      h.assist.start(observeLifecycle: false);
      h.add(_bigMac());
      h.mealsChanged.value++;
      await _until(() => h.lookups.submits.isNotEmpty);
      await _until(() => h.notices.isNotEmpty);
      final listings = h.dao.listings;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(h.dao.listings, listings);
    });

    test('a resume sweeps after the settle delay', () async {
      h.add(_bigMac());
      h.assist.onResumed();
      await _until(() => h.lookups.submits.isNotEmpty);
    });

    test('turning the mode on sweeps at once', () async {
      h.settings = const AssistSettingsView();
      h.assist.start(observeLifecycle: false);
      h.add(_bigMac());
      h.setSettings(
        AssistSettingsView(
          mode: AssistMode.always,
          consentAt: _consentAt,
          consentRecipient: 'anthropic',
        ),
      );
      await _until(() => h.lookups.submits.isNotEmpty);
    });

    test('newest meal first', () async {
      final older = h.add(_bigMac(), timestamp: '2026-10-24T09:00:00.000');
      final newer = h.add(_bigMac(), timestamp: '2026-10-24T12:00:00.000');
      final order = <int>[];
      h.dao.beforeCompareAndSet = (id) async => order.add(id);
      await h.assist.sweep();
      expect(order, [newer, older]);
    });

    test('the same chain and menu item applied within 6 h on another meal '
        'is only suggested', () async {
      h.add(_bigMac(), timestamp: '2026-10-24T12:00:00.000');
      final second = h.add(_bigMac(), timestamp: '2026-10-24T12:30:00.000');
      final first = second - 1;
      // The newer meal goes first and applies; the older one is a repeat.
      await h.assist.sweep();
      expect(
        (h.analysisOf(second)['assist'] as Map)['status'],
        AssistStatus.applied,
      );
      final block = h.analysisOf(first)['assist'] as Map;
      expect(block['status'], AssistStatus.suggested);
      expect(block['reason'], AssistReason.repeat);
    });
  });

  group('lookupNow (the editor)', () {
    test('ignores the mode and the triggers; manual, no snackbar', () async {
      h.settings = AssistSettingsView(
        consentAt: _consentAt,
        consentRecipient: 'anthropic',
      );
      final id = h.add(_bigMac(confidence: 'high'));
      h.inUse.add(id); // the editor holds it
      final run = await h.assist.lookupNow(id);
      expect(run.wrote, isTrue);
      expect(run.code, AssistSkip.applied);
      expect(run.decision?.trigger, AssistTrigger.manual);
      expect((h.analysisOf(id)['assist'] as Map)['trigger'], 'manual');
      expect(h.notices, isEmpty);
      expect(await h.state.unseen(), isEmpty);
    });

    test('without a consent for this recipient: nothing sent, the sheet is '
        'asked for', () async {
      h.settings = const AssistSettingsView();
      final id = h.add(_bigMac());
      final run = await h.assist.lookupNow(id);
      expect(run.code, AssistSkip.consentNeeded);
      expect(h.lookups.submits, isEmpty);
      expect(h.assist.consentNeeded.value, isNotNull);
    });

    test('no printed chain: nothing sent', () async {
      final id = h.add(_bigMac(brand: ''));
      final run = await h.assist.lookupNow(id);
      expect(run.code, AssistSkip.noBrand);
      expect(h.lookups.submits, isEmpty);
    });

    test('in the background: nothing sent, nothing polled', () async {
      final id = h.add(_bigMac());
      h.foreground = false;
      final run = await h.assist.lookupNow(id);
      expect(run.code, AssistSkip.background);
      expect(h.lookups.submits, isEmpty);
      expect(h.lookups.polls, isEmpty);
    });

    // Review 2026-10-25 (PROBE3): a not_published answer was cached, and the
    // editor's lookup was answered from it for 30 days.
    test('never answered from the cache: a context-only meal is asked '
        'again', () async {
      h.lookups.onSubmit = (_) async => _done(
        json: {..._found(), 'status': 'not_published', 'matches': <Object>[]},
      );
      final id = h.add(_bigMac());
      await h.assist.sweep();
      expect((h.analysisOf(id)['assist'] as Map)['status'], 'not_published');
      expect(h.document(assistCacheDocument)['entries'], hasLength(1));

      h.lookups.onSubmit = null; // a fresh search finds it now
      final run = await h.assist.lookupNow(id);
      expect(h.lookups.submits, hasLength(2), reason: 'asked again');
      expect(run.wrote, isTrue);
      expect((h.analysisOf(id)['assist'] as Map)['status'], 'applied');
      // The fresh answer replaced the cached one.
      final entries = h.document(assistCacheDocument)['entries'] as List;
      expect(((entries.single as Map)['result'] as Map)['status'], 'found');
    });
  });

  group('the cache and the user\'s answers (review 2026-10-25)', () {
    Future<String> raw(int id) async =>
        (await h.dao.mealSnapshot(id))!.rawAnalysis;

    /// A second meal with the same items, 30 minutes later (inside the
    /// 6 h rule only if the first one still stands applied).
    int again({String at = '2026-10-24T13:20:00.000'}) {
      h.now = DateTime.parse(at).add(const Duration(minutes: 10));
      return h.add(_bigMac(), timestamp: at);
    }

    // PROBE2: Use AI estimate (or Undo, Wrong restaurant, Not from a
    // restaurant), and the next identical meal was applied again straight
    // from the cache — 0 lookups, a new snackbar — for 30 days.
    for (final answer in [
      'undo',
      AssistUserAction.useEstimate.name,
      AssistUserAction.wrongRestaurant.name,
      AssistUserAction.notFromRestaurant.name,
    ]) {
      test('$answer: the next identical meal is only suggested, from the '
          'cache, with no lookup and no snackbar', () async {
        final first = h.add(_bigMac());
        await h.assist.sweep();
        expect((h.analysisOf(first)['assist'] as Map)['status'], 'applied');
        expect(h.notices, hasLength(1));
        if (answer == 'undo') {
          expect(await h.notices.single.undo(), isTrue);
        } else {
          final r = await h.assist.act(
            first,
            AssistUserAction.values.byName(answer),
            expectedRaw: await raw(first),
          );
          expect(r.status, AssistActionStatus.done);
        }
        final entries = h.document(assistCacheDocument)['entries'] as List;
        expect((entries.single as Map)['declined'], isTrue);

        final second = again();
        await h.assist.sweep();
        expect(h.lookups.submits, hasLength(1), reason: 'a cache hit');
        final block = h.analysisOf(second)['assist'] as Map;
        expect(block['status'], AssistStatus.suggested);
        expect(block['reason'], AssistReason.declinedBefore);
        expect(h.analysisOf(second)['total_calories'], 540);
        expect(h.notices, hasLength(1), reason: 'no new snackbar');
        expect(await h.state.unseen(), isNot(contains(second)));
      });
    }

    test('Use published numbers takes the refusal back: the next identical '
        'meal applies again', () async {
      final first = h.add(_bigMac());
      await h.assist.sweep();
      await h.notices.single.undo();
      final second = again();
      await h.assist.sweep();
      expect((h.analysisOf(second)['assist'] as Map)['status'], 'suggested');
      final accepted = await h.assist.act(
        second,
        AssistUserAction.acceptSuggestion,
        expectedRaw: await raw(second),
      );
      expect(accepted.status, AssistActionStatus.done);
      final entries = h.document(assistCacheDocument)['entries'] as List;
      expect((entries.single as Map).containsKey('declined'), isFalse);

      // Past the 6 h rule for the accepted meal.
      final third = again(at: '2026-10-24T19:40:00.000');
      await h.assist.sweep();
      expect((h.analysisOf(third)['assist'] as Map)['status'], 'applied');
      expect(h.lookups.submits, hasLength(1));
      expect(h.notices, hasLength(2));
      expect(first, isNot(third));
    });

    test('a refusal holds for a fresh answer too (another provider)', () async {
      final first = h.add(_bigMac());
      await h.assist.sweep();
      await h.assist.act(
        first,
        AssistUserAction.useEstimate,
        expectedRaw: await raw(first),
      );
      h.lookups.support = _openrouter;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'openrouter',
      );
      h.lookups.onSubmit = (_) async =>
          _done(provider: LookupRecipient.openrouter);
      final second = again();
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2), reason: 'another provider');
      final block = h.analysisOf(second)['assist'] as Map;
      expect(block['status'], AssistStatus.suggested);
      expect(block['reason'], AssistReason.declinedBefore);
      expect(block['provider'], 'openrouter');
      final entries = h.document(assistCacheDocument)['entries'] as List;
      expect((entries.single as Map)['declined'], isTrue, reason: 'kept');
      expect((entries.single as Map)['provider'], 'openrouter');
    });

    // PROBE4 / P3: an Anthropic answer kept in the cache applied by itself
    // after the switch to Claude Plan, whose copy says it only suggests.
    test('an answer cached from another provider is a miss: on Claude Plan '
        'the meal is asked there, and only suggested', () async {
      h.add(_bigMac());
      await h.assist.sweep();
      expect(h.notices, hasLength(1));
      h.lookups.support = _claudePlan;
      h.settings = AssistSettingsView(
        mode: AssistMode.auto,
        consentAt: _consentAt,
        consentRecipient: 'claude_plan:abcd1234',
      );
      h.lookups.onSubmit = (_) async =>
          _done(provider: LookupRecipient.claudePlan, verbatim: false);
      final second = again(at: '2026-10-24T19:50:00.000');
      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2), reason: 'not from the cache');
      expect(h.lookups.args.last.recipient, LookupRecipient.claudePlan);
      final block = h.analysisOf(second)['assist'] as Map;
      expect(block['status'], AssistStatus.suggested);
      expect(block['provider'], 'claude_plan');
      expect(h.notices, hasLength(1));
    });

    test('the updated dot is stored before the meals-changed signal', () async {
      final id = h.add(_bigMac());
      Future<Set<int>>? atSignal;
      h.onSignal = () => atSignal ??= h.state.unseen();
      await h.assist.sweep();
      expect(await atSignal, contains(id));
    });
  });

  group('the decision log', () {
    test(
      'holds codes and kcal only: no chain, item, place, URL or meal id',
      () async {
        final id = h.add(_bigMac());
        await h.assist.sweep();
        await h.notices.single.undo();
        h.add(_bigMac(), timestamp: '2026-10-24T12:40:00.000');
        h.lookups.onSubmit = (_) async =>
            _failed(LookupFailureCode.malformedReply, transient: false);
        await h.assist.sweep();

        final doc = h.document(assistDecisionsDocument);
        final log = doc['log'] as List;
        expect(log, hasLength(3));
        for (final e in log) {
          expect((e as Map).keys.toSet(), {
            'at',
            'code',
            'old_kcal',
            'new_kcal',
            'provider',
          });
        }
        final text = jsonEncode(doc).toLowerCase();
        for (final banned in [
          'mcdonald',
          'big mac',
          'http',
          '.com',
          'sandwich',
          '"meal',
          '"id"',
        ]) {
          expect(text, isNot(contains(banned)), reason: banned);
        }
        expect(text, isNot(contains('"$id"')));
      },
    );

    test('keeps the last 20', () async {
      for (var i = 0; i < 25; i++) {
        await h.state.logDecision(AssistDecisionEntry(at: _now, code: 'c$i'));
      }
      final log = await h.state.decisions();
      expect(log, hasLength(assistDecisionLogCap));
      expect(log.first.code, 'c5');
      expect(log.last.code, 'c24');
    });
  });

  group('the snackbar', () {
    AssistAppliedNotice notice(String key, String name) => AssistAppliedNotice(
      mealId: 1,
      chainKey: key,
      brandName: name,
      oldKcal: 540,
      newKcal: 590,
      undo: () async => true,
    );

    test('en and zh, exactly', () {
      final en = AppLocalizationsEn();
      final zh = AppLocalizationsZh();
      expect(
        assistAppliedSnackbar(en, notice('mcdonalds', "McDonald's")),
        "Used McDonald's published numbers: 540 → 590 kcal",
      );
      expect(
        assistAppliedSnackbar(zh, notice('mcdonalds', "McDonald's")),
        '已采用 麦当劳 公布的数值：540 → 590 千卡',
      );
      // No Chinese name in the table: the table's own name.
      expect(
        assistAppliedSnackbar(zh, notice('chipotle', 'Chipotle')),
        '已采用 Chipotle 公布的数值：540 → 590 千卡',
      );
      // English possessives: a name that already is one keeps its own.
      expect(
        assistAppliedSnackbar(en, notice('chipotle', 'Chipotle')),
        "Used Chipotle's published numbers: 540 → 590 kcal",
      );
      expect(
        assistAppliedSnackbar(en, notice('popeyes', 'Popeyes')),
        "Used Popeyes' published numbers: 540 → 590 kcal",
      );
      expect(
        assistAppliedSnackbar(en, notice('wendys', 'Wendy’s')),
        'Used Wendy’s published numbers: 540 → 590 kcal',
      );
      expect(en.assistUndo, 'Undo');
      expect(zh.assistUndo, '撤销');
    });
  });

  test('deviceRegion: the locale name\'s region, else the preferred '
      'languages\' (review 2026-10-25: a region-less zh_Hans read as "not '
      'the US")', () {
    expect(deviceRegion('zh-Hans_US', const ['CN']), 'US');
    expect(deviceRegion('zh_Hans', const [null, 'US', 'CN']), 'US');
    expect(deviceRegion('zh_Hans', const [null, 'us']), isNull);
    expect(deviceRegion('en', const []), isNull);
  });

  test('regionOfLocale', () {
    expect(regionOfLocale('en_US'), 'US');
    expect(regionOfLocale('zh-Hans_US'), 'US');
    expect(regionOfLocale('zh_Hant_TW'), 'TW');
    expect(regionOfLocale('en_US.UTF-8'), 'US');
    expect(regionOfLocale('zh-Hans'), isNull);
    expect(regionOfLocale(''), isNull);
  });
}
