// Re-consent for a changed consent text (owner decision, run 7). B14 made
// a photo taken before 4 a.m. also carry the day before's meals, and the
// consent text now says so. A grant given under the older text is asked
// about ONCE more by the app shell; until it is allowed again the photo
// pipeline keeps sending only that day's meals (auto_leftover_test,
// ai_consent_settings_test). Not now is remembered and changes nothing.
import 'dart:async';

import 'package:calorie_tracker/core/ai_consent.dart';
import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/ai_consent.dart';
import 'package:calorie_tracker/ui/app.dart';
import 'package:calorie_tracker/ui/di.dart' show createSettingsStore;
import 'package:calorie_tracker/ui/screens/settings_screen.dart';
import 'package:calorie_tracker/ui/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../settings/app_settings_test.dart' show freshSettings;
import 'fakes.dart';

/// Gemini allowed under the text from before versions were recorded.
FakeSettings _oldGrant({String apiKey = 'k', bool watcher = false}) =>
    FakeSettings(
        apiKey: apiKey, watcherEnabled: watcher, watcherDisclosureSeen: watcher)
      ..aiConsent = {'gemini'}
      ..aiConsentVersions = {};

Finder get _update => find.byKey(const Key('aiConsentUpdateDialog'));

Widget _app(Widget home, {Locale? locale}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

UiServices _services(SettingsStore settings, {Stream<Uri>? links}) =>
    UiServices(
      dao: FakeDao(),
      analyzer: FakeAnalyzer(),
      executor: FakeExecutor(),
      settings: settings,
      picker: FakePicker(),
      requestPhotoPermission: () async => true,
      setupLinks: links,
    );

Future<void> _launch(WidgetTester tester, SettingsStore settings,
    {Locale? locale, Stream<Uri>? links}) async {
  await tester.pumpWidget(
      _app(HomeShell(services: _services(settings, links: links)),
          locale: locale));
  await tester.pumpAndSettle();
}

/// The app goes to the background and comes back.
Future<void> _leaveAndReturn(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

String _bodyOf(WidgetTester tester, Finder dialog) =>
    // The dialog's content: title and text scroll together now (A1), so
    // the scroll view holds both.
    (tester.widget<AlertDialog>(dialog).content! as Text).data!;

Uri _link(String backend) =>
    Uri.parse('bitewise://setup?server=https%3A%2F%2F10.0.0.7'
        '&key=k1234567890abcdef&backend=$backend');

void main() {
  group('the one-time question', () {
    testWidgets('a grant from before the text changed is asked once, with '
        'the full text; Allow records the new text', (tester) async {
      final settings = _oldGrant();
      await _launch(tester, settings);
      expect(_update, findsOneWidget);
      expect(
          find.descendant(
              of: _update,
              matching: find.text('What Chopstats sends has changed')),
          findsOneWidget);
      final body = _bodyOf(tester, _update);
      // What is new first, then the full text it changed.
      expect(
          body,
          startsWith('New: a photo taken before 4 a.m. now also carries a '
              "short summary of the day before's meals"));
      expect(body, contains('Not now keeps it that way.\n\n'
          'Chopstats estimates calories'));
      expect(body, contains('Google (Gemini)'));
      expect(body, contains('(for a photo taken before 4 a.m., the day before too)'));
      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);

      await tester.tap(find.byKey(const Key('aiConsentUpdateAllow')));
      await tester.pumpAndSettle();
      expect(_update, findsNothing);
      expect(settings.aiConsentVersion('gemini'), aiConsentWordingVersion);
      expect(settings.aiConsentWrites, [('gemini', true)]);
      expect(settings.aiConsentUpdateDeclines, isEmpty);

      await _leaveAndReturn(tester);
      expect(_update, findsNothing, reason: 'answered');
    });

    testWidgets('Not now is remembered and changes nothing else',
        (tester) async {
      final settings = _oldGrant(watcher: true);
      await _launch(tester, settings);
      await tester.tap(find.byKey(const Key('aiConsentUpdateNotNow')));
      await tester.pumpAndSettle();
      expect(_update, findsNothing);
      expect(settings.aiConsentUpdateDeclines, {'gemini'});
      expect(settings.aiConsentWrites, isEmpty,
          reason: 'the older grant is neither withdrawn nor upgraded');
      expect(settings.hasAiConsent('gemini'), isTrue);
      expect(settings.aiConsentVersion('gemini'), 1);
      expect(settings.watcherEnabled, isTrue,
          reason: 'automatic logging goes on under the older grant');
      expect(settings.updateCalls, 0);

      await _leaveAndReturn(tester);
      expect(_update, findsNothing);
      await _launch(tester, settings); // the next launch
      expect(_update, findsNothing);
    });

    testWidgets('never on a fresh install, without a key, or without a grant',
        (tester) async {
      final cases = {
        'fresh install': FakeSettings(apiKey: '')
          ..aiConsent = {}
          ..aiConsentVersions = {},
        'no key': _oldGrant(apiKey: ''),
        'key, no grant': _oldGrant()..aiConsent = {},
        'granted under the current text': FakeSettings(apiKey: 'k'),
        'another recipient has the old grant': _oldGrant()
          ..aiConsent = {'openai'}
          ..provider = 'gemini',
      };
      for (final MapEntry(key: name, value: settings) in cases.entries) {
        await _launch(tester, settings);
        expect(_update, findsNothing, reason: name);
        await _leaveAndReturn(tester);
        expect(_update, findsNothing, reason: '$name, on return');
        expect(settings.aiConsentWrites, isEmpty, reason: name);
        expect(settings.aiConsentUpdateDeclines, isEmpty, reason: name);
      }
    });

    testWidgets('with Watch Camera Roll on, the camera-roll notice follows '
        'what is new, ahead of the full text', (tester) async {
      await _launch(tester, _oldGrant(watcher: true));
      final body = _bodyOf(tester, _update);
      expect(body, startsWith('New: a photo taken before 4 a.m.'));
      final notice = body.indexOf('While Watch Camera Roll is on');
      final text = body.indexOf('Chopstats estimates calories');
      expect(notice, greaterThan(0));
      expect(text, greaterThan(notice));
    });

    testWidgets('Chinese', (tester) async {
      await _launch(tester, _oldGrant(), locale: const Locale('zh'));
      expect(find.text('筷拍发送的内容有更新'), findsOneWidget);
      final body = _bodyOf(tester, _update);
      expect(body, startsWith('新增：凌晨 4 点前拍的照片，现在还会附带前一天餐食的简短摘要'));
      expect(body, contains('选择「暂不」会保持这样。'));
      expect(body, contains('凌晨 4 点前拍的照片还包括前一天的餐食'));
      expect(find.text('暂不'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
    });

    testWidgets('asked on a return to the app, not after a system alert',
        (tester) async {
      final settings = _oldGrant(apiKey: '');
      await _launch(tester, settings);
      expect(_update, findsNothing);
      settings.apiKey = 'k';
      // An iOS system alert (the Photos prompt) is inactive → resumed only.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(_update, findsNothing);
      await _leaveAndReturn(tester);
      expect(_update, findsOneWidget);
    });
  });

  group('one question at a time', () {
    testWidgets('a setup link that lands meanwhile waits for the answer',
        (tester) async {
      final settings = _oldGrant();
      final links = StreamController<Uri>.broadcast();
      await _launch(tester, settings, links: links.stream);
      expect(_update, findsOneWidget);
      links.add(_link('doubao'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setupLinkConfirm')), findsNothing,
          reason: 'not stacked over the open question');
      await tester.tap(find.byKey(const Key('aiConsentUpdateNotNow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('setupLinkConfirm')));
      await tester.pumpAndSettle();
      expect(settings.aiConsentWrites, [('server:doubao', true)]);
      expect(settings.aiConsentVersion('server:doubao'),
          aiConsentWordingVersion);
      expect(settings.aiConsentUpdateDeclines, {'gemini'});
      expect(_update, findsNothing);
      await links.close();
    });

    testWidgets('never over the setup-link question or another screen',
        (tester) async {
      final settings = _oldGrant(apiKey: '');
      final links = StreamController<Uri>.broadcast();
      await _launch(tester, settings, links: links.stream);
      links.add(_link('claude'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setupLinkConfirm')), findsOneWidget);
      settings.apiKey = 'k';
      await _leaveAndReturn(tester);
      expect(_update, findsNothing, reason: 'the link is being asked');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // A screen on top of the shell.
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('a screen')))));
      await tester.pumpAndSettle();
      await _leaveAndReturn(tester);
      expect(_update, findsNothing, reason: 'not over a screen');
      nav.pop();
      await tester.pumpAndSettle();
      await _leaveAndReturn(tester);
      expect(_update, findsOneWidget);
      await links.close();
    });

    testWidgets('the check does not tie the shell to its route: a screen '
        'pushed and popped after the question rebuilds nothing', (tester) async {
      await _launch(tester, _oldGrant());
      await tester.tap(find.byKey(const Key('aiConsentUpdateNotNow')));
      await tester.pumpAndSettle();
      var shellBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is HomeShell) shellBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('a screen')))));
      await tester.pumpAndSettle();
      nav.pop();
      await tester.pumpAndSettle();
      debugOnRebuildDirtyWidget = null;
      // ModalRoute.of(context) made it 2: the shell and its selected tab
      // rebuilt on every push and every pop for the rest of the session.
      expect(shellBuilds, 0);
    });
  });

  // The real store (AppSettings through the UI adapter), so "records the
  // current text" is the production write, not the fake's.
  group('every grant path records the current text', () {
    testWidgets('a foreground send (ensureAiConsent; the share gate asks '
        'through it too)', (tester) async {
      final (s, _, _) = await freshSettings();
      await s.setGeminiApiKey('k');
      final store = createSettingsStore(s);
      await tester.pumpWidget(_app(Builder(
          builder: (context) => TextButton(
              onPressed: () => ensureAiConsent(context, store),
              child: const Text('send')))));
      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('aiConsentAllow')));
      await tester.pumpAndSettle();
      expect(s.aiConsentVersion('gemini'), aiConsentWordingVersion);
      expect(s.previousDayLeftoverContext, isTrue);
    });

    testWidgets('a recipient change while the watcher is on', (tester) async {
      final (s, _, _) = await freshSettings(initial: {
        'settings.watcher_enabled': true,
      });
      expect(s.aiConsentVersion('gemini'), 1, reason: 'the seed');
      final store = createSettingsStore(s);
      await tester.pumpWidget(_app(Builder(
          builder: (context) => TextButton(
              onPressed: () => confirmAiRecipientChange(context, store,
                  provider: 'openai', serverBackend: 'claude'),
              child: const Text('switch')))));
      await tester.tap(find.text('switch'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('aiConsentAllow')));
      await tester.pumpAndSettle();
      expect(s.aiConsentVersion('openai'), aiConsentWordingVersion);
      expect(s.aiConsentVersion('gemini'), 1, reason: 'per recipient');
    });

    testWidgets('turning on Watch Camera Roll', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (s, _, _) = await freshSettings();
      await s.setGeminiApiKey('k');
      final store = createSettingsStore(s);
      await tester.pumpWidget(_app(Scaffold(
          body: SettingsScreen(
        settings: store,
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        photoIntake: FakeIntake(),
        requestPhotoPermission: () async => true,
      ))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watcherToggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watcherDisclosureContinue')));
      await tester.pumpAndSettle();
      expect(s.watcherEnabled, isTrue);
      expect(s.aiConsentVersion('gemini'), aiConsentWordingVersion);
    });

    testWidgets('a setup link, and the update question itself',
        (tester) async {
      final (s, _, _) = await freshSettings(initial: {
        'settings.watcher_enabled': true,
      });
      await s.setGeminiApiKey('k');
      final store = createSettingsStore(s);
      final links = StreamController<Uri>.broadcast();
      await _launch(tester, store, links: links.stream);
      // The seeded grant (version 1) is asked about once.
      expect(_update, findsOneWidget);
      await tester.tap(find.byKey(const Key('aiConsentUpdateAllow')));
      await tester.pumpAndSettle();
      expect(s.aiConsentVersion('gemini'), aiConsentWordingVersion);
      links.add(_link('glm'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('setupLinkConfirm')));
      await tester.pumpAndSettle();
      expect(s.aiConsentVersion('server:glm'), aiConsentWordingVersion);
      expect(s.previousDayLeftoverContext, isTrue);
      await links.close();
    });
  });
}
