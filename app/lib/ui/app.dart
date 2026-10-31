/// App shell: Material 3 light+dark, Today / History / Settings navigation,
/// FAB → add flow. Also the startup-failure screen used by main.dart.
library;

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io' show File, Platform;

import '../core/ai_consent.dart' show aiConsentRoute;
import '../core/setup_link.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

import 'package:flutter/material.dart';

import '../services/photo/background_time.dart' show appEngineInForeground;
import 'ai_consent.dart' show aiConsentCompanyName, ensureAiConsent;
import 'background_glue.dart' show foregroundCatchUp;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    mealsChangedSignal.addListener(_onMealsChanged);
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
    // Onboarding: with no API key yet, land on Settings first.
    _index = widget.services.settings.apiKey.trim().isEmpty ? 3 : 0;
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
  }

  /// The share gate's question: true = allowed (and saved). Not now says
  /// that the shared photo was not analyzed.
  Future<bool> _askShareConsent() async {
    if (!mounted) return false;
    return ensureAiConsent(context, widget.services.settings,
        declined: context.l10n.shareConsentDeclined);
  }

  @override
  void dispose() {
    widget.services.sharedPhotoConsent?.detach(_askShareConsent);
    _linkSub?.cancel();
    mealsChangedSignal.removeListener(_onMealsChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A setup link arrived. Never applied silently: a crafted link could
  /// point every future photo upload at a stranger's server, so the user
  /// sees exactly what it names and confirms with one tap.
  Future<void> _onSetupLink(Uri uri) async {
    // Not ours at all — e.g. the share extension's ShareMedia-<bundle>:share
    // bounce on iOS, which app_links also forwards — is ignored silently.
    // Only a malformed bitewise:// link earns the "not valid" message.
    if (!isSetupLinkScheme(uri)) return;
    final l = context.l10n;
    final link = parseSetupLink(uri);
    if (link == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.setupLinkInvalid)));
      return;
    }
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

  /// A meal was saved somewhere in the app (watcher, catch-up, coverage
  /// screen). Re-query the data tabs so what's on screen matches the DB.
  void _onMealsChanged() {
    if (!mounted) return;
    _todayKey.currentState?.reload();
    _historyKey.currentState?.reload();
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
    if (state != AppLifecycleState.resumed) return;
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
    await foregroundCatchUp(intake,
            shouldContinue: Platform.isIOS ? appEngineInForeground : null)
        .then((_) {}, onError: (Object _) {})
        .then((_) => Future<void>.delayed(const Duration(seconds: 15)))
        .then((_) {
      if (!mounted) return;
      _todayKey.currentState?.reload();
      if (_index == 1) _historyKey.currentState?.reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return Scaffold(
      // No shared AppBar: each tab renders its own iOS-style large title
      // that collapses as it scrolls (SliverAppBar.large).
      body: IndexedStack(
        index: _index,
        children: [
          TodayScreen(
              key: _todayKey,
              dao: s.dao,
              executor: s.executor,
              thumbs: s.thumbs,
              garminDaily: s.garminDaily),
          HistoryScreen(key: _historyKey, dao: s.dao, thumbs: s.thumbs),
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
          ),
        ],
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
