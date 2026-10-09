// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get tabToday => 'Today';

  @override
  String get tabHistory => 'History';

  @override
  String get tabBody => 'Body';

  @override
  String get tabSettings => 'Settings';

  @override
  String kcalAmount(String kcal) {
    return '$kcal kcal';
  }

  @override
  String mealsToday(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count meals today',
      one: '1 meal today',
    );
    return '$_temp0';
  }

  @override
  String get rowTypical => 'Typical';

  @override
  String get rowBurn => 'Burn';

  @override
  String get rowEaten => 'Eaten';

  @override
  String get rowResultLeft => '= Left';

  @override
  String get rowResultOver => '= Above typical';

  @override
  String get ringHeadroom => 'headroom';

  @override
  String get ringLeftToday => 'left today';

  @override
  String get ringAboveTypical => 'above typical';

  @override
  String get ringKcalToday => 'kcal today';

  @override
  String get todayEmptyTitle => 'No meals logged yet today.';

  @override
  String get todayEmptyHint =>
      'Tap \"Log\" below to add one from a photo or a description — or turn on \"Watch camera roll\" in Settings and new food photos log themselves.';

  @override
  String get fabLog => 'Log';

  @override
  String get shareDayTooltip => 'Share today as an image';

  @override
  String shareDayFailed(String error) {
    return 'Could not build the image: $error';
  }

  @override
  String historyAverage(String kcal) {
    return 'Average: ~$kcal kcal / day';
  }

  @override
  String get historyNoMeals => 'no meals logged';

  @override
  String historyEmpty(int days) {
    return 'No meals logged in the past $days days.';
  }

  @override
  String get retry => 'Retry';

  @override
  String get bodyWeightHeader => 'Weight';

  @override
  String get bodyMeasurementsHeader => 'Measurements';

  @override
  String get bodyHistoryHeader => 'History';

  @override
  String bodyOnDate(String date) {
    return 'on $date';
  }

  @override
  String get bodyNoChange => 'no change';

  @override
  String get bodyWaist => 'Waist';

  @override
  String get bodyChest => 'Chest';

  @override
  String get bodyHip => 'Hip';

  @override
  String get bodyWaistShort => 'W';

  @override
  String get bodyChestShort => 'C';

  @override
  String get bodyHipShort => 'H';

  @override
  String get bodyEmptyTitle => 'No body data yet.';

  @override
  String get bodyEmptyHint =>
      'Tap Log to record your weight or your waist, chest and hip measurements. Weight logged by chat (\"I weigh 81.6 kg\") lands here too.';

  @override
  String bodySheetLogTitle(String date) {
    return 'Log body · $date';
  }

  @override
  String bodySheetEditTitle(String date) {
    return 'Edit $date';
  }

  @override
  String get bodySheetHint => 'Leave anything you did not measure empty.';

  @override
  String get bodyFieldWeight => 'Weight';

  @override
  String get save => 'Save';

  @override
  String get saving => 'Saving…';

  @override
  String bodyErrNotNumber(String label, String raw) {
    return '$label: \"$raw\" is not a number.';
  }

  @override
  String bodyErrBounds(String label, String min, String max) {
    return '$label must be between $min and $max.';
  }

  @override
  String get bodyErrEmpty => 'Enter at least one value.';

  @override
  String bodyDeleteTitle(String date) {
    return 'Delete $date?';
  }

  @override
  String bodyDeleteBody(String what) {
    return 'Removes the $what recorded for this day.';
  }

  @override
  String get bodyDeleteWeight => 'weight';

  @override
  String get bodyDeleteMeasurements => 'measurements';

  @override
  String get bodyDeleteBoth => 'weight and measurements';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get settingsWelcomeTitle => 'Welcome — one step to start logging';

  @override
  String get settingsWelcomeBody =>
      'Tap AI Provider below, pick a provider and paste its API key (it saves as you type), then Test This Provider.\nThen turn on Watch Camera Roll and new food photos log themselves.\nIn mainland China choose Qwen 通义千问, Doubao 豆包 or GLM 智谱 (GLM\'s default model is free) — the other providers need a VPN. 中国大陆用户请选择国内提供商。';

  @override
  String get settingsSectionAi => 'AI';

  @override
  String get settingsAiFooterPaused =>
      'Analyses are paused — the daily quota was hit. New photos are kept and retried automatically; changing the key or provider on the AI Provider page resumes now.';

  @override
  String get providerQuotaPaused =>
      'Analyses are paused — the daily quota was hit. New photos are kept and retried automatically; changing the key or provider resumes now.';

  @override
  String providerQuotaPausedUntil(String time) {
    return 'Analyses are paused — the daily quota was hit (until $time). New photos are kept and retried automatically; changing the key or provider resumes now.';
  }

  @override
  String get settingsAiFooter =>
      'Photos are analysed by the provider you pick — its key never leaves this phone.';

  @override
  String get settingsRowAiProvider => 'AI Provider';

  @override
  String get settingsSectionPhotos => 'Photos';

  @override
  String get settingsPhotosFooter =>
      'The watcher logs new food photos automatically; the lookback window decides how far back catch-up scans reach.';

  @override
  String get settingsRowWatch => 'Watch Camera Roll';

  @override
  String get settingsRowLookback => 'Backfill Lookback';

  @override
  String lookbackDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String get settingsRowCoverage => 'Photo Coverage';

  @override
  String get settingsSectionReport => 'Report';

  @override
  String get settingsRowReportTime => 'Report Time';

  @override
  String get settingsRowNextSummary => 'Next summary';

  @override
  String timeToday(String time) {
    return 'Today $time';
  }

  @override
  String timeTomorrow(String time) {
    return 'Tomorrow $time';
  }

  @override
  String get nextSummaryNone => 'Not scheduled';

  @override
  String timeYesterday(String time) {
    return 'Yesterday $time';
  }

  @override
  String get settingsRowBackgroundScan => 'Background scan';

  @override
  String get backgroundScanNever => 'Not run yet';

  @override
  String get backgroundScanDisabled => 'Off';

  @override
  String get settingsSectionProfile => 'Profile';

  @override
  String get settingsRowDietaryProfile => 'Dietary Profile';

  @override
  String get profileSet => 'Set';

  @override
  String get profileNotSet => 'Not set';

  @override
  String get settingsSectionData => 'Your Data';

  @override
  String get settingsDataFooter =>
      'Import MERGES an exported file into this phone: meals already here are left alone, so importing twice never doubles your calories.';

  @override
  String get settingsRowExport => 'Export Data…';

  @override
  String get settingsRowImport => 'Import Data…';

  @override
  String get settingsRowLanguage => 'Language';

  @override
  String get languageSystem => 'System';

  @override
  String get languageSheetTitle => 'Language';

  @override
  String get lookbackSheetTitle => 'Backfill lookback';

  @override
  String get lookbackSheetHint => 'How many days catch-up scans look back.';

  @override
  String lookbackSet(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return 'Set $_temp0';
  }

  @override
  String get providerPageTitle => 'AI Provider';

  @override
  String get connectionTypeHeader => 'Connection type';

  @override
  String get connectionTypeFooter =>
      'An API key pays per photo and lives on this phone. A subscription is a flat-rate plan your own cloud server signs into — photos cost nothing extra.';

  @override
  String get typeApiKey => 'API Key';

  @override
  String get typeSubscription => 'Subscription';

  @override
  String get testProvider => 'Test This Provider';

  @override
  String get testProviderFooter =>
      'The test names exactly what is broken: configuration, network, key, account credit, reply format, or quota.';

  @override
  String get apiPageTitle => 'API Key';

  @override
  String get apiProviderHeader => 'Provider';

  @override
  String get apiProviderFooter =>
      'Pay per photo: the key lives on this phone and every photo is a metered API call billed by the vendor. In mainland China choose DeepSeek, Qwen, Doubao or GLM — the others need a VPN. 中国大陆用户请选择国内提供商。';

  @override
  String get noteVpn => 'VPN in China';

  @override
  String get noteFreeTierVpn => 'free · VPN in China';

  @override
  String get noteDirect => 'direct in China';

  @override
  String get noteFreeDirect => 'free · direct in China';

  @override
  String get apiKeyHeader => 'API key';

  @override
  String apiKeyLabel(String provider) {
    return '$provider API key';
  }

  @override
  String get apiKeyFooterDefault =>
      'The key saves as you type. Stored securely on this device only.';

  @override
  String get apiKeyFooterQwen =>
      'From bailian.console.aliyun.com (Alibaba Cloud 百炼 → API-KEY). New accounts get ~1M free tokens per model. Stored securely on this device only.';

  @override
  String get apiKeyFooterDoubao =>
      'From console.volcengine.com/ark (API Key + 开通管理 to activate models). 500k free tokens per model. Stored securely on this device only.';

  @override
  String get apiKeyFooterGlm =>
      'From open.bigmodel.cn (real-name verification required). The default flash model is free. Stored securely on this device only.';

  @override
  String get apiKeyFooterDeepseek =>
      'From platform.deepseek.com (API keys). Pay as you go; reachable from mainland China. Stored securely on this device only.';

  @override
  String get apiKeyFooterXai =>
      'From console.x.ai (API keys). Pay as you go. Stored securely on this device only.';

  @override
  String get apiKeyFooterOpenrouter =>
      'From openrouter.ai/keys. One key reaches GPT, Claude, Gemini, Grok, DeepSeek and more; a few models are free. Stored securely on this device only.';

  @override
  String get modelHeader => 'Model';

  @override
  String get modelCustomRow => 'Custom — type a model name…';

  @override
  String get modelCustomLabel => 'Custom model name';

  @override
  String modelHelperDefault(String model) {
    return 'Default: $model';
  }

  @override
  String modelHelperQwen(String model) {
    return 'Default: $model. Doubles as the cheap tier — qwen3-vl-plus is the stronger paid model.';
  }

  @override
  String modelHelperDoubao(String model) {
    return 'Default: $model. Doubao needs the EXACT versioned ID from the Ark model list — undated names are rejected.';
  }

  @override
  String modelHelperGlm(String model) {
    return 'Default: $model (free tier). glm-4.6v is the stronger paid model.';
  }

  @override
  String modelHelperDeepseek(String model) {
    return 'Default: $model — the only DeepSeek model that accepts photos.';
  }

  @override
  String modelHelperOpenrouter(String model) {
    return 'Default: $model. Any vendor/model slug from openrouter.ai/models that accepts images works.';
  }

  @override
  String get apiInactiveFooter =>
      'A subscription is currently active. Pick a provider above to switch to a pay-per-photo API key.';

  @override
  String get subPageTitle => 'Subscription';

  @override
  String get planHeader => 'Plan';

  @override
  String get planFooter =>
      'Flat-rate: your own cloud machine signs in to ONE plan and analyses photos under it — each photo costs nothing extra. Plan credentials stay on that machine.';

  @override
  String get planClaude => 'Claude Plan';

  @override
  String get planClaudeNote => 'Anthropic';

  @override
  String get planGlmNote => 'Zhipu';

  @override
  String get planDoubaoNote => 'Volcengine';

  @override
  String get noteManyModels => 'many models';

  @override
  String get nlDeleteTitle => 'Delete meals?';

  @override
  String get nlCannotUndo => 'This cannot be undone.';

  @override
  String get planGlm => 'GLM Coding Plan';

  @override
  String get planDoubao => 'Doubao Agent Plan';

  @override
  String get serverHeader => 'Your server';

  @override
  String get serverFooter =>
      'The cloud machine that holds your plan sign-in and runs the analysis — not this phone. This phone keeps only the upload key it uses to talk to that machine.';

  @override
  String get serverAddressLabel => 'Server address';

  @override
  String get serverUploadKeyLabel => 'Server upload key';

  @override
  String get connectClaude => 'Connect Claude';

  @override
  String get connectClaudeFooter =>
      'Signs this server in to your Anthropic subscription. Needs a VPN in mainland China.';

  @override
  String get subInactiveFooter =>
      'An API key is currently active. Pick a plan above to switch to subscription analysis via your server.';

  @override
  String get connectDialogTitle => 'Finish connecting Claude';

  @override
  String get connectDialogBody =>
      'Sign in on the Anthropic page that just opened. It will show you a code — paste it here.';

  @override
  String get connectCodeLabel => 'Authorization code';

  @override
  String get connect => 'Connect';

  @override
  String get connectStartFailed => 'Could not start the sign-in.';

  @override
  String get connectBrowserFailed => 'Could not open the browser.';

  @override
  String get connectDone =>
      'Claude connected — analyses run on your subscription.';

  @override
  String get profilePageTitle => 'Dietary Profile';

  @override
  String get profileFooter =>
      'Preferences and cultural context the AI reads alongside every photo — e.g. \"vegetarian\", \"Cantonese home cooking, light oil\", \"cutting, high protein\". Saves as you type.';

  @override
  String get profileHint =>
      'Nothing yet — the AI assumes no special preferences.';

  @override
  String get addSheetTitle => 'Log a meal';

  @override
  String get addFromPhotos => 'From recent photos';

  @override
  String get addDescribe => 'Describe a meal';

  @override
  String get addDescribeNote => 'any language';

  @override
  String get addManual => 'Enter manually';

  @override
  String get addManualNote => 'no AI';

  @override
  String get addFix => 'Fix or delete a meal';

  @override
  String get addFixFooter => '\"meal 2 was roast duck\" · \"删除第一餐\"';

  @override
  String get addPhotosTip =>
      'Tip: chopsticks or a hand in the shot helps the AI judge portion sizes.';

  @override
  String get addNoPhotos => 'No recent photos found.';

  @override
  String get analyzing => 'Analyzing…';

  @override
  String get reportTitle => 'Daily intake';

  @override
  String reportMeals(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count meals',
      one: '1 meal',
    );
    return '$_temp0';
  }

  @override
  String get reportNoMeals => 'No meals logged.';

  @override
  String get reportFooter => 'Logged with Bitewise';

  @override
  String typicalDayHeadroom(String typical, String delta) {
    return 'Typical day: ~$typical kcal · ~$delta kcal headroom';
  }

  @override
  String typicalDayOver(String typical, String delta) {
    return 'Typical day: ~$typical kcal · ~$delta kcal above typical';
  }

  @override
  String get historyDayPattern => 'EEEE, MMM dd';

  @override
  String garminBurnLine(String burn, String net) {
    return 'Active burn: ~$burn kcal (Garmin) · net ~$net kcal';
  }

  @override
  String garminBurnOnlyLine(String burn) {
    return 'Active burn: ~$burn kcal (Garmin)';
  }

  @override
  String get settingsRowUnits => 'Units';

  @override
  String get unitsMetric => 'Metric';

  @override
  String get unitsImperial => 'Imperial';

  @override
  String get unitsMetricDetail => 'Metric — kg · cm';

  @override
  String get unitsImperialDetail => 'Imperial — lb · in';

  @override
  String get unitsSheetTitle => 'Units';

  @override
  String get unitsFooter =>
      'How body weight and measurements are shown and entered. Food stays in grams and kcal either way.';

  @override
  String get bodyEmptyHintImperial =>
      'Tap Log to record your weight or your waist, chest and hip measurements. Weight logged by chat (\"I weigh 180 lb\") lands here too.';

  @override
  String bodySince(String date) {
    return 'since $date';
  }

  @override
  String get addLeftover => 'Leftovers';

  @override
  String get addLeftoverNote => 'deduct what\'s left';

  @override
  String get leftoverTitle => 'Leftovers';

  @override
  String get leftoverPickMeal => 'Which meal was this?';

  @override
  String get leftoverPickPhoto =>
      'Pick the photo of what\'s LEFT — the meal\'s calories shrink to what you ate.';

  @override
  String get leftoverChangeMeal => 'Change';

  @override
  String get leftoverNotSame => 'This doesn\'t look like the same meal';

  @override
  String get leftoverUseAnyway => 'Use anyway';

  @override
  String get leftoverResultTitle => 'Deduct leftovers?';

  @override
  String leftoverResultLine(String pct, String kcal, String now) {
    return 'Eaten ~$pct% — deducting $kcal kcal, this meal is now $now kcal.';
  }

  @override
  String leftoverDupRemoved(String kcal) {
    return 'This photo was also logged as its own $kcal kcal meal — that duplicate will be removed.';
  }

  @override
  String get leftoverApplied => 'Leftovers deducted.';

  @override
  String get leftoverFailed =>
      'Couldn\'t estimate the leftovers from that photo.';

  @override
  String get leftoverNoMeals =>
      'No meals from today or yesterday to deduct from.';

  @override
  String get planTuningHeader => 'Model & thinking';

  @override
  String get planTuningFooter =>
      'Which Claude model analyzes on your server, and how hard it thinks. Default follows the server\'s own setting; only the Claude plan offers this — the other plans choose models themselves.';

  @override
  String get planModelRow => 'Model';

  @override
  String get planEffortRow => 'Thinking effort';

  @override
  String get planChoiceDefault => 'Server default';

  @override
  String get planModelOpus => 'Opus — most accurate';

  @override
  String get planModelSonnet => 'Sonnet — balanced';

  @override
  String get planModelHaiku => 'Haiku — fastest';

  @override
  String get planEffortLow => 'Low — fastest';

  @override
  String get planEffortMedium => 'Medium';

  @override
  String get planEffortHigh => 'High — most thorough';

  @override
  String get planEffortLowShort => 'Low';

  @override
  String get planEffortHighShort => 'High';

  @override
  String get planModelFable => 'Fable — frontier · needs credits on Pro';

  @override
  String typicalDayOnly(String typical) {
    return 'Typical day: ~$typical kcal';
  }

  @override
  String get garminIdleLine =>
      'Garmin connected · no activity recorded yet today';

  @override
  String coachTitle(String kcal) {
    return 'Today: $kcal kcal';
  }

  @override
  String coachTitleYesterday(String kcal) {
    return 'Yesterday: $kcal kcal';
  }

  @override
  String get coachEmpty =>
      'Nothing logged today. Snap your next meal and it lands here automatically.';

  @override
  String get coachEmptyYesterday =>
      'Nothing logged yesterday. Snap your next meal and it lands here automatically.';

  @override
  String coachUnderGoal(String delta) {
    return '$delta kcal under your goal — that\'s a real cut. Discipline like this compounds. 💪';
  }

  @override
  String coachUnderTypical(String delta) {
    return '$delta kcal below your usual day. Strong work — that\'s the kind of day that moves the needle.';
  }

  @override
  String coachPartialGoal(String delta) {
    return '$delta kcal under your goal — any meals not logged yet? Add them in BiteWise.';
  }

  @override
  String coachPartialTypical(String delta) {
    return '$delta kcal below your usual day — any meals not logged yet? Add them in BiteWise.';
  }

  @override
  String get coachOnTarget =>
      'Right on target. Consistency beats intensity — keep stacking days like this.';

  @override
  String coachOverGoal(String delta) {
    return '$delta kcal over your goal. One day doesn\'t undo a week — just keep going.';
  }

  @override
  String coachOverTypical(String delta) {
    return '$delta kcal above your usual. Worth knowing, not worth worrying about — the next meal\'s a clean slate.';
  }

  @override
  String get coachNoReference =>
      'Logged and counted. A few more days and I can tell you how this compares to your usual.';

  @override
  String coachDetail(String meals, String protein) {
    return '$meals meals · $protein g protein';
  }

  @override
  String get settingsRowGoal => 'Daily calorie goal';

  @override
  String get goalSheetTitle => 'Daily calorie goal';

  @override
  String get goalNotSet => 'Not set';

  @override
  String get goalFooter =>
      'The daily summary measures against this. Leave it empty and it compares against your typical day instead.';

  @override
  String get goalFieldLabel => 'kcal per day';

  @override
  String get goalClear => 'Clear goal';

  @override
  String get macroProtein => 'Protein';

  @override
  String get macroCarbs => 'Carbs';

  @override
  String get macroFat => 'Fat';

  @override
  String get macroProteinShort => 'P';

  @override
  String get macroCarbsShort => 'C';

  @override
  String get macroFatShort => 'F';

  @override
  String get editorProteinLabel => 'Protein (g)';

  @override
  String get editorCarbsLabel => 'Carbs (g)';

  @override
  String get editorFatLabel => 'Fat (g)';

  @override
  String get diagTitle => 'Test AI provider';

  @override
  String get diagIntro =>
      'Checks your AI setup step by step and names exactly what is broken: configuration, network (VPN), key, account credit, reply format, and quota. Running the test spends two small AI calls.';

  @override
  String get diagRunning => 'Testing…';

  @override
  String get diagRunAgain => 'Run again';

  @override
  String get diagRunChecks => 'Run the checks';

  @override
  String get diagVerdictOk =>
      'Everything works. If a photo still fails, it is photo-specific — try \"Analyze again\" on it.';

  @override
  String diagVerdictProblems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count problems found — the red/orange rows below say what to do.',
      one: '1 problem found — the red/orange rows below say what to do.',
    );
    return '$_temp0';
  }

  @override
  String get diagStageTestRun => 'Test run';

  @override
  String get diagTestRunFailed => 'The check itself failed part-way through.';

  @override
  String get diagFixTestRun =>
      'Re-run; if it keeps failing here, the provider is answering something the app cannot parse at all.';

  @override
  String get diagStageConfiguration => 'Configuration';

  @override
  String get diagStageEndpoint => 'Endpoint reachability';

  @override
  String get diagStageAuth => 'Authentication';

  @override
  String get diagStageText => 'Text analysis';

  @override
  String get diagStagePhoto => 'Photo analysis';

  @override
  String get diagStageQuota => 'Quota';

  @override
  String get diagNoServerAddress => 'No server address is set.';

  @override
  String get diagFixEnterServer =>
      'Enter your server address in Settings, then re-run.';

  @override
  String get diagNoUploadKey => 'No server upload key is set.';

  @override
  String get diagNoApiKey => 'No API key is set for this provider.';

  @override
  String get diagFixPasteKey => 'Paste the key in Settings, then re-run.';

  @override
  String diagServerConfigured(String backend) {
    return 'Server address and upload key are set (backend: $backend).';
  }

  @override
  String diagProviderConfigured(String provider, String model) {
    return 'Provider \"$provider\" with a key and model \"$model\".';
  }

  @override
  String get diagTargetServer => 'server';

  @override
  String get diagTargetYourServer => 'your server';

  @override
  String diagEndpointAnswered(String target) {
    return 'The $target endpoint answered.';
  }

  @override
  String diagEndpointUnreachable(String target) {
    return 'Could not reach $target at all.';
  }

  @override
  String get diagFixVpn =>
      'This provider is blocked in mainland China without a VPN. Turn the VPN on, or switch to Qwen/Doubao/GLM (no VPN needed).';

  @override
  String get diagFixServerUnreachable =>
      'Check the server address, that the server is running, and your network.';

  @override
  String get diagFixNetwork => 'Check your network connection and try again.';

  @override
  String get diagKeyAccepted => 'The provider accepted your key.';

  @override
  String get diagOutOfCredit =>
      'The key works, but the account cannot pay right now.';

  @override
  String get diagFixTopUp =>
      'Top up the provider account, or switch to a free tier (Zhipu GLM\'s default vision model is free, no VPN needed in mainland China).';

  @override
  String get diagRateLimited =>
      'The key works, but the provider is rate-limiting right now.';

  @override
  String get diagFixWaitRateLimit =>
      'Wait a minute and re-run; photos are kept and retried automatically meanwhile.';

  @override
  String get diagKeyRejected => 'The key was not accepted.';

  @override
  String get diagFixRecopyKey =>
      'Re-copy the key from the provider console — and check it belongs to THIS provider (keys are not interchangeable).';

  @override
  String diagModelNotFound(String model) {
    return 'The key works, but the model \"$model\" was not found.';
  }

  @override
  String get diagTextOk =>
      'The model answered JSON — chat fixes and \"describe a meal\" work.';

  @override
  String get diagTextBad =>
      'The text request did not succeed (busy server, rate limit or closed usage window, timeout, or no JSON from the model).';

  @override
  String get diagTextBadDetail =>
      'Chat fixes and \"describe a meal\" may fail; photo analysis can still work.';

  @override
  String get diagFixPickModel =>
      'If this persists, pick a different model in Settings.';

  @override
  String get diagTextBadPhotoAlsoFailed =>
      'Chat fixes and \"describe a meal\" may fail. The photo request below failed too, so its reason is the likely cause of both.';

  @override
  String get diagFixTextPickModel =>
      'If photo analysis works but this keeps failing, pick a different model in Settings.';

  @override
  String get diagFixTextFollowPhoto =>
      'Follow the fix on the photo row, then run the test again.';

  @override
  String get diagPhotoOk =>
      'The model analyzed a test image and answered the meal format.';

  @override
  String get diagPhotoThoughtFood => 'It even thought the test disc was food.';

  @override
  String get diagPhotoNotFood =>
      'Verdict \"not food\" — correct for the test image.';

  @override
  String get diagPhotoTempFail =>
      'Photo analysis failed with a TEMPORARY problem.';

  @override
  String get diagPhotoPermFail =>
      'Photo analysis failed and a retry will NOT fix it.';

  @override
  String get diagFixPhotoTemp =>
      'Usually a rate limit or a busy server — photos are kept and retried automatically.';

  @override
  String get diagFixPhotoPerm =>
      'Read the message above — it names the broken piece (model, format, or account).';

  @override
  String get diagQuotaPaused =>
      'Analyses are PAUSED — the daily quota was hit.';

  @override
  String diagQuotaPausedUntil(String until) {
    return 'Paused until $until.';
  }

  @override
  String get diagFixQuota =>
      'Wait it out (photos are kept), or change the key or provider to resume immediately.';

  @override
  String get diagQuotaOk => 'No quota pause is active.';

  @override
  String get addPhotosTitle => 'Recent photos';

  @override
  String get addPhotoUnreadable =>
      'That photo could not be read (too large or removed).';

  @override
  String addPhotosLoadFailed(String error) {
    return 'Could not load photos: $error';
  }

  @override
  String get photoPermissionDenied =>
      'Bitewise isn\'t allowed to see your photos.';

  @override
  String get openSystemSettings => 'Open system settings';

  @override
  String get outcomeSaved => 'Meal logged';

  @override
  String get outcomeSkipped => 'No food detected';

  @override
  String get outcomeDuplicate => 'Duplicate photo';

  @override
  String get outcomeAlreadyTracked => 'Already logged';

  @override
  String get outcomeInFlight => 'Still analyzing';

  @override
  String get outcomeFailed => 'Analysis failed';

  @override
  String get outcomeLeftoverApplied => 'Leftovers deducted';

  @override
  String get outcomeLogManuallyHint =>
      'If this IS food, log it yourself — the photo stays attached to the meal.';

  @override
  String get okButton => 'OK';

  @override
  String get logManually => 'Log manually';

  @override
  String get describeTitle => 'Describe a meal';

  @override
  String get describeLabel => 'What did you eat?';

  @override
  String get describeHint =>
      'e.g. \"two eggs and toast with butter\"\nor \"一碗牛肉面加一个鸡蛋\"';

  @override
  String get describeHelp =>
      'Any language works. You will see the estimate and can fix it before it is saved.';

  @override
  String get describeEstimating => 'Estimating…';

  @override
  String get describeEstimate => 'Estimate this meal';

  @override
  String get notificationsOffHint =>
      'Notifications are off — the daily summary can\'t be delivered.';

  @override
  String outcomeSavedMsg(String summary) {
    return 'Meal logged: $summary';
  }

  @override
  String outcomeLeftoverMsg(String summary) {
    return 'Leftovers deducted: $summary';
  }

  @override
  String outcomeFailedKeptMsg(String reason) {
    return 'Photo analysis failed — kept for retry. $reason';
  }

  @override
  String get backlogTruncatedWarning =>
      'Photo library backlog is very large — some older photos may need to be added manually.';

  @override
  String get outcomeNotFoodMsg => 'No food detected in this photo.';

  @override
  String get outcomeDuplicateMsg =>
      'Looks like a duplicate of a photo logged minutes ago.';

  @override
  String get outcomeAlreadyTrackedMsg => 'This photo was already logged.';

  @override
  String get outcomeInFlightMsg =>
      'This photo is still being analyzed — check back in a moment.';

  @override
  String get errNoApiKey =>
      'No API key is set for this provider — add one in Settings.';

  @override
  String get errNoServerKey =>
      'No server address or upload key is set — add them in Settings.';

  @override
  String get errRejectedKey =>
      'The provider rejected the API key. Check the key in Settings.';

  @override
  String get errRateLimited =>
      'The provider is rate-limiting right now — the photo is kept and retried later.';

  @override
  String get errQuotaPaused =>
      'Analysis is paused: the daily quota was hit. The photo is kept and retried later.';

  @override
  String get errNetwork =>
      'Could not reach the provider (network or service issue). The photo is kept and retried later.';

  @override
  String get errBadModel =>
      'The provider rejected the model — check the model name in Settings.';

  @override
  String get errBadResponse =>
      'The AI answered in a form the app could not use.';

  @override
  String get errBadPhoto =>
      'This photo could not be processed (it could not be decoded).';

  @override
  String get errServerBusy =>
      'Your server is busy with another analysis — the photo is kept and retried later.';

  @override
  String get mealCardAutoTitle => '🍽️ Meal logged automatically';

  @override
  String dayLoadFailed(String error) {
    return 'Could not load this day: $error';
  }

  @override
  String get dayEmpty => 'Nothing logged on this day yet. Tap + to add a meal.';

  @override
  String get notFoodTag => 'not food';

  @override
  String fixRequestFailed(String error) {
    return 'That request failed: $error';
  }

  @override
  String get fixTitle => 'Fix a meal';

  @override
  String get fixIntro =>
      'Say what to change or delete — describe the meal however you like (\"the noodles\", \"breakfast\", \"the 600 kcal one\"), in any language. To move a meal to another day or time, tap it on Today or in History and change its date or time.';

  @override
  String get fixNamingTip =>
      'Naming the food is safest — meal numbers count across the last 7 days, not just today.';

  @override
  String get fixLabel => 'What should change?';

  @override
  String get fixHint =>
      'e.g. \"the noodles were roast duck rice\"\nor \"删除刚才那杯咖啡\"';

  @override
  String get working => 'Working…';

  @override
  String get fixApply => 'Apply the fix';

  @override
  String get fixAppliedHeader => 'Applied this session';

  @override
  String editorSaveFailed(String error) {
    return 'Could not save: $error';
  }

  @override
  String editorDeleteFailed(String error) {
    return 'Could not delete: $error';
  }

  @override
  String get editorDeleteTitle => 'Delete this meal?';

  @override
  String get editorDeleteBody =>
      'It will be removed from your history and totals. This cannot be undone.';

  @override
  String get editorTitleAdd => 'Add meal';

  @override
  String get editorTitleEdit => 'Edit meal';

  @override
  String get editorDeleteTooltip => 'Delete meal';

  @override
  String get editorDescriptionLabel => 'What was it?';

  @override
  String get editorTotalsHeader => 'Totals';

  @override
  String get editorCaloriesLabel => 'Calories (kcal)';

  @override
  String get editorItemsHeader => 'Items';

  @override
  String get editorTotalsDerivedHint => 'Totals follow these items';

  @override
  String get editorAddItem => 'Add item';

  @override
  String get editorAdd => 'Add';

  @override
  String get editorItemLabel => 'Item';

  @override
  String get editorRemoveItemTooltip => 'Remove item';

  @override
  String editorErrNotNumber(String label) {
    return '$label must be a number.';
  }

  @override
  String editorErrNegative(String label) {
    return '$label cannot be negative.';
  }

  @override
  String editorErrTooLarge(String label, String max) {
    return '$label looks too large (max $max).';
  }

  @override
  String editorErrDescTooLong(String max) {
    return 'Description is too long (max $max).';
  }

  @override
  String get editorErrDate => 'Date must be a real YYYY-MM-DD date.';

  @override
  String get editorErrTime => 'Time must look like 07:30 PM.';

  @override
  String editorErrTooManyItems(String max) {
    return 'Too many items (max $max).';
  }

  @override
  String editorErrsNeedFixing(int count) {
    return '$count things need fixing — see the top.';
  }

  @override
  String get editorFieldCalories => 'Calories';

  @override
  String editorItemFieldCalories(int n) {
    return 'Item $n calories';
  }

  @override
  String editorItemFieldProtein(int n) {
    return 'Item $n protein';
  }

  @override
  String editorItemFieldCarbs(int n) {
    return 'Item $n carbs';
  }

  @override
  String editorItemFieldFat(int n) {
    return 'Item $n fat';
  }

  @override
  String get editorItemKcalLabel => 'kcal';

  @override
  String get covPermissionRequired =>
      'Photo permission is required for the check.';

  @override
  String covCheckFailed(String error) {
    return 'Check failed: $error';
  }

  @override
  String get covNoAnalysis =>
      'No analysis is possible right now — add a key for the selected provider, or wait for the quota pause to end.';

  @override
  String covBulkTitle(String verb, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count photos',
      one: '1 photo',
    );
    return '$verb $_temp0?';
  }

  @override
  String covBulkBody(int minutes, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count model calls',
      one: '1 model call',
    );
    return 'Each photo is analyzed separately, one after another — expect roughly $_temp0 and $_temp1. You can leave this screen; the work continues.';
  }

  @override
  String get covPhotoUnreadable => 'That photo is no longer readable.';

  @override
  String get covTitle => 'Photo coverage';

  @override
  String covIntro(int days) {
    return 'Checks every photo of the last $days day(s) against the log: each one is fingerprinted and looked up — nothing is sent to the AI by the check itself.';
  }

  @override
  String get covChecking => 'Checking…';

  @override
  String get covRun => 'Run check';

  @override
  String covNeverScanned(int count) {
    return 'Never scanned ($count)';
  }

  @override
  String get covLogAll => 'Log all';

  @override
  String covMoreLogAll(int count) {
    return '…and $count more — \"Log all\" still covers every one.';
  }

  @override
  String covJudgedNotFood(int count) {
    return 'Judged \"not food\" ($count)';
  }

  @override
  String get covAnalyzeAgain => 'Analyze again';

  @override
  String get covNotFoodHelp =>
      'Drinks, order screenshots and unusual dishes land here. \"Analyze again\" re-asks the AI (useful after the rules improve); tap a row to enter it yourself.';

  @override
  String covFailedEarlier(int count) {
    return 'Failed earlier ($count)';
  }

  @override
  String get covRetryAll => 'Retry all';

  @override
  String get covFailedHelp =>
      '\"Retry all\" asks the AI again (the same error often comes back); tap a row to enter it yourself.';

  @override
  String covMoreRetryAll(int count) {
    return '…and $count more — \"Retry all\" still covers every one.';
  }

  @override
  String covAllAccounted(int count) {
    return 'All $count photos are accounted for.';
  }

  @override
  String covSummary(int scanned, int missing) {
    return '$scanned photos checked — $missing never scanned.';
  }

  @override
  String get covLimitedAccess =>
      'Note: the app has LIMITED photo access — only the selected photos can be checked. Grant full access in system settings for a complete answer.';

  @override
  String get covTruncated =>
      'Note: over 2000 photos in this window — older ones were not checked. Shorten the window for a complete answer.';

  @override
  String get covVerbLog => 'Log';

  @override
  String get covVerbRetry => 'Retry';

  @override
  String get covProgLogging => 'Logging';

  @override
  String get covProgReanalyzing => 'Re-analyzing';

  @override
  String get covProgRetrying => 'Retrying';

  @override
  String covStopped(String label, int attempted, int total, int remaining) {
    String _temp0 = intl.Intl.pluralLogic(
      remaining,
      locale: localeName,
      other: '$remaining photos were',
      one: '1 photo was',
    );
    return '$label stopped after $attempted of $total: analysis is unavailable right now (quota pause or missing key). The remaining $_temp0 not touched — run this again later.';
  }

  @override
  String covStoppedBecause(
    String label,
    int attempted,
    int total,
    String reason,
    int remaining,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      remaining,
      locale: localeName,
      other: '$remaining photos were',
      one: '1 photo was',
    );
    return '$label stopped after $attempted of $total: $reason The remaining $_temp0 not touched — run this again later.';
  }

  @override
  String covMoreNotFood(int count) {
    return '…and $count more.';
  }

  @override
  String get covUnnamedPhoto => '(unnamed photo)';

  @override
  String covDone(String label, int count) {
    return '$label done ($count photos).';
  }

  @override
  String covDoneFailures(String label, int failures, int count) {
    return '$label done — $failures of $count could not be processed (kept in the Failed list for retry).';
  }

  @override
  String covDaysShort(int days) {
    return '$days d';
  }

  @override
  String covLoggedAsMeals(int count) {
    return '$count logged as meals';
  }

  @override
  String covNotFoodCount(int count) {
    return '$count not food';
  }

  @override
  String covLeftoverCount(int count) {
    return '$count leftover photos (deducted from their meal)';
  }

  @override
  String covFailedCount(int count) {
    return '$count failed';
  }

  @override
  String covDeletedCount(int count) {
    return '$count deleted by you';
  }

  @override
  String covInFlightCount(int count) {
    return '$count in progress';
  }

  @override
  String covUnreadableCount(int count) {
    return '$count unreadable';
  }

  @override
  String covTooLargeCount(int count) {
    return '$count too large to analyze';
  }

  @override
  String get macroNoBreakdown => 'No macro breakdown recorded.';

  @override
  String get setupLinkTitle => 'Set up server from this link?';

  @override
  String setupLinkBody(String server, String backend, String keyTail) {
    return 'Server: $server\nPlan: $backend\nUpload key: ••••$keyTail\n\nYour meal photos will be sent to this server for analysis. Confirm only if it is yours.';
  }

  @override
  String get setupLinkConfirm => 'Use this server';

  @override
  String get setupLinkDone =>
      'Server configured — photos will be analyzed through your plan.';

  @override
  String get setupLinkInvalid => 'That setup link is not valid.';

  @override
  String get serverLoginRow => 'Server Claude sign-in';

  @override
  String get serverLoginOk => 'Signed in ✓';

  @override
  String get serverLoginMissing => 'Not signed in';

  @override
  String get serverLoginUnknown => 'Could not check';

  @override
  String get serverLoginChecking => 'Checking…';

  @override
  String get serverLoginFooter =>
      'Signed in: nothing to connect. Not signed in: use Connect Claude below. Could not check: the server is unreachable or rejected the key.';

  @override
  String get errServerFailed =>
      'Your server could not analyze this photo this time — it is kept and retried later.';

  @override
  String errServerRejected(String code) {
    return 'Your server rejected this request ($code). Update the app and the server to matching versions, then retry from Settings › Coverage.';
  }

  @override
  String get watcherPermissionDenied =>
      'Photo library permission is required for automatic intake.';

  @override
  String get watcherOnQuotaPaused =>
      'Watching is on, but analyses are paused by the daily quota — new photos will wait.';

  @override
  String get watcherOnNoKey =>
      'Watching is on, but photos won\'t be analyzed until a working API key is set above.';

  @override
  String get watcherLimitedAccess =>
      'Only SELECTED photos are shared, so new food photos won\'t be seen automatically. Grant access to ALL photos for automatic logging.';

  @override
  String get fixAction => 'Fix';

  @override
  String get importDialogTitle => 'Import exported data';

  @override
  String get importDialogBody =>
      'Paste the contents of an exported JSON file. Existing meals are kept; only new ones are added.';

  @override
  String get importAction => 'Import';

  @override
  String get importNothingNew =>
      'Nothing new to import — everything in that file is already here.';

  @override
  String importDone(int meals, int rows) {
    String _temp0 = intl.Intl.pluralLogic(
      meals,
      locale: localeName,
      other: '$meals meals',
      one: '1 meal',
    );
    return 'Imported $_temp0 ($rows rows total).';
  }

  @override
  String importDoneKept(int meals, int rows, int kept) {
    String _temp0 = intl.Intl.pluralLogic(
      meals,
      locale: localeName,
      other: '$meals meals',
      one: '1 meal',
    );
    return 'Imported $_temp0 ($rows rows total); $kept already here.';
  }

  @override
  String importFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get exportShareSubject => 'CalorieTracker data export';

  @override
  String get importErrNotJson => 'That file is not JSON.';

  @override
  String get importErrNotExport => 'That file is not a CalorieTracker export.';

  @override
  String get importErrWrongFormatTag =>
      'That file is not a CalorieTracker export (wrong format tag).';

  @override
  String get importErrBadVersion => 'That export has an unusable version tag.';

  @override
  String get importErrNoTables => 'That export has no tables section.';

  @override
  String get nlSomethingWrong =>
      '❌ Something went wrong handling that message. Please try again.';

  @override
  String get nlMissingServer =>
      '❌ No server is configured — set your server address and upload key in Settings first.';

  @override
  String nlMissingKey(String provider) {
    return '❌ No $provider API key yet — add one in Settings to use text logging.';
  }

  @override
  String get nlTypeFirst => 'Type what you ate first.';

  @override
  String get nlErrorContactingAi => '❌ Error contacting AI. Please try again.';

  @override
  String get nlNoFoodDetected =>
      '🚫 I couldn\'t detect food in that description.';

  @override
  String nlInvalidMealIndex(String shown, int count) {
    return '❌ Invalid meal index ($shown). You have $count recent meals.';
  }

  @override
  String nlCorrectedMeal(int n) {
    return '✏️ Corrected meal $n!';
  }

  @override
  String nlKcalChange(String oldKcal, String newKcal, String diff) {
    return '🔥 $oldKcal → $newKcal ($diff)';
  }

  @override
  String nlDeleteAsk(int count) {
    return '🗑️ Delete $count meal(s)?';
  }

  @override
  String get nlDeleteCancelled => '👍 Cancelled — nothing was deleted.';

  @override
  String nlDeletedMeals(int count) {
    return '🗑️ Deleted $count meal(s):';
  }

  @override
  String get nlAddedManualMeal => '✅ Added new manual meal:';

  @override
  String nlMealLabel(String desc, String date, String time, String kcal) {
    return '$desc ($date $time, ~$kcal)';
  }

  @override
  String get nlNoActions =>
      '❌ I couldn\'t work out what to do with that. Try one request at a time, e.g. “change meal 2 to roast duck rice”.';

  @override
  String get nlRequestFailed => '❌ That request failed. Please try again.';

  @override
  String nlAllActionsFailed(int count) {
    return '❌ All $count requested actions failed. Please try again.';
  }

  @override
  String nlSomeActionsFailed(int failed, int total) {
    return '⚠️ $failed of $total requested action(s) failed — the rest were applied.';
  }

  @override
  String get nlCannotCorrectNoMeals =>
      '❌ Cannot correct because no meals are logged recently.';

  @override
  String get nlCorrectionUnusable =>
      '❌ That correction didn\'t include a usable updated analysis, so I left the meal unchanged. Try restating it, e.g. “meal 2 was roast duck rice, ~780 kcal”.';

  @override
  String get nlCannotDeleteNoMeals =>
      '❌ Cannot delete because no meals are logged recently.';

  @override
  String get nlDeleteWhich =>
      '❌ Didn\'t catch which meals to delete. Try being more specific.';

  @override
  String get nlDeleteNoMatch =>
      '❌ Couldn\'t match those meals to the recent list.';

  @override
  String nlDescribedMultiple(int count) {
    return 'That described $count meals — only the first is shown. Describe the others one at a time.';
  }

  @override
  String get nlWeightUnreadable =>
      '⚖️ I couldn\'t read a valid body weight (30–300 kg). Try “I weigh 72.5 kg”.';

  @override
  String nlWeightLogged(String kg, String date) {
    return '⚖️ Logged $kg kg for $date.';
  }

  @override
  String get nlActivityUnreadable =>
      '🏃 I couldn\'t find any activity numbers to log. Try “burned 450 kcal running 5 km”.';

  @override
  String nlActivityLogged(String bits, String date) {
    return '🏃 Logged activity: $bits ($date).';
  }

  @override
  String nlStepsAmount(String steps) {
    return '$steps steps';
  }

  @override
  String nlKmAmount(String km) {
    return '$km km';
  }

  @override
  String get nlChatFallback =>
      'I\'m not sure what you mean. Try describing a meal or correction!';
}
