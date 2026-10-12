/// Settings screen behavior: the ONE test action (diagnostics), key and
/// model persistence, the server backend selector, and the Claude OAuth
/// re-connect flow. The old 'Validate key' states are gone with the button
/// (2026-07-31) — the diagnostics page answers strictly more.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:calorie_tracker/l10n/app_localizations.dart';
import 'package:calorie_tracker/ui/screens/settings_screen.dart';

import 'fakes.dart';

/// AppSettings' notifier, as the screen sees it.
class _Changes extends ChangeNotifier {
  void fire() => notifyListeners();
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The 2026-08-02 Apple restructure moved provider/key/model/server
/// controls onto their own page (progressive disclosure): tests that
/// exercise them walk through the root's AI Provider row first.
Future<void> openProviderPage(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('aiProviderRow')));
  await tester.pumpAndSettle();
}

/// v2 IA (2026-08-02): each connection TYPE has its own page below the
/// chooser — API-key controls and plan controls need one more hop.
Future<void> openApiKeyPage(WidgetTester tester) async {
  await openProviderPage(tester);
  await tester.tap(find.byKey(const Key('apiKeyTypeRow')));
  await tester.pumpAndSettle();
}

Future<void> openSubscriptionPage(WidgetTester tester) async {
  await openProviderPage(tester);
  await tester.tap(find.byKey(const Key('subscriptionTypeRow')));
  await tester.pumpAndSettle();
}

void main() {
  connectClaudeTests();
  importExportTests();
  planTuningTests();

  testWidgets('ONE test action: the key field has no separate Validate — '
      'it opens the diagnostics page', (tester) async {
    // 'Validate key' ran the same analyzer.validateKey the diagnostics
    // page runs as stage 3 of six, and its persist-on-success job became
    // redundant when the field started persisting on type (2026-07-31).
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k');
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openProviderPage(tester);
    expect(find.text('Test This Provider'), findsOneWidget);
    expect(find.byKey(const Key('diagnosticsTile')), findsNothing,
        reason: 'the tile was a third door to the same page');
    expect(find.text('Validate key'), findsNothing);
    expect(find.text('Key OK'), findsNothing);

    await tester.tap(find.byKey(const Key('testProviderButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('runDiagnostics')), findsOneWidget,
        reason: 'the one action opens the page that answers everything');
  });

  testWidgets('a typed key persists without any button', (tester) async {
    final settings = FakeSettings(apiKey: '');
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openApiKeyPage(tester);
    await tester.enterText(find.byKey(const Key('apiKeyField')), 'my-key');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.apiKey, 'my-key');
  });
  testWidgets('server backend selector shows for the server provider and '
      'persists the choice', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k')..provider = 'server';
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openSubscriptionPage(tester);
    // The segmented control became the Subscription checklist (user-
    // designed two-type IA, 2026-08-02): picking a plan row selects both
    // the server provider AND the backend.
    expect(find.byKey(const Key('planChoice-claude')), findsOneWidget);
    expect(settings.serverBackend, 'claude');

    await tester.tap(find.byKey(const Key('planChoice-glm')));
    await tester.pumpAndSettle();
    expect(settings.serverBackend, 'glm',
        reason: 'the tap must reach SettingsStore.update(serverBackend:)');
    expect(settings.provider, 'server');

    await tester.tap(find.byKey(const Key('planChoice-doubao')));
    await tester.pumpAndSettle();
    expect(settings.serverBackend, 'doubao');
  });

  testWidgets('picking a plan from an API provider switches to the server '
      'in one tap', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k'); // gemini default
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openSubscriptionPage(tester);
    expect(find.byKey(const Key('serverBackendSelector')), findsNothing,
        reason: 'the segmented control is gone — plans are first-class rows');
    await tester.ensureVisible(find.byKey(const Key('planChoice-doubao')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planChoice-doubao')));
    await tester.pumpAndSettle();
    expect(settings.provider, 'server');
    expect(settings.serverBackend, 'doubao');
  });

  testWidgets('model is PICKED from a curated list, not typed', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k'); // gemini, curated default
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openApiKeyPage(tester);
    expect(find.byKey(const Key('modelPicker')), findsOneWidget);
    expect(find.byKey(const Key('modelField')), findsNothing,
        reason: 'no raw text entry unless the user asks for Custom');

    await tester.ensureVisible(find.byKey(const Key('modelPicker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('modelPicker')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.text('gemini-3.1-pro-preview — strongest, slower').last);
    await tester.pumpAndSettle();
    expect(settings.model, 'gemini-3.1-pro-preview',
        reason: 'picking persists');

    // The Custom row reveals the text field for unlisted models.
    await tester.tap(find.byKey(const Key('modelPicker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom — type a model name…').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('modelField')), findsOneWidget);
  });

  testWidgets('a stored unlisted model renders as Custom with the field '
      'visible', (tester) async {
    final settings =
        FakeSettings(apiKey: 'k', model: 'gemini-exp-something-new');
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openApiKeyPage(tester);
    expect(find.byKey(const Key('modelField')), findsOneWidget,
        reason: 'an unlisted stored model must stay visible and editable');
    expect(find.text('Custom — type a model name…'), findsOneWidget);
  });

  testWidgets('switching provider reloads BOTH the key and the model, and '
      'remounts the picker', (tester) async {
    // The dropdown's onChanged is the only place these three move
    // together; nothing tested it, so a dropped line would have shown
    // Gemini's key under Doubao (review 2026-07-31).
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(
      keys: {'gemini': 'gem-key', 'glm': 'glm-key'},
      models: {'gemini': 'gemini-3.8-flash', 'glm': 'glm-4.6v-flash'},
    );
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openApiKeyPage(tester);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('apiKeyField')))
            .controller!
            .text,
        'gem-key');

    // The dropdown became an Apple checkmark list (2026-08-02).
    await tester.tap(find.byKey(const Key('providerChoice-glm')));
    await tester.pumpAndSettle();

    expect(settings.provider, 'glm');
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('apiKeyField')))
            .controller!
            .text,
        'glm-key',
        reason: "the key field must show the NEW provider's key");
    // The picker remounted onto the GLM list (its free flash default).
    expect(find.textContaining('glm-4.6v-flash'), findsWidgets);
    expect(find.byKey(const Key('modelField')), findsNothing,
        reason: 'the GLM default IS curated — no custom field');
  });

  testWidgets('enabling the watcher without a usable key warns instead of '
      'arming a switch that does nothing', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(
        apiKey: '', watcherEnabled: false, watcherDisclosureSeen: true);
    final intake = FakeIntake();
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      photoIntake: intake,
      requestPhotoPermission: () async => true,
    )));
    await tester.tap(find.byKey(const Key('watcherToggle')));
    await tester.pumpAndSettle();

    expect(settings.watcherEnabled, isTrue, reason: 'the toggle still arms');
    expect(intake.started, isTrue);
    expect(find.textContaining("won't be analyzed"), findsOneWidget);
    expect(intake.backfillScans, 0,
        reason: 'no key: reading photo bytes would be for nothing');
  });

  testWidgets('a quota pause gets its OWN warning wording', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final paused = FakeSettings(apiKey: 'k', watcherDisclosureSeen: true)
      ..isQuotaPaused = true;
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: paused,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      photoIntake: FakeIntake(),
      requestPhotoPermission: () async => true,
    )));
    await tester.tap(find.byKey(const Key('watcherToggle')));
    await tester.pumpAndSettle();
    // The BANNER also says "daily quota" — assert the snackbar's own words.
    expect(find.textContaining('new photos will wait'), findsOneWidget);
  });

  testWidgets('a healthy enable is silent and sweeps immediately',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final healthy = FakeSettings(apiKey: 'k', watcherDisclosureSeen: true);
    final intake = FakeIntake();
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: healthy,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      photoIntake: intake,
      requestPhotoPermission: () async => true,
    )));
    await tester.tap(find.byKey(const Key('watcherToggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining("won't be analyzed"), findsNothing);
    expect(intake.backfillScans, 1,
        reason: 'a healthy enable sweeps the window immediately');
  });

  testWidgets('the Photos footer shows a pause the moment it starts and '
      'drops it the moment it ends — no tab switch', (tester) async {
    // The shell's rebuild keeps the same SettingsScreen instance, so a
    // pause armed while Settings was open only appeared after switching
    // tabs (API 35 emulator, 2026-10-12).
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(
        apiKey: 'k', watcherEnabled: true, watcherDisclosureSeen: true);
    final changes = _Changes();
    addTearDown(changes.dispose);
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
      changes: changes,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('rejected the API key'), findsNothing);

    settings
      ..autoScanBlockedKind = 'rejectedKey'
      ..autoScanBlockedUntil = DateTime.now().add(const Duration(hours: 3));
    changes.fire();
    await tester.pump();
    expect(find.textContaining('rejected the API key'), findsOneWidget);

    settings
      ..autoScanBlockedKind = null
      ..autoScanBlockedUntil = null;
    changes.fire();
    await tester.pump();
    expect(find.textContaining('rejected the API key'), findsNothing);
  });

  testWidgets('a latched automatic scan says why — in the Photos footer, '
      'and on enable, without sweeping', (tester) async {
    // A rejected key / blocked region (perhaps found by a background run,
    // which has no snackbar) parks the automatic scan for up to a day;
    // without a visible line it just silently stopped (review 2026-10-12).
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final latched = FakeSettings(apiKey: 'k', watcherDisclosureSeen: true)
      ..autoScanBlockedKind = 'rejectedKey'
      ..autoScanBlockedUntil = DateTime.now().add(const Duration(hours: 3));
    final intake = FakeIntake();
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: latched,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      photoIntake: intake,
      requestPhotoPermission: () async => true,
    )));
    expect(find.textContaining('rejected the API key'), findsNothing,
        reason: 'watcher off: nothing is paused');
    await tester.tap(find.byKey(const Key('watcherToggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('rejected the API key'), findsNWidgets(2),
        reason: 'the enable snackbar and the Photos footer');
    expect(intake.backfillScans, 0,
        reason: 'the latch means the sweep would upload for nothing');

    latched
      ..autoScanBlockedKind = 'regionBlocked'
      ..provider = 'openai';
    await tester.pumpWidget(_wrap(SettingsScreen(
      key: const Key('again'),
      settings: latched,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      photoIntake: intake,
      requestPhotoPermission: () async => true,
    )));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            'OpenAI is not available from this network region'),
        findsOneWidget);
  });

  testWidgets('first-run card shows only without a key, and the quota '
      'banner only while paused', (tester) async {
    final fresh = FakeSettings(apiKey: '');
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: fresh,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    expect(find.byKey(const Key('firstRunCard')), findsOneWidget);
    expect(find.textContaining('中国大陆用户'), findsOneWidget,
        reason: 'the mainland steer is the point of the card');
    expect(find.byKey(const Key('quotaPauseBanner')), findsNothing);
    // The card must not still name a button that no longer exists.
    expect(find.textContaining('Validate key'), findsNothing);

    final paused = FakeSettings(apiKey: 'k')
      ..isQuotaPaused = true
      ..quotaPauseUntil = DateTime(2026, 7, 31, 23, 30);
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: paused,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    expect(find.byKey(const Key('firstRunCard')), findsNothing);
    // The banner moved WITH the provider controls to the AI Provider
    // page; the root footer still states the pause in prose.
    await openProviderPage(tester);
    expect(find.byKey(const Key('quotaPauseBanner')), findsOneWidget);
  });

  testWidgets('the watcher toggle is ONE screen-reader stop: its name and '
      'its on/off state together', (tester) async {
    // Unmerged, VoiceOver stopped on 'Watch Camera Roll' and then on an
    // unnamed switch — the state was never read with its name.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: FakeSettings(apiKey: 'k', watcherEnabled: true),
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      photoIntake: FakeIntake(),
      requestPhotoPermission: () async => true,
    )));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.byKey(const Key('watcherToggle')));
    expect(node.label, contains('Watch Camera Roll'));
    expect(node, isSemantics(hasToggledState: true, isToggled: true));
    expect(find.bySemanticsLabel('Watch Camera Roll'), findsOneWidget,
        reason: 'one node, not a title node plus a nameless switch');
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('the Privacy Policy row opens the published policy',
      (tester) async {
    // App Store 5.1.1(i) / Google Play: the policy must be reachable from
    // inside the app.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final opened = <Uri>[];
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: FakeSettings(apiKey: 'k'),
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
      openUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    )));
    final row = find.byKey(const Key('privacyPolicyRow'));
    await tester.scrollUntilVisible(row, 200);
    expect(find.text('Privacy Policy'), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(opened, [privacyPolicyUri]);
    expect(privacyPolicyUri.toString(),
        'https://github.com/AkiyamaKunka/BiteWise/blob/main/docs/PRIVACY.md');
  });

  for (final (label, fails) in <(String, Future<bool> Function(Uri))>[
    ('returns false', (_) async => false),
    ('throws', (_) async => throw StateError('no browser')),
  ]) {
    testWidgets('a Privacy Policy launch that $label shows the address',
        (tester) async {
      // A phone with no browser (or one that refuses the launch) used to
      // get no reaction at all from the row.
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(SettingsScreen(
        settings: FakeSettings(apiKey: 'k'),
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        requestPhotoPermission: () async => true,
        openUrl: fails,
      )));
      final row = find.byKey(const Key('privacyPolicyRow'));
      await tester.scrollUntilVisible(row, 200);
      await tester.tap(row);
      await tester.pump();
      expect(
          find.text('Could not open the privacy policy. '
              'It is at $privacyPolicyUri'),
          findsOneWidget);
    });
  }

  test('the privacy-link notice names the address in Chinese too', () {
    expect(lookupAppLocalizations(const Locale('zh')).privacyOpenFailed('U'),
        '无法打开隐私政策，网址：U');
  });

  testWidgets('watcher toggle stays off when permission is denied',
      (tester) async {
    final settings =
        FakeSettings(watcherEnabled: false, watcherDisclosureSeen: true);

    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => false,
    )));

    await tester.tap(find.byKey(const Key('watcherToggle')));
    await tester.pumpAndSettle();

    expect(settings.watcherEnabled, isFalse);
    expect(
        find.text(
            'Photo library permission is required for automatic intake.'),
        findsOneWidget);
  });
}

// ── Claude OAuth re-connect flow (server provider) ──────────────────

Widget _serverWrap({
  required FakeSettings settings,
  required Future<({String? url, String? error})> Function() start,
  required Future<String?> Function(String) complete,
  required Future<bool> Function(Uri) openUrl,
}) =>
    MaterialApp(
        home: Scaffold(
            body: SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
      startClaudeAuth: start,
      completeClaudeAuth: complete,
      openUrl: openUrl,
    )));

void connectClaudeTests() {
  testWidgets('connect: opens the OFFICIAL url, collects code, completes',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k')..provider = 'server';
    final opened = <Uri>[];
    final completed = <String>[];
    await tester.pumpWidget(_serverWrap(
      settings: settings,
      start: () async =>
          (url: 'https://claude.ai/oauth/authorize?code=true', error: null),
      complete: (code) async {
        completed.add(code);
        return null;
      },
      openUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    ));

    await openSubscriptionPage(tester);
    await tester.tap(find.byKey(const Key('connectClaudeButton')));
    // Fixed pumps: the busy spinner animates while the dialog is up, so
    // pumpAndSettle would wait forever.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    // RFC 8252: the system browser got Anthropic's own page.
    expect(opened.single.host, 'claude.ai');
    expect(find.text('Finish connecting Claude'), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('claudeAuthCodeField')), ' abc#state ');
    await tester.tap(find.byKey(const Key('claudeAuthSubmit')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(completed.single, 'abc#state'); // trimmed
    expect(find.textContaining('Claude connected'), findsOneWidget);
  });

  testWidgets('connect: start failure surfaces the reason, no dialog',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k')..provider = 'server';
    await tester.pumpWidget(_serverWrap(
      settings: settings,
      start: () async => (url: null, error: 'the CLI did not produce a URL'),
      complete: (_) async => fail('must not be called'),
      openUrl: (_) async => fail('must not be called'),
    ));
    await openSubscriptionPage(tester);
    await tester.tap(find.byKey(const Key('connectClaudeButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not produce'), findsOneWidget);
    expect(find.text('Finish connecting Claude'), findsNothing);
  });

  testWidgets('connect: cancelling the dialog completes nothing',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k')..provider = 'server';
    var completions = 0;
    await tester.pumpWidget(_serverWrap(
      settings: settings,
      start: () async => (url: 'https://claude.ai/oauth/x', error: null),
      complete: (_) async {
        completions++;
        return null;
      },
      openUrl: (_) async => true,
    ));
    await openSubscriptionPage(tester);
    await tester.tap(find.byKey(const Key('connectClaudeButton')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(completions, 0);
  });

  testWidgets('button hidden off the server provider and without wiring',
      (tester) async {
    final settings = FakeSettings(); // gemini
    await tester.pumpWidget(_serverWrap(
      settings: settings,
      start: () async => (url: null, error: null),
      complete: (_) async => null,
      openUrl: (_) async => true,
    ));
    expect(find.byKey(const Key('connectClaudeButton')), findsNothing);
  });
}

void importExportTests() {
  testWidgets('import: a pasted export merges and reports what happened',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: FakeSettings(apiKey: 'k'),
      analyzer: FakeAnalyzer(),
      dao: dao,
      requestPhotoPermission: () async => true,
    )));
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('importField')),
        '{"format":"calorie_tracker_export","version":1,'
        '"exported_at":"2026-07-30T10:00:00.000",'
        '"tables":{"meals":[{"date":"2026-07-30"}]}}');
    await tester.tap(find.byKey(const Key('importConfirm')));
    await tester.pumpAndSettle();

    expect(dao.imported, hasLength(1));
    expect(find.textContaining('Imported 1 meal'), findsOneWidget);
  });

  testWidgets('import: a wrong file is REFUSED with a readable reason',
      (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: FakeSettings(apiKey: 'k'),
      analyzer: FakeAnalyzer(),
      dao: dao,
      requestPhotoPermission: () async => true,
    )));
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('importField')), 'my shopping list');
    await tester.tap(find.byKey(const Key('importConfirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('not JSON'), findsOneWidget);
  });

  testWidgets('import: cancelling after PASTING writes nothing', (tester) async {
    // Cancelling an EMPTY dialog proves nothing (an unconditional import
    // of '' would also leave dao.imported empty by throwing) — paste a
    // valid payload first, so only the Cancel path can explain the
    // silence (review 2026-07-31).
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dao = FakeDao();
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: FakeSettings(apiKey: 'k'),
      analyzer: FakeAnalyzer(),
      dao: dao,
      requestPhotoPermission: () async => true,
    )));
    await tester.tap(find.byKey(const Key('importButton')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('importField')),
        '{"format":"calorie_tracker_export","version":1,'
        '"tables":{"meals":[{"date":"2026-07-30"}]}}');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(dao.imported, isEmpty,
        reason: 'a pasted-but-cancelled payload must not be written');
    expect(find.textContaining('Imported'), findsNothing);
  });
}

// ─── Claude-plan model & effort choice (2026-08-05) ──────────────────

void planTuningTests() {
  Future<FakeSettings> pumpPlan(WidgetTester tester,
      {String backend = 'claude'}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeSettings(apiKey: 'k')
      ..provider = 'server'
      ..serverBackend = backend;
    await tester.pumpWidget(_wrap(SettingsScreen(
      settings: settings,
      analyzer: FakeAnalyzer(),
      dao: FakeDao(),
      requestPhotoPermission: () async => true,
    )));
    await openSubscriptionPage(tester);
    return settings;
  }

  testWidgets('the Claude plan offers model + effort; picks persist',
      (tester) async {
    final settings = await pumpPlan(tester);
    await tester.ensureVisible(find.byKey(const Key('planModelRow')));
    await tester.tap(find.byKey(const Key('planModelRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-model-haiku')));
    await tester.pumpAndSettle();
    expect(settings.serverModel, 'haiku');

    await tester.ensureVisible(find.byKey(const Key('planEffortRow')));
    await tester.tap(find.byKey(const Key('planEffortRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-effort-low')));
    await tester.pumpAndSettle();
    expect(settings.serverEffort, 'low');

    // Back to server default.
    await tester.tap(find.byKey(const Key('planModelRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-model-default')));
    await tester.pumpAndSettle();
    expect(settings.serverModel, '');
  });

  testWidgets('vendor plans hide the tuning rows entirely', (tester) async {
    await pumpPlan(tester, backend: 'glm');
    expect(find.byKey(const Key('planModelRow')), findsNothing,
        reason: 'GLM maps models server-side — offering a choice would '
            '400 every photo');
    expect(find.byKey(const Key('planEffortRow')), findsNothing);
  });

  group('daily summary switch (2026-10-10)', () {
    // Friends on the pre-08-16 APKs got a nightly card they never opted
    // into and could not stop short of muting the whole notification
    // channel (meal cards included) — which this screen then painted as a
    // fault with the red notifications-off remedy.
    Widget screen(FakeSettings settings) => _wrap(SettingsScreen(
          key: UniqueKey(),
          settings: settings,
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          requestPhotoPermission: () async => true,
          notificationsEnabled: () async => false,
          nextSummaryAt: () async => null,
          openSystemSettings: () async {},
        ));

    testWidgets(
        'off persists through the store and hides the time row, the '
        'armed-slot row and the notifications-off remedy', (tester) async {
      final settings = FakeSettings(apiKey: 'k');
      await tester.pumpWidget(screen(settings));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('summaryToggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      expect(find.byKey(const Key('reportTimeTile')), findsOneWidget);
      expect(find.byKey(const Key('nextSummaryRow')), findsOneWidget);
      expect(find.byKey(const Key('notificationsOffHint')), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(settings.summaryEnabled, isFalse, reason: 'persisted via update');
      expect(find.byKey(const Key('reportTimeTile')), findsNothing);
      expect(find.byKey(const Key('nextSummaryRow')), findsNothing);
      expect(find.byKey(const Key('notificationsOffHint')), findsNothing,
          reason: 'off is a choice, not a fault');
      expect(find.byKey(const Key('calorieGoalTile')), findsOneWidget,
          reason: 'the goal still drives the Today ring');

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(settings.summaryEnabled, isTrue);
      expect(find.byKey(const Key('reportTimeTile')), findsOneWidget);
    });

    testWidgets('a stored off shows the switch off from the first frame',
        (tester) async {
      await tester.pumpWidget(
          screen(FakeSettings(apiKey: 'k', summaryEnabled: false)));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('summaryToggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(find.byKey(const Key('reportTimeTile')), findsNothing);
      expect(find.byKey(const Key('notificationsOffHint')), findsNothing);
    });
  });

  group('next-summary row (2026-09-30)', () {
    // A fresh key per pump: the probe runs in initState, and a same-typed
    // widget at the same slot would otherwise keep the old State.
    Widget screen({Future<DateTime?> Function()? next}) =>
        _wrap(SettingsScreen(
          key: UniqueKey(),
          settings: FakeSettings(apiKey: 'k'),
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          requestPhotoPermission: () async => true,
          nextSummaryAt: next,
        ));

    testWidgets('shows the armed slot, today or tomorrow', (tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 21, 30);
      await tester.pumpWidget(screen(next: () async => today));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nextSummaryRow')), findsOneWidget);
      expect(find.textContaining('21:30'), findsOneWidget);
      expect(find.textContaining('Today'), findsOneWidget);
      final tomorrow = today.add(const Duration(days: 1));
      await tester.pumpWidget(screen(next: () async => tomorrow));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tomorrow'), findsOneWidget);
    });

    // 2026-10-09: on a first run the startup arm sits behind the
    // notification-permission dialog; di.dart makes the probe wait for the
    // arm, so the row must stay a neutral '…' while it is pending — never a
    // red 'Not scheduled' — and settle on the slot once the arm completes.
    testWidgets('a probe still waiting on the startup arm shows …, then slot',
        (tester) async {
      final now = DateTime.now();
      final slot = DateTime(now.year, now.month, now.day + 1, 21, 30);
      final armed = Completer<DateTime?>();
      await tester.pumpWidget(screen(next: () => armed.future));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('nextSummaryRow')), findsOneWidget);
      expect(find.text('…'), findsOneWidget);
      expect(find.textContaining('Not scheduled'), findsNothing);
      armed.complete(slot);
      await tester.pumpAndSettle();
      expect(find.text('…'), findsNothing);
      expect(find.textContaining('Not scheduled'), findsNothing);
      expect(find.textContaining('Tomorrow'), findsOneWidget);
      expect(find.textContaining('21:30'), findsOneWidget);
    });

    testWidgets('background-scan row: last OS launch, or "Not run yet"',
        (tester) async {
      Widget bg(Future<DateTime?> Function()? last) => _wrap(SettingsScreen(
            key: UniqueKey(),
            settings: FakeSettings(apiKey: 'k'),
            analyzer: FakeAnalyzer(),
            dao: FakeDao(),
            requestPhotoPermission: () async => true,
            lastBackgroundScan: last,
          ));
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day - 1, 14, 2);
      await tester.pumpWidget(bg(() async => yesterday));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backgroundScanRow')), findsOneWidget);
      expect(find.textContaining('Yesterday 14:02'), findsOneWidget);
      await tester.pumpWidget(bg(() async => null));
      await tester.pumpAndSettle();
      expect(find.text('Not run yet'), findsOneWidget);
      await tester.pumpWidget(bg(null));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backgroundScanRow')), findsNothing);
    });

    // 2026-10-10: iOS alone decides when BGAppRefresh launches the scan (a
    // few times a day), and swiping the app away in the app switcher stops
    // every launch until the next open — so a 后台扫描 time that stopped
    // advancing looked exactly like a bug. The Photos footer now says so:
    // on iOS only (Android's WorkManager survives a swipe-away), only
    // while the row is there, and not over the Off remedy.
    testWidgets('iOS: the Photos footer explains the OS cadence and force-quit',
        (tester) async {
      Widget bg({
        Future<DateTime?> Function()? last,
        bool refreshOn = true,
      }) =>
          _wrap(SettingsScreen(
            key: UniqueKey(),
            settings: FakeSettings(apiKey: 'k'),
            analyzer: FakeAnalyzer(),
            dao: FakeDao(),
            requestPhotoPermission: () async => true,
            lastBackgroundScan: last,
            backgroundRefreshEnabled: () async => refreshOn,
            openSystemSettings: () async {},
          ));
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day - 1, 14, 2);
      await tester.pumpWidget(bg(last: () async => yesterday));
      await tester.pumpAndSettle();
      expect(find.textContaining('Yesterday 14:02'), findsOneWidget);
      expect(find.textContaining('iOS decides when the background scan runs'),
          findsOneWidget);
      expect(find.textContaining('app switcher'), findsOneWidget);
      // The generic watcher sentence is still there, in the same footer.
      expect(find.textContaining('lookback window'), findsOneWidget);
      // Refresh off: the red 'Off' remedy is the explanation.
      await tester.pumpWidget(bg(last: () async => null, refreshOn: false));
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsOneWidget);
      expect(find.textContaining('app switcher'), findsNothing);
      // No probe → no row → nothing to explain.
      await tester.pumpWidget(bg());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('backgroundScanRow')), findsNothing);
      expect(find.textContaining('app switcher'), findsNothing);
      expect(find.textContaining('lookback window'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('Android: no force-quit note — WorkManager survives a swipe',
        (tester) async {
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day - 1, 14, 2);
      await tester.pumpWidget(_wrap(SettingsScreen(
        key: UniqueKey(),
        settings: FakeSettings(apiKey: 'k'),
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        requestPhotoPermission: () async => true,
        lastBackgroundScan: () async => yesterday,
        backgroundRefreshEnabled: () async => true,
        openSystemSettings: () async {},
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('Yesterday 14:02'), findsOneWidget);
      expect(find.textContaining('app switcher'), findsNothing);
      expect(find.textContaining('iOS decides'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('Background App Refresh off → the row becomes the remedy',
        (tester) async {
      // iOS refuses every BGTask request while the system switch (or Low
      // Power Mode) is off, and the plugin swallows the error: the row
      // must say so instead of "not run yet" forever.
      var opened = 0;
      await tester.pumpWidget(_wrap(SettingsScreen(
        key: UniqueKey(),
        settings: FakeSettings(apiKey: 'k'),
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        requestPhotoPermission: () async => true,
        lastBackgroundScan: () async => null,
        backgroundRefreshEnabled: () async => false,
        openSystemSettings: () async => opened++,
      )));
      await tester.pumpAndSettle();
      // Bare 'Off' (the red icon and chevron point to the remedy): 'Off in
      // Settings' cut the 'Background scan' title (row_fit_layout_test).
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Not run yet'), findsNothing);
      await tester.tap(find.byKey(const Key('backgroundScanRow')));
      await tester.pump();
      expect(opened, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    // 2026-10-10: on Android the same probe answers for the user-set 电池 ›
    // 受限 bucket (ActivityManager.isBackgroundRestricted), which parks the
    // periodic WorkManager job — the closed-app scan AND the nightly
    // summary — for days. Until now the row showed 'Not run yet' / a
    // frozen time with no hint and no link, exactly like a healthy phone.
    testWidgets('Android Restricted battery → "Restricted", tap opens App info',
        (tester) async {
      var opened = 0;
      await tester.pumpWidget(_wrap(SettingsScreen(
        key: UniqueKey(),
        settings: FakeSettings(apiKey: 'k'),
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        requestPhotoPermission: () async => true,
        lastBackgroundScan: () async => null,
        backgroundRefreshEnabled: () async => false,
        openSystemSettings: () async => opened++,
      )));
      await tester.pumpAndSettle();
      // Named after the switch the chevron leads to (App battery usage ›
      // Restricted), not iOS's 'Off'.
      expect(find.text('Restricted'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
      expect(find.text('Not run yet'), findsNothing);
      await tester.tap(find.byKey(const Key('backgroundScanRow')));
      await tester.pump();
      expect(opened, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('an unanswered Android probe keeps the plain row',
        (tester) async {
      // No channel (an older native build) → null: no remedy, no chevron,
      // the last-run time still shows.
      var opened = 0;
      await tester.pumpWidget(_wrap(SettingsScreen(
        key: UniqueKey(),
        settings: FakeSettings(apiKey: 'k'),
        analyzer: FakeAnalyzer(),
        dao: FakeDao(),
        requestPhotoPermission: () async => true,
        lastBackgroundScan: () async => null,
        backgroundRefreshEnabled: () async => null,
        openSystemSettings: () async => opened++,
      )));
      await tester.pumpAndSettle();
      expect(find.text('Not run yet'), findsOneWidget);
      expect(find.text('Restricted'), findsNothing);
      await tester.tap(find.byKey(const Key('backgroundScanRow')));
      await tester.pump();
      expect(opened, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('nothing armed → "Not scheduled"; no probe → no row',
        (tester) async {
      await tester.pumpWidget(screen(next: () async => null));
      await tester.pumpAndSettle();
      expect(find.text('Not scheduled'), findsOneWidget);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nextSummaryRow')), findsNothing);
    });
  });

  group('notifications-off remedy (2026-09-28)', () {
    // On iOS a declined notification permission makes every scheduled
    // daily summary vanish with no trace. The report section must say so
    // and offer the only fix, and must clear itself when the user comes
    // back from system settings.
    Widget screen({Future<bool?> Function()? enabled,
            Future<void> Function()? open}) =>
        _wrap(SettingsScreen(
          settings: FakeSettings(apiKey: 'k'),
          analyzer: FakeAnalyzer(),
          dao: FakeDao(),
          requestPhotoPermission: () async => true,
          notificationsEnabled: enabled,
          openSystemSettings: open,
        ));

    testWidgets('off → hint + system-settings button', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var opened = 0;
      await tester.pumpWidget(screen(
          enabled: () async => false, open: () async => opened++));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notificationsOffHint')), findsOneWidget);
      await tester.ensureVisible(
          find.byKey(const Key('notificationsOffOpenSettings')));
      await tester.tap(find.byKey(const Key('notificationsOffOpenSettings')));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('on, or unknown → no row', (tester) async {
      await tester.pumpWidget(screen(enabled: () async => true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notificationsOffHint')), findsNothing);
      await tester.pumpWidget(screen(enabled: () async => null));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notificationsOffHint')), findsNothing);
      await tester.pumpWidget(screen()); // not probed at all (tests/Android)
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notificationsOffHint')), findsNothing);
    });

    testWidgets('re-probes on resume and clears itself', (tester) async {
      var enabled = false;
      await tester.pumpWidget(screen(enabled: () async => enabled));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notificationsOffHint')), findsOneWidget);
      enabled = true; // the user flipped it in system settings…
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notificationsOffHint')), findsNothing);
    });

    testWidgets('a throwing probe keeps the row hidden', (tester) async {
      await tester.pumpWidget(
          screen(enabled: () async => throw StateError('no channel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notificationsOffHint')), findsNothing);
    });
  });
}
