// Explicit permission before meal data goes to a third-party AI (App Store
// 5.1.2(i), review finding R-F1): every path that sends asks first, per
// recipient; Not now sends nothing; the camera-roll switch, a recipient
// change while it is on, and a setup link ask at the moment it matters;
// Stop sharing withdraws the consent and turns the watcher off.
import 'dart:async';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/server_transport.dart';
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

/// The one Text a consent dialog's body is.
String _dialogText(WidgetTester tester, Finder dialog) =>
    // The dialog's content: title and text scroll together now (A1), so
    // the scroll view holds both.
    (tester.widget<AlertDialog>(dialog).content! as Text).data!;

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
      // B14: a photo taken before 04:00 also carries the day before's
      // meals (remains of a late dinner); the dialog must say so.
      expect(
          t,
          contains('summary of the other meals logged that day (for a '
              'photo taken before 4 a.m., the day before too)'));
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

    // Owner decision 2026-11-13: a plain http:// server gets nothing while
    // the https switch is on, and the consent says so; with it off, the
    // consent says what is sent goes unencrypted. Transport only: the
    // wording version does not change.
    group('a server address that is not https://', () {
      setUp(() => debugRequireHttpsServerOverride = true);
      tearDown(() => debugRequireHttpsServerOverride = null);
      String server(AppLocalizations l, String url, {String plan = 'claude'}) =>
          aiConsentText(l,
              provider: 'server', serverBackend: plan, serverBaseUrl: url);

      test('switch on: says nothing is sent until it is https://', () {
        for (final url in ['http://10.0.0.7', 'HTTP://h.example:5000']) {
          expect(server(en, url), endsWith(en.serverHttpsRequiredConsentNote),
              reason: url);
          expect(server(zh, url), endsWith(zh.serverHttpsRequiredConsentNote),
              reason: url);
          expect(server(en, url), isNot(contains(en.serverHttpConsentNote)));
        }
        // After the mainland-China note, which stays.
        final glm = server(en, 'http://10.0.0.7', plan: 'glm');
        expect(glm, contains('mainland China'));
        expect(glm, endsWith(en.serverHttpsRequiredConsentNote));
        expect(en.serverHttpsRequiredConsentNote, contains('sends it nothing'));
        expect(zh.serverHttpsRequiredConsentNote, contains('不会向它发送任何内容'));
      });

      test('switch off: says it travels unencrypted', () {
        debugRequireHttpsServerOverride = false;
        expect(server(en, 'http://10.0.0.7'), endsWith(en.serverHttpConsentNote));
        expect(server(zh, 'http://10.0.0.7'), endsWith(zh.serverHttpConsentNote));
        expect(en.serverHttpConsentNote, contains('unencrypted'));
        expect(zh.serverHttpConsentNote, contains('未加密'));
      });

      test('https://, no address, and other providers: no line', () {
        for (final require in [true, false]) {
          debugRequireHttpsServerOverride = require;
          for (final t in [
            server(en, 'https://10.0.0.7'),
            server(en, ''),
            aiConsentText(en,
                provider: 'gemini',
                serverBackend: 'claude',
                serverBaseUrl: 'http://10.0.0.7'),
          ]) {
            expect(t, isNot(contains(en.serverHttpConsentNote)));
            expect(t, isNot(contains(en.serverHttpsRequiredConsentNote)));
          }
        }
      });

      testWidgets('the dialog shows it', (tester) async {
        await tester.pumpWidget(_app(Builder(
            builder: (context) => TextButton(
                onPressed: () => showAiConsentDialog(context,
                    provider: 'server',
                    serverBackend: 'claude',
                    serverBaseUrl: 'http://10.0.0.7'),
                child: const Text('go')))));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        expect(_dialogText(tester, _dialog),
            endsWith(en.serverHttpsRequiredConsentNote));
      });
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
      expect(t, contains('当天其他已记录餐食的简短摘要（凌晨 4 点前拍的照片还包括前一天的餐食）'));
      expect(t, contains('最近 7 天'));
      expect(t, contains('中国大陆'));
    });

    // U26: the camera-roll notice sits above aiConsentBody, which already
    // says the developer receives nothing.
    test('the camera-roll notice leaves the developer to the general text',
        () {
      expect(en.watcherDisclosureBody('Gemini', 2), isNot(contains('developer')));
      expect(zh.watcherDisclosureBody('Gemini', 2), isNot(contains('开发者')));
      expect(en.aiConsentBody('X'), contains('developer never receives'));
      expect(zh.aiConsentBody('X'), contains('开发者收不到'));
    });

    testWidgets('an appendix follows the text unless the caller leads with it',
        (tester) async {
      Future<void> open({required bool lead}) async {
        await tester.pumpWidget(_app(Builder(
            builder: (context) => TextButton(
                onPressed: () => showAiConsentDialog(context,
                    provider: 'gemini',
                    serverBackend: 'claude',
                    serverBaseUrl: '',
                    appendix: 'THE NOTICE',
                    leadWithAppendix: lead),
                child: const Text('ask')))));
        await tester.tap(find.text('ask'));
        await tester.pumpAndSettle();
      }

      await open(lead: false);
      expect(_dialogText(tester, _dialog), startsWith('Chopstats estimates'));
      expect(_dialogText(tester, _dialog), endsWith('\n\nTHE NOTICE'));
      await _notNow(tester);
      await open(lead: true);
      expect(_dialogText(tester, _dialog), startsWith('THE NOTICE\n\n'));
      expect(_dialogText(tester, _dialog), endsWith('at any time in Settings.'));
      await _notNow(tester);
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

  // The screens above are pumped directly. These go through the routes the
  // app really takes, with a store that was never asked: a call site that
  // stopped handing the screen the app's store (a merge resolution, say)
  // would send unasked while every test above stayed green (review run 7).
  group('the app\'s own routes ask', () {
    testWidgets('the Meals sheet: Describe a meal and Fix a meal ask, and '
        'the answer lands in the app\'s store', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final settings = _unasked();
      final executor = FakeExecutor();
      await tester.pumpWidget(CalorieTrackerApp(
          services: makeServices(settings: settings, executor: executor)));
      await tester.pumpAndSettle();

      Future<void> fromSheet(String tile) async {
        await tester.tap(find.byKey(const Key('addMealFab')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key(tile)));
        await tester.pumpAndSettle();
      }

      await fromSheet('addFromText');
      await tester.enterText(
          find.byKey(const Key('addTextField')), 'beef noodle soup');
      await tester.tap(find.byKey(const Key('addTextSend')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget, reason: 'Describe a meal');
      await _notNow(tester);
      expect(executor.describedTexts, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await fromSheet('addFixMeal');
      await tester.enterText(
          find.byKey(const Key('fixMealField')), 'the soup was 400 kcal');
      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget, reason: 'Fix a meal');
      await _notNow(tester);
      expect(executor.handledTexts, isEmpty);
      expect(settings.aiConsentWrites, isEmpty);

      await tester.tap(find.byKey(const Key('fixMealSend')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(settings.aiConsentWrites, [('gemini', true)]);
      expect(executor.handledTexts, ['the soup was 400 kcal']);
    });

    testWidgets('Settings › Photo Coverage: Log all asks first', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final library = FakePhotoLibrary()
        ..assets = [
          FakeAsset('a2', 'IMG_2.jpg', DateTime(2026, 7, 26, 9), bytesOf(2)),
        ];
      final settings = _unasked();
      final processed = <IntakePhoto>[];
      await tester.pumpWidget(_app(Scaffold(
          body: SettingsScreen(
        settings: settings,
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        photoIntake: FakeIntake(),
        requestPhotoPermission: () async => true,
        coverage: CoverageAuditor(
            library: library,
            dao: FakeDao(),
            hasher: (b) async => 'h${b.first}',
            clock: () => DateTime(2026, 7, 26, 12)),
        processPhoto: (p) async {
          processed.add(p);
          return const PhotoOutcome(PhotoOutcomeKind.saved, 'ok');
        },
      ))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('coverageCheckTile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('runCoverageCheck')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('logAllMissing')));
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      await _notNow(tester);
      expect(find.byKey(const Key('confirmBulkAction')), findsNothing);
      expect(processed, isEmpty);

      await tester.tap(find.byKey(const Key('logAllMissing')));
      await tester.pumpAndSettle();
      await _allow(tester);
      expect(settings.aiConsentWrites, [('gemini', true)]);
      expect(find.byKey(const Key('confirmBulkAction')), findsOneWidget,
          reason: 'allowed: on to the usual how-long question');
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

    // U26 (run 7): the camera-roll notice is the one thing new in this
    // dialog, and it used to come last, below the fold at large text.
    testWidgets('the camera-roll notice comes first, then the general '
        'text, and the developer is named once', (tester) async {
      final settings = _unasked()..provider = 'qwen';
      settings.apiKey = 'k';
      final intake = await pumpSettings(tester, settings);
      await tester.tap(find.byKey(const Key('watcherToggle')));
      await tester.pumpAndSettle();
      final text = _dialogText(
          tester, find.byKey(const Key('watcherDisclosureDialog')));
      expect(text, startsWith('While Watch Camera Roll is on'));
      expect(text.indexOf('Chopstats estimates calories'),
          greaterThan(text.indexOf('including ones that are not food')));
      expect(text, contains('its developer never receives any of this'));
      expect(text, isNot(contains("Nothing is sent to the app's developer")));
      expect('developer'.allMatches(text), hasLength(1));
      // Text order only: asked, and Continue saves, exactly as before.
      await tester.tap(find.byKey(const Key('watcherDisclosureContinue')));
      await tester.pumpAndSettle();
      expect(settings.aiConsentWrites, [('qwen', true)]);
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
      // U26: the notice that explains why leads the dialog.
      expect(_dialogText(tester, _dialog),
          startsWith('While Watch Camera Roll is on'));
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

  // One Not now per share (an-bugs 'PROBE consent'): a 5-photo Android
  // share answered Not now asked five times. Now the answer covers every
  // photo that arrived before it — dropped unasked, never sent — and one
  // line says how many; a share after the answer asks again.
  group('one Not now per share', () {
    test('a 5-photo share: one question, nothing passes, a later share '
        'asks again', () async {
      final settings = _unasked();
      final gate = SharedPhotoConsentGate(settings);
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed.add(p.assetId));
      final notSent = <int>[];
      var asked = 0;
      final answers = [false, true];
      // The user reads the question: the rest of the share is in by the
      // time they answer (the test answers each one).
      var reading = Completer<void>();
      Future<bool> ask() async {
        final yes = answers[asked++];
        await reading.future;
        reading = Completer<void>();
        if (yes) {
          await settings.setAiConsent('gemini', granted: true);
        } else {
          // What askSharedPhotoConsent does at the answer.
          notSent.add(gate.declineOpenQuestion());
        }
        return yes;
      }

      gate.attach(ask);
      for (var i = 1; i <= 5; i++) {
        input.add(_photo('share1-$i'));
      }
      await pumpEventQueue();
      expect(asked, 1);
      reading.complete(); // Not now
      await pumpEventQueue();
      expect(asked, 1, reason: 'one question for the whole share');
      expect(passed, isEmpty, reason: 'none of the five is sent');
      expect(notSent, [5]);

      input.add(_photo('share2-1'));
      input.add(_photo('share2-2'));
      await pumpEventQueue();
      expect(asked, 2, reason: 'a share after the answer asks again');
      reading.complete(); // Allow
      await pumpEventQueue();
      expect(passed, ['share2-1', 'share2-2']);
      gate.detach(ask);
      await sub.cancel();
      await input.close();
    });

    test('photos that arrive while the question is open are covered by its '
        'Not now', () async {
      final settings = _unasked();
      final gate = SharedPhotoConsentGate(settings);
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed.add(p.assetId));
      final open = Completer<bool>();
      var asked = 0;
      final notSent = <int>[];
      Future<bool> ask() async {
        asked++;
        if (asked > 1) return false;
        final yes = await open.future;
        if (!yes) notSent.add(gate.declineOpenQuestion());
        return yes;
      }

      gate.attach(ask);
      input.add(_photo('a'));
      await pumpEventQueue();
      expect(asked, 1);
      // Still open: two more arrive (the rest of the share, or another).
      input.add(_photo('b'));
      input.add(_photo('c'));
      await pumpEventQueue();
      open.complete(false);
      await pumpEventQueue();
      expect(asked, 1);
      expect(notSent, [3]);
      expect(passed, isEmpty);
      gate.detach(ask);
      await sub.cancel();
      await input.close();
    });

    test('a covered photo is dropped even if the recipient is allowed '
        'before its turn', () async {
      final settings = _unasked();
      final gate = SharedPhotoConsentGate(settings);
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed.add(p.assetId));
      final reading = Completer<void>();
      Future<bool> ask() async {
        await reading.future; // the user reads the question
        gate.declineOpenQuestion();
        // Allowed some other way right after the Not now (Settings).
        await settings.setAiConsent('gemini', granted: true);
        return false;
      }

      gate.attach(ask);
      input.add(_photo('x1'));
      input.add(_photo('x2'));
      await pumpEventQueue();
      reading.complete();
      await pumpEventQueue();
      expect(passed, isEmpty, reason: 'the answer for them was no');
      input.add(_photo('later'));
      await pumpEventQueue();
      expect(passed, ['later'], reason: 'allowed now, and it came after');
      gate.detach(ask);
      await sub.cancel();
      await input.close();
    });

    test('a cold-start share waits for the shell; one Not now, even with no '
        'dialog shown, covers all of it', () async {
      final settings = _unasked();
      final gate = SharedPhotoConsentGate(settings);
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed.add(p.assetId));
      for (final id in ['p1', 'p2', 'p3']) {
        input.add(_photo(id));
      }
      await pumpEventQueue();
      var asked = 0;
      // The shell answers false without a dialog (it is going away).
      Future<bool> ask() async {
        asked++;
        return false;
      }

      gate.attach(ask);
      await pumpEventQueue();
      expect(asked, 1);
      expect(passed, isEmpty);
      gate.detach(ask);
      await sub.cancel();
      await input.close();
    });

    test('Allow on a several-photo share: one question, every photo passes, '
        'in order', () async {
      final settings = _unasked();
      final gate = SharedPhotoConsentGate(settings);
      final input = StreamController<IntakePhoto>();
      final passed = <String>[];
      final sub = gate.gate(input.stream).listen((p) => passed.add(p.assetId));
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        await settings.setAiConsent('gemini', granted: true);
        return true;
      }

      gate.attach(ask);
      for (final id in ['a1', 'a2', 'a3', 'a4']) {
        input.add(_photo(id));
      }
      await pumpEventQueue();
      expect(asked, 1);
      expect(passed, ['a1', 'a2', 'a3', 'a4']);
      gate.detach(ask);
      await sub.cancel();
      await input.close();
    });

    for (final (locale, line) in [
      (const Locale('en'),
          '5 shared photos were not analyzed — nothing was sent.'),
      (const Locale('zh'), '5 张分享的照片没有分析 — 没有发送任何内容。'),
    ]) {
      testWidgets('the app shell: one dialog for a 5-photo share, one line '
          'with the count (${locale.languageCode})', (tester) async {
        final settings = _unasked();
        final gate = SharedPhotoConsentGate(settings);
        final input = StreamController<IntakePhoto>();
        final passed = <String>[];
        final sub =
            gate.gate(input.stream).listen((p) => passed.add(p.assetId));
        final services = UiServices(
          dao: FakeDao(),
          analyzer: FakeAnalyzer(),
          executor: FakeExecutor(),
          settings: settings,
          picker: FakePicker(),
          requestPhotoPermission: () async => true,
          sharedPhotoConsent: gate,
        );
        await tester.pumpWidget(
            _app(HomeShell(services: services), locale: locale));
        await tester.pumpAndSettle();

        for (var i = 1; i <= 5; i++) {
          input.add(_photo('s$i'));
        }
        await tester.pumpAndSettle();
        expect(_dialog, findsOneWidget);
        await _notNow(tester);
        expect(_dialog, findsNothing, reason: 'not asked again for s2..s5');
        expect(passed, isEmpty);
        expect(find.text(line), findsOneWidget);

        input.add(_photo('next'));
        await tester.pumpAndSettle();
        expect(_dialog, findsOneWidget, reason: 'a later share asks again');
        await _allow(tester);
        expect(passed, ['next']);
        unawaited(sub.cancel());
      });
    }
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
      setupLinks: links.stream,
    );
    await tester.pumpWidget(_app(HomeShell(services: services)));
    links.add(Uri.parse('bitewise://setup?server=https%3A%2F%2F10.0.0.7'
        '&key=k1234567890abcdef&backend=doubao'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ByteDance Volcengine (Doubao)'),
        findsOneWidget);
    expect(find.textContaining('meal descriptions and recent meals'),
        findsOneWidget);
    // This confirmation is the consent: it says where the plan's company
    // processes the data, as the consent dialog does (PRIVACY.md).
    expect(find.textContaining('mainland China'), findsOneWidget);
    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.aiConsentWrites, [('server:doubao', true)]);
    expect(settings.provider, 'server');
    await links.close();
  });

  Future<(FakeSettings, StreamController<Uri>)> pumpSetupLink(
      WidgetTester tester, String backend,
      {Locale? locale}) async {
    final settings = _unasked();
    final links = StreamController<Uri>.broadcast();
    final services = UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      setupLinks: links.stream,
    );
    await tester
        .pumpWidget(_app(HomeShell(services: services), locale: locale));
    links.add(Uri.parse('bitewise://setup?server=https%3A%2F%2F10.0.0.7'
        '&key=k1234567890abcdef&backend=$backend'));
    await tester.pumpAndSettle();
    return (settings, links);
  }

  testWidgets('a GLM-plan setup link says, in Chinese, that the data is '
      'processed in mainland China', (tester) async {
    final (settings, links) =
        await pumpSetupLink(tester, 'glm', locale: const Locale('zh'));
    expect(find.textContaining('中国大陆'), findsOneWidget);
    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.aiConsentWrites, [('server:glm', true)]);
    await links.close();
  });

  testWidgets('a Claude-plan setup link has no mainland-China note',
      (tester) async {
    final (settings, links) = await pumpSetupLink(tester, 'claude');
    expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
    expect(find.textContaining('mainland China'), findsNothing);
    await tester.tap(find.byKey(const Key('setupLinkConfirm')));
    await tester.pumpAndSettle();
    expect(settings.aiConsentWrites, [('server:claude', true)]);
    await links.close();
  });
}

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}
