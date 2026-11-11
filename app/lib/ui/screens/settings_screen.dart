/// Onboarding/Settings (spec §8 knobs), in six section builders: AI
/// provider + key + curated model picker + one "Test this provider"
/// action (the diagnostics page), photo intake (watcher, coverage audit,
/// backfill window), daily-report time, dietary profile, and the data
/// section (export to a file, import by merge — settings/data_section.dart).
/// Restaurant nutrition (design R7a) is its own widget,
/// settings/restaurant_section.dart, shown when the app wires the assist.
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../core/contracts.dart';
import '../../services/backup/backup_coordinator.dart';

import '../../services/analyzer/platform_decode.dart';
import '../../services/photo/coverage.dart';
import '../../services/photo/photo_library.dart';
import '../ai_consent.dart';
import '../photo_pipeline.dart';
import '../outcome_text.dart' show autoScanPausedLine, dayTimeLabel;
import '../restaurant_assist_controls.dart';
import '../widgets/restaurant_consent_sheet.dart'
    show restaurantAssistStopFor, stopRestaurantAssistFor;
import '../services.dart';
import '../l10n.dart';
import '../widgets/grouped.dart';
import '../../services/settings/app_settings.dart' show maxDailyGoalKcal;
import '../app_formats.dart';
import '../format.dart' show formatKcal;
import '../large_text.dart';
import '../theme/app_dialog.dart';
import '../theme/app_theme.dart' show AppButtonStyles;
import '../theme/tokens.dart';
import '../widgets/pickers.dart';
import 'settings/settings_kit.dart' show showChoiceSheet;
import 'coverage_screen.dart';
import 'meal_editor_screen.dart';
import 'settings/data_section.dart';
import 'settings/profile_page.dart';
import 'settings/provider_page.dart';
import 'settings/restaurant_section.dart';

/// The published privacy policy (docs/PRIVACY.md in the public repo).
/// App Store guideline 5.1.1(i) and Google Play both want it reachable
/// from inside the app, not only on the store listing.
final Uri privacyPolicyUri = Uri.parse(
    'https://github.com/AkiyamaKunka/Chopstats/blob/main/docs/PRIVACY.md');

/// How long a snackbar that carries an action stays up.
const _actionSnackBarDuration = Duration(seconds: 8);

/// `SnackBar.persist` for a snackbar that may carry an action.
///
/// Left unset it is `action != null` (Flutter 3.44): the snackbar ignores
/// its `duration`, stays until it is pressed or swiped, and every later
/// snackbar queues unseen behind it. A flat `false` goes too far the other
/// way — it also times out under VoiceOver / TalkBack, where a screen
/// reader user needs longer than that to reach the button. So: hold it
/// only there, and only when there is a button to reach.
bool _holdForScreenReader(BuildContext context, {required bool hasAction}) =>
    hasAction && MediaQuery.accessibleNavigationOf(context);

class SettingsScreen extends StatefulWidget {
  final SettingsStore settings;
  final AnalyzerService analyzer;
  final MealsDao dao;
  final Future<bool> Function() requestPhotoPermission;
  final PhotoIntake? photoIntake; // started/stopped on watcher toggle

  /// Claude OAuth re-connect (server provider). Nulls in tests hide the
  /// button; [openUrl] is injectable so widget tests need no url_launcher.
  final Future<({String? url, String? error})> Function()? startClaudeAuth;
  final Future<String?> Function(String code)? completeClaudeAuth;
  final Future<String?> Function()? serverLoginState;
  final Future<bool> Function(Uri url)? openUrl;

  /// Opens the OS app-settings page — the only remedy once the system
  /// stops re-showing the photo-permission dialog. Null hides the action.
  final Future<void> Function()? openSystemSettings;

  /// Whether the OS will deliver notifications; null = unknown / not
  /// probed (tests). False surfaces the daily-summary remedy row.
  final Future<bool?> Function()? notificationsEnabled;

  /// The slot the daily summary is armed for; null = nothing armed. A
  /// null PROBE hides the row (tests, older wiring).
  final Future<DateTime?> Function()? nextSummaryAt;

  /// When the OS last launched the background photo scan; null = never.
  /// A null PROBE hides the row.
  final Future<DateTime?> Function()? lastBackgroundScan;

  /// Whether the OS still launches the background scan: iOS Background App
  /// Refresh, or on Android not the user-set 电池 › 受限 bucket. False
  /// turns the background-scan row into the remedy (opens system settings).
  final Future<bool?> Function()? backgroundRefreshEnabled;

  /// Whether the recorded background runs say the scan is stuck: the row
  /// turns red and the Photos footer says to open the app once.
  final Future<bool> Function()? backgroundScanStuck;

  /// Coverage-audit pieces; all three null in tests → the tile is hidden.
  final CoverageAuditor? coverage;
  final Future<PhotoOutcome> Function(IntakePhoto photo)? processPhoto;
  final PhotoLibrary? photoLibrary;

  /// Fires when settings change (AppServices.settingsChanges). The app
  /// shell's rebuild keeps this same screen instance, so without listening
  /// the Photos footer showed a pause armed or lifted mid-view only after
  /// a tab switch (API 35 emulator, 2026-10-12). Null in most tests.
  final Listenable? changes;

  /// The restaurant assist (design R7a): its Settings group and consent
  /// sheets. Null hides the group (most tests).
  final RestaurantAssistControls? restaurantAssist;

  /// iCloud Backup's rows in Your Data (iPhone). Null hides them.
  final BackupCoordinator? cloudBackup;

  /// Android: Your Data's footer explains Android's own backup.
  final bool androidBackupNote;

  /// After an import added rows (the screens reload, thumbnails refetch).
  final VoidCallback? onImported;

  const SettingsScreen({
    super.key,
    required this.settings,
    required this.analyzer,
    required this.dao,
    required this.requestPhotoPermission,
    this.photoIntake,
    this.coverage,
    this.processPhoto,
    this.photoLibrary,
    this.startClaudeAuth,
    this.completeClaudeAuth,
    this.serverLoginState,
    this.openUrl,
    this.openSystemSettings,
    this.notificationsEnabled,
    this.nextSummaryAt,
    this.lastBackgroundScan,
    this.backgroundRefreshEnabled,
    this.backgroundScanStuck,
    this.changes,
    this.restaurantAssist,
    this.cloudBackup,
    this.androidBackupNote = false,
    this.onImported,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _profileController;
  late int _lookbackDays;
  late String _reportTime;
  late bool _summaryEnabled;
  late bool _watcherEnabled;
  late bool _watchGlasses;

  /// True only when the OS says notifications are OFF for this app. On iOS
  /// a declined permission makes every scheduled summary vanish silently,
  /// so the report section says so and offers the only remedy (system
  /// settings). Unknown/null keeps the row hidden.
  bool _notificationsOff = false;

  /// The armed daily-summary slot; null once probed = nothing armed.
  DateTime? _nextSummary;
  bool _nextSummaryProbed = false;

  /// The OS's last background launch; null once probed = never ran.
  DateTime? _lastBackgroundScan;
  bool _lastBackgroundProbed = false;

  /// True only when the OS says the background scan cannot launch: iOS
  /// Background App Refresh off, or Android's 电池 › 受限 bucket.
  bool _backgroundRefreshOff = false;

  /// The recorded runs show no progress (backgroundScanLooksStuck).
  bool _backgroundStuck = false;

  final GlobalKey<RestaurantAssistSectionState> _restaurantKey =
      GlobalKey<RestaurantAssistSectionState>();

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_onSettingsChanged);
    final s = widget.settings;
    _profileController = TextEditingController(text: s.dietaryProfile);
    _lookbackDays = s.lookbackDays.clamp(1, 30); // spec §6.4 range
    _reportTime = s.reportTime.isEmpty ? '21:00' : s.reportTime;
    _summaryEnabled = s.summaryEnabled;
    _watcherEnabled = s.watcherEnabled;
    _watchGlasses = s.watchGlasses;
    WidgetsBinding.instance.addObserver(this);
    _probeNotifications();
    _probeNextSummary();
    _probeBackgroundScan();
    _probePhotoAccess();
  }

  Future<void> _probeBackgroundScan() async {
    final probe = widget.lastBackgroundScan;
    if (probe == null) return;
    DateTime? when;
    bool? refresh;
    var stuck = false;
    try {
      when = await probe();
      refresh = await widget.backgroundRefreshEnabled?.call();
      stuck = await widget.backgroundScanStuck?.call() ?? false;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _lastBackgroundScan = when;
      _lastBackgroundProbed = true;
      _backgroundRefreshOff = refresh == false;
      _backgroundStuck = stuck;
    });
  }

  /// "Next summary: today 21:30" — or "not scheduled", which is the whole
  /// point: on iOS the card is armed ahead of time, and a phone that shows
  /// nothing at the slot should be able to say WHY in Settings.
  Future<void> _probeNextSummary() async {
    final probe = widget.nextSummaryAt;
    if (probe == null) return;
    DateTime? when;
    try {
      when = await probe();
    } catch (_) {
      return; // unknown: leave the row as it was
    }
    if (!mounted) return;
    setState(() {
      _nextSummary = when;
      _nextSummaryProbed = true;
    });
  }

  String _nextSummaryLabel(DateTime? when) =>
      when == null ? context.l10n.nextSummaryNone : _dayTime(when);

  String _lastBackgroundLabel(DateTime? when) =>
      when == null ? context.l10n.backgroundScanNever : _dayTime(when);

  /// The remedy value, worded after the switch the chevron leads to: iOS
  /// 'Off' (Background App Refresh), Android 'Restricted' (App battery
  /// usage). Both short — 'Off in Settings' once cut the English title.
  String _backgroundOffLabel() =>
      defaultTargetPlatform == TargetPlatform.android
          ? context.l10n.backgroundScanRestricted
          : context.l10n.backgroundScanDisabled;

  /// "Today 21:30" / "Tomorrow 07:00" / "Yesterday 14:02" / "09-28 14:02".
  String _dayTime(DateTime when) => dayTimeLabel(context.l10n, when);

  /// Re-probe on resume: the user comes BACK from system settings to this
  /// very screen (it lives in the IndexedStack), so the row must clear
  /// itself without a restart.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _probeNotifications();
      _probeNextSummary();
      _probeBackgroundScan();
      _probePhotoAccess();
    }
  }

  Future<void> _probeNotifications() async {
    final probe = widget.notificationsEnabled;
    if (probe == null) return;
    bool? enabled;
    try {
      enabled = await probe();
    } catch (_) {
      return; // unknown: keep the row hidden rather than cry wolf
    }
    if (!mounted) return;
    final off = enabled == false;
    if (off != _notificationsOff) setState(() => _notificationsOff = off);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  /// True when Photos access is not full (U7): "selected photos only", or
  /// withdrawn in system settings. The watcher then sees at most that
  /// selection, so a meal shot later is never logged — and after the one
  /// warning snackbar Settings used to say nothing.
  bool _photosLimited = false;

  /// Reads the permission STATE only (hasFullAccess shows no prompt and
  /// fetches no asset), so it cannot raise the iOS limited-library alert
  /// or touch the logging path.
  Future<void> _probePhotoAccess() async {
    final lib = widget.photoLibrary;
    if (lib == null) return;
    bool limited;
    try {
      limited = !await lib.hasFullAccess();
    } catch (_) {
      return; // unknown: keep the footer as it was
    }
    if (!mounted || limited == _photosLimited) return;
    setState(() => _photosLimited = limited);
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    if (old.changes != widget.changes) {
      old.changes?.removeListener(_onSettingsChanged);
      widget.changes?.addListener(_onSettingsChanged);
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _profileController.dispose();
    super.dispose();
  }

  Future<void> _toggleWatcher(bool enable) async {
    // Captured BEFORE the first await: every snackbar below fires after a
    // permission / photo-library round trip, and reading l10n off a
    // context that may have gone away is the use-after-await the lint
    // exists for. (The strings themselves were English literals until
    // 2026-10-07 — the Chinese UI showed them verbatim.)
    final l10n = context.l10n;
    if (enable) {
      // App Store 5.1.2(i): say where the photos go BEFORE the first one
      // leaves, and get the user's permission for THIS recipient. Asked
      // when the recipient is not allowed yet, or the camera-roll notice
      // was never shown (an earlier Allow from a picked photo did not say
      // that non-food photos and the lookback window go too). A watcher
      // that is already on, and every headless/background path, never
      // asks: a recipient change while it is on asks at the change.
      final route = currentAiConsentRoute(widget.settings);
      if (!widget.settings.hasAiConsent(route) ||
          !widget.settings.watcherDisclosureSeen) {
        if (!await _confirmWatcherDisclosure()) return; // switch stays off
        await widget.settings.setAiConsent(route, granted: true);
        await widget.settings.update(watcherDisclosureSeen: true);
        if (!mounted) return;
      }
      final granted = await widget.requestPhotoPermission();
      if (!granted) {
        if (!mounted) return;
        final open = widget.openSystemSettings;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            persist: _holdForScreenReader(context, hasAction: open != null),
            duration: _actionSnackBarDuration,
            content: Text(l10n.watcherPermissionDenied),
            // Once the OS stops re-prompting, the in-app request above is
            // a silent no-op — without this action the toggle is a
            // forever dead end.
            action: open == null
                ? null
                : SnackBarAction(
                    label: l10n.openSystemSettings,
                    onPressed: () => open())));
        return; // leave the switch off
      }
      if (!mounted) return;
      // The watcher arms fine without a usable key — it just never logs
      // anything. Flipping a switch that silently does nothing needs a
      // sentence, not silence.
      final paused = _autoScanPausedText();
      if (!widget.settings.canAnalyze) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(widget.settings.isQuotaPaused
                ? l10n.watcherOnQuotaPaused
                : l10n.watcherOnNoKey)));
      } else if (paused != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(paused)));
      }
      await widget.photoIntake?.start();
      // A "selected photos" (limited) grant is a TRAP: the watcher can
      // only ever see the photos picked in that one dialog, so a meal
      // shot later is invisible forever — and the toggle used to turn on
      // regardless, silently. Say so, with a path to fix it.
      final lib = widget.photoLibrary;
      final limited = lib != null && !await lib.hasFullAccess();
      _photosLimited = limited; // the footer line; setState follows below
      if (limited) {
        if (!mounted) return;
        final open = widget.openSystemSettings;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            persist: _holdForScreenReader(context, hasAction: open != null),
            duration: _actionSnackBarDuration,
            content: Text(l10n.watcherLimitedAccess),
            action: open == null
                ? null
                : SnackBarAction(
                    label: l10n.fixAction, onPressed: () => open())));
      }
      // Instant feedback on enable: sweep the lookback window right away
      // instead of waiting for the next change event / background run.
      // Only when analyses can actually succeed (key present, no quota
      // pause, no rejected-key/region latch) — otherwise the sweep reads
      // bytes for nothing.
      if (widget.settings.canAutoAnalyze) {
        unawaited(widget.photoIntake
            ?.backfillScan()
            .then((_) {}, onError: (Object _) {}));
      }
    } else {
      await widget.photoIntake?.stop();
    }
    if (!mounted) return;
    setState(() => _watcherEnabled = enable);
    await widget.settings.update(watcherEnabled: enable);
  }

  Future<void> _toggleWatchGlasses(bool include) async {
    setState(() => _watchGlasses = include);
    await widget.settings.update(watchGlasses: include);
  }

  /// The 照片会发送给 AI 服务 notice: the AI consent for the current
  /// recipient, then what the camera roll adds; true = Continue.
  Future<bool> _confirmWatcherDisclosure() {
    final l = context.l10n;
    final s = widget.settings;
    final provider = providerDisplayLabel(l, s.provider, s.serverBackend);
    return showAiConsentDialog(context,
        provider: s.provider,
        serverBackend: s.serverBackend,
        serverBaseUrl: s.serverBaseUrl,
        title: l.watcherDisclosureTitle,
        // Shown in the other order (U26): what the camera roll adds leads,
        // and the general text every other consent shows follows it.
        appendix: l.watcherDisclosureBody(provider, _lookbackDays),
        leadWithAppendix: true,
        allowLabel: l.watcherDisclosureContinue,
        cancelLabel: l.cancel,
        dialogKey: const Key('watcherDisclosureDialog'),
        cancelKey: const Key('watcherDisclosureCancel'),
        allowKey: const Key('watcherDisclosureContinue'));
  }

  /// Settings' Stop sharing row: withdraws the AI consent for the current
  /// recipient, turns Watch Camera Roll off through the same path as its
  /// switch and, when its lookups go to that recipient, the restaurant
  /// assist through the same path as its mode row (pending lookups
  /// dropped, its consent forgotten), so nothing more is sent until the
  /// user allows it again (App Store 5.1.1(ii): consent can be withdrawn).
  Future<void> _stopSharing() async {
    final l = context.l10n;
    final s = widget.settings;
    final provider = providerDisplayLabel(l, s.provider, s.serverBackend);
    // Restaurant lookups to this same recipient stop with it
    // (docs/RELEASING.md): the dialog says so when it turns them off.
    final lookupsToo = restaurantAssistStopFor(
            s, widget.restaurantAssist, currentAiConsentRoute(s))
        .turnOff;
    final stop = await showDialog<bool>(
      context: context,
      builder: (ctx) => appAlertDialog(
        key: const Key('aiStopSharingDialog'),
        title: Text(ctx.l10n.aiStopSharingTitle(provider)),
        content: SingleChildScrollView(
            child: Text(lookupsToo
                ? ctx.l10n.aiStopSharingBodyWithLookups(provider)
                : ctx.l10n.aiStopSharingBody(provider))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('aiStopSharingConfirm'),
              style: AppButtonStyles.destructive(ctx),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l10n.aiStopSharingConfirm)),
        ],
      ),
    );
    if (stop != true || !mounted) return;
    // The assist first, in ONE settings write: no lookup reads the AI
    // consent, so its own mode and consent are what stop them, and this
    // row stays for a retry until the assist is off (Watch Camera Roll is
    // switched off after the AI consent, as before).
    final route = currentAiConsentRoute(s);
    final assist =
        await stopRestaurantAssistFor(s, widget.restaurantAssist, route);
    await s.setAiConsent(route, granted: false);
    if (_watcherEnabled || s.watcherEnabled) await _toggleWatcher(false);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(assist.turnOff
            ? l.aiStopSharingDoneWithLookups(provider)
            : l.aiStopSharingDone(provider))));
  }

  Future<void> _pickReportTime() async {
    final parts = _reportTime.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 21,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );
    final picked =
        await showAppTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final formatted = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    setState(() => _reportTime = formatted);
    await widget.settings.update(reportTime: formatted);
    await _probeNextSummary(); // the store re-armed the card for the new slot
  }

  /// The off switch for the nightly card (friend-cohort finding
  /// 2026-10-10): before it, the only way to stop the summary was muting
  /// the whole notification channel, which silenced meal cards too — and
  /// this screen then painted that choice as a fault.
  Future<void> _toggleSummary(bool enable) async {
    setState(() => _summaryEnabled = enable);
    await widget.settings.update(summaryEnabled: enable);
    if (enable) await _probeNextSummary(); // the store re-armed the card
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Apple grouped anatomy (2026-08-02 restructure): inset sections on a
    // grouped background, disclosure to subpages, footers as helper text.
    // Section builders keep features findable — the wall is gone.
    return Container(
      color: pageColor(context),
      child: CustomScrollView(
        slivers: [
          appLargeTitleBar(context, title: context.l10n.tabSettings),
          SliverList.list(children: [
            ..._aiSection(theme),
            ..._photoSection(theme),
            if (widget.restaurantAssist != null)
              RestaurantAssistSection(
                key: _restaurantKey,
                settings: widget.settings,
                controls: widget.restaurantAssist!,
              ),
            ..._reportSection(theme),
            ..._profileSection(theme),
            ..._languageSection(theme),
            DataSection(
                dao: widget.dao,
                onOpenPrivacyPolicy: _openPrivacyPolicy,
                privacyPolicyUrl: privacyPolicyUri,
                backup: widget.cloudBackup,
                platform: defaultTargetPlatform == TargetPlatform.android
                    ? 'android'
                    : 'ios',
                androidBackupNote: widget.androidBackupNote,
                onImported: widget.onImported),
            const SizedBox(height: 32),
          ]),
        ],
      ),
    );
  }

  /// The first-run card: what to do first, and a tap that goes there (the
  /// AI Provider page, where the Test This Provider row is). Without a
  /// button the card was a paragraph pointing at a row below it.
  Widget _firstRunCard(ThemeData theme) {
    final colors = context.colors;
    final title = Text(context.l10n.settingsWelcomeTitle,
        style: theme.textTheme.titleMedium?.copyWith(color: colors.label));
    final body = Text(context.l10n.settingsWelcomeBody,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: colors.secondaryLabel));
    final chevron = ExcludeSemantics(
        child: Icon(Icons.chevron_right_rounded,
            size: 20, color: colors.tertiaryLabel));
    // At accessibility sizes the badge and chevron would leave the text a
    // sliver of the width: the text takes the whole card instead.
    final content = isLargeText(context)
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: AppSpace.s4), body],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: colors.accentSoft, shape: BoxShape.circle),
                  child: Icon(Icons.auto_awesome_rounded,
                      size: 22, color: colors.accent),
                ),
              ),
              const SizedBox(width: AppSpace.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, const SizedBox(height: AppSpace.s4), body],
                ),
              ),
              const SizedBox(width: AppSpace.s8),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: chevron,
              ),
            ],
          );
    return GroupedCard(
      key: const Key('firstRunCard'),
      margin: const EdgeInsets.fromLTRB(
          kGroupInset, AppSpace.s16, kGroupInset, 0),
      padding: const EdgeInsets.all(AppSpace.cardPadding),
      onTap: _openProviderPage,
      child: content,
    );
  }

  /// The AI Provider page, as the AI Provider row opens it.
  Future<void> _openProviderPage() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ProviderSettingsPage(
        settings: widget.settings,
        analyzer: widget.analyzer,
        startClaudeAuth: widget.startClaudeAuth,
        completeClaudeAuth: widget.completeClaudeAuth,
        serverLoginState: widget.serverLoginState,
        openUrl: widget.openUrl,
      ),
    ));
    if (mounted) setState(() {}); // the card hides once a key is set
  }

  /// One row of STATE (Apple progressive disclosure): choosing and
  /// configuring the provider lives on its own page.
  List<Widget> _aiSection(ThemeData theme) => [
        // First-run: the shell deliberately lands a key-less install here.
        // Everything a mainland user needs to know is one tap away on the
        // provider page; this card just points there.
        if (widget.settings.apiKey.trim().isEmpty) _firstRunCard(theme),
        GroupedSection(
          header: context.l10n.settingsSectionAi,
          footer: widget.settings.isQuotaPaused
              ? context.l10n.settingsAiFooterPaused
              : context.l10n.settingsAiFooter,
          children: [
            GroupedRow(
              key: const Key('aiProviderRow'),
              icon: Icons.auto_awesome,
              iconColor: theme.colorScheme.primary,
              title: context.l10n.settingsRowAiProvider,
              value: providerDisplayLabel(context.l10n,
                  widget.settings.provider, widget.settings.serverBackend),
              onTap: () async {
                // Who a restaurant lookup would reach before the visit: a
                // new provider or server pauses the assist until the user
                // agrees to it (design R7a).
                final stampBefore =
                    _restaurantKey.currentState?.currentRecipientStamp();
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ProviderSettingsPage(
                    settings: widget.settings,
                    analyzer: widget.analyzer,
                    startClaudeAuth: widget.startClaudeAuth,
                    completeClaudeAuth: widget.completeClaudeAuth,
                    serverLoginState: widget.serverLoginState,
                    openUrl: widget.openUrl,
                    dao: widget.dao,
                    restaurantAssist: widget.restaurantAssist,
                  ),
                ));
                if (mounted) setState(() {}); // provider label refresh
                if (stampBefore != null) {
                  await _restaurantKey.currentState
                      ?.promptIfRecipientChanged(stampBefore);
                }
              },
            ),
            // Only while the current recipient is allowed: withdrawing a
            // consent that was never given would be a dead row.
            if (widget.settings
                .hasAiConsent(currentAiConsentRoute(widget.settings)))
              GroupedRow(
                key: const Key('aiStopSharingRow'),
                icon: Icons.block,
                iconColor: theme.colorScheme.error,
                title: context.l10n.aiStopSharingRow(providerDisplayLabel(
                    context.l10n,
                    widget.settings.provider,
                    widget.settings.serverBackend)),
                showChevron: false,
                onTap: _stopSharing,
              ),
          ],
        ),
  ];

  /// The Photos footer, plus on iOS why the 后台扫描 time is what it is:
  /// iOS alone picks when BGAppRefresh launches the scan (a few times a
  /// day, AppDelegate.swift), and a swipe-away in the app switcher stops
  /// every launch until the next open — so a time that stopped advancing
  /// looked exactly like the real bug run 4 chased through this row.
  /// Said under the group, Apple-style, so the row value stays short
  /// (d5458ca title fit). Not over the Off remedy, which already says what
  /// to do, and not on Android: WorkManager survives a swipe-away there.
  String _photosFooter() {
    final l10n = context.l10n;
    final explainIos = _showBackgroundScanRow &&
        !_backgroundRefreshOff &&
        defaultTargetPlatform == TargetPlatform.iOS;
    final footer = explainIos
        ? '${l10n.settingsPhotosFooter(_lookbackDays)}\n'
            '${l10n.backgroundScanIosHint}'
        : l10n.settingsPhotosFooter(_lookbackDays);
    // A rejected key / blocked region latched the automatic scan (perhaps
    // in a background run, which has no snackbar): without this line the
    // scan just stops, silently, for up to a day.
    final paused = _watcherEnabled ? _autoScanPausedText() : null;
    // The runs keep starting but log nothing (backgroundScanLooksStuck):
    // the launch time alone looked healthy through the Oct 11 and Oct 15
    // stalls. Not over the Off remedy, which says what to do already.
    final stuck = _watcherEnabled &&
            _backgroundStuck &&
            !_backgroundRefreshOff &&
            widget.lastBackgroundScan != null
        ? l10n.backgroundScanStuck
        : null;
    // Not full access: the switch is on, but photos taken from now on are
    // outside what the app may read, so they are never logged.
    final limited =
        _watcherEnabled && _photosLimited ? l10n.watcherLimitedFooter : null;
    return [?limited, ?paused, ?stuck, footer].join('\n');
  }

  /// Whether the 后台扫描 row (and its iOS footer line) shows. On iOS only
  /// while Watch Camera Roll is on (U21): with it off the background job
  /// still records its launches, so a fresh install showed 'Not run yet',
  /// a time, or a red 'Off' for a scan it does not want — each read as a
  /// fault. Android keeps the row: its Restricted remedy also covers the
  /// nightly summary, which runs on the same job.
  bool get _showBackgroundScanRow =>
      widget.lastBackgroundScan != null &&
      (_watcherEnabled || defaultTargetPlatform != TargetPlatform.iOS);

  /// Why the automatic scan is latched, with its next try; null when not.
  String? _autoScanPausedText() {
    final s = widget.settings;
    final until = s.autoScanBlockedUntil;
    if (until == null) return null;
    return autoScanPausedLine(context.l10n,
        kind: s.autoScanBlockedKind,
        until: until,
        provider: s.provider,
        serverBackend: s.serverBackend);
  }

  /// Camera-roll watching, coverage audit, backfill window.
  List<Widget> _photoSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsSectionPhotos,
          footer: _photosFooter(),
          children: [
            GroupedToggleRow(
              switchKey: const Key('watcherToggle'),
              icon: Icons.photo_camera_outlined,
              iconColor: theme.colorScheme.primary,
              title: context.l10n.settingsRowWatch,
              value: _watcherEnabled,
              onChanged: (v) => _toggleWatcher(v),
            ),
            // Design G3: photos recognized as taken with Meta glasses. Off,
            // the automatic scan does not offer them at all; on (the
            // default), an iPhone checks each one for food on the phone
            // before anything is sent (docs/PRIVACY.md).
            GroupedToggleRow(
              key: const Key('watchGlassesRow'),
              switchKey: const Key('watchGlassesToggle'),
              icon: Icons.visibility_outlined,
              iconColor: theme.colorScheme.secondary,
              title: context.l10n.settingsRowWatchGlasses,
              value: _watchGlasses,
              onChanged: (v) => _toggleWatchGlasses(v),
            ),
            GroupedRow(
              icon: Icons.history,
              iconColor: theme.colorScheme.tertiary,
              title: context.l10n.settingsRowLookback,
              value: context.l10n.lookbackDays(_lookbackDays),
              onTap: _pickLookback,
            ),
            // The OS's last background launch — on iOS the only visible
            // proof that Background App Refresh runs for this app at all.
            if (_showBackgroundScanRow)
              GroupedRow(
                key: const Key('backgroundScanRow'),
                icon: Icons.update,
                // Stuck only while the watcher is on, like its footer line.
                iconColor: _backgroundRefreshOff ||
                        (_watcherEnabled && _backgroundStuck)
                    ? theme.colorScheme.error
                    : theme.colorScheme.secondary,
                title: context.l10n.settingsRowBackgroundScan,
                // Off in iOS settings beats any timestamp: nothing can be
                // scheduled until the user turns it back on. A bare 'Off'
                // (the red badge and chevron lead to the remedy): 'Off in
                // Settings' cut the English title to 'Background sc…'
                // (loop find 2026-10-08, test/ui/row_fit_layout_test.dart).
                // Android's 电池 › 受限 (App battery usage › Restricted)
                // parks the periodic job — the scan AND the nightly
                // summary — for days, and until 2026-10-10 the row showed
                // 尚未运行 / a frozen time with no hint; the chevron now
                // lands on App info, where that switch is one tap away.
                value: _backgroundRefreshOff
                    ? _backgroundOffLabel()
                    : _lastBackgroundProbed
                        ? _lastBackgroundLabel(_lastBackgroundScan)
                        : '…',
                onTap: _backgroundRefreshOff && widget.openSystemSettings != null
                    ? () => widget.openSystemSettings!()
                    : null,
                showChevron: _backgroundRefreshOff &&
                    widget.openSystemSettings != null,
              ),
            if (widget.coverage != null && widget.processPhoto != null)
              GroupedRow(
                key: const Key('coverageCheckTile'),
                icon: Icons.fact_check_outlined,
                iconColor: theme.colorScheme.secondary,
                title: context.l10n.settingsRowCoverage,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CoverageScreen(
                    auditor: widget.coverage!,
                    processPhoto: widget.processPhoto!,
                    requestPhotoPermission: widget.requestPhotoPermission,
                    initialLookbackDays: _lookbackDays,
                    // A closure, not a snapshot: the quota latch can arm
                    // while the coverage screen's bulk run is mid-batch.
                    canAnalyze: () => widget.settings.canAnalyze,
                    ensureConsent: (ctx) =>
                        ensureAiConsent(ctx, widget.settings),
                    library: widget.photoLibrary,
                    logManually: (photo) async =>
                        await Navigator.of(context)
                            .push<bool>(MaterialPageRoute(
                          builder: (_) => MealEditorScreen(
                            dao: widget.dao,
                            fromPhoto: photo,
                            makeThumb: makeMealThumbAny,
                          ),
                        )) ==
                        true,
                  ),
                )),
              ),
          ],
        ),
  ];

  /// Apple's compact-value pattern: the row shows the state; a sheet
  /// adjusts it (the old always-visible slider gave a rarely-touched
  /// setting permanent screen space).
  Future<void> _pickLookback() async {
    var days = _lookbackDays;
    final picked = await showGroupedSheet<int>(
      context,
      title: context.l10n.lookbackSheetTitle,
      subtitle: context.l10n.lookbackSheetHint,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GroupedCard(
              padding: const EdgeInsets.fromLTRB(AppSpace.rowH, AppSpace.s12,
                  AppSpace.rowH, AppSpace.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The Cupertino slider has no value bubble: the count
                  // is spelled out above it.
                  Text(ctx.l10n.lookbackDays(days),
                      key: const Key('lookbackValue'),
                      style: ctx.nums.value.copyWith(color: ctx.colors.label)),
                  Slider.adaptive(
                    key: const Key('lookbackSlider'),
                    value: days.toDouble(),
                    min: 1,
                    max: 30, // spec §6.4 clamp 1–30
                    divisions: 29,
                    label: '$days',
                    onChanged: (v) => setSheet(() => days = v.round()),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  kGroupInset, AppSpace.s20, kGroupInset, 0),
              child: FilledButton(
                key: const Key('lookbackSetButton'),
                onPressed: () => Navigator.pop(ctx, days),
                child: Text(ctx.l10n.lookbackSet(days)),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _lookbackDays = picked);
    await widget.settings.update(lookbackDays: picked);
  }

  /// Daily summary on/off, its time, the goal.
  List<Widget> _reportSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsSectionReport,
          footer: context.l10n.goalFooter,
          children: [
            GroupedToggleRow(
              switchKey: const Key('summaryToggle'),
              icon: Icons.notifications_outlined,
              iconColor: theme.colorScheme.primary,
              title: context.l10n.settingsRowDailySummary,
              value: _summaryEnabled,
              onChanged: (v) => _toggleSummary(v),
            ),
            // Off is a choice, not a fault: the slot, the armed-slot row
            // and the notifications-off remedy all describe a delivery the
            // user just declined, so they hide with it.
            if (_summaryEnabled) ...[
              GroupedRow(
                key: const Key('reportTimeTile'),
                icon: Icons.schedule,
                iconColor: theme.colorScheme.primary,
                title: context.l10n.settingsRowReportTime,
                // Display only: stored as 'HH:mm'. English follows the
                // phone's 24-Hour Time switch ('9:00 PM').
                value: AppFormats.hm(context, _reportTime),
                onTap: _pickReportTime,
              ),
              if (_notificationsOff) _notificationsOffRow(theme),
              if (widget.nextSummaryAt != null)
                GroupedRow(
                  key: const Key('nextSummaryRow'),
                  icon: Icons.notifications_active_outlined,
                  iconColor: _nextSummaryProbed && _nextSummary == null
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                  title: context.l10n.settingsRowNextSummary,
                  value:
                      _nextSummaryProbed ? _nextSummaryLabel(_nextSummary) : '…',
                  showChevron: false,
                ),
            ],
            GroupedRow(
              key: const Key('calorieGoalTile'),
              icon: Icons.flag_outlined,
              iconColor: theme.colorScheme.secondary,
              title: context.l10n.settingsRowGoal,
              value: widget.settings.calorieGoal > 0
                  ? context.l10n
                      .kcalAmount(formatKcal(widget.settings.calorieGoal))
                  : context.l10n.goalNotSet,
              onTap: _pickCalorieGoal,
            ),
          ],
        ),
  ];

  /// Shown only when the OS reports notifications OFF: without this the
  /// daily summary simply never arrives and nothing on the phone says why.
  Widget _notificationsOffRow(ThemeData theme) {
    final open = widget.openSystemSettings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.notifications_off_outlined,
                  size: 18, color: context.colors.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.notificationsOffHint,
                  key: const Key('notificationsOffHint'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: context.colors.danger),
                ),
              ),
            ],
          ),
          if (open != null) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(
              key: const Key('notificationsOffOpenSettings'),
              onPressed: () => open(),
              child: Text(context.l10n.openSystemSettings),
            ),
          ],
        ],
      ),
    );
  }

  /// The daily goal the coach notification measures against; empty clears
  /// it and the summary falls back to the typical-day median.
  Future<void> _pickCalorieGoal() async {
    final saved = await showDialog<int>(
      context: context,
      builder: (_) =>
          _CalorieGoalDialog(initialGoal: widget.settings.calorieGoal),
    );
    if (saved == null || !mounted) return;
    await widget.settings.update(calorieGoal: saved);
    if (mounted) setState(() {});
  }

  /// Dietary profile appended to the photo prompt (§1.3).
  List<Widget> _profileSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsSectionProfile,
          children: [
            GroupedRow(
              key: const Key('dietaryProfileRow'),
              icon: Icons.person_outline,
              iconColor: theme.colorScheme.secondary,
              title: context.l10n.settingsRowDietaryProfile,
              value: widget.settings.dietaryProfile.trim().isEmpty
                  ? context.l10n.profileNotSet
                  : context.l10n.profileSet,
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      ProfileSettingsPage(settings: widget.settings),
                ));
                if (mounted) setState(() {}); // Set/Not set refresh
              },
            ),
          ],
        ),
  ];

  String _languageLabel(BuildContext context) =>
      switch (widget.settings.appLanguage) {
        'en' => 'English',
        'zh' => '中文',
        _ => context.l10n.languageSystem,
      };

  Future<void> _pickLanguage() async {
    final picked = await showChoiceSheet(
      context,
      title: context.l10n.languageSheetTitle,
      keyPrefix: 'language',
      current: widget.settings.appLanguage,
      options: [
        ('system', context.l10n.languageSystem),
        ('en', 'English'),
        ('zh', '中文'),
      ],
    );
    if (picked == null || !mounted) return;
    await widget.settings.update(appLanguage: picked);
    if (mounted) setState(() {});
  }

  List<Widget> _languageSection(ThemeData theme) => [
        GroupedSection(
          header: context.l10n.settingsRowLanguage,
          // The Units row rides the language section and only exists in
          // the ENGLISH UI: the Chinese UI is always metric (user
          // decision 2026-08-03), so offering the choice there would be
          // a lie — the zh screens ignore it.
          footer: _showUnitsRow ? context.l10n.unitsFooter : null,
          children: [
            GroupedRow(
              key: const Key('languageRow'),
              icon: Icons.translate,
              iconColor: theme.colorScheme.tertiary,
              title: context.l10n.settingsRowLanguage,
              value: _languageLabel(context),
              onTap: _pickLanguage,
            ),
            if (_showUnitsRow)
              GroupedRow(
                key: const Key('unitsRow'),
                icon: Icons.straighten,
                iconColor: theme.colorScheme.secondary,
                title: context.l10n.settingsRowUnits,
                value: widget.settings.units == 'imperial'
                    ? context.l10n.unitsImperial
                    : context.l10n.unitsMetric,
                onTap: _pickUnits,
              ),
          ],
        ),
  ];

  bool get _showUnitsRow =>
      Localizations.maybeLocaleOf(context)?.languageCode != 'zh';

  Future<void> _pickUnits() async {
    final picked = await showChoiceSheet(
      context,
      title: context.l10n.unitsSheetTitle,
      keyPrefix: 'units',
      current: widget.settings.units,
      options: [
        ('metric', context.l10n.unitsMetricDetail),
        ('imperial', context.l10n.unitsImperialDetail),
      ],
    );
    if (picked == null || !mounted) return;
    await widget.settings.update(units: picked);
    if (mounted) setState(() {});
  }

  Future<void> _openPrivacyPolicy() async {
    final open = widget.openUrl ??
        (uri) => launcher.launchUrl(uri,
            mode: launcher.LaunchMode.externalApplication);
    var opened = false;
    try {
      opened = await open(privacyPolicyUri);
    } catch (_) {}
    if (opened || !mounted) return;
    // No browser, or the launch was refused: the address itself keeps the
    // policy reachable — and copyable, since a snackbar's text cannot be
    // selected. It leaves after its duration, except under VoiceOver.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        persist: _holdForScreenReader(context, hasAction: true),
        duration: _actionSnackBarDuration,
        content: Text(
            context.l10n.privacyOpenFailed(privacyPolicyUri.toString())),
        action: SnackBarAction(
            key: const Key('privacyCopyAction'),
            label: context.l10n.privacyCopyAction,
            onPressed: () => Clipboard.setData(
                ClipboardData(text: privacyPolicyUri.toString())))));
  }
}

/// The daily-goal dialog. Save checks the number HERE, with the dialog
/// still open (B19): '2,000' pasted or typed on an Android number pad
/// used to fail int.tryParse and save 0, and anything over the store's
/// cap was stored as 0 too — either way the goal silently read 'Not set'.
/// Now grouping separators are ignored, anything that is not a whole
/// number from 1 to [maxGoal] says so under the field, and only an empty
/// field or Clear goal clears it. Pops the goal (0 = cleared), or null.
class _CalorieGoalDialog extends StatefulWidget {
  const _CalorieGoalDialog({required this.initialGoal});
  final int initialGoal;

  /// What AppSettings.setCalorieGoal stores; above it, it stored 0.
  static const int maxGoal = maxDailyGoalKcal;

  @override
  State<_CalorieGoalDialog> createState() => _CalorieGoalDialogState();
}

class _CalorieGoalDialogState extends State<_CalorieGoalDialog> {
  // Owned by the State: disposed after the dialog's exit animation, never
  // while the closing field still builds with it.
  late final TextEditingController _ctrl = TextEditingController(
      text: widget.initialGoal > 0 ? '${widget.initialGoal}' : '');
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// The goal in the field: 0 for empty, null when it is not a whole
  /// number in range.
  static int? parse(String text, int max) {
    final t = text.trim().replaceAll(RegExp(r'[,，\s]'), '');
    if (t.isEmpty) return 0;
    if (!RegExp(r'^[0-9]+$').hasMatch(t)) return null;
    final n = int.tryParse(t);
    return n == null || n < 1 || n > max ? null : n;
  }

  void _save() {
    final goal = parse(_ctrl.text, _CalorieGoalDialog.maxGoal);
    if (goal == null) {
      setState(() => _error = context.l10n
          .goalInvalid(formatKcal(_CalorieGoalDialog.maxGoal)));
      return;
    }
    Navigator.pop(context, goal);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return appAlertDialog(
      title: Text(l.goalSheetTitle),
      content: TextField(
        key: const Key('calorieGoalField'),
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: l.goalFieldLabel,
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
            key: const Key('calorieGoalClear'),
            onPressed: () => Navigator.pop(context, 0),
            child: Text(l.goalClear)),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel)),
        FilledButton(
          key: const Key('calorieGoalSave'),
          onPressed: _save,
          child: Text(l.save),
        ),
      ],
    );
  }
}
