/// App shell: Material 3 light+dark, Today / History / Settings navigation,
/// FAB → add flow. Also the startup-failure screen used by main.dart.
library;

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io' show File, Platform;

import '../core/ai_consent.dart' show aiConsentRoute, aiRoutesInMainlandChina;
import '../core/setup_link.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'package:flutter/material.dart';

import '../services/backup/backup_coordinator.dart';
import '../services/photo/background_time.dart' show appEngineInForeground;
import 'ai_consent.dart'
    show
        aiConsentCompanyName,
        aiConsentUpdateNeeded,
        askAiConsentUpdate,
        ensureAiConsent;
import 'background_glue.dart' show foregroundCatchUp;
import 'backup_sheets.dart';
import 'screens/add_flow.dart';
import 'screens/body_screen.dart';
import 'l10n.dart';
import 'theme/app_theme.dart';
import 'screens/history_screen.dart';
import 'screens/settings/provider_page.dart';
import 'screens/settings_screen.dart';
import 'screens/today_screen.dart';
import 'refresh_signal.dart';
import 'services.dart';
import 'widgets/restaurant_consent_sheet.dart';

class _AppleScrollBehavior extends MaterialScrollBehavior {
  const _AppleScrollBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}

class CalorieTrackerApp extends StatelessWidget {
  final UiServices services;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;
  const CalorieTrackerApp({super.key, required this.services, this.messengerKey});

  @override
  Widget build(BuildContext context) {
    // Design (run 7, theme/app_theme.dart): Apple's system neutrals for
    // every surface, the terracotta accent (#A64B2A light / #F2A07B dark),
    // iOS type sizes on the system fonts, depth from the page/cell tone
    // inversion instead of elevation. The restraint is deliberate: the
    // researched redesign backlashes (MFP 3.2→1.5 stars, Yazio "app for
    // children") all came from decoration and added friction, never from
    // calm. Macro identity hues are unaffected (contract).

    // ListenableBuilder: the language row writes settings, and the whole
    // app re-locales in place — no restart.
    final shell = HomeShell(services: services);
    Widget appFor(Locale? locale) {
      // Chinese text takes no Latin tracking (every letterSpacing 0).
      final cjk = (locale ?? WidgetsBinding.instance.platformDispatcher.locale)
              .languageCode ==
          'zh';
      return MaterialApp(
          title: 'Chopstats',
          scaffoldMessengerKey: messengerKey,
          // iOS scroll feel everywhere: bounce, no glow indicator.
          scrollBehavior: const _AppleScrollBehavior(),
          theme: AppTheme.build(Brightness.light, cjk: cjk),
          darkTheme: AppTheme.build(Brightness.dark, cjk: cjk),
          // iOS Increase Contrast: darker accent, labels and separators.
          highContrastTheme:
              AppTheme.build(Brightness.light, cjk: cjk, highContrast: true),
          highContrastDarkTheme:
              AppTheme.build(Brightness.dark, cjk: cjk, highContrast: true),
          themeMode: ThemeMode.system,
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          home: shell,
        );
    }

    final changes = services.settingsChanges;
    if (changes == null) {
      return appFor(localeForSetting(services.settings.appLanguage));
    }
    return ListenableBuilder(
      listenable: changes,
      builder: (context, _) =>
          appFor(localeForSetting(services.settings.appLanguage)),
    );
  }
}

class HomeShell extends StatefulWidget {
  final UiServices services;
  const HomeShell({super.key, required this.services});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  late int _index;
  final GlobalKey<TodayScreenState> _todayKey = GlobalKey<TodayScreenState>();
  // History sits in the IndexedStack, so its initState runs once at app
  // launch; reload it on tab selection or it shows launch-time data forever
  // (bug found by the e2e flow: meals logged after launch never appeared).
  final GlobalKey<HistoryScreenState> _historyKey =
      GlobalKey<HistoryScreenState>();
  final GlobalKey<BodyScreenState> _bodyKey = GlobalKey<BodyScreenState>();

  StreamSubscription<Uri>? _linkSub;

  /// Recipients whose consent sheet the user answered 'Not now' to in this
  /// session: the shell does not raise it again for them (Settings' paused
  /// row still does).
  final Set<String> _consentDeclined = {};
  bool _consentAsking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    mealsChangedSignal.addListener(_onMealsChanged);
    widget.services.restaurantAssist?.consentNeeded
        ?.addListener(_onConsentNeeded);
    // One-click setup: a bitewise://setup link (QR, adb, devicectl) lands
    // here whether the app was warm (stream) or cold (initial link).
    _linkSub = widget.services.setupLinks?.listen(_onSetupLink);
    // A photo shared into the app waits for the AI consent (5.1.2(i)); the
    // question needs this navigator, so the gate holds photos until now.
    widget.services.sharedPhotoConsent?.attach(_askShareConsent);
    final initial = widget.services.initialSetupLink;
    if (initial != null) {
      unawaited(initial().then((uri) {
        if (uri != null && mounted) _onSetupLink(uri);
      }, onError: (Object _) {}));
    }
    // Onboarding: with no API key yet, land on Settings first — unless this
    // install already logs meals by hand (no AI needed), where Settings on
    // every launch only cost a tap before + Log.
    final settings = widget.services.settings;
    _index =
        settings.apiKey.trim().isEmpty && !settings.mealLogged ? 3 : 0;
    // Debug-only: headless simulator screenshot runs force a tab by
    // dropping a one-byte file into the app's Documents dir (simctl has no
    // tap injection; env forwarding and HOME-derived paths both proved
    // unreliable). Async by necessity — a forced tab pops in a frame after
    // first build, which screenshot runs don't care about. Inert in release
    // builds and when the file is absent.
    if (kDebugMode) {
      unawaited(getApplicationDocumentsDirectory().then((dir) {
        final f = File('${dir.path}/ct_debug_tab');
        if (!f.existsSync() || !mounted) return;
        final raw = f.readAsStringSync().trim();
        // '3p' = Settings tab + push the provider page (screenshot runs).
        final push = raw.endsWith('p');
        final forced = int.tryParse(push ? raw.substring(0, raw.length - 1) : raw);
        if (forced != null && forced >= 0 && forced <= 3) {
          setState(() => _index = forced);
          if (push && forced == 3) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final s = widget.services;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProviderSettingsPage(
                  settings: s.settings,
                  analyzer: s.analyzer,
                  startClaudeAuth: s.startClaudeAuth,
                  completeClaudeAuth: s.completeClaudeAuth,
            serverLoginState: s.serverLoginState,
                ),
              ));
            });
          }
        }
      }, onError: (Object _) {}));
    }
    // The consent text changed what is sent since the current recipient
    // was allowed: asked once, over the first frame.
    _askConsentUpdateWhenIdle();
    // iCloud Backup (iPhone, 1.7.0): starts after the first frame (the
    // database is open by then: init opened it); its notice and restore
    // offer are asked here, one question at a time.
    final backup = widget.services.cloudBackup;
    if (backup != null) {
      backup.prompt.addListener(_onBackupPrompt);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(backup.start().then((_) {}, onError: (Object _) {}));
      });
    }
  }

  /// The backup question being asked, so it is asked once.
  BackupPrompt? _backupAsking;

  /// iCloud Backup asks (the notice, or a restore offer): like the
  /// consent update, only over the shell itself with nothing on top, and
  /// after the consent-update question. A later prompt change or a return
  /// to the app asks again if it could not now.
  void _onBackupPrompt() {
    final backup = widget.services.cloudBackup;
    final prompt = backup?.prompt.value;
    if (backup == null || prompt == null || !mounted) return;
    if (identical(_backupAsking, prompt)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || backup.prompt.value != prompt) return;
      if (_backupAsking != null) return;
      await _consentUpdateAnswered();
      if (!mounted || backup.prompt.value != prompt) return;
      if (Navigator.maybeOf(context)?.canPop() ?? false) return;
      _backupAsking = prompt;
      try {
        switch (prompt) {
          case NoticePrompt():
            await showBackupNotice(context, backup);
          case RestoreOfferPrompt(:final candidate, :final localMeals):
            await showRestoreOffer(context, backup, candidate, localMeals);
        }
      } finally {
        _backupAsking = null;
      }
      // Answering one may raise the next (the notice after a restore).
      if (mounted && backup.prompt.value != null &&
          !identical(backup.prompt.value, prompt)) {
        _onBackupPrompt();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// The share gate's question: true = allowed (and saved). Not now says
  /// that the shared photo was not analyzed.
  Future<bool> _askShareConsent() async {
    if (!mounted) return false;
    return ensureAiConsent(context, widget.services.settings,
        declined: context.l10n.shareConsentDeclined);
  }

  /// The consent-update question while it is open: a setup link that
  /// lands meanwhile waits for its answer ([_consentUpdateAnswered]).
  Future<bool>? _consentUpdate;

  /// Set once the app really left the screen (hidden / paused), so the
  /// inactive → resumed around an iOS system alert is not a return.
  bool _leftApp = false;

  /// On a launch or a return to the app: asks once more for the current
  /// recipient when the consent text changed what is sent since it was
  /// allowed (aiConsentUpdateNeeded — never without a key or a grant).
  /// One question at a time, and only over the shell itself: never on top
  /// of the setup-link or shared-photo question, another dialog or a
  /// screen — a later return asks instead.
  void _askConsentUpdateWhenIdle() {
    if (_consentUpdate != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _consentUpdate != null) return;
      final settings = widget.services.settings;
      if (!aiConsentUpdateNeeded(settings)) return;
      // Nothing on top: asked through the navigator, not ModalRoute.of —
      // that makes the shell depend on its route, and every push and pop
      // over it then rebuilt the shell and its selected tab.
      if (Navigator.maybeOf(context)?.canPop() ?? false) return;
      final asked = _consentUpdate = askAiConsentUpdate(context, settings);
      asked.whenComplete(() => _consentUpdate = null).ignore();
    });
    // A post-frame callback alone waits for SOME frame; ask for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _consentUpdateAnswered() async {
    try {
      await _consentUpdate;
    } catch (_) {
      // A failed question is no answer; the link goes on.
    }
  }

  @override
  void dispose() {
    widget.services.cloudBackup?.prompt.removeListener(_onBackupPrompt);
    widget.services.sharedPhotoConsent?.detach(_askShareConsent);
    _linkSub?.cancel();
    mealsChangedSignal.removeListener(_onMealsChanged);
    widget.services.restaurantAssist?.consentNeeded
        ?.removeListener(_onConsentNeeded);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The last setup link handled, and when: app_links' stream also
  /// carries the link that cold-started the app, which the initial-link
  /// read already delivered — one link, one confirmation.
  ({String uri, DateTime at})? _lastSetupLink;

  /// A setup link arrived. Never applied silently: a crafted link could
  /// point every future photo upload at a stranger's server, so the user
  /// sees exactly what it names and confirms with one tap.
  Future<void> _onSetupLink(Uri uri) async {
    // Not ours at all — e.g. the share extension's ShareMedia-<bundle>:share
    // bounce on iOS, which app_links also forwards — is ignored silently.
    // Only a malformed bitewise:// link earns the "not valid" message.
    if (!isSetupLinkScheme(uri)) return;
    final now = DateTime.now();
    final text = uri.toString();
    final last = _lastSetupLink;
    if (last != null &&
        last.uri == text &&
        now.difference(last.at) < setupLinkRepeatWindow) {
      return;
    }
    _lastSetupLink = (uri: text, at: now);
    final l = context.l10n;
    final link = parseSetupLink(uri);
    if (link == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.setupLinkInvalid)));
      return;
    }
    // One question at a time: the consent-update one answers first.
    await _consentUpdateAnswered();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.l10n.setupLinkTitle),
        // The plan is named with the same words the Settings row shows
        // after confirming (Claude 订阅 / Claude Plan), not the raw id
        // 'claude' the link carries; the id itself is what gets saved.
        // Confirming is also the AI consent for this plan (5.1.2(i)), so the
        // dialog names the company the server passes the data to.
        content: SingleChildScrollView(
          child: Text([
            ctx.l10n.setupLinkBody(
                link.server,
                providerDisplayLabel(ctx.l10n, 'server', link.backend),
                link.keyTail),
            ctx.l10n.setupLinkSharing(aiConsentCompanyName(ctx.l10n,
                provider: 'server', serverBackend: link.backend)),
            // The same mainland-China note the consent dialog adds: this
            // confirmation IS the consent for the plan (GLM, Doubao).
            if (aiRoutesInMainlandChina
                .contains(aiConsentRoute('server', link.backend)))
              ctx.l10n.aiConsentChinaNote(aiConsentCompanyName(ctx.l10n,
                  provider: 'server', serverBackend: link.backend)),
          ].join('\n\n')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('setupLinkConfirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.setupLinkConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final s = widget.services.settings;
    // The confirmation named the plan's AI company: it is the consent for
    // that recipient, saved before anything can be sent to it.
    await s.setAiConsent(aiConsentRoute('server', link.backend),
        granted: true);
    // Provider FIRST: the store routes apiKey to the active provider's slot.
    await s.update(
        provider: 'server',
        serverBackend: link.backend,
        serverBaseUrl: link.server);
    await s.update(apiKey: link.key);
    if (!mounted) return;
    setState(() => _index = 3); // land on Settings, where the result shows
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l.setupLinkDone)));
  }

  /// The restaurant assist paused for a consent that does not name the
  /// recipient a lookup would reach now (another provider or server, design
  /// R7a): the consent sheet, once per recipient per session, and only over
  /// the shell itself — never on top of the editor or another screen (the
  /// assist asks again on its next sweep).
  void _onConsentNeeded() {
    final controls = widget.services.restaurantAssist;
    final support = controls?.consentNeeded?.value;
    if (controls == null || support == null || !mounted) return;
    final settings = widget.services.settings;
    if (settings.restaurantAssist == 'off') return;
    if (_consentAsking || _consentDeclined.contains(support.recipientStamp)) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _consentAsking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
        // Answered meanwhile (in Settings, say), or turned off: nothing to ask.
        if (settings.restaurantAssist == 'off' ||
            restaurantConsentCovers(settings, controls.lookupSupport())) {
          return;
        }
        final choice = await askRestaurantConsent(context,
            settings: settings,
            controls: controls,
            kind: RestaurantConsentKind.recipientChanged);
        if (choice == null) _consentDeclined.add(support.recipientStamp);
      } finally {
        _consentAsking = false;
      }
    });
    // A post-frame callback alone waits for SOME frame; ask for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// A meal was saved somewhere in the app (watcher, catch-up, coverage
  /// screen). Re-query the data tabs so what's on screen matches the DB.
  void _onMealsChanged() {
    if (!mounted) return;
    _todayKey.currentState?.reload();
    _historyKey.currentState?.reload();
    final settings = widget.services.settings;
    if (!settings.mealLogged) {
      unawaited(settings.markMealLogged().then((_) {}, onError: (Object _) {}));
    }
    // A change worth backing up (debounced by the coordinator).
    widget.services.cloudBackup?.noteChange();
    // iOS: a meal just landed (pipeline / share sheet) — the pending OS card
    // must carry it even if the user stays in the app through the slot.
    final rearm = widget.services.refreshDailyNotification;
    if (rearm != null) {
      unawaited(rearm().then((_) {}, onError: (Object _) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final s = widget.services;
    // iOS: whatever the user last saw is what the OS will deliver at the
    // slot — re-arm on EVERY transition (pause included: that is the last
    // moment content can still change before the app is suspended).
    final rearm = s.refreshDailyNotification;
    if (rearm != null) {
      unawaited(rearm().then((_) {}, onError: (Object _) {}));
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _leftApp = true;
      // iCloud Backup's background-entry run (inside a background task).
      s.cloudBackup?.onLifecycle(false);
    }
    if (state != AppLifecycleState.resumed) return;
    if (_leftApp) {
      _leftApp = false;
      _askConsentUpdateWhenIdle();
      s.cloudBackup?.onLifecycle(true);
      _onBackupPrompt();
    }
    // The background job may have logged meals while we were away — the
    // IndexedStack keeps stale screens alive, so refresh them now.
    _todayKey.currentState?.reload();
    if (_index == 1) _historyKey.currentState?.reload();
    if (!s.settings.watcherEnabled) return;
    unawaited(_resumeCatchUp());
  }

  Future<void> _resumeCatchUp() async {
    final s = widget.services;
    // The background run (its own isolate and preferences cache) may have
    // latched the automatic scan on a rejected key / blocked region while
    // we were away — or an analysis there may have lifted it.
    try {
      await s.settings.reloadAutoScanBlock();
    } catch (_) {}
    // One predicate for "an automatic analysis could succeed" (key, no
    // quota latch, no rejected-key/region latch): don't read photo bytes
    // for nothing.
    if (!mounted || !s.settings.canAutoAnalyze) return;
    // Resume catch-up (full lookback window): the change-notify watcher is
    // frozen with the process on EMUI-class OSes, so photos taken while the
    // app was backgrounded surface here. The md5 ledger + in-session seen
    // set make repeat resumes near-free. Refresh again once the scan's
    // emissions have had a chance to process. What it covers moves the
    // background watermark too (foregroundCatchUp). iOS: it reads no more
    // photos once the user leaves again.
    final intake = s.photoIntake;
    if (intake == null) return;
    // iCloud Backup: a restore offer is open or a restore runs (answered
    // once a look for a backup to offer that is running decided); the next
    // return to the app catches up. One running stops before its next
    // photo once an offer or a restore holds it.
    final backup = s.cloudBackup;
    if (await backup?.holdsCatchUp() ?? false) return;
    await foregroundCatchUp(intake,
            shouldContinue: Platform.isIOS
                ? () =>
                    appEngineInForeground() &&
                    !(backup?.holdsCatchUpNow ?? false)
                : null)
        .then((_) {}, onError: (Object _) {})
        .then((_) => Future<void>.delayed(const Duration(seconds: 15)))
        .then((_) {
      if (!mounted) return;
      _todayKey.currentState?.reload();
      if (_index == 1) _historyKey.currentState?.reload();
    });
  }

  /// The tab widgets as last placed in the IndexedStack.
  List<Widget>? _tabs;

  /// Only the SELECTED tab gets this build's widget; the hidden ones keep
  /// their last one, which Flutter then skips. A tab tap used to rebuild
  /// all four screens, the hidden Body one re-deriving its whole history
  /// each time. The selected tab still rebuilds in the tap frame, so what
  /// it reads while building (the units preference, Settings' Today /
  /// Tomorrow labels) is current the moment it shows; hidden tabs still
  /// follow their own theme, locale and text-size dependencies.
  List<Widget> _onlySelectedRebuilds(List<Widget> fresh) {
    final kept = _tabs;
    return _tabs = [
      for (var i = 0; i < fresh.length; i++)
        i == _index || kept == null || kept.length != fresh.length
            ? fresh[i]
            : kept[i],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return Scaffold(
      // No shared AppBar: each tab renders its own iOS-style large title
      // that collapses as it scrolls (SliverAppBar.large).
      body: IndexedStack(
        index: _index,
        children: _onlySelectedRebuilds([
          TodayScreen(
              key: _todayKey,
              dao: s.dao,
              thumbs: s.thumbs,
              garminDaily: s.garminDaily,
              mealInUse: s.mealInUse,
              restaurantAssist: s.restaurantAssist,
              settings: s.settings,
              usual: s.usualFoods),
          HistoryScreen(
              key: _historyKey,
              dao: s.dao,
              thumbs: s.thumbs,
              mealInUse: s.mealInUse,
              restaurantAssist: s.restaurantAssist,
              settings: s.settings),
          BodyScreen(key: _bodyKey, dao: s.dao, settings: s.settings),
          SettingsScreen(
            settings: s.settings,
            analyzer: s.analyzer,
            dao: s.dao,
            requestPhotoPermission: s.requestPhotoPermission,
            photoIntake: s.photoIntake,
            coverage: s.coverage,
            processPhoto: s.processPhoto,
            photoLibrary: s.photoLibrary,
            startClaudeAuth: s.startClaudeAuth,
            completeClaudeAuth: s.completeClaudeAuth,
            serverLoginState: s.serverLoginState,
            openSystemSettings: s.openSystemSettings,
            notificationsEnabled: s.notificationsEnabled,
            nextSummaryAt: s.nextSummaryAt,
            lastBackgroundScan: s.lastBackgroundScan,
            backgroundRefreshEnabled: s.backgroundRefreshEnabled,
            backgroundScanStuck: s.backgroundScanStuck,
            changes: s.settingsChanges,
            restaurantAssist: s.restaurantAssist,
            cloudBackup: s.cloudBackup,
            androidBackupNote: Platform.isAndroid,
            onImported: () {
              s.thumbs?.clear();
              signalMealsChanged();
            },
          ),
        ]),
      ),
      // The + 记录 button is a REAL Scaffold FAB (Today tab only — Body has
      // its own), so Material lifts it above this messenger's snackbars.
      // Until 2026-10-12 it was a Positioned inside TodayScreen, kept out
      // of the Scaffold so it would not cover the chat box's send button
      // (the chat box went 2026-07-31) — and every snackbar covered IT.
      floatingActionButton: _index == 0
          ? FloatingActionButton.extended(
              key: const Key('addMealFab'),
              // The SIGNAL, not a Today-only reload: the fix/delete,
              // describe, manual and leftover paths write meals directly,
              // and on iOS the pending OS card must be re-armed with them
              // (_onMealsChanged reloads Today + History and re-arms).
              onPressed: () => openAddFlow(context, s,
                  onChanged: () async => signalMealsChanged()),
              icon: const Icon(Icons.add),
              label: Text(context.l10n.fabLog),
            )
          : null,
      bottomNavigationBar: _TopHairline(child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          // BOTH data tabs reload on selection. They live in an IndexedStack,
          // so their state survives tab switches — and a meal logged while
          // the app was open (watcher, background job, or the launch/resume
          // catch-up) is invisible on a screen built before it existed. That
          // is exactly how a 07:40 latte, correctly analyzed and saved at
          // 18:06, stayed missing from Today until a manual pull-to-refresh
          // (real report, 2026-07-26).
          if (i == 0) _todayKey.currentState?.reload();
          if (i == 1) _historyKey.currentState?.reload();
          if (i == 2) _bodyKey.currentState?.reload();
          // The backup's upload state for the status line.
          final backup = s.cloudBackup;
          if (i == 3 && backup != null) unawaited(backup.refresh());
        },
        destinations: [
          NavigationDestination(
              icon: const Icon(Icons.today_outlined),
              selectedIcon: const Icon(Icons.today),
              label: context.l10n.tabToday),
          NavigationDestination(
              icon: const Icon(Icons.history),
              label: context.l10n.tabHistory),
          NavigationDestination(
              icon: const Icon(Icons.monitor_weight_outlined),
              selectedIcon: const Icon(Icons.monitor_weight),
              label: context.l10n.tabBody),
          NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: context.l10n.tabSettings),
        ],
      )),
    );
  }
}

/// The tab bar's top edge: one physical-pixel separator line, painted
/// OVER the bar (the bar's own Material would cover a background line).
class _TopHairline extends StatelessWidget {
  const _TopHairline({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
                color: context.colors.separator,
                width: 1 / MediaQuery.devicePixelRatioOf(context)),
          ),
        ),
        child: child,
      );
}

/// Shown when async startup (settings → dao → services) throws.
class StartupErrorApp extends StatefulWidget {
  final String error;

  /// Another startup attempt; run on resume and from the Retry button.
  final Future<void> Function()? onRetry;
  const StartupErrorApp({super.key, required this.error, this.onRetry});

  @override
  State<StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends State<StartupErrorApp>
    with WidgetsBindingObserver {
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _retry();
  }

  Future<void> _retry() async {
    final retry = widget.onRetry;
    if (retry == null || _retrying) return;
    _retrying = true;
    try {
      await retry(); // success replaces this whole app via runApp
    } finally {
      if (mounted) _retrying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // No AppLocalizations exists yet when startup fails, so the two lines
    // follow the phone's language directly.
    final zh =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    return MaterialApp(
      title: 'Chopstats',
      theme: AppTheme.build(Brightness.light, cjk: zh),
      darkTheme: AppTheme.build(Brightness.dark, cjk: zh),
      themeMode: ThemeMode.system,
      home: Builder(builder: (context) {
        final text = Theme.of(context).textTheme;
        final colors = context.colors;
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.error_outline_rounded,
                        size: 44, color: colors.secondaryLabel),
                  ),
                  const SizedBox(height: 12),
                  Text(zh ? '筷拍无法启动。' : 'Chopstats could not start.',
                      textAlign: TextAlign.center, style: text.titleMedium),
                  const SizedBox(height: 8),
                  Text(widget.error,
                      textAlign: TextAlign.center,
                      style: text.bodySmall
                          ?.copyWith(color: colors.secondaryLabel)),
                  if (widget.onRetry != null) ...[
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('startupRetry'),
                      onPressed: _retry,
                      child: Text(zh ? '重试' : 'Retry'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
