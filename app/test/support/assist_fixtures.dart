/// Meals carrying a restaurant-assist block (design R7b's screens), built
/// through the real decision and write rules (core/restaurant_assist_logic
/// .dart), so a screen test sees exactly the blocks the assist writes.
library;

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/restaurant_assist_logic.dart';
import 'package:calorie_tracker/core/restaurant_lookup_contract.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart'
    show LookupRecipient, LookupSupport;
import 'package:calorie_tracker/services/assist/meal_assist.dart'
    show
        AssistActionResult,
        AssistActionStatus,
        AssistRun,
        AssistSkip,
        AssistUserAction;
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';

import 'fake_meals_dao.dart';

const String assistMcdUrl =
    'https://www.mcdonalds.com/us/en-us/product/big-mac.html';

/// When the fixtures' lookups were decided (the meals are logged on this
/// day).
final DateTime assistFixtureNow = DateTime(2026, 10, 24, 13, 0);

/// A Big Mac in its printed McDonald's box, 540 kcal by the photo model.
Map<String, dynamic> bigMacAnalysis({
  String brand = "McDonald's",
  String context = 'restaurant',
  String portion = 'whole',
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
  'meal_description': 'A Big Mac in its box',
  'estimate_confidence': 'low',
  'restaurant_context': context,
  'portion_state': portion,
  'order_merchant': '',
};

/// McDonald's published Big Mac: 590 kcal, 25 g protein, 46 g carbs, 34 g
/// fat.
Map<String, dynamic> bigMacFound({
  String? url = assistMcdUrl,
  String type = 'official_site',
  String notes = '',
}) => {
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
          'label': 'Regular',
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
  'source_url': url,
  'source_title': 'Big Mac: Calories & Nutrition',
  'source_type': type,
  'source_year': 2026,
  'match_confidence': 0.9,
  'notes': notes,
};

/// decideAssist for [analysis] and [result] as the assist would call it.
/// [verbatim] false is the owner's server (search summaries): a one-tap
/// suggestion at most.
///
/// [atSpot] plays the location path: the place step named McDonald's at
/// the photo's spot — a chain the user confirmed there ([confirmed]:
/// location_confirmed, which can apply) or a first visit (location: a
/// suggestion at most).
AssistDecision decideFixture(
  Map<String, dynamic> analysis,
  Map<String, dynamic> result, {
  bool verbatim = true,
  String provider = 'anthropic',
  bool atSpot = false,
  bool confirmed = false,
}) {
  final request = LookupRequest.compose({
    'items': analysis['food_items'],
    'order_merchant': analysis['order_merchant'],
    if (atSpot) 'chains': ['mcdonalds'],
  });
  final url = result['source_url'] is String
      ? result['source_url'] as String
      : assistMcdUrl;
  return decideAssist(
    Meal(
      id: 1,
      date: '2026-10-24',
      time: '12:30 PM',
      timestamp: '2026-10-24T12:30:00.000',
      source: MealSource.appWatch,
      analysis: analysis,
    ),
    AssistLookup(
      result: result,
      provider: provider,
      citedUrls: [url],
      evidence: [
        AssistEvidence(
          url: url,
          text: 'Big Mac 590 Cal. 25 g protein, 46 g carbs, 34 g fat.',
          verbatim: verbatim,
        ),
      ],
    ),
    AssistContext(
      now: assistFixtureNow,
      trigger: AssistTrigger.autoLowConfidence,
      country: 'US',
      requestChainKeys: request.chainKeys,
      requestItems: request.body['items'] as List<Object?>,
      locationChainKeys: atSpot ? const ['mcdonalds'] : const [],
      placeChainKey: atSpot ? 'mcdonalds' : null,
      confirmedChainKeys: confirmed ? const {'mcdonalds'} : const {},
      placeVerified: atSpot,
    ),
  );
}

/// McDonald's published numbers applied (a direct Anthropic key).
Map<String, dynamic> appliedBigMac({String notes = ''}) {
  final a = bigMacAnalysis();
  final d = decideFixture(a, bigMacFound(notes: notes));
  assert(d.outcome == AssistOutcome.apply);
  return applyAssist(a, d)!;
}

/// McDonald's published numbers applied on location alone: an unbranded
/// Big Mac at a spot where the user confirmed McDonald's
/// (location_confirmed) — 'Correct' can teach that spot.
Map<String, dynamic> appliedBigMacAtSpot() {
  final a = bigMacAnalysis(brand: '');
  final d = decideFixture(a, bigMacFound(), atSpot: true, confirmed: true);
  assert(d.outcome == AssistOutcome.apply);
  assert(d.evidence == AssistEvidenceKind.locationConfirmed);
  return applyAssist(a, d)!;
}

/// A first visit: an unbranded Big Mac where the place step named
/// McDonald's (evidence location) — a suggestion.
Map<String, dynamic> suggestedBigMacAtSpot() {
  final a = bigMacAnalysis(brand: '');
  final d = decideFixture(a, bigMacFound(), atSpot: true);
  assert(d.outcome == AssistOutcome.suggest);
  assert(d.evidence == AssistEvidenceKind.location);
  return recordAssistDecision(a, d)!;
}

/// A shared plate (portion_state shared): the published number is one
/// whole serving, so a suggestion with reason portion_not_whole.
Map<String, dynamic> suggestedSharedBigMac() {
  final a = bigMacAnalysis(portion: 'shared');
  final d = decideFixture(a, bigMacFound());
  assert(d.outcome == AssistOutcome.suggest);
  assert(d.reason == AssistReason.portionNotWhole);
  return recordAssistDecision(a, d)!;
}

/// A suggestion whose size the photo cannot tell: McDonald's fries
/// published in three sizes (reason size_ambiguous, every size listed).
Map<String, dynamic> suggestedFriesSizes() {
  final a = {
    ...bigMacAnalysis(),
    'food_items': [
      {
        'name': 'French Fries',
        'estimated_calories': 320,
        'protein_g': 4,
        'carbs_g': 42,
        'fat_g': 15,
        'brand': "McDonald's",
        'qty': 1,
        'unit': 'serving',
      },
    ],
    'total_calories': 320,
    'total_protein_g': 4,
    'total_carbs_g': 42,
    'total_fat_g': 15,
  };
  Map<String, Object?> size(String label, int kcal, num p, num c, num f) => {
    'label': label,
    'serving': '1 $label fries',
    'unit': 'serving',
    'calories': kcal,
    'calories_range': null,
    'protein_g': p,
    'carbs_g': c,
    'fat_g': f,
  };
  final d = decideFixture(a, {
    ...bigMacFound(),
    'matches': [
      {
        'item_index': 0,
        'menu_item': 'World Famous Fries',
        'match_type': 'exact_item',
        'is_drink': false,
        'components': <Object>[],
        'options': [
          size('Small', 230, 3, 29, 11),
          size('Medium', 320, 5, 43, 15),
          size('Large', 480, 7, 65, 23),
        ],
      },
    ],
  });
  assert(d.outcome == AssistOutcome.suggest);
  assert(d.reason == AssistReason.sizeAmbiguous);
  return recordAssistDecision(a, d)!;
}

/// A one-tap suggestion (the owner's server: no verbatim page text).
Map<String, dynamic> suggestedBigMac() {
  final a = bigMacAnalysis();
  final d = decideFixture(
    a,
    bigMacFound(),
    verbatim: false,
    provider: 'claude_plan',
  );
  assert(d.outcome == AssistOutcome.suggest);
  return recordAssistDecision(a, d)!;
}

/// A lookup that found no published nutrition: names no restaurant.
Map<String, dynamic> contextOnlyBigMac() {
  final a = bigMacAnalysis();
  final d = decideFixture(a, {
    ...bigMacFound(),
    'status': 'not_published',
    'matches': <Object>[],
  });
  return recordAssistDecision(a, d)!;
}

/// [analysis] after the user changed the first item's calories.
Map<String, dynamic> editedFirstItem(Map<String, dynamic> analysis, num kcal) {
  final items = [
    for (final e in analysis['food_items'] as List)
      Map<String, dynamic>.from(e as Map),
  ];
  items[0]['estimated_calories'] = kcal;
  return Map<String, dynamic>.from(analysis)..['food_items'] = items;
}

/// A photo meal (camera roll) holding [analysis].
Meal assistMeal(Map<String, dynamic> analysis, {int id = 1}) => Meal(
  id: id,
  date: '2026-10-24',
  time: '12:30 PM',
  timestamp: '2026-10-24T12:30:00.000',
  source: MealSource.appWatch,
  imageHash: 'h$id',
  fileId: 'asset-$id',
  analysis: analysis,
);

/// The restaurant assist as the screens see it (RestaurantAssistControls),
/// over a fake DAO: the editor's answers write through the real pure rules
/// and the DAO's compare-and-set, as MealAssist.act does; lookups are
/// scripted. It records every call.
class FakeAssist {
  FakeAssist(this.dao);

  final BaseFakeDao dao;
  LookupSupport support = const LookupSupport(
    supported: true,
    recipient: LookupRecipient.anthropic,
    locationAllowed: true,
  );
  bool canLearn = true;
  Set<int> unseenIds = {};

  final List<({int id, AssistUserAction action, String expectedRaw})> acts = [];
  final List<({int id, bool useLocation, String? chainKey})> lookups = [];
  final List<int> seen = [];

  /// Overrides an answer's result (default: [defaultAct]).
  Future<AssistActionResult> Function(int id, AssistUserAction action)? onAct;

  /// Scripts a lookup (default: nothing to ask about).
  Future<AssistRun> Function(int id, bool useLocation, String? chainKey)?
  onLookup;

  RestaurantLookupsDiagnostics diagnostics = const RestaurantLookupsDiagnostics(
    today: 0,
    cap: 20,
  );

  RestaurantAssistControls controls() => RestaurantAssistControls(
    lookupSupport: () => support,
    clearLearnedPlaces: () async => true,
    lookupNow: (id, {bool useLocation = false, String? chainKey}) async {
      lookups.add((id: id, useLocation: useLocation, chainKey: chainKey));
      final f = onLookup;
      return f == null
          ? const AssistRun(AssistSkip.noBrand)
          : f(id, useLocation, chainKey);
    },
    act: (id, action, {required String expectedRaw}) async {
      acts.add((id: id, action: action, expectedRaw: expectedRaw));
      final f = onAct;
      return f != null ? f(id, action) : defaultAct(id, action, expectedRaw);
    },
    canLearnPlace: (_) => canLearn,
    unseen: () async => unseenIds,
    markSeen: (id) async {
      seen.add(id);
      unseenIds = {...unseenIds}..remove(id);
      return true;
    },
    lookupsDiagnostics: () async => diagnostics,
  );

  Future<AssistActionResult> defaultAct(
    int id,
    AssistUserAction action,
    String expectedRaw,
  ) async {
    final snap = await dao.mealSnapshot(id);
    if (snap == null || snap.rawAnalysis != expectedRaw) {
      return const AssistActionResult(AssistActionStatus.changed);
    }
    final a = snap.meal.analysis;
    final next = switch (action) {
      AssistUserAction.useEstimate => revertAssist(a),
      AssistUserAction.acceptSuggestion => acceptAssistSuggestion(
        a,
        now: assistFixtureNow,
      ),
      AssistUserAction.wrongRestaurant =>
        revertAssist(a, reason: AssistReason.userWrongRestaurant) ??
            declineAssistSuggestion(
              a,
              reason: AssistReason.userWrongRestaurant,
            ),
      AssistUserAction.notFromRestaurant =>
        revertAssist(a, reason: AssistReason.userNotRestaurant) ??
            declineAssistSuggestion(a, reason: AssistReason.userNotRestaurant),
      AssistUserAction.correct => null,
    };
    if (next == null && action != AssistUserAction.correct) {
      return const AssistActionResult(AssistActionStatus.nothing);
    }
    if (next != null &&
        !await dao.updateMealAnalysisIfUnchanged(
          id,
          expectedRaw: expectedRaw,
          analysis: next,
        )) {
      return const AssistActionResult(AssistActionStatus.changed);
    }
    return AssistActionResult(
      AssistActionStatus.done,
      placeLearned: canLearn && action != AssistUserAction.useEstimate,
    );
  }
}
