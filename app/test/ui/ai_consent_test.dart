// Explicit permission before meal data goes to a third-party AI (App Store
// 5.1.2(i), review finding R-F1): every path that sends asks first, per
// recipient; Not now sends nothing; the camera-roll switch, a recipient
// change while it is on, and a setup link ask at the moment it matters;
// Stop sharing withdraws the consent and turns the watcher off.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/l10n/app_localizations_en.dart';
import 'package:calorie_tracker/l10n/app_localizations_zh.dart';
import 'package:calorie_tracker/services/photo/coverage.dart';
import 'package:calorie_tracker/ui/ai_consent.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/add_flow.dart';
import 'package:calorie_tracker/ui/screens/coverage_screen.dart';
import 'package:calorie_tracker/ui/screens/diagnostics_screen.dart';
import 'package:calorie_tracker/ui/screens/fix_meal_screen.dart';
import 'package:calorie_tracker/ui/screens/leftover_flow.dart';
import 'package:calorie_tracker/ui/screens/settings/api_key_page.dart';
import 'package:calorie_tracker/ui/screens/settings/provider_page.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../photo/watcher_test.dart' show FakeAsset, FakePhotoLibrary, bytesOf;
import 'fakes.dart';

/// A store that has never been asked: no recipient allowed.
FakeSettings _unasked({String apiKey = 'k', bool watcherEnabled = false}) =>
    FakeSettings(apiKey: apiKey, watcherEnabled: watcherEnabled)
      ..aiConsent = {};

IntakePhoto _photo(String id) => IntakePhoto(
    Uint8List.fromList(List.filled(16, 3)), id, '$id.jpg',
    capturedAt: DateTime(2026, 7, 30, 12));

Finder get _dialog => find.byKey(const Key('aiConsentDialog'));

Future<void> _notNow(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('aiConsentNotNow')));
  await tester.pumpAndSettle();
}

Future<void> _allow(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('aiConsentAllow')));
  await tester.pumpAndSettle();
}

Widget _app(Widget home, {Locale? locale}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the consent text', () {
    final en = AppLocalizationsEn();
    final zh = AppLocalizationsZh();

    test('names the company and everything that goes with a photo or a '
        'typed request', () {
      final t = aiConsentText(en,
          provider: 'gemini', serverBackend: 'claude', serverBaseUrl: '');
      expect(t, contains('Google (Gemini)'));
      expect(t, contains('dietary profile'));
      expect(t, contains('summary of the other meals logged that day'));
      expect(t, contains('last 7 days'));
      expect(t, contains('leftover photos'));
      expect(t, contains('never receives'));
      expect(t, isNot(contains('mainland China')));
    });

    test('a server plan names the server AND the company behind it', () {
      final t = aiConsentText(en,
          provider: 'server',
          serverBackend: 'claude',
          serverBaseUrl: 'https://calories.example.test/');
      expect(t, contains('your own server (calories.example.test)'));
      expect(t, contains('Anthropic (Claude)'));
      final glm = aiConsentText(en,
          provider: 'server', serverBackend: 'glm', serverBaseUrl: '');
      expect(glm, contains('your own server, which passes it to '
          'Zhipu AI (GLM)'));
      expect(glm, contains('mainland China'));
    });

    test('mainland-China providers say where the data is processed; '
        'OpenRouter says it passes data on', () {
      for (final p in ['deepseek', 'qwen', 'doubao', 'glm']) {
        expect(
            aiConsentText(en,
                provider: p, serverBackend: 'claude', serverBaseUrl: ''),
            contains('servers in mainland China'),
            reason: p);
      }
      for (final p in ['openai', 'anthropic', 'xai', 'openrouter']) {
        expect(
            aiConsentText(en,
                provider: p, serverBackend: 'claude', serverBaseUrl: ''),
            isNot(contains('mainland China')),
            reason: p);
      }
      expect(
          aiConsentText(en,
              provider: 'openrouter',
              serverBackend: 'claude',
              serverBaseUrl: ''),
          contains('maker of the model you picked'));
    });

    test('Chinese', () {
      final t = aiConsentText(zh,
          provider: 'qwen', serverBackend: 'claude', serverBaseUrl: '');
      expect(t, contains('阿里云（通义千问）'));
      expect(t, contains('饮食档案'));
      expect(t, contains('最近 7 天'));
      expect(t, contains('中国大陆'));
    });
  });

  group('foreground sends ask first', () {
    testWidgets('picking a photo: Not now reads no bytes and sends nothing; '
        'Allow is saved and asked once', (tester) async {
      final settings = _unasked();
      final picker = FakePicker()..photos = [_photo('a0')];
      final processed = <IntakePhoto>[];
      final services = makeServices(
          settings: settings,
          picker: picker,
          processPhoto: (p) async {
            processed.add(p);
            return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
          });
      await tester.pumpWidget(_app(AddPhotoScreen(services: services)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      expect(find.textContaining('Google (Gemini)'), findsOneWidget);
      await _notNow(tester);
      expect(picker.loadedOriginals, isEmpty,
          reason: 'not even the original is read');
      expect(processed, isEmpty);
      expect(find.text('Nothing was sent.'), findsOneWidget);
      expect(settings.hasAiConsent('gemini'), isFalse);

      await tester.tap(find.byKey(const Key('recentPhoto0')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(settings.aiConsentWrites, [('gemini', true)]);
      expect(processed, hasLength(1));
    });

    testWidgets('an allowed recipient is not asked again, and without a key '
        'there is nothing to ask about', (tester) async {
      for (final settings in [
        FakeSettings(apiKey: 'k'), // allowed
        _unasked(apiKey: ''), // nothing can be sent
      ]) {
        final picker = FakePicker()..photos = [_photo('a0')];
        var processed = 0;
        await tester.pumpWidget(_app(AddPhotoScreen(
            services: makeServices(
                settings: settings,
                picker: picker,
                processPhoto: (p) async {
                  processed++;
                  return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
                }))));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('recentPhoto0')));
        await tester.pumpAndSettle();
        expect(_dialog, findsNothing);
        expect(processed, 1);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Describe a meal: Not now sends no text', (tester) async {
      final settings = _unasked();
      final executor = FakeExecutor();
      await tester.pumpWidget(_app(AddTextScreen(
          executor: executor, dao: FakeDao(), settings: settings)));
      await tester.enterText(
          find.byKey(const Key('addTextField')), 'beef noodle soup');
      await tester.tap(find.byKey(const Key('addTextSend')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      await _notNow(tester);
      expect(executor.describedTexts, isEmpty);

      await tester.tap(find.byKey(const Key('addTextSend')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(executor.describedTexts, ['beef noodle soup']);
      expect(settings.hasAiConsent('gemini'), isTrue);
    });

    testWidgets('Fix a meal: Not now sends no request', (tester) async {
      final settings = _unasked()..provider = 'deepseek';
      settings.apiKey = 'k';
      final executor = FakeExecutor();
      await tester.pumpWidget(
          _app(FixMealScreen(executor: executor, settings: settings)));
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'the soup was 400 kcal');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      expect(find.textContaining('mainland China'), findsOneWidget);
      await _notNow(tester);
      expect(executor.handledTexts, isEmpty);

      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(executor.handledTexts, ['the soup was 400 kcal']);
      expect(settings.aiConsentWrites, [('deepseek', true)]);
    });

    testWidgets('Leftovers: Not now reads no photo and sends nothing',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final settings = _unasked();
      final dao = FakeDao()
        ..seed(Meal(
          id: 1,
          date: _today(),
          time: '12:30',
          timestamp: '${_today()}T12:30:00',
          source: 'app_watch',
          imageHash: 'h',
          analysis: const {
            'is_food': true,
            'meal_description': 'Tray',
            'total_calories': 900,
          },
        ));
      final analyzer = FakeAnalyzer();
      final picker = FakePicker()..photos = [_photo('lp1')];
      await tester.pumpWidget(_app(LeftoverScreen(
          services: makeServices(
              settings: settings,
              dao: dao,
              analyzer: analyzer,
              picker: picker))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('leftoverMeal-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('leftoverPhoto-lp1')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      await _notNow(tester);
      expect(picker.loadedOriginals, isEmpty);
      expect(analyzer.lastLeftoverCompact, isNull);
    });

    testWidgets('Test This Provider: Not now does not open the test',
        (tester) async {
      final settings = _unasked();
      await tester.pumpWidget(_app(ProviderSettingsPage(
          settings: settings, analyzer: FakeAnalyzer())));
      await tester.tap(find.byKey(const Key('testProviderButton')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      await _notNow(tester);
      expect(find.byType(DiagnosticsScreen), findsNothing);

      await tester.tap(find.byKey(const Key('testProviderButton')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(find.byType(DiagnosticsScreen), findsOneWidget);
    });

    testWidgets('Photo Coverage Log all: Not now sends nothing',
        (tester) async {
      final library = FakePhotoLibrary()
        ..assets = [
          FakeAsset('a2', 'IMG_2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
        ];
      final settings = _unasked();
      final processed = <IntakePhoto>[];
      await tester.pumpWidget(_app(CoverageScreen(
        auditor: CoverageAuditor(
            library: library,
            dao: FakeDao(),
            hasher: (b) async => 'h${b.first}',
            clock: () => DateTime(2026, 7, 26, 12)),
        processPhoto: (p) async {
          processed.add(p);
          return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
        },
        requestPhotoPermission: () async => true,
        initialLookbackDays: 2,
        ensureConsent: (ctx) => ensureAiConsent(ctx, settings),
        library: library,
      )));
      await tester.tap(find.byKey(const Key('runCoverageCheck')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('logAllMissing')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      await _notNow(tester);
      expect(find.byKey(const Key('confirmBulkAction')), findsNothing);
      expect(processed, isEmpty);
    });
  });

  group('the camera-roll switch', () {
    Future<FakeIntake> pumpSettings(
        WidgetTester tester, FakeSettings settings) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final intake = FakeIntake();
      await tester.pumpWidget(_app(Scaffold(
          body: SettingsScreen(
        settings: settings,
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        photoIntake: intake,
        requestPhotoPermission: () async => true,
      ))));
      await tester.pumpAndSettle();
      return intake;
    }

    testWidgets('a seen notice is not consent for a NEW recipient: the '
        'switch asks, naming it, and Continue saves the consent',
        (tester) async {
      final settings = _unasked()
        ..watcherDisclosureSeen = true
        ..provider = 'qwen';
      settings.apiKey = 'k';
      final intake = await pumpSettings(tester, settings);
      await tester.tap(find.byKey(const Key('watcherToggle')));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('watcherDisclosureDialog'));
      expect(dialog, findsOneWidget);
      expect(
          find.descendant(
              of: dialog, matching: find.textContaining('Alibaba Cloud (Qwen)')),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('watcherDisclosureCancel')));
      await tester.pumpAndSettle();
      expect(intake.started, isFalse);
      expect(settings.hasAiConsent('qwen'), isFalse);

      await tester.tap(find.byKey(const Key('watcherToggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watcherDisclosureContinue')));
      await tester.pumpAndSettle();
      expect(settings.hasAiConsent('qwen'), isTrue);
      expect(settings.watcherEnabled, isTrue);
      expect(intake.started, isTrue);
    });

    testWidgets('Stop sharing withdraws the consent and turns the watcher '
        'off; the row leaves with it', (tester) async {
      final settings = FakeSettings(
          apiKey: 'k', watcherEnabled: true, watcherDisclosureSeen: true);
      final intake = await pumpSettings(tester, settings);
      intake.started = true;
      final row = find.byKey(const Key('aiStopSharingRow'));
      expect(row, findsOneWidget);
      expect(find.text('Stop Sharing with Gemini'), findsOneWidget);

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('aiStopSharingDialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('aiStopSharingConfirm')));
      await tester.pumpAndSettle();

      expect(settings.hasAiConsent('gemini'), isFalse);
      expect(settings.hasAiConsent('openai'), isTrue,
          reason: 'only the current recipient is withdrawn');
      expect(settings.watcherEnabled, isFalse);
      expect(intake.started, isFalse);
      expect(
          tester.widget<Switch>(find.byKey(const Key('watcherToggle'))).value,
          isFalse);
      expect(row, findsNothing);
      expect(find.text('Stopped — nothing more is sent to Gemini.'),
          findsOneWidget);
    });

    testWidgets('no Stop sharing row before anything was allowed',
        (tester) async {
      await pumpSettings(tester, _unasked());
      expect(find.byKey(const Key('aiStopSharingRow')), findsNothing);
    });
  });

  group('a recipient change while the watcher is on', () {
    testWidgets('API key provider: asked at the switch; Not now keeps the '
        'previous provider', (tester) async {
      final settings = _unasked(watcherEnabled: true)..aiConsent = {'gemini'};
      await tester.pumpWidget(_app(ApiKeyProviderPage(settings: settings)));
      await tester.tap(find.byKey(const Key('providerChoice-openai')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      expect(find.textContaining('OpenAI'), findsWidgets);
      expect(find.textContaining('Watch Camera Roll'), findsOneWidget,
          reason: 'the automatic scan is why it is asked now');
      await _notNow(tester);
      expect(settings.provider, 'gemini');

      await tester.tap(find.byKey(const Key('providerChoice-openai')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(settings.provider, 'openai');
      expect(settings.hasAiConsent('openai'), isTrue);
    });

    testWidgets('with the watcher OFF the switch just happens (the next '
        'send asks)', (tester) async {
      final settings = _unasked();
      await tester.pumpWidget(_app(ApiKeyProviderPage(settings: settings)));
      await tester.tap(find.byKey(const Key('providerChoice-openai')));
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(settings.provider, 'openai');
      expect(settings.aiConsentWrites, isEmpty);
    });

    testWidgets('a server PLAN switch is a new recipient', (tester) async {
      final settings = _unasked(watcherEnabled: true)
        ..provider = 'server'
        ..serverBackend = 'claude'
        ..aiConsent = {'server:claude'};
      settings.apiKey = 'up';
      await tester
          .pumpWidget(_app(SubscriptionProviderPage(settings: settings)));
      await tester.tap(find.byKey(const Key('planChoice-glm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Zhipu AI (GLM)'), findsOneWidget);
      await _notNow(tester);
      expect(settings.serverBackend, 'claude');
      expect(settings.provider, 'server');

      await tester.tap(find.byKey(const Key('planChoice-glm')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(settings.serverBackend, 'glm');
      expect(settings.hasAiConsent('server:glm'), isTrue);
    });
  });

  group('the share sheet', () {
    test('an allowed recipient passes straight through, in order', () async {
      final gate = SharedPhotoConsentGate(FakeSettings(apiKey: 'k'));
      final out = await gate
          .gate(Stream.fromIterable([_photo('s1'), _photo('s2')]))
          .map((p) => p.assetId)
          .toList();
      expect(out, ['s1', 's2']);
    });

    test('without a key nothing can be sent, so nothing is asked', () async {
      final gate = SharedPhotoConsentGate(_unasked(apiKey: ''));
      final out = await gate.gate(Stream.value(_photo('s1'))).toList();
      expect(out, hasLength(1));
    });

    test('a photo waits for the shell, then Not now drops it and Allow '
        'passes the next one', () async {
      final settings = _unasked();
      final gate = SharedPhotoConsentGate(settings);
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed.add(p.assetId));
      input.add(_photo('cold-start'));
      await pumpEventQueue();
      expect(passed, isEmpty, reason: 'held until a question can be asked');

      final answers = [false, true];
      var asked = 0;
      Future<bool> ask() async {
        final yes = answers[asked++];
        if (yes) await settings.setAiConsent('gemini', granted: true);
        return yes;
      }

      gate.attach(ask);
      await pumpEventQueue();
      expect(asked, 1);
      expect(passed, isEmpty, reason: 'Not now drops the photo');

      input.add(_photo('second'));
      await pumpEventQueue();
      expect(asked, 2);
      expect(passed, ['second']);

      input.add(_photo('third'));
      await pumpEventQueue();
      expect(asked, 2, reason: 'allowed now: no question');
      expect(passed, ['second', 'third']);
      gate.detach(ask);
      await sub.cancel();
      await input.close();
    });

    testWidgets('the app shell asks, and Not now says the photo was not '
        'analyzed', (tester) async {
      final settings = _unasked();
      final gate = SharedPhotoConsentGate(settings);
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed.add(p.assetId));
      final services = UiServices(
        dao: FakeDao(),
        analyzer: FakeAnalyzer(),
        executor: FakeExecutor(),
        settings: settings,
        picker: FakePicker(),
        requestPhotoPermission: () async => true,
        reports: FakeReports(),
        sharedPhotoConsent: gate,
      );
      await tester.pumpWidget(_app(HomeShell(services: services)));
      await tester.pumpAndSettle();

      input.add(_photo('shared'));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      await _notNow(tester);
      expect(passed, isEmpty);
      expect(
          find.text('The shared photo was not analyzed — nothing was sent.'),
          findsOneWidget);

      input.add(_photo('again'));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(passed, ['again']);
      expect(settings.hasAiConsent('gemini'), isTrue);
      // Not awaited: a cancel future awaited inside the fake-async zone
      // never lets the test finish.
      unawaited(sub.cancel());
    });
  });

  testWidgets('a setup link names the plan\'s company, and confirming is '
      'the consent for it', (tester) async {
    final settings = _unasked();
    final links = StreamController<Uri>.broadcast();
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      reports: FakeReports(),
      setupLinks: links.stream,
    );
    await tester.pumpWidget(_app(HomeShell(services: services)));
    links.add(Uri.parse('bitewise://setup?server=http%3A%2F%2F10.0.0.7'
        '&key=k1234567890abcdef&backend=doubao'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ByteDance Volcengine (Doubao)'),
        findsOneWidget);
    expect(find.textContaining('meal descriptions and recent meals'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.aiConsentWrites, [('server:doubao', true)]);
    expect(settings.provider, 'server');
    await links.close();
  });
}

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}
