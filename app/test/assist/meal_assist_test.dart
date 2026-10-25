/// services/assist/meal_assist.dart — the restaurant assist's engine, brand
/// path (design R6b): the preconditions (Off, the pipeline, the analyzer,
/// the foreground, the consent's recipient, the daily cap), eligibility
/// (24 h, the consent time, corrected, in use, the miss list), the triggers,
/// the compare-and-set write and its miss counting, Undo, Off cancelling
/// the call in flight, the Claude Plan job kept for the next sweep, the
/// snackbar wording, and a decision log without names or places.
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

  @override
  Future<List<Meal>> mealsBetween(String startDate, String endDate) {
    listings++;
    return super.mealsBetween(startDate, endDate);
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
  late final AssistLocalState state = AssistLocalState(
    LocalNoBackupStore(
      root: () async => root,
      createMissingDirectory: true,
      clock: () => now,
    ),
    clock: () => now,
  );

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
      mealsChanged.value++;
    },
    onApplied: notices.add,
    inForeground: () => foreground,
    country: () => 'US',
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

      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2));
      expect((await h.state.misses())[id], assistMissesBeforeDenylist);

      await h.assist.sweep();
      expect(h.lookups.submits, hasLength(2), reason: 'denylisted');
      expect(h.analysisOf(id).containsKey('assist'), isFalse);
    });
  });

  group('triggers', () {
    test(
      'When unsure: unknown, medium or high confidence never triggers',
      () async {
        h.add(_bigMac(confidence: null));
        h.add(_bigMac(confidence: 'medium'));
        h.add(_bigMac(confidence: 'high'));
        h.add(_bigMac(confidence: 'unsure'));
        await h.assist.sweep();
        expect(h.lookups.submits, isEmpty);
      },
    );

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

  test('regionOfLocale', () {
    expect(regionOfLocale('en_US'), 'US');
    expect(regionOfLocale('zh-Hans_US'), 'US');
    expect(regionOfLocale('zh_Hant_TW'), 'TW');
    expect(regionOfLocale('en_US.UTF-8'), 'US');
    expect(regionOfLocale('zh-Hans'), isNull);
    expect(regionOfLocale(''), isNull);
  });
}
