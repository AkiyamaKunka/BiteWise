// Today's Garmin energy-balance line (2026-08-02, spec §9): the active
// burn arrives via the user's OWN server and is strictly cosmetic — it
// must never block, error, or mislead the screen.
import 'dart:convert';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/server_transport.dart';
import 'package:calorie_tracker/services/garmin_client.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/format.dart' show isoDate;
import 'package:calorie_tracker/ui/l10n.dart';
import 'package:calorie_tracker/ui/screens/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

/// A food meal dated TODAY (computed — a pinned date is a time bomb).
Meal _todayMeal(num kcal) => Meal(
      id: 1,
      date: isoDate(DateTime.now()),
      time: '12:00 PM',
      timestamp: '${isoDate(DateTime.now())}T12:00:00',
      source: 'app_photo',
      imageHash: '',
      analysis: {
        'is_food': true,
        'total_calories': kcal,
        'total_protein_g': 20,
        'total_carbs_g': 50,
        'total_fat_g': 10,
        'meal_description': 'Lunch',
      },
    );

GarminDailyFetch _burn(double kcal) => (date) async => GarminDaily(
    activeCalories: kcal, steps: 8000, distanceM: 6200, activityCount: 1);

void main() {
  Future<void> pump(WidgetTester tester,
      {GarminDailyFetch? garmin, num? eatenKcal, Locale? locale}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    if (eatenKcal != null) dao.put(_todayMeal(eatenKcal));
    await tester.pumpWidget(MaterialApp(
        locale: locale,
        // Bare MaterialApp = the suite's English fallback; a zh pump
        // installs the real delegates like day_report_test does.
        localizationsDelegates:
            locale == null ? null : AppLocalizations.localizationsDelegates,
        supportedLocales: locale == null
            ? const [Locale('en', 'US')]
            : AppLocalizations.supportedLocales,
        home: Scaffold(
            body: TodayScreen(
                key: UniqueKey(),
                dao: dao,
                garminDaily: garmin))));
    await tester.pumpAndSettle();
  }

  String burnLine(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('garminBurnLine'))).data!;

  testWidgets('a burn > 0 on a fed day draws the line with the net math',
      (tester) async {
    await pump(tester, garmin: _burn(512), eatenKcal: 1200);
    final line = burnLine(tester);
    expect(line, contains('512'));
    expect(line, contains('Garmin'));
    expect(line, contains('net'),
        reason: 'intake minus burn is the point of the line');
    expect(line, contains('688'), reason: '1,200 eaten − 512 burned');
  });

  testWidgets('a burn above the intake states the burn ALONE — a negative '
      '"net intake" is a countdown in disguise (testing loop 2026-10-07)',
      (tester) async {
    // Empty day: the old line read "net ~-897 kcal".
    await pump(tester, garmin: _burn(897));
    var line = burnLine(tester);
    expect(line, contains('897'));
    expect(line, contains('Garmin'));
    expect(line, isNot(contains('net')));
    expect(line, isNot(contains('-')));
    expect(line, isNot(contains('−')));
    expect(find.byKey(const Key('garminIdleLine')), findsNothing,
        reason: 'there WAS activity — the idle line would be a lie');

    // Light day: 300 eaten, 897 burned — still no negative figure.
    await pump(tester, garmin: _burn(897), eatenKcal: 300);
    line = burnLine(tester);
    expect(line, contains('897'));
    expect(line, isNot(contains('net')));
    expect(line, isNot(contains('-')));
    expect(line, isNot(contains('597')),
        reason: 'the magnitude of a negative net is not an intake either');

    // Break-even is dropped with the negatives: no "net ~0 kcal" noise.
    await pump(tester, garmin: _burn(500), eatenKcal: 500);
    expect(burnLine(tester), isNot(contains('net')));

    // One kcal over break-even is a real (tiny) net intake again.
    await pump(tester, garmin: _burn(500), eatenKcal: 501);
    expect(burnLine(tester), contains('net ~1 kcal'));
  });

  testWidgets('zh: 净摄入 is never negative either', (tester) async {
    await pump(tester,
        garmin: _burn(897), eatenKcal: 300, locale: const Locale('zh'));
    final line = burnLine(tester);
    expect(line, contains('活动消耗：~897 千卡（Garmin）'));
    expect(line, isNot(contains('净摄入')));
    expect(line, isNot(contains('-')));

    await pump(tester,
        garmin: _burn(512), eatenKcal: 1200, locale: const Locale('zh'));
    expect(burnLine(tester), contains('净摄入 ~688 千卡'));
  });

  testWidgets('no fetch, no line', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('garminBurnLine')), findsNothing);
  });

  testWidgets('an unavailable day (null) draws nothing', (tester) async {
    await pump(tester, garmin: (date) async => null);
    expect(find.byKey(const Key('garminBurnLine')), findsNothing);
    expect(find.byKey(const Key('garminIdleLine')), findsNothing,
        reason: 'not connected must never claim to be connected');
  });

  testWidgets('a zero-burn day says CONNECTED instead of drawing a '
      '"~0 kcal" line — silence read as "Garmin is broken" (user report '
      '2026-08-06)', (tester) async {
    await pump(tester,
        garmin: (date) async => const GarminDaily(
            activeCalories: 0, steps: 0, distanceM: 0, activityCount: 0));
    expect(find.byKey(const Key('garminBurnLine')), findsNothing,
        reason: 'no fake arithmetic on a zero day');
    expect(find.byKey(const Key('garminIdleLine')), findsOneWidget,
        reason: 'but the connection itself must be visible');
  });

  testWidgets('a fetch that throws leaves the screen intact', (tester) async {
    await pump(tester,
        garmin: (date) async => throw Exception('server down'));
    expect(find.byKey(const Key('ringCenterValue')), findsOneWidget);
    expect(find.byKey(const Key('garminBurnLine')), findsNothing);
  });

  // Settings › Stop Sharing with your own server withdraws its consent and
  // says nothing more is sent there — and every Today reload still POSTed
  // the date with the upload key to the server (review 171, C13). The fetch
  // asks the server only while the server, on its current plan, is a
  // recipient the user allows.
  group('the fetch from your own server', () {
    late List<http.Request> requests;
    late AppSettings s;
    http.Client server() => MockClient((req) async {
          requests.add(req);
          return http.Response(
              jsonEncode({
                'available': true,
                'active_calories': 512,
                'steps': 8000,
                'distance_m': 6200,
                'activity_count': 1,
              }),
              200);
        });

    Future<AppSettings> allowedServer() async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await app.setProvider(AiProvider.server);
      await app.setServerBaseUrl('https://10.0.0.7');
      await app.setServerApiKey('upload-key');
      await app.setAiConsent('server:claude', granted: true);
      return app;
    }

    setUp(() async {
      requests = [];
      s = await allowedServer();
    });

    test('asks for the day while the server is allowed', () async {
      final daily =
          await makeGarminDailyFetch(s, client: server())('2026-11-13');
      expect(daily?.activeCalories, 512);
      final req = requests.single;
      expect(req.url.toString(), 'https://10.0.0.7/api/garmin_daily');
      expect(req.headers['X-API-Key'], 'upload-key');
      expect(jsonDecode(req.body), {'date': '2026-11-13'});
    });

    // Owner decision 2026-11-13: a plain http:// address gets nothing
    // while the https switch is on (the request carries the upload key).
    test('asks nothing of a plain http:// address (https switch on)',
        () async {
      debugRequireHttpsServerOverride = true;
      addTearDown(() => debugRequireHttpsServerOverride = null);
      for (final url in ['http://10.0.0.7', 'HTTP://h.example:5000', 'h.example']) {
        await s.setServerBaseUrl(url);
        expect(await makeGarminDailyFetch(s, client: server())('2026-11-13'),
            isNull,
            reason: url);
      }
      expect(requests, isEmpty);
    });

    test('asks a plain http:// address with the https switch off', () async {
      debugRequireHttpsServerOverride = false;
      addTearDown(() => debugRequireHttpsServerOverride = null);
      await s.setServerBaseUrl('http://10.0.0.7');
      expect(await makeGarminDailyFetch(s, client: server())('2026-11-13'),
          isNotNull);
      expect(requests.single.url.toString(),
          'http://10.0.0.7/api/garmin_daily');
    });

    test('asks nothing once sharing with the server is stopped', () async {
      final fetch = makeGarminDailyFetch(s, client: server());
      // What Settings › Stop Sharing does: the current route is withdrawn.
      await s.setAiConsent(s.activeAiConsentRoute, granted: false);
      expect(await fetch('2026-11-13'), isNull);
      // Nor after a switch to another provider.
      await s.setProvider(AiProvider.gemini);
      expect(await fetch('2026-11-13'), isNull);
      expect(requests, isEmpty);
    });

    test('nor while the plan it would serve is not allowed', () async {
      // Switched to GLM with Watch Camera Roll off: nothing asked yet.
      await s.setServerBackend('glm');
      expect(await makeGarminDailyFetch(s, client: server())('2026-11-13'),
          isNull);
      expect(requests, isEmpty);
    });

    test('another provider in use with the server still allowed: asked as '
        'before (PRIVACY.md: while the address is set)', () async {
      await s.setProvider(AiProvider.gemini);
      expect(await makeGarminDailyFetch(s, client: server())('2026-11-13'),
          isNotNull);
      expect(requests, hasLength(1));
    });

    testWidgets('Today: a reload after Stop Sharing sends nothing and drops '
        'the line', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      late AppSettings app;
      await tester.runAsync(() async => app = await allowedServer());
      await tester.pumpWidget(MaterialApp(
          supportedLocales: const [Locale('en', 'US')],
          home: Scaffold(
              body: TodayScreen(
                  dao: FakeDao(),
                  garminDaily: makeGarminDailyFetch(app, client: server())))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('garminBurnLine')), findsOneWidget);
      expect(requests, hasLength(1));

      await tester.runAsync(
          () => app.setAiConsent(app.activeAiConsentRoute, granted: false));
      await tester.state<TodayScreenState>(find.byType(TodayScreen)).reload();
      await tester.pumpAndSettle();
      expect(requests, hasLength(1), reason: 'no date, no upload key');
      expect(find.byKey(const Key('garminBurnLine')), findsNothing);
    });
  });

  group('parseGarminDailyBody', () {
    test('maps a full reply', () {
      final d = parseGarminDailyBody(200,
          '{"available":true,"active_calories":512.5,"steps":8000,'
          '"distance_m":6200,"activity_count":2}')!;
      expect(d.activeCalories, 512.5);
      expect(d.steps, 8000);
      expect(d.activityCount, 2);
    });

    test('anything not 200+available is null, never a throw', () {
      expect(parseGarminDailyBody(200, '{"available":false}'), isNull);
      expect(parseGarminDailyBody(401, '{"error":"Unauthorized"}'), isNull);
      expect(parseGarminDailyBody(200, 'not json at all'), isNull);
      expect(parseGarminDailyBody(200, '[]'), isNull);
      expect(
          parseGarminDailyBody(
              200, '{"available":true,"active_calories":"junk"}'),
          isNotNull,
          reason: 'junk numerics coerce to 0, the line simply stays hidden');
    });
  });
}
