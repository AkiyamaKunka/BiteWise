// The Your own server page's address field. It saved only on Done or on a
// tap outside it — and Flutter does not count a tap into another text field
// (the upload key, right under it) as outside. So the natural order (type
// the address, tap the upload key, type it, Done) lost the address: Test
// This Provider said "No server address is set", and Connect Claude (U3)
// asked for an address the field still showed. Found on the run-7
// decisions simulator walk.
//
// The run-7 fix saved the address on every keystroke instead, and the
// analyzer, the Garmin fetch and the lookups all read the saved address at
// each request: an automatic photo sent while the user retyped the address
// went, with the upload key, to whatever host the half-typed text named
// (review 171, C10). The address is saved now when the edit is over — Done,
// focus moving to another field (or a sheet or dialog), leaving the page,
// or an action about to use it (Connect Claude, a plan pick) — and never
// when a pointer goes down outside while the field keeps its focus (a
// scroll, a tap beside it), nor as typed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:calorie_tracker/core/contracts.dart';
import 'package:calorie_tracker/core/server_transport.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/services/analyzer/provider_analyzers.dart';
import 'package:calorie_tracker/services/settings/app_settings.dart';
import 'package:calorie_tracker/ui/background_glue.dart' show aiSendGateFor;
import 'package:calorie_tracker/ui/di.dart' show createSettingsStore;
import 'package:calorie_tracker/ui/photo_pipeline.dart';
import 'package:calorie_tracker/ui/screens/settings/subscription_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analyzer/server_analyzer_test.dart' show MemoryKeyStore;
import 'fakes.dart';

void main() {
  testWidgets('the address is kept when the next tap is the upload key',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(keys: {'server': ''})..provider = 'server';
    var starts = 0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SubscriptionProviderPage(
        settings: settings,
        startClaudeAuth: () async {
          starts++;
          return (url: null, error: 'stop here');
        },
        completeClaudeAuth: (_) async => null,
      ),
    ));
    await tester.pumpAndSettle();

    final address = find.byKey(const Key('serverUrlField'));
    final key = find.byKey(const Key('serverUploadKeyField'));
    await tester.tap(address);
    await tester.enterText(address, 'https://10.0.0.7');
    await tester.tap(key);
    await tester.enterText(key, 'up');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.serverBaseUrl, 'https://10.0.0.7');
    expect(settings.apiKey, 'up');

    // So Connect Claude asks the server instead of for the address.
    await tester.tap(find.byKey(const Key('connectClaudeButton')));
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(find.text('Enter your server address and upload key above first.'),
        findsNothing);
  });

  // A screen reader (VoiceOver, TalkBack, Switch Control) activates a row
  // with a semantics tap: no pointer, so no tap outside, and the address
  // field keeps its focus. Connect Claude then read the saved address, not
  // the one the field showed: it asked for an address the field held (the
  // U3 bug run 7 fixed) or went to the old server (review 171). A finger's
  // tap must keep working too, now that a pointer going down outside the
  // field saves nothing.
  for (final reader in const [false, true]) {
    final by = reader ? 'a screen reader' : 'a tap';
    Future<void> activate(
        WidgetTester tester, String key, Pattern label) async {
      if (reader) {
        tester.semantics.tap(find.semantics.byLabel(label));
      } else {
        await tester.tap(find.byKey(Key(key)));
      }
    }

    for (final (saved, typed) in const [
      ('', 'https://10.0.0.7'),
      ('https://10.0.0.7', 'https://10.0.0.55'),
    ]) {
      testWidgets('Connect Claude by $by right after "$typed" is typed '
          '(saved: "$saved") uses the typed address', (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        final settings = FakeSettings(keys: {'server': 'up'})
          ..provider = 'server'
          ..serverBaseUrl = saved;
        final asked = <String>[]; // the saved address at each start
        await tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SubscriptionProviderPage(
            settings: settings,
            startClaudeAuth: () async {
              asked.add(settings.serverBaseUrl);
              return (url: null, error: 'stop here');
            },
            completeClaudeAuth: (_) async => null,
          ),
        ));
        await tester.pumpAndSettle();

        final address = find.byKey(const Key('serverUrlField'));
        await tester.tap(address);
        await tester.enterText(address, typed);
        await tester.pump();
        expect(settings.serverBaseUrl, saved, reason: 'not committed yet');
        await activate(
            tester, 'connectClaudeButton', RegExp('^Connect Claude'));
        await tester.pumpAndSettle();
        expect(asked, [typed]);
        expect(
            find.text(
                'Enter your server address and upload key above first.'),
            findsNothing);
        semantics.dispose();
      });
    }

    // The same for a plan picked while Watch Camera Roll is on: its
    // question names the host the photos would go to, and it named the
    // saved one while the field showed the new one (saved a moment later,
    // when the dialog took the focus).
    testWidgets('a plan picked by $by right after typing names the typed '
        'host in its question', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final settings =
          FakeSettings(keys: {'server': 'up'}, watcherEnabled: true)
            ..provider = 'server'
            ..serverBaseUrl = 'https://10.0.0.7'
            ..aiConsent = {'server:claude'};
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SubscriptionProviderPage(settings: settings),
      ));
      await tester.pumpAndSettle();

      final address = find.byKey(const Key('serverUrlField'));
      await tester.tap(address);
      await tester.enterText(address, 'https://10.0.0.55');
      await tester.pump();
      await activate(tester, 'planChoice-glm', RegExp('^GLM'));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('aiConsentDialog'));
      expect(dialog, findsOneWidget);
      expect(
          find.descendant(
              of: dialog, matching: find.textContaining('10.0.0.55')),
          findsOneWidget);
      expect(
          find.descendant(
              of: dialog, matching: find.textContaining('10.0.0.7')),
          findsNothing);
      await tester.tap(find.byKey(const Key('aiConsentNotNow')));
      await tester.pumpAndSettle();
      expect(settings.serverBackend, 'claude');
      expect(settings.serverBaseUrl, 'https://10.0.0.55');
      semantics.dispose();
    });
  }

  testWidgets('a space around the address is trimmed when it is saved',
      (tester) async {
    final settings = FakeSettings(keys: {'server': 'up'})..provider = 'server';
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SubscriptionProviderPage(settings: settings),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('serverUrlField')), ' https://10.0.0.7 ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(settings.serverBaseUrl, 'https://10.0.0.7');
    expect(find.text(' https://10.0.0.7 '), findsOneWidget,
        reason: 'the field keeps what was typed; only the saved value is trimmed');
  });

  testWidgets('typing saves nothing; Done saves the address once',
      (tester) async {
    final settings = FakeSettings(keys: {'server': 'up'})
      ..provider = 'server'
      ..serverBaseUrl = 'https://10.0.0.7';
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SubscriptionProviderPage(settings: settings),
    ));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('serverUrlField'));
    final before = settings.updateCalls;
    // The last octet edited in place: 7 deleted, then 5 and 5 typed.
    for (final typed in ['https://10.0.0.', 'https://10.0.0.5']) {
      await tester.enterText(field, typed);
      await tester.pump();
      expect(settings.serverBaseUrl, 'https://10.0.0.7',
          reason: 'half-typed "$typed" must not become the address');
    }
    await tester.enterText(field, 'https://10.0.0.55');
    await tester.pump();
    expect(settings.serverBaseUrl, 'https://10.0.0.7');
    expect(settings.updateCalls, before, reason: 'no keystroke saves');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.serverBaseUrl, 'https://10.0.0.55');
    expect(settings.updateCalls, before + 1,
        reason: 'Done saves once, and losing focus with it saves nothing more');
  });

  // A pointer going down outside the field is not the end of the edit: on
  // a phone the field keeps its focus and the keyboard stays up. A scroll
  // of the page or a tap just beside the field, mid-edit, saved the
  // half-typed address while the user went on typing (review 171).
  testWidgets('a scroll or a tap beside the field mid-edit saves nothing; '
      'the edit goes on', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(keys: {'server': 'up'})
      ..provider = 'server'
      ..serverBaseUrl = 'https://10.0.0.7';
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SubscriptionProviderPage(settings: settings),
    ));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('serverUrlField'));
    final before = settings.updateCalls;
    await tester.tap(field);
    await tester.enterText(field, 'https://10.0.0.5');
    await tester.pump();

    await scrollAndMissField(tester, field);
    expect(settings.serverBaseUrl, 'https://10.0.0.7');
    expect(settings.updateCalls, before);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue,
        reason: 'still editing, the keyboard up');

    await tester.enterText(field, 'https://10.0.0.55');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.serverBaseUrl, 'https://10.0.0.55');
    expect(settings.updateCalls, before + 1);
  });

  testWidgets('leaving the page saves an edit not committed yet; a visit '
      'without an edit saves nothing', (tester) async {
    final settings = FakeSettings(keys: {'server': 'up'})
      ..provider = 'server'
      ..serverBaseUrl = 'https://10.0.0.7';
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SubscriptionProviderPage(settings: settings))),
          child: const Text('open'),
        ),
      ),
    ));
    Future<void> open() async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> back() async {
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
    }

    final field = find.byKey(const Key('serverUrlField'));
    final key = find.byKey(const Key('serverUploadKeyField'));

    // A visit: into the address field, on to the upload key, back out.
    await open();
    final before = settings.updateCalls;
    await tester.tap(field);
    await tester.pump();
    await tester.tap(key);
    await tester.pump();
    await back();
    expect(settings.updateCalls, before,
        reason: 'an address nobody edited is not saved again');

    // An edit, then Back with the field still focused.
    await open();
    await tester.enterText(field, 'https://10.0.0.55');
    await tester.pump();
    expect(settings.serverBaseUrl, 'https://10.0.0.7');
    await back();
    expect(settings.serverBaseUrl, 'https://10.0.0.55');
  });

  // The reported case, with the production pieces: the store the app uses,
  // the photo pipeline with its consent gate, and the server analyzer.
  testWidgets('an automatic photo sent while the address is retyped goes to '
      'the saved address, never to a half-typed host', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppSettings app;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      app = await AppSettings.load(
          prefs: await SharedPreferences.getInstance(),
          keyStore: MemoryKeyStore());
      await app.setProvider(AiProvider.server);
      await app.setServerBaseUrl('https://10.0.0.7');
      await app.setServerApiKey('upload-key');
      await app.setAiConsent('server:claude', granted: true);
    });

    final uploads = <String>[]; // host <- X-API-Key
    final pipeline = PhotoPipeline(
        dao: FakeDao(),
        analyzer: ServerAnalyzer(app,
            normalizer: (b) async => b,
            client: MockClient((req) async {
              uploads.add('${req.url.host} <- ${req.headers['X-API-Key']}');
              return http.Response(
                  jsonEncode({
                    'ok': true,
                    'analysis': {'is_food': false},
                    'analyzed_by': 'claude',
                  }),
                  200);
            })),
        sendGate: aiSendGateFor(app),
        hasher: (b) async => 'h${b.first}',
        thumbnailer: (_) async => null);
    var n = 0;
    Future<void> automaticPhoto() => tester.runAsync(() => pipeline.process(
        IntakePhoto(Uint8List.fromList([++n, n, n]), 'a$n', 'IMG_$n.jpg')));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SubscriptionProviderPage(settings: createSettingsStore(app)),
    ));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('serverUrlField'));

    // The server moved to .55: the last octet is edited in place, and an
    // automatic photo goes out after each keystroke.
    for (final typed in ['https://10.0.0.', 'https://10.0.0.5', 'https://10.0.0.55']) {
      await tester.enterText(field, typed);
      await tester.pump();
      await automaticPhoto();
    }
    expect(uploads, List.filled(3, '10.0.0.7 <- upload-key'));
    expect(app.serverBaseUrl, 'https://10.0.0.7');

    // Nor after a scroll or a tap beside the field while it is retyped.
    await tester.enterText(field, 'https://10.0.0.5');
    await tester.pump();
    await scrollAndMissField(tester, field);
    await tester.runAsync(() async {}); // a save, had one started, finishes
    await automaticPhoto();
    expect(uploads, List.filled(4, '10.0.0.7 <- upload-key'));
    expect(app.serverBaseUrl, 'https://10.0.0.7');

    await tester.enterText(field, 'https://10.0.0.55');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {}); // the store's save finishes
    expect(app.serverBaseUrl, 'https://10.0.0.55');
    await automaticPhoto();
    expect(uploads.last, '10.0.0.55 <- upload-key');
  });

  // Owner decision 2026-11-13: plain http is refused everywhere. With the
  // https switch on (shipped), an address that does not start with
  // https:// is never saved, and one saved before shows "Needs https://"
  // and a footer saying nothing is sent to it. With it off, http:// is
  // saved and the footer says it travels unencrypted.
  group('an address that is not https://', () {
    setUp(() => debugRequireHttpsServerOverride = true);
    tearDown(() => debugRequireHttpsServerOverride = null);
    final en = lookupAppLocalizations(const Locale('en'));
    final zh = lookupAppLocalizations(const Locale('zh'));

    Future<(FakeSettings, List<String>)> pumpPage(WidgetTester tester,
        {String saved = '', Locale locale = const Locale('en')}) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final settings = FakeSettings(keys: {'server': 'up'})
        ..provider = 'server'
        ..serverBaseUrl = saved;
      final asked = <String>[];
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SubscriptionProviderPage(
          settings: settings,
          startClaudeAuth: () async {
            asked.add(settings.serverBaseUrl);
            return (url: null, error: 'stop here');
          },
          completeClaudeAuth: (_) async => null,
        ),
      ));
      await tester.pumpAndSettle();
      return (settings, asked);
    }

    Finder footerWith(String text) => find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains(text));

    testWidgets('the hint is an https:// address', (tester) async {
      await pumpPage(tester);
      final field = tester.widget<TextField>(
          find.byKey(const Key('serverUrlField')));
      expect(field.decoration!.hintText, 'https://your.server');
    });

    for (final typed in ['http://10.0.0.7', 'HTTP://h.example:5000', '10.0.0.7']) {
      testWidgets('switch on: "$typed" is not saved, and the field says '
          'why until the next keystroke', (tester) async {
        final (settings, _) = await pumpPage(tester, saved: 'https://10.0.0.5');
        final field = find.byKey(const Key('serverUrlField'));
        await tester.enterText(field, typed);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(settings.serverBaseUrl, 'https://10.0.0.5',
            reason: 'the saved address is left as it was');
        expect(find.text(en.serverNeedsHttpsField), findsOneWidget);
        await tester.enterText(field, 'https://10.0.0.7');
        await tester.pump();
        expect(find.text(en.serverNeedsHttpsField), findsNothing);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(settings.serverBaseUrl, 'https://10.0.0.7');
        expect(find.text(en.serverNeedsHttpsField), findsNothing);
      });
    }

    testWidgets('switch on: Connect Claude after an http:// edit stops and '
        'says why, calling nothing', (tester) async {
      final (settings, asked) =
          await pumpPage(tester, saved: 'https://10.0.0.5');
      await tester.enterText(
          find.byKey(const Key('serverUrlField')), 'http://10.0.0.7');
      await tester.tap(find.byKey(const Key('connectClaudeButton')));
      await tester.pumpAndSettle();
      expect(asked, isEmpty);
      expect(find.text(en.errServerNeedsHttps), findsOneWidget);
      expect(settings.serverBaseUrl, 'https://10.0.0.5');
    });

    testWidgets('switch on: leaving the page with an http:// edit saves '
        'nothing', (tester) async {
      final (settings, _) = await pumpPage(tester, saved: 'https://10.0.0.5');
      await tester.enterText(
          find.byKey(const Key('serverUrlField')), 'http://10.0.0.7');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(settings.serverBaseUrl, 'https://10.0.0.5');
    });

    for (final (locale, l) in [(const Locale('en'), en), (const Locale('zh'), zh)]) {
      testWidgets('switch on: an http:// address saved before is shown with '
          '"needs https" and Connect Claude calls nothing '
          '(${locale.languageCode})', (tester) async {
        final (settings, asked) =
            await pumpPage(tester, saved: 'http://10.0.0.7', locale: locale);
        expect(find.text(l.serverNeedsHttpsField), findsOneWidget);
        expect(footerWith(l.serverNeedsHttpsFooter), findsOneWidget);
        expect(footerWith(l.serverFooter), findsOneWidget);
        await tester.tap(find.byKey(const Key('connectClaudeButton')));
        await tester.pumpAndSettle();
        expect(asked, isEmpty);
        expect(find.text(l.errServerNeedsHttps), findsOneWidget);
        expect(settings.serverBaseUrl, 'http://10.0.0.7',
            reason: 'kept, so fixing it is an edit, not a retype');
      });
    }

    testWidgets('switch on: an https:// address has neither line',
        (tester) async {
      await pumpPage(tester, saved: 'https://10.0.0.7');
      expect(find.text(en.serverNeedsHttpsField), findsNothing);
      expect(footerWith(en.serverNeedsHttpsFooter), findsNothing);
      expect(footerWith(en.serverHttpFooter), findsNothing);
    });

    testWidgets('switch off: http:// is saved, and the footer says it '
        'travels unencrypted', (tester) async {
      debugRequireHttpsServerOverride = false;
      final (settings, asked) = await pumpPage(tester);
      await tester.enterText(
          find.byKey(const Key('serverUrlField')), 'http://10.0.0.7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(settings.serverBaseUrl, 'http://10.0.0.7');
      expect(find.text(en.serverNeedsHttpsField), findsNothing);
      expect(footerWith(en.serverHttpFooter), findsOneWidget);
      await tester.tap(find.byKey(const Key('connectClaudeButton')));
      await tester.pumpAndSettle();
      expect(asked, ['http://10.0.0.7']);
    });
  });
}

/// Two pointers going down outside the focused address [field], neither of
/// them a commit: a scroll that starts on the plan list's footer, then a
/// tap that just misses the field (in its cell, above it).
Future<void> scrollAndMissField(WidgetTester tester, Finder field) async {
  final l = lookupAppLocalizations(const Locale('en'));
  await tester.dragFrom(
      tester.getCenter(find.text(l.planFooter)), const Offset(0, -40));
  await tester.pumpAndSettle();
  final rect = tester.getRect(field);
  await tester.tapAt(Offset(rect.left + 8, rect.top - 6));
  await tester.pumpAndSettle();
}
