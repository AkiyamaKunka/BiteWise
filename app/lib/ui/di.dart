/// DI seam — the ONLY file that imports the concrete factory modules.
///
/// Workflow guard: if a factory import or signature drifts at integration
/// time, the integrator fixes THIS file alone.
library;

import 'dart:async' show Completer, unawaited;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show compute;

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/contracts.dart';
import '../data/meals_dao_impl.dart';
import '../services/analyzer/platform_decode.dart' show isEngineBackgrounded;
import '../services/analyzer/provider_analyzers.dart'
    show MultiProviderAnalyzer, ServerAnalyzer;
import '../services/assist/assist_local_state.dart';
import '../services/assist/assist_places_store.dart';
import '../services/assist/meal_assist.dart';
import '../services/nl/executor.dart';
import '../services/garmin_client.dart';
import '../services/photo/background_restriction.dart'
    show androidBackgroundAllowed;
import '../services/photo/background_time.dart';
import '../services/photo/deferred_assets.dart'
    show clearDeferredAsset, holdGlassesPreview;
import '../services/photo/coverage.dart';
import '../services/photo/filename_dates.dart' show deriveCapturedAt;
import '../services/photo/food_prefilter.dart' show foodScoreViaImageIO;
import '../services/photo/glasses.dart' show captureMetaFor;
import '../services/photo/glasses_check.dart' show recordGlassesCheckLocally;
import '../services/photo/photo_hash.dart' show originalBytesMd5;
import '../services/photo/photo_library.dart';
import '../services/photo/photo_location.dart';
import '../services/photo/share_intake.dart';
import '../services/places/places.dart' show MapKitPlaces;
import '../services/photo/watcher.dart';
import '../services/report/builders.dart';
import '../services/report/notifications.dart';
import '../services/report/daily_summary.dart';
import 'coach_strings.dart';
import '../services/settings/app_settings.dart';
import 'background_glue.dart';
import 'migrations.dart';
import 'outcome_text.dart' show assistAppliedSnackbar, outcomeSnackbar;
import 'os_summary.dart';
import 'meal_in_use.dart';
import 'meal_thumbs.dart';
import 'photo_pipeline.dart';
import 'refresh_signal.dart';
import 'restaurant_assist_controls.dart';
import 'services.dart';

/// Singleton wiring of the workflow-fixed factories, in the spec'd startup
/// order: settings → dao → reclaimStaleProcessing (spec §2.3 launch sweep)
/// → services.
class AppServices {
  final UiServices ui;
  final PhotoPipeline pipeline;
  final AppSettings settings;

  /// The app engine's one registry of meals a screen is working on (design
  /// R6a): the screens hold, the restaurant assist (R6b) reads.
  final MealInUseRegistry mealInUse;

  /// The restaurant assist (design R6b): app engine only — background_glue
  /// never builds one.
  final MealAssist mealAssist;

  AppServices._(this.ui, this.pipeline, this.settings, this.mealInUse,
      this.mealAssist);

  static AppServices? _instance;
  static AppServices get instance => _instance!;

  static Future<AppServices> init(
      {void Function(String)? notify,
      void Function(String message, String action, void Function() onAction)?
          notifyAction}) async {
    if (_instance != null) return _instance!;

    final settings = await AppSettings.load();
    final MealsDao dao = await createMealsDao();
    // Any 'processing' ledger row at launch is a crashed run — reclaim it
    // before services start (spec §2.3 single-process simplification).
    await dao.reclaimStaleProcessing();
    if (Platform.isIOS) {
      // This engine's GPU goes off whenever the app is in the background:
      // no dart:ui decode may start there (platform_decode.dart).
      isEngineBackgrounded = appEngineBackgrounded;
      try {
        // iPhone photos are HEIC; earlier builds showed them to the model
        // unreadable. Forget those verdicts once (migrations.dart).
        await reofferUnreadPhotosOnce(
            dao, await SharedPreferences.getInstance());
      } catch (_) {
        // A repair must never block startup.
      }
    }
    // The app's daily restaurant-lookup ledger (design R6b: 20 a day, in
    // shared_preferences): every lookup client counts against it.
    final assistBudget =
        AssistDailyBudget(await SharedPreferences.getInstance());
    final analyzer =
        MultiProviderAnalyzer(settings, lookupBudget: assistBudget);
    // A dedicated ServerAnalyzer instance for the OAuth re-connect calls:
    // they exist regardless of the currently selected provider (the user
    // may re-connect Claude while temporarily on Gemini).
    final serverAnalyzer = ServerAnalyzer(settings);
    final appLinks = AppLinks();
    final executor = createExecutor(dao, analyzer, settings);
    // The photo module reads lookbackDays through the live settings object,
    // so slider edits apply to the next scan without rewiring (spec §6.4).
    // Late imports skip photos a meal already names, without a read (G1b).
    final photoIntake =
        createPhotoIntake(settings, loggedAssetIds: dao.loggedAssetIds);
    final shareIntake = createShareIntake(settings);
    final ReportBuilder reports = createReportBuilder(dao);

    // Notification surface (spec §5.5/§6): init() also performs the runtime
    // permission request (Android 13+ / iOS) — without it every meal card
    // and daily report is silently dropped. The in-process daily Timer dies
    // with the process, so re-arm it on every launch (notifications.dart
    // integrator contract). MUST be fire-and-forget: init() resolves only
    // when the user answers the permission dialog, and awaiting that here
    // blocks the first frame indefinitely (found by the iOS E2E hanging
    // 15 minutes at launch).
    // dailyBody gets the ARMED SLOT's date: a Timer delivered late (after
    // overnight suspension) must still report the day it was scheduled
    // for, not the fresh morning's near-empty totals.
    late final ReportNotifier notifier;
    // The coach summary (user request 2026-08-06) replaces the long
    // Telegram-parity report as the notification body: a lock screen wants
    // one sentence and two numbers, not a full meal table. Both firing
    // paths — this Timer and the WorkManager heartbeat in
    // background_glue — call the SAME builder behind the SAME per-date
    // watermark, so whichever runs first wins and the other no-ops. The
    // watermark is read FRESH at fire time: the heartbeat writes it from
    // another isolate, which this isolate's prefs cache would never see.
    Future<void> postSummary() async =>
        maybePostDailySummary(DailySummaryDeps(
          dao: dao,
          reportTime: settings.reportTime,
          calorieGoal: settings.calorieGoal,
          postedDate: await settings.freshSummaryPostedDate(),
          markPosted: settings.markSummaryPosted,
          present: notifier.showDailySummary,
          strings: coachStringsFor(settings.appLanguage),
          now: DateTime.now,
        ));
    notifier = ReportNotifier(
      // Read per post: the channel name Android shows in its Settings
      // follows a language switch without a restart.
      channelStrings: () => notificationChannelFor(settings.appLanguage),
      dailyBody: (slotDate) async {
        await postSummary();
        // NULL, not '': postSummary has ALREADY presented the coach summary
        // through showDailySummary, which uses the same notification id.
        // Returning a string makes the notifier present again over the top
        // — and '' produced the English "📊 Daily Calorie Report" with a
        // blank body that the user actually saw on 2026-08-16. Null means
        // "handled".
        return null;
      },
    );
    // iOS has NO background execution in this app (spec §6: share/picker
    // only, enableBackgroundScan no-ops, no BGTask ids) and suspends the
    // process seconds after backgrounding — so the Timer that scheduleDaily
    // arms never fires unless the app happens to be open at the slot. The
    // whole August delivery work (catch-up window, watermark) is therefore
    // Android-only in practice; on iOS the summary simply never arrived
    // (found 2026-09-28). Hand delivery to the OS: a one-shot card for the
    // next slot carrying the summary as it stands NOW, re-armed on launch,
    // on every lifecycle transition (app.dart) and on slot edits (below).
    final osSchedulesSummary = Platform.isIOS;
    Future<void> armOsSummary() =>
        armOsDailySummary(dao: dao, settings: settings, notifier: notifier);
    // Settings' 下次总结 probe waits on this: on a first run init() sits
    // behind the notification-permission dialog, and a probe answered
    // before the arm read null and painted a red 'Not scheduled' over a
    // summary armed seconds later. Completed right after the arm (not after
    // the catch-up) and in `finally`, so a denial or a junk hh:mm resolves
    // the probe instead of leaving it pending.
    final summaryArmed = Completer<void>();
    unawaited(() async {
      try {
        await notifier.init();
        if (!settings.summaryEnabled) {
          // Switched off in Settings: nothing armed, no launch catch-up.
          // The OS card is withdrawn here too, in case the process died
          // between the toggle's prefs write and its own cancel.
          await notifier.cancelPendingDaily();
        } else if (osSchedulesSummary) {
          await armOsSummary();
          if (!summaryArmed.isCompleted) summaryArmed.complete();
        } else {
          await notifier.scheduleDaily(settings.reportTime);
          if (!summaryArmed.isCompleted) summaryArmed.complete();
          // Catch-up at launch: if the slot passed while the app was dead
          // and no background run has happened yet, say it now.
          await postSummary();
        }
      } catch (_) {
        // Permission denial / corrupt hh:mm must never break startup.
      } finally {
        if (!summaryArmed.isCompleted) summaryArmed.complete();
      }
    }());

    // Photo pipeline glue (spec §2.3/§3/§6): intake streams → md5 → reserve
    // → analyze → save/skip/fail, notification-style snackbar on save.
    // Worded HERE, in the app language read live at each call, so a
    // language switch applies to the next snackbar; main.dart stays a
    // plain String sink. The add flow gets the same sink for a verdict
    // that lands after the user backed out.
    final void Function(PhotoOutcome)? announce = notify == null
        ? null
        : (o) =>
            notify(outcomeSnackbar(localizationsFor(settings.appLanguage), o));
    final pipeline = PhotoPipeline(
        dao: dao,
        analyzer: analyzer,
        notify: announce,
        // Open screens re-query instead of showing pre-save data.
        onMealSaved: signalMealsChanged,
        // A rejected key / blocked region parks the automatic scan.
        latch: autoScanLatchFor(settings),
        // iOS suspends the app seconds after the user leaves it: each photo
        // asks for the time to finish its upload and save first, and no
        // automatic photo starts once the app is in the background.
        backgroundTime: Platform.isIOS ? const BackgroundTime() : null,
        backgrounded: Platform.isIOS ? appEngineBackgrounded : null,
        // A photo the background run kept deferring is forgotten once it
        // has a verdict here. 'Already logged' was settled by an earlier
        // run, which forgot it then.
        onOutcome: (photo, o) {
          if (!o.retryable && o.kind != PhotoOutcomeKind.alreadyTracked) {
            unawaited(clearDeferredAsset(photo.assetId));
          }
        },
        // A glasses preview copy waits once for its full-size one (G2b).
        previewHold: holdGlassesPreview,
        // Design G3: the 'Meta glasses photos' switch, read live, and on iOS
        // the on-device food check before any glasses photo is uploaded.
        includeGlasses: () => settings.watchGlasses,
        foodCheck: Platform.isIOS ? foodScoreViaImageIO : null,
        glassesCheckLog: recordGlassesCheckLocally);

    // Held by the editor, a leftover selection and a pending fix-meal
    // request (design R6a); app engine only — background_glue builds none.
    final mealInUse = MealInUseRegistry();

    final photoLibrary = PhotoManagerLibrary();

    // The restaurant assist (design R6b): saved meals are enriched later,
    // in the foreground only, when the pipeline is idle and no analyzer
    // call is in flight. The mode, 'Use photo location' and the consent
    // are R7a's settings (settings.restaurant_assist…), read fresh on every
    // decision; Off — the default — makes no call.
    final mealAssist = MealAssist(
      dao: dao,
      lookups: analyzer,
      analyzerBusy: analyzer.analyzerBusy,
      pipelineIdle: () => pipeline.isIdle,
      inUse: mealInUse.isInUse,
      budget: assistBudget,
      state: AssistLocalState.platform(),
      settings: () => AssistSettingsView(
        mode: AssistMode.fromWire(settings.restaurantAssist),
        useLocation: settings.restaurantAssistLocation,
        consentAt: settings.restaurantAssistConsentAt,
        consentRecipient: settings.restaurantAssistConsentRecipient,
      ),
      settingsChanges: settings,
      mealsChanged: mealsChangedSignal,
      onMealsChanged: signalMealsChanged,
      inForeground: appEngineInForeground,
      country: () => regionOfLocale(Platform.localeName),
      repliesInChinese: () => settings.repliesInChinese,
      // The location path (design R6c), iOS only: the photo's position
      // from the library's record of the asset, Apple Maps' food places
      // around it (one instance: its rate limit is the engine's), and the
      // places the user taught. Android reads no photo location: brand-only.
      location: Platform.isIOS ? PhotoLocationReader(photoLibrary) : null,
      places: Platform.isIOS ? MapKitPlaces() : null,
      placesStore: AssistPlacesStore.platform(),
      onApplied: notifyAction == null
          ? null
          : (n) {
              final l = localizationsFor(settings.appLanguage);
              notifyAction(assistAppliedSnackbar(l, n), l.assistUndo,
                  () => unawaited(n.undo()));
            },
    );

    // Settings' Restaurant nutrition group and the consent sheets (design
    // R7a): who a lookup would reach now, the assist's consent prompt and
    // learned places, and what the owner's server says (Claude Plan only).
    // The photo location is read on iOS only.
    final restaurantAssist = RestaurantAssistControls(
      lookupSupport: analyzer.lookupSupport,
      clearLearnedPlaces: mealAssist.clearLearnedPlaces,
      consentNeeded: mealAssist.consentNeeded,
      serverState: () async =>
          assistServerStateOf(await serverAnalyzer.serverFeatures()),
      locationSupported: Platform.isIOS,
    );

    // PhotoManager, NOT permission_handler: on Android <=12 the latter's
    // Permission.photos resolves to READ_MEDIA_IMAGES (SDK 33+ only) and
    // auto-DENIES with no dialog, dead-ending both photo flows on the
    // cheap end of the friend cohort. PhotoManager.requestPermissionExtend
    // handles every version and reports limited vs full.
    Future<bool> requestPhotos() => photoLibrary.requestPermission();
    final ui = UiServices(
      dao: dao,
      analyzer: analyzer,
      executor: executor,
      photoIntake: photoIntake,
      reports: reports,
      settings: _AppSettingsStore(settings, notifier,
          // iOS: a slot edit must re-arm the OS card for the new time.
          onReportTimeChanged: osSchedulesSummary ? armOsSummary : null),
      settingsChanges: settings,
      refreshDailyNotification: osSchedulesSummary ? armOsSummary : null,
      garminDaily: makeGarminDailyFetch(settings),
      picker: _ShareIntakePicker(photoLibrary),
      requestPhotoPermission: requestPhotos,
      thumbs: MealThumbResolver(dao: dao, library: photoLibrary),
      coverage: CoverageAuditor(
          library: photoLibrary,
          dao: dao,
          // compute(): the audit hashes up to 2000 originals back-to-back —
          // synchronous md5 on the UI isolate would freeze scrolling for
          // the whole sweep.
          hasher: (bytes) => compute(originalBytesMd5, bytes)),
      // The audit's log/retry actions share the pipeline's global FIFO —
      // enqueue() chains onto the tail; process() would race it.
      processPhoto: pipeline.enqueue,
      announceOutcome: announce,
      photoLibrary: photoLibrary,
      startClaudeAuth: serverAnalyzer.startClaudeAuth,
      completeClaudeAuth: serverAnalyzer.completeClaudeAuth,
      serverLoginState: serverAnalyzer.serverLoginState,
      // One-click setup links (bitewise://setup?...), see setup_link.dart.
      setupLinks: appLinks.uriLinkStream,
      initialSetupLink: appLinks.getInitialLink,
      notificationsEnabled: notifier.notificationsEnabled,
      nextSummaryAt: () async {
        await summaryArmed.future;
        return notifier.scheduledDailyAt();
      },
      lastBackgroundScan: lastBackgroundRun,
      // Read fresh: the background engine writes the runs, and a catch-up
      // here that moved the watermark since clears it.
      backgroundScanStuck: backgroundScanStuckNow,
      // BGTaskScheduler refuses every request (error 1, swallowed by the
      // plugin) while Background App Refresh is off — without this the
      // row would say "not run yet" forever and never say why. Android's
      // counterpart is the user-set 电池 › 受限 bucket, which parks the
      // periodic WorkManager job (the scan AND the nightly summary).
      backgroundRefreshEnabled: Platform.isIOS
          ? () async => (await Permission.backgroundRefresh.status).isGranted
          : Platform.isAndroid
              ? androidBackgroundAllowed
              : null,
      openSystemSettings: () async {
        await openAppSettings(); // permission_handler
      },
      mealInUse: mealInUse,
      restaurantAssist: restaurantAssist,
    );
    pipeline.bind(photoIntake); // automated watch (deliberate=false)
    pipeline.bindStream(shareIntake.photos()); // share sheet (deliberate)
    mealAssist.start();
    var catchingUp = false;
    if (settings.watcherEnabled) {
      await photoIntake.start();
      // Launch catch-up over the FULL lookback window: change-notify only
      // fires while the process lives, and EMUI-class OS freezing kills it
      // minutes after backgrounding — photos taken since are picked up here.
      // Fire-and-forget: startup must not block on Gemini analyses. Key
      // guard: without a key nothing can succeed, so don't read photo bytes
      // (nor while a rejected key / blocked region latched the scan).
      // It also moves the background watermark over what it covers, so the
      // next background run starts from here (foregroundCatchUp).
      if (settings.canAutoAnalyze) {
        catchingUp = true;
        // The assist looks once the catch-up's photos are in (design R6b).
        unawaited(foregroundCatchUp(photoIntake,
                shouldContinue: Platform.isIOS ? appEngineInForeground : null)
            .whenComplete(() => unawaited(mealAssist.sweep()))
            .then((_) {},
            onError: (Object e) {
          // Truncation must not vanish silently: >2000 window images means
          // the catch-up cannot promise full coverage.
          if (e is BackfillWindowTruncated) {
            notify?.call(localizationsFor(settings.appLanguage)
                .backlogTruncatedWarning);
          }
        }));
      }
    }
    if (!catchingUp) unawaited(mealAssist.sweep());
    // Reconcile the periodic WorkManager backfill (background_glue) with the
    // persisted toggle so it also runs while the app is closed.
    await syncBackgroundScan(settings);

    return _instance =
        AppServices._(ui, pipeline, settings, mealInUse, mealAssist);
  }
}

/// Test seam for the adapter below: it is the ONLY production code that
/// maps the UI's provider-scoped apiKey/model onto AppSettings' seven
/// slots, and every widget test uses a fake that merely SIMULATES that
/// routing — so a real mis-route would have stayed green (review
/// 2026-07-31). [notifier] is optional here; the daily-report reschedule
/// is exercised by the report suite.
SettingsStore createSettingsStore(AppSettings settings,
        {ReportNotifier? notifier,
        Future<void> Function()? onReportTimeChanged}) =>
    _AppSettingsStore(settings, notifier ?? ReportNotifier(dailyBody: null),
        onReportTimeChanged: onReportTimeChanged);

/// Adapts the persistent AppSettings onto the UI's SettingsStore, keeping
/// the background job and the daily-report schedule in lockstep with edits.
class _AppSettingsStore implements SettingsStore {
  final AppSettings _s;
  final ReportNotifier _notifier;
  _AppSettingsStore(this._s, this._notifier, {this.onReportTimeChanged});

  /// iOS: re-arm the OS-scheduled summary card when the slot moves or the
  /// summary is switched back on. Null = Android, the in-process Timer.
  final Future<void> Function()? onReportTimeChanged;

  /// Arm the summary for the current slot on this platform's delivery path.
  Future<void> _rearmSummary() async {
    final rearmOs = onReportTimeChanged;
    if (rearmOs != null) {
      // iOS: the OS card is the ONLY delivery. Arming the in-process
      // Timer here too made a suspended app wake the next morning and
      // post a second, stale 昨天 card on top of the OS one (loop find
      // 2026-10-07).
      await rearmOs();
    } else {
      await _notifier.scheduleDaily(_s.reportTime); // Android: re-arm
    }
  }

  @override
  String get apiKey => _s.activeApiKey ?? '';
  @override
  bool get canAnalyze => _s.canAnalyze;
  @override
  bool get canAutoAnalyze => _s.canAutoAnalyze;
  @override
  String? get autoScanBlockedKind => _s.analysisBlockedKind;
  @override
  DateTime? get autoScanBlockedUntil => _s.analysisBlockedUntil;
  @override
  Future<void> reloadAutoScanBlock() => _s.reloadAnalysisBlock();
  @override
  Future<void> credentialsProven({required bool reachedGeneration}) =>
      _s.credentialsProven(reachedGeneration: reachedGeneration);
  @override
  String get provider => _s.provider.name;
  @override
  bool get isQuotaPaused => _s.isQuotaPaused;
  @override
  DateTime? get quotaPauseUntil => _s.quotaPauseUntil;
  @override
  String get model => _s.activeModel;
  @override
  int get lookbackDays => _s.lookbackDays;
  @override
  String get reportTime => _s.reportTime;
  @override
  bool get summaryEnabled => _s.summaryEnabled;
  @override
  bool get watcherEnabled => _s.watcherEnabled;
  @override
  bool get watcherDisclosureSeen => _s.watcherDisclosureSeen;
  @override
  bool get watchGlasses => _s.watchGlasses;
  @override
  String get dietaryProfile => _s.dietaryProfile ?? '';
  @override
  String get serverBaseUrl => _s.serverBaseUrl;
  @override
  String get serverBackend => _s.serverBackend;
  @override
  String get appLanguage => _s.appLanguage;
  @override
  String get units => _s.units;
  @override
  String get serverModel => _s.serverModel;
  @override
  String get serverEffort => _s.serverEffort;
  @override
  int get calorieGoal => _s.calorieGoal;
  @override
  String get restaurantAssist => _s.restaurantAssist;
  @override
  bool get restaurantAssistLocation => _s.restaurantAssistLocation;
  @override
  DateTime? get restaurantAssistConsentAt => _s.restaurantAssistConsentAt;
  @override
  String? get restaurantAssistConsentRecipient =>
      _s.restaurantAssistConsentRecipient;
  @override
  Future<void> updateRestaurantAssist({
    String? mode,
    bool? location,
    DateTime? consentAt,
    String? consentRecipient,
    bool clearConsent = false,
  }) =>
      _s.setRestaurantAssist(
        mode: mode,
        location: location,
        consentAt: consentAt,
        consentRecipient: consentRecipient,
        clearConsent: clearConsent,
      );

  @override
  Future<void> update({
    String? apiKey,
    String? provider,
    String? model,
    int? lookbackDays,
    String? reportTime,
    bool? summaryEnabled,
    bool? watcherEnabled,
    bool? watcherDisclosureSeen,
    bool? watchGlasses,
    String? dietaryProfile,
    String? serverBaseUrl,
    String? serverBackend,
    String? appLanguage,
    String? units,
    String? serverModel,
    String? serverEffort,
    int? calorieGoal,
  }) async {
    if (appLanguage != null) await _s.setAppLanguage(appLanguage);
    if (units != null) await _s.setUnits(units);
    if (serverModel != null) await _s.setServerModel(serverModel);
    if (serverEffort != null) await _s.setServerEffort(serverEffort);
    if (calorieGoal != null) await _s.setCalorieGoal(calorieGoal);
    if (provider != null) {
      await _s.setProvider(AiProvider.values
          .firstWhere((v) => v.name == provider, orElse: () => _s.provider));
    }
    // apiKey/model always target the ACTIVE provider (the UI's key and
    // model fields are provider-scoped by design).
    if (apiKey != null) {
      await switch (_s.provider) {
        AiProvider.gemini => _s.setGeminiApiKey(apiKey),
        AiProvider.openai => _s.setOpenaiApiKey(apiKey),
        AiProvider.anthropic => _s.setAnthropicApiKey(apiKey),
        AiProvider.server => _s.setServerApiKey(apiKey),
        AiProvider.qwen => _s.setQwenApiKey(apiKey),
        AiProvider.doubao => _s.setDoubaoApiKey(apiKey),
        AiProvider.glm => _s.setGlmApiKey(apiKey),
        AiProvider.deepseek => _s.setDeepseekApiKey(apiKey),
        AiProvider.xai => _s.setXaiApiKey(apiKey),
        AiProvider.openrouter => _s.setOpenrouterApiKey(apiKey),
      };
    }
    if (model != null) {
      await switch (_s.provider) {
        AiProvider.gemini => _s.setModel(model),
        AiProvider.openai => _s.setOpenaiModel(model),
        AiProvider.anthropic => _s.setAnthropicModel(model),
        // The server chooses its own model; the field is hidden in the UI.
        AiProvider.server => Future<void>.value(),
        AiProvider.qwen => _s.setQwenModel(model),
        AiProvider.doubao => _s.setDoubaoModel(model),
        AiProvider.glm => _s.setGlmModel(model),
        AiProvider.deepseek => _s.setDeepseekModel(model),
        AiProvider.xai => _s.setXaiModel(model),
        AiProvider.openrouter => _s.setOpenrouterModel(model),
      };
    }
    if (lookbackDays != null) {
      await _s.setLookbackDays(lookbackDays);
      await syncBackgroundScan(_s);
    }
    if (reportTime != null) {
      try {
        await _s.setReportTime(reportTime); // validates HH:mm, throws on junk
        // A slot edit while the summary is off must arm nothing.
        if (_s.summaryEnabled) await _rearmSummary();
      } on ArgumentError {
        // UI always sends zero-padded HH:mm; a junk value keeps the default.
      }
    }
    if (summaryEnabled != null) {
      await _s.setSummaryEnabled(summaryEnabled);
      if (summaryEnabled) {
        await _rearmSummary();
      } else {
        // Both halves: this process's Timer AND the card the OS already
        // holds (the iOS one-shot) — else tonight's card still fires.
        _notifier.cancelDaily();
        await _notifier.cancelPendingDaily();
      }
    }
    if (watcherEnabled != null) {
      await _s.setWatcherEnabled(watcherEnabled);
      await syncBackgroundScan(_s); // register/cancel the periodic job
    }
    if (watcherDisclosureSeen != null) {
      await _s.setWatcherDisclosureSeen(watcherDisclosureSeen);
    }
    if (watchGlasses != null) await _s.setWatchGlasses(watchGlasses);
    if (dietaryProfile != null) await _s.setDietaryProfile(dietaryProfile);
    if (serverBaseUrl != null) await _s.setServerBaseUrl(serverBaseUrl);
    if (serverBackend != null) await _s.setServerBackend(serverBackend);
  }
}

/// The Add-flow grid source: list assets, thumbnail per visible cell,
/// original bytes only for the photo the user taps.
class _ShareIntakePicker implements RecentPhotoPicker {
  final PhotoLibrary _library;
  _ShareIntakePicker(this._library);

  @override
  Future<List<RecentAsset>> recentAssets({int limit = 30}) async {
    if (!await _library.requestPermission()) return const [];
    final assets = await _library.recentImages(limit);
    return [
      for (final a in assets.take(limit))
        RecentAsset(a.id, await a.fileName(), a.createDateTime),
    ];
  }

  @override
  Future<Uint8List?> thumbnail(String assetId) =>
      _library.thumbnailByAssetId(assetId);

  @override
  Future<IntakePhoto?> loadOriginal(RecentAsset asset) async {
    final bytes = await _library.originBytesByAssetId(asset.id);
    if (bytes == null || bytes.isEmpty) return null;
    // §8 25 MB cap, as every other intake path enforces: the eager
    // pickFromRecent skipped oversize photos, and the lazy rewrite lost
    // that guard — a 40 MP original would hit the analyzer's normalizer
    // and the base64 upload on a phone that cannot afford either.
    if (bytes.length > maxPhotoBytes) return null;
    // §6.3 dating from the asset's own metadata, same rule the eager path
    // applied; deliberate=true (user-picked, spec §2.3).
    return IntakePhoto(bytes, asset.id, asset.fileName,
        capturedAt: deriveCapturedAt(
            fileName: asset.fileName, assetCreateDate: asset.createdAt),
        deliberate: true,
        // How it was taken (design G2a): the badge, for a picked photo too.
        capture: captureMetaFor(bytes, asset.fileName,
            createDate: asset.createdAt));
  }
}
