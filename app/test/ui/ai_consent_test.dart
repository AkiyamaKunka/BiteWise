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

IntakePhoto _photo(String id, {int? delivery}) => IntakePhoto(
    Uint8List.fromList(List.filled(16, 3)), id, '$id.jpg',
    capturedAt: DateTime(2026, 7, 30, 12), shareDelivery: delivery);

/// The share intake's side of a Not now (ShareDeliveries), scripted.
class _Deliveries implements ShareDeliveries {
  final sizes = <int, int>{};
  final unreadable = <int, int>{};
  final declined = <int>{};
  int _arrived = 0;

  /// A batch event of [n] copies arrives; its number.
  int arrive(int n) {
    sizes[++_arrived] = n;
    return _arrived;
  }

  @override
  int get arrivedDelivery => _arrived;

  @override
  int photoCountOf(int delivery) =>
      (sizes[delivery] ?? 0) - (unreadable[delivery] ?? 0);

  @override
  void declineDeliveries(Set<int> deliveries) => declined.addAll(deliveries);

  /// Start-up batches of copies left unread.
  final alone = <int>{};

  @override
  bool asksAlone(int delivery) => alone.contains(delivery);
}

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
      // The text is still typed: back asks before it drops it (ui lane).
      await tester.tap(find.byKey(const Key('discardChangesDiscard')));
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
  // share answered Not now asked five times. The share intake numbers each
  // share as its batch event arrives (IntakePhoto.shareDelivery); a Not now
  // covers every delivery that had arrived by the answer — dropped unasked,
  // never sent, their unread copies deleted — and one line says how many.
  // A share that arrives after the answer asks again. (share_intake_test
  // runs the same through the real intake: unread copies stay unread.)
  group('one Not now per share', () {
    late _Deliveries deliveries;
    late SharedPhotoConsentGate gate;
    late StreamController<IntakePhoto> input;
    late List<String> passed;
    late StreamSubscription<IntakePhoto> sub;
    late FakeSettings settings;

    setUp(() {
      settings = _unasked();
      deliveries = _Deliveries();
      gate = SharedPhotoConsentGate(settings);
      input = StreamController<IntakePhoto>();
      passed = [];
      sub = gate
          .gate(input.stream, deliveries: deliveries)
          .listen((p) => passed.add(p.assetId));
    });
    tearDown(() async {
      await sub.cancel();
      await input.close();
    });

    /// A share of [n] photos arrives (its batch event), numbered next.
    List<IntakePhoto> share(String name, int n) {
      final d = deliveries.arrive(n);
      return [for (var i = 1; i <= n; i++) _photo('$name-$i', delivery: d)];
    }

    test('a 5-photo share: one question, nothing passes, the rest is '
        'declined at the intake; a later share asks again', () async {
      final notSent = <int>[];
      var asked = 0;
      final answers = [false, true];
      Future<bool> ask() async {
        final yes = answers[asked++];
        if (yes) {
          await settings.setAiConsent('gemini', granted: true);
        } else {
          notSent.add(gate.declineOpenQuestion());
        }
        return yes;
      }

      gate.attach(ask);
      final first = share('share1', 5);
      // The intake hands on one photo at a time; the rest wait unread.
      input.add(first.first);
      await pumpEventQueue();
      expect(asked, 1);
      expect(notSent, [5], reason: 'all five, four never read');
      expect(deliveries.declined, {1});
      expect(passed, isEmpty);
      // One read ahead before the answer is dropped, not asked.
      input.add(first[1]);
      await pumpEventQueue();
      expect(asked, 1);
      expect(passed, isEmpty);

      final second = share('share2', 2);
      second.forEach(input.add);
      await pumpEventQueue();
      expect(asked, 2, reason: 'a share after the answer asks again');
      expect(passed, ['share2-1', 'share2-2']);
      gate.detach(ask);
    });

    test('a share that arrives while the question is open is covered by its '
        'Not now, and counted', () async {
      final open = Completer<bool>();
      final notSent = <int>[];
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        final yes = await open.future;
        if (!yes) notSent.add(gate.declineOpenQuestion());
        return yes;
      }

      gate.attach(ask);
      final a = share('a', 3);
      input.add(a.first);
      await pumpEventQueue();
      expect(asked, 1);
      final b = share('b', 2); // shared again while asked
      open.complete(false);
      await pumpEventQueue();
      expect(notSent, [5]);
      expect(deliveries.declined, {1, 2});
      [...a.skip(1), ...b].forEach(input.add);
      await pumpEventQueue();
      expect(asked, 1);
      expect(passed, isEmpty);
      gate.detach(ask);
    });

    test("the same share's files read after the answer are covered too; "
        'only a new share asks again', () async {
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        gate.declineOpenQuestion();
        return false;
      }

      gate.attach(ask);
      final slow = share('slow', 3);
      input.add(slow[0]);
      await pumpEventQueue();
      input.add(slow[1]); // its slow files, after the answer
      input.add(slow[2]);
      await pumpEventQueue();
      expect(asked, 1);
      input.add(share('next', 1).single);
      await pumpEventQueue();
      expect(asked, 2);
      expect(passed, isEmpty);
      gate.detach(ask);
    });

    test('a covered photo is dropped even if the recipient is allowed '
        'before its turn', () async {
      Future<bool> ask() async {
        gate.declineOpenQuestion();
        // Allowed some other way right after the Not now (Settings).
        await settings.setAiConsent('gemini', granted: true);
        return false;
      }

      gate.attach(ask);
      share('x', 2).forEach(input.add);
      await pumpEventQueue();
      expect(passed, isEmpty, reason: 'the answer for them was no');
      input.add(share('later', 1).single);
      await pumpEventQueue();
      expect(passed, ['later-1'], reason: 'allowed now, and a new share');
      gate.detach(ask);
    });

    test('a cold-start share waits for the shell; one Not now covers all of '
        'it', () async {
      share('p', 3).forEach(input.add);
      await pumpEventQueue();
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        return false;
      }

      gate.attach(ask);
      await pumpEventQueue();
      expect(asked, 1);
      expect(passed, isEmpty);
      expect(deliveries.declined, {1});
      gate.detach(ask);
    });

    // Review of 46da8b74, low 3: a shell going away answers without showing
    // a dialog (null). That is no answer: nothing is declined, and the
    // photo waits for the next shell's question.
    test('no dialog shown (null) is not a Not now: nothing declined, the '
        'photo waits for the next shell', () async {
      var stale = 0;
      Future<bool?> goingAway() async {
        stale++;
        return null;
      }

      gate.attach(goingAway);
      share('w', 2).forEach(input.add);
      await pumpEventQueue();
      expect(stale, 1, reason: 'asked once, then it waits: no spinning');
      expect(deliveries.declined, isEmpty);
      expect(passed, isEmpty);

      var asked = 0;
      Future<bool> fresh() async {
        asked++;
        await settings.setAiConsent('gemini', granted: true);
        return true;
      }

      gate.detach(goingAway);
      gate.attach(fresh);
      await pumpEventQueue();
      expect(stale, 1);
      expect(asked, 1);
      expect(passed, ['w-1', 'w-2']);
      gate.detach(fresh);
    });

    // Review of 46da8b74, low 1: at a cold start the start-up batch of
    // copies left unread is numbered right after the launch share, before
    // the question opens. A Not now covers the share asked about and those
    // that arrive while it is open, not a delivery already waiting: that
    // one gets its own question.
    test('the start-up batch arriving while the question is open is not '
        'covered either', () async {
      final open = Completer<void>();
      final notSent = <int>[];
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        if (asked == 1) {
          await open.future;
          notSent.add(gate.declineOpenQuestion());
          return false;
        }
        await settings.setAiConsent('gemini', granted: true);
        return true;
      }

      gate.attach(ask);
      final launch = share('launch', 2);
      input.add(launch.first);
      await pumpEventQueue();
      final left = share('left', 3); // its sweep finished late
      deliveries.alone.add(2);
      final live = share('live', 1); // a share made while asked
      open.complete();
      await pumpEventQueue();
      expect(notSent, [3], reason: 'the launch share and the live share');
      expect(deliveries.declined, {1, 3});
      [...launch.skip(1), ...left, ...live].forEach(input.add);
      await pumpEventQueue();
      expect(asked, 2);
      expect(passed, ['left-1', 'left-2', 'left-3']);
      gate.detach(ask);
    });

    test('a delivery already waiting when the question opens gets its own '
        'question', () async {
      final notSent = <int>[];
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        if (asked == 1) {
          notSent.add(gate.declineOpenQuestion());
          return false;
        }
        await settings.setAiConsent('gemini', granted: true);
        return true;
      }

      final launch = share('launch', 2);
      final stranded = share('left', 3); // numbered before the question
      gate.attach(ask);
      [...launch, ...stranded].forEach(input.add);
      await pumpEventQueue();
      expect(notSent, [2], reason: 'the launch share only');
      expect(deliveries.declined, {1});
      expect(asked, 2, reason: 'the waiting batch is asked about');
      expect(passed, ['left-1', 'left-2', 'left-3']);
      gate.detach(ask);
    });

    test('Allow on a several-photo share: one question, every photo passes, '
        'in order', () async {
      var asked = 0;
      Future<bool> ask() async {
        asked++;
        await settings.setAiConsent('gemini', granted: true);
        return true;
      }

      gate.attach(ask);
      share('a', 4).forEach(input.add);
      await pumpEventQueue();
      expect(asked, 1);
      expect(passed, ['a-1', 'a-2', 'a-3', 'a-4']);
      expect(deliveries.declined, isEmpty);
      gate.detach(ask);
    });

    test('the count leaves out what was already passed on, and copies found '
        'unreadable', () async {
      // Allowed for the first two of a 4-photo share, then withdrawn.
      await settings.setAiConsent('gemini', granted: true);
      final four = share('w', 4);
      input
        ..add(four[0])
        ..add(four[1]);
      await pumpEventQueue();
      expect(passed, ['w-1', 'w-2']);
      await settings.setAiConsent('gemini', granted: false);
      deliveries.unreadable[1] = 1; // w-4 turned out not to be a photo
      final notSent = <int>[];
      Future<bool> ask() async {
        notSent.add(gate.declineOpenQuestion());
        return false;
      }

      gate.attach(ask);
      input.add(four[2]);
      await pumpEventQueue();
      expect(notSent, [1], reason: 'w-3 only: 4 − 2 passed − 1 unreadable');
      gate.detach(ask);
    });

    test('a photo with no delivery (not from the share intake): its Not now '
        'covers that photo only', () async {
      var asked = 0;
      final notSent = <int>[];
      Future<bool> ask() async {
        asked++;
        notSent.add(gate.declineOpenQuestion());
        return false;
      }

      gate.attach(ask);
      input
        ..add(_photo('loose-1'))
        ..add(_photo('loose-2'));
      await pumpEventQueue();
      expect(asked, 2);
      expect(notSent, [1, 1]);
      expect(deliveries.declined, isEmpty);
      gate.detach(ask);
    });

    for (final (locale, line) in [
      (const Locale('en'),
          '5 shared photos were not analyzed — nothing was sent.'),
      (const Locale('zh'), '5 张分享的照片没有分析 — 没有发送任何内容。'),
    ]) {
      testWidgets('the app shell: one dialog for a 5-photo share, one line '
          'with the count (${locale.languageCode})', (tester) async {
        // Its own gate and stream, made inside the test's zone (the ones
        // from setUp deliver outside it).
        final settings = _unasked();
        final deliveries = _Deliveries();
        final gate = SharedPhotoConsentGate(settings);
        final input = StreamController<IntakePhoto>();
        final passed = <String>[];
        final sub = gate
            .gate(input.stream, deliveries: deliveries)
            .listen((p) => passed.add(p.assetId));
        List<IntakePhoto> share(String name, int n) {
          final d = deliveries.arrive(n);
          return [
            for (var i = 1; i <= n; i++) _photo('$name-$i', delivery: d)
          ];
        }

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

        final five = share('s', 5);
        input.add(five.first);
        await tester.pumpAndSettle();
        expect(_dialog, findsOneWidget);
        await _notNow(tester);
        expect(find.text(line), findsOneWidget);
        five.skip(1).forEach(input.add);
        await tester.pumpAndSettle();
        expect(_dialog, findsNothing, reason: 'not asked again for s2..s5');
        expect(passed, isEmpty);

        input.add(share('next', 1).single);
        await tester.pumpAndSettle();
        expect(_dialog, findsOneWidget, reason: 'a later share asks again');
        await _allow(tester);
        expect(passed, ['next-1']);
        // Not awaited: a cancel future awaited inside the fake-async zone
        // never lets the test finish.
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
