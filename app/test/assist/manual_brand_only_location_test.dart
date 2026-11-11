/// "Brand only" on the editor's consent sheet holds for the automatic
/// lookups it un-pauses (release-candidate review of 1.6.0, privacy).
///
/// The restaurant assist is ON with 'Use photo location' ON for recipient
/// A (Anthropic). The user switches the AI service to B (OpenRouter + Exa):
/// the assist pauses for a new consent. The editor's "Look up restaurant
/// nutrition" then shows the consent sheet for B (kind: manual) — the only
/// state the editor can show it in, since its button needs the mode on —
/// and the user answers **Brand only** ("Brand only skips the location and
/// uses only brand names printed on cups, bags or receipts").
///
/// That answer stamps the consent for B, so the AUTOMATIC sweep resumes.
/// It must resume brand-only: askRestaurantConsent used to leave
/// `restaurant_assist_location` as it was (true) for the manual kind, and
/// the next sweep read the next restaurant photo's position, asked Apple
/// Maps and sent the chain found there to B — although the only answer the
/// user ever gave about B was "Brand only".
///
/// The real sheet and restaurantManualLookupChoice, then a real MealAssist
/// wired to the same settings the way di.dart wires it: no photo position
/// is read, Apple Maps is not asked and no location-derived chain reaches
/// B.
library;

import 'dart:io';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/assist/assist_local_state.dart';
import 'package:calorie_tracker/services/assist/assist_places_store.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_client.dart';
import 'package:calorie_tracker/services/assist/clients/lookup_contract_adapter.dart';
import 'package:calorie_tracker/services/assist/meal_assist.dart';
import 'package:calorie_tracker/services/local_store.dart';
import 'package:calorie_tracker/services/photo/photo_library.dart';
import 'package:calorie_tracker/services/photo/photo_location.dart';
import 'package:calorie_tracker/services/places/places.dart';
import 'package:calorie_tracker/ui/restaurant_assist_controls.dart';
import 'package:calorie_tracker/ui/widgets/restaurant_consent_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/fakes.dart';

final DateTime _sheetAnsweredAt = DateTime(2026, 10, 24, 12, 0);
final DateTime _engineNow = DateTime(2026, 10, 24, 13, 0);

const LookupSupport _openrouter = LookupSupport(
  supported: true,
  recipient: LookupRecipient.openrouter,
  locationAllowed: true,
);

/// An unbranded burger at a restaurant, GPS in the photo: only the photo's
/// location can name its chain.
Map<String, dynamic> _bigMac() => {
      'is_food': true,
      'food_items': [
        {
          'name': 'Big Mac',
          'estimated_calories': 540,
          'protein_g': 24,
          'carbs_g': 44,
          'fat_g': 30,
          'brand': '',
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
      'capture': {'has_gps': true, 'gps_acc_m': 10, 'gps_fix_delta_s': 3},
    };

class _Lookups implements LookupClient {
  final List<LookupRequest> submits = [];
  @override
  LookupSupport lookupSupport() => _openrouter;
  @override
  Future<LookupOutcome> submit(LookupRequest request,
      {List<String> chainDomains = const [],
      LookupCancelToken? cancel,
      LookupRecipient? expectedRecipient,
      String? expectedRecipientStamp}) async {
    submits.add(request);
    return const LookupOutcome(
        kind: LookupOutcomeKind.failed,
        provider: LookupRecipient.openrouter,
        failure: LookupFailure(LookupFailureCode.malformedReply,
            transient: false));
  }

  @override
  Future<LookupOutcome> poll(String jobId) async =>
      LookupOutcome.unsupported('no jobs');
}

class _Source implements AssetLocationSource {
  final List<String> asked = [];
  @override
  Future<({double latitude, double longitude})?> assetLatLng(
      String assetId) async {
    asked.add(assetId);
    return (latitude: 40.758896, longitude: -73.985130); // Times Square
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

void main() {
  setUp(debugResetRestaurantConsentSheet);

  testWidgets(
      'paused for a new recipient: "Brand only" on the editor\'s consent '
      'sheet must not resume automatic lookups that read the photo location',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // On for Anthropic with 'Use photo location'; the user then switched
    // the AI service to OpenRouter: paused (the consent names Anthropic).
    final settings = FakeSettings()
      ..provider = 'openrouter'
      ..restaurantAssist = 'auto'
      ..restaurantAssistLocation = true
      ..restaurantAssistConsentAt = DateTime(2026, 10, 1)
      ..restaurantAssistConsentRecipient = 'anthropic';
    final controls = RestaurantAssistControls(
      lookupSupport: () => _openrouter,
      clearLearnedPlaces: () async => true,
      locationSupported: true, // iPhone
      now: () => _sheetAnsweredAt,
    );
    expect(restaurantConsentCovers(settings, _openrouter), isFalse,
        reason: 'paused: nothing is sent to OpenRouter yet');

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (context) {
        ctx = context;
        return const SizedBox.expand();
      })),
    ));

    // The editor's "Look up restaurant nutrition" (meal_editor_screen.dart
    // _lookUp → restaurantManualLookupChoice): the sheet for OpenRouter.
    final pending = restaurantManualLookupChoice(ctx,
        settings: settings, controls: controls);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restaurantConsentSheet')), findsOneWidget);
    expect(
        find.textContaining('Brand only skips the location'), findsOneWidget);
    await tester.tap(find.byKey(const Key('restaurantConsentBrandOnly')));
    await tester.pumpAndSettle();
    expect((await pending)?.useLocation, isFalse);
    expect(settings.restaurantAssistConsentRecipient, 'openrouter');
    expect(restaurantConsentCovers(settings, _openrouter), isTrue,
        reason: 'the automatic assist is no longer paused');

    // The engine, wired to these settings the way di.dart wires it
    // (assistSettingsView), meets the next restaurant photo.
    final lookups = _Lookups();
    final source = _Source();
    final places = _Places();
    await tester.runAsync(() async {
      final root = Directory.systemTemp.createTempSync('repro_brand_only');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LocalNoBackupStore(
          root: () async => root,
          createMissingDirectory: true,
          clock: () => _engineNow);
      final dao = FakeDao();
      dao.put(Meal(
        id: 0,
        date: '2026-10-24',
        time: '12:30 PM',
        timestamp: '2026-10-24T12:30:00.000',
        source: MealSource.appWatch,
        fileId: 'asset-1',
        analysis: _bigMac(),
      ));
      final assist = MealAssist(
        dao: dao,
        lookups: lookups,
        analyzerBusy: ValueNotifier<int>(0),
        pipelineIdle: () => true,
        inUse: (_) => false,
        budget: AssistDailyBudget(prefs, clock: () => _engineNow),
        state: AssistLocalState(store, clock: () => _engineNow),
        settings: () => AssistSettingsView(
          mode: AssistMode.fromWire(settings.restaurantAssist),
          useLocation: settings.restaurantAssistLocation,
          consentAt: settings.restaurantAssistConsentAt,
          consentRecipient: settings.restaurantAssistConsentRecipient,
        ),
        inForeground: () => true,
        country: () => 'US',
        utcOffset: () => const Duration(hours: -5),
        location: PhotoLocationReader(source, enabled: true),
        places: places,
        placesStore: AssistPlacesStore(store, clock: () => _engineNow),
        clock: () => _engineNow,
      );
      try {
        await assist.sweep();
      } finally {
        assist.dispose();
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });

    expect(settings.restaurantAssistLocation, isFalse,
        reason: 'Brand only turned the location setting off');
    // What "Brand only" for OpenRouter promises: the position is not read,
    // Apple Maps is not asked, and no chain found near the photo
    // (mcdonalds) is sent to OpenRouter and Exa.
    // One expectation, so a failure shows all three at once.
    expect(
        {
          'photo positions read': source.asked,
          'Apple Maps queries': places.calls,
          'chains sent to OpenRouter': [
            for (final r in lookups.submits) r.chainKeys,
          ],
        },
        {
          'photo positions read': <String>[],
          'Apple Maps queries': 0,
          'chains sent to OpenRouter': <List<String>>[],
        },
        reason: 'Brand only for OpenRouter: no position read, Apple Maps not '
            'asked, no location-derived chain sent');
  });
}
