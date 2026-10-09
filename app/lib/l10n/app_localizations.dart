import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @tabToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get tabToday;

  /// No description provided for @tabHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get tabHistory;

  /// No description provided for @tabBody.
  ///
  /// In en, this message translates to:
  /// **'Body'**
  String get tabBody;

  /// No description provided for @tabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// No description provided for @kcalAmount.
  ///
  /// In en, this message translates to:
  /// **'{kcal} kcal'**
  String kcalAmount(String kcal);

  /// No description provided for @mealsToday.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 meal today} other{{count} meals today}}'**
  String mealsToday(int count);

  /// No description provided for @rowTypical.
  ///
  /// In en, this message translates to:
  /// **'Typical'**
  String get rowTypical;

  /// No description provided for @rowBurn.
  ///
  /// In en, this message translates to:
  /// **'Burn'**
  String get rowBurn;

  /// No description provided for @rowEaten.
  ///
  /// In en, this message translates to:
  /// **'Eaten'**
  String get rowEaten;

  /// No description provided for @rowResultLeft.
  ///
  /// In en, this message translates to:
  /// **'= Left'**
  String get rowResultLeft;

  /// No description provided for @rowResultOver.
  ///
  /// In en, this message translates to:
  /// **'= Above typical'**
  String get rowResultOver;

  /// No description provided for @ringHeadroom.
  ///
  /// In en, this message translates to:
  /// **'headroom'**
  String get ringHeadroom;

  /// No description provided for @ringLeftToday.
  ///
  /// In en, this message translates to:
  /// **'left today'**
  String get ringLeftToday;

  /// No description provided for @ringAboveTypical.
  ///
  /// In en, this message translates to:
  /// **'above typical'**
  String get ringAboveTypical;

  /// No description provided for @ringKcalToday.
  ///
  /// In en, this message translates to:
  /// **'kcal today'**
  String get ringKcalToday;

  /// No description provided for @todayEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No meals logged yet today.'**
  String get todayEmptyTitle;

  /// No description provided for @todayEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Tap \"Log\" below to add one from a photo or a description — or turn on \"Watch camera roll\" in Settings and new food photos log themselves.'**
  String get todayEmptyHint;

  /// No description provided for @fabLog.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get fabLog;

  /// No description provided for @shareDayTooltip.
  ///
  /// In en, this message translates to:
  /// **'Share today as an image'**
  String get shareDayTooltip;

  /// No description provided for @shareDayFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not build the image: {error}'**
  String shareDayFailed(String error);

  /// No description provided for @historyAverage.
  ///
  /// In en, this message translates to:
  /// **'Average: ~{kcal} kcal / day'**
  String historyAverage(String kcal);

  /// No description provided for @historyNoMeals.
  ///
  /// In en, this message translates to:
  /// **'no meals logged'**
  String get historyNoMeals;

  /// No description provided for @historyEmpty.
  ///
  /// In en, this message translates to:
  /// **'No meals logged in the past {days} days.'**
  String historyEmpty(int days);

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @bodyWeightHeader.
  ///
  /// In en, this message translates to:
  /// **'Weight'**
  String get bodyWeightHeader;

  /// No description provided for @bodyMeasurementsHeader.
  ///
  /// In en, this message translates to:
  /// **'Measurements'**
  String get bodyMeasurementsHeader;

  /// No description provided for @bodyHistoryHeader.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get bodyHistoryHeader;

  /// No description provided for @bodyOnDate.
  ///
  /// In en, this message translates to:
  /// **'on {date}'**
  String bodyOnDate(String date);

  /// No description provided for @bodyNoChange.
  ///
  /// In en, this message translates to:
  /// **'no change'**
  String get bodyNoChange;

  /// No description provided for @bodyWaist.
  ///
  /// In en, this message translates to:
  /// **'Waist'**
  String get bodyWaist;

  /// No description provided for @bodyChest.
  ///
  /// In en, this message translates to:
  /// **'Chest'**
  String get bodyChest;

  /// No description provided for @bodyHip.
  ///
  /// In en, this message translates to:
  /// **'Hip'**
  String get bodyHip;

  /// No description provided for @bodyWaistShort.
  ///
  /// In en, this message translates to:
  /// **'W'**
  String get bodyWaistShort;

  /// No description provided for @bodyChestShort.
  ///
  /// In en, this message translates to:
  /// **'C'**
  String get bodyChestShort;

  /// No description provided for @bodyHipShort.
  ///
  /// In en, this message translates to:
  /// **'H'**
  String get bodyHipShort;

  /// No description provided for @bodyEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No body data yet.'**
  String get bodyEmptyTitle;

  /// No description provided for @bodyEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Tap Log to record your weight or your waist, chest and hip measurements. Weight logged by chat (\"I weigh 81.6 kg\") lands here too.'**
  String get bodyEmptyHint;

  /// No description provided for @bodySheetLogTitle.
  ///
  /// In en, this message translates to:
  /// **'Log body · {date}'**
  String bodySheetLogTitle(String date);

  /// No description provided for @bodySheetEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit {date}'**
  String bodySheetEditTitle(String date);

  /// No description provided for @bodySheetHint.
  ///
  /// In en, this message translates to:
  /// **'Leave anything you did not measure empty.'**
  String get bodySheetHint;

  /// No description provided for @bodyFieldWeight.
  ///
  /// In en, this message translates to:
  /// **'Weight'**
  String get bodyFieldWeight;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @saving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get saving;

  /// No description provided for @bodyErrNotNumber.
  ///
  /// In en, this message translates to:
  /// **'{label}: \"{raw}\" is not a number.'**
  String bodyErrNotNumber(String label, String raw);

  /// No description provided for @bodyErrBounds.
  ///
  /// In en, this message translates to:
  /// **'{label} must be between {min} and {max}.'**
  String bodyErrBounds(String label, String min, String max);

  /// No description provided for @bodyErrEmpty.
  ///
  /// In en, this message translates to:
  /// **'Enter at least one value.'**
  String get bodyErrEmpty;

  /// No description provided for @bodyDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {date}?'**
  String bodyDeleteTitle(String date);

  /// No description provided for @bodyDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'Removes the {what} recorded for this day.'**
  String bodyDeleteBody(String what);

  /// No description provided for @bodyDeleteWeight.
  ///
  /// In en, this message translates to:
  /// **'weight'**
  String get bodyDeleteWeight;

  /// No description provided for @bodyDeleteMeasurements.
  ///
  /// In en, this message translates to:
  /// **'measurements'**
  String get bodyDeleteMeasurements;

  /// No description provided for @bodyDeleteBoth.
  ///
  /// In en, this message translates to:
  /// **'weight and measurements'**
  String get bodyDeleteBoth;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @settingsWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome — one step to start logging'**
  String get settingsWelcomeTitle;

  /// No description provided for @settingsWelcomeBody.
  ///
  /// In en, this message translates to:
  /// **'Tap AI Provider below, pick a provider and paste its API key (it saves as you type), then Test This Provider.\nThen turn on Watch Camera Roll and new food photos log themselves.\nIn mainland China choose Qwen 通义千问, Doubao 豆包 or GLM 智谱 (GLM\'s default model is free) — the other providers need a VPN. 中国大陆用户请选择国内提供商。'**
  String get settingsWelcomeBody;

  /// No description provided for @settingsSectionAi.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get settingsSectionAi;

  /// No description provided for @settingsAiFooterPaused.
  ///
  /// In en, this message translates to:
  /// **'Analyses are paused — the daily quota was hit. New photos are kept and retried automatically; changing the key or provider on the AI Provider page resumes now.'**
  String get settingsAiFooterPaused;

  /// No description provided for @providerQuotaPaused.
  ///
  /// In en, this message translates to:
  /// **'Analyses are paused — the daily quota was hit. New photos are kept and retried automatically; changing the key or provider resumes now.'**
  String get providerQuotaPaused;

  /// Banner on the AI Provider page itself, so unlike settingsAiFooterPaused it does not point at that page. {time} is the local clock time the pause lifts.
  ///
  /// In en, this message translates to:
  /// **'Analyses are paused — the daily quota was hit (until {time}). New photos are kept and retried automatically; changing the key or provider resumes now.'**
  String providerQuotaPausedUntil(String time);

  /// No description provided for @settingsAiFooter.
  ///
  /// In en, this message translates to:
  /// **'Photos are analysed by the provider you pick — its key never leaves this phone.'**
  String get settingsAiFooter;

  /// No description provided for @settingsRowAiProvider.
  ///
  /// In en, this message translates to:
  /// **'AI Provider'**
  String get settingsRowAiProvider;

  /// No description provided for @settingsSectionPhotos.
  ///
  /// In en, this message translates to:
  /// **'Photos'**
  String get settingsSectionPhotos;

  /// No description provided for @settingsPhotosFooter.
  ///
  /// In en, this message translates to:
  /// **'The watcher logs new food photos automatically; the lookback window decides how far back catch-up scans reach.'**
  String get settingsPhotosFooter;

  /// No description provided for @settingsRowWatch.
  ///
  /// In en, this message translates to:
  /// **'Watch Camera Roll'**
  String get settingsRowWatch;

  /// No description provided for @settingsRowLookback.
  ///
  /// In en, this message translates to:
  /// **'Backfill Lookback'**
  String get settingsRowLookback;

  /// No description provided for @lookbackDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day} other{{count} days}}'**
  String lookbackDays(int count);

  /// No description provided for @settingsRowCoverage.
  ///
  /// In en, this message translates to:
  /// **'Photo Coverage'**
  String get settingsRowCoverage;

  /// No description provided for @settingsSectionReport.
  ///
  /// In en, this message translates to:
  /// **'Report'**
  String get settingsSectionReport;

  /// No description provided for @settingsRowReportTime.
  ///
  /// In en, this message translates to:
  /// **'Report Time'**
  String get settingsRowReportTime;

  /// No description provided for @settingsRowNextSummary.
  ///
  /// In en, this message translates to:
  /// **'Next summary'**
  String get settingsRowNextSummary;

  /// No description provided for @timeToday.
  ///
  /// In en, this message translates to:
  /// **'Today {time}'**
  String timeToday(String time);

  /// No description provided for @timeTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow {time}'**
  String timeTomorrow(String time);

  /// No description provided for @nextSummaryNone.
  ///
  /// In en, this message translates to:
  /// **'Not scheduled'**
  String get nextSummaryNone;

  /// No description provided for @timeYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday {time}'**
  String timeYesterday(String time);

  /// No description provided for @settingsRowBackgroundScan.
  ///
  /// In en, this message translates to:
  /// **'Background scan'**
  String get settingsRowBackgroundScan;

  /// No description provided for @backgroundScanNever.
  ///
  /// In en, this message translates to:
  /// **'Not run yet'**
  String get backgroundScanNever;

  /// No description provided for @backgroundScanDisabled.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get backgroundScanDisabled;

  /// No description provided for @settingsSectionProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get settingsSectionProfile;

  /// No description provided for @settingsRowDietaryProfile.
  ///
  /// In en, this message translates to:
  /// **'Dietary Profile'**
  String get settingsRowDietaryProfile;

  /// No description provided for @profileSet.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get profileSet;

  /// No description provided for @profileNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get profileNotSet;

  /// No description provided for @settingsSectionData.
  ///
  /// In en, this message translates to:
  /// **'Your Data'**
  String get settingsSectionData;

  /// No description provided for @settingsDataFooter.
  ///
  /// In en, this message translates to:
  /// **'Import MERGES an exported file into this phone: meals already here are left alone, so importing twice never doubles your calories.'**
  String get settingsDataFooter;

  /// No description provided for @settingsRowExport.
  ///
  /// In en, this message translates to:
  /// **'Export Data…'**
  String get settingsRowExport;

  /// No description provided for @settingsRowImport.
  ///
  /// In en, this message translates to:
  /// **'Import Data…'**
  String get settingsRowImport;

  /// No description provided for @settingsRowLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsRowLanguage;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @languageSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSheetTitle;

  /// No description provided for @lookbackSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Backfill lookback'**
  String get lookbackSheetTitle;

  /// No description provided for @lookbackSheetHint.
  ///
  /// In en, this message translates to:
  /// **'How many days catch-up scans look back.'**
  String get lookbackSheetHint;

  /// No description provided for @lookbackSet.
  ///
  /// In en, this message translates to:
  /// **'Set {count, plural, =1{1 day} other{{count} days}}'**
  String lookbackSet(int count);

  /// No description provided for @providerPageTitle.
  ///
  /// In en, this message translates to:
  /// **'AI Provider'**
  String get providerPageTitle;

  /// No description provided for @connectionTypeHeader.
  ///
  /// In en, this message translates to:
  /// **'Connection type'**
  String get connectionTypeHeader;

  /// No description provided for @connectionTypeFooter.
  ///
  /// In en, this message translates to:
  /// **'An API key pays per photo and lives on this phone. A subscription is a flat-rate plan your own cloud server signs into — photos cost nothing extra.'**
  String get connectionTypeFooter;

  /// No description provided for @typeApiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get typeApiKey;

  /// No description provided for @typeSubscription.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get typeSubscription;

  /// No description provided for @testProvider.
  ///
  /// In en, this message translates to:
  /// **'Test This Provider'**
  String get testProvider;

  /// No description provided for @testProviderFooter.
  ///
  /// In en, this message translates to:
  /// **'The test names exactly what is broken: configuration, network, key, account credit, reply format, or quota.'**
  String get testProviderFooter;

  /// No description provided for @apiPageTitle.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiPageTitle;

  /// No description provided for @apiProviderHeader.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get apiProviderHeader;

  /// No description provided for @apiProviderFooter.
  ///
  /// In en, this message translates to:
  /// **'Pay per photo: the key lives on this phone and every photo is a metered API call billed by the vendor. In mainland China choose DeepSeek, Qwen, Doubao or GLM — the others need a VPN. 中国大陆用户请选择国内提供商。'**
  String get apiProviderFooter;

  /// No description provided for @noteVpn.
  ///
  /// In en, this message translates to:
  /// **'VPN in China'**
  String get noteVpn;

  /// No description provided for @noteFreeTierVpn.
  ///
  /// In en, this message translates to:
  /// **'free · VPN in China'**
  String get noteFreeTierVpn;

  /// No description provided for @noteDirect.
  ///
  /// In en, this message translates to:
  /// **'direct in China'**
  String get noteDirect;

  /// No description provided for @noteFreeDirect.
  ///
  /// In en, this message translates to:
  /// **'free · direct in China'**
  String get noteFreeDirect;

  /// No description provided for @apiKeyHeader.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get apiKeyHeader;

  /// No description provided for @apiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'{provider} API key'**
  String apiKeyLabel(String provider);

  /// No description provided for @apiKeyFooterDefault.
  ///
  /// In en, this message translates to:
  /// **'The key saves as you type. Stored securely on this device only.'**
  String get apiKeyFooterDefault;

  /// No description provided for @apiKeyFooterQwen.
  ///
  /// In en, this message translates to:
  /// **'From bailian.console.aliyun.com (Alibaba Cloud 百炼 → API-KEY). New accounts get ~1M free tokens per model. Stored securely on this device only.'**
  String get apiKeyFooterQwen;

  /// No description provided for @apiKeyFooterDoubao.
  ///
  /// In en, this message translates to:
  /// **'From console.volcengine.com/ark (API Key + 开通管理 to activate models). 500k free tokens per model. Stored securely on this device only.'**
  String get apiKeyFooterDoubao;

  /// No description provided for @apiKeyFooterGlm.
  ///
  /// In en, this message translates to:
  /// **'From open.bigmodel.cn (real-name verification required). The default flash model is free. Stored securely on this device only.'**
  String get apiKeyFooterGlm;

  /// No description provided for @apiKeyFooterDeepseek.
  ///
  /// In en, this message translates to:
  /// **'From platform.deepseek.com (API keys). Pay as you go; reachable from mainland China. Stored securely on this device only.'**
  String get apiKeyFooterDeepseek;

  /// No description provided for @apiKeyFooterXai.
  ///
  /// In en, this message translates to:
  /// **'From console.x.ai (API keys). Pay as you go. Stored securely on this device only.'**
  String get apiKeyFooterXai;

  /// No description provided for @apiKeyFooterOpenrouter.
  ///
  /// In en, this message translates to:
  /// **'From openrouter.ai/keys. One key reaches GPT, Claude, Gemini, Grok, DeepSeek and more; a few models are free. Stored securely on this device only.'**
  String get apiKeyFooterOpenrouter;

  /// No description provided for @modelHeader.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get modelHeader;

  /// No description provided for @modelCustomRow.
  ///
  /// In en, this message translates to:
  /// **'Custom — type a model name…'**
  String get modelCustomRow;

  /// No description provided for @modelCustomLabel.
  ///
  /// In en, this message translates to:
  /// **'Custom model name'**
  String get modelCustomLabel;

  /// No description provided for @modelHelperDefault.
  ///
  /// In en, this message translates to:
  /// **'Default: {model}'**
  String modelHelperDefault(String model);

  /// No description provided for @modelHelperQwen.
  ///
  /// In en, this message translates to:
  /// **'Default: {model}. Doubles as the cheap tier — qwen3-vl-plus is the stronger paid model.'**
  String modelHelperQwen(String model);

  /// No description provided for @modelHelperDoubao.
  ///
  /// In en, this message translates to:
  /// **'Default: {model}. Doubao needs the EXACT versioned ID from the Ark model list — undated names are rejected.'**
  String modelHelperDoubao(String model);

  /// No description provided for @modelHelperGlm.
  ///
  /// In en, this message translates to:
  /// **'Default: {model} (free tier). glm-4.6v is the stronger paid model.'**
  String modelHelperGlm(String model);

  /// No description provided for @modelHelperDeepseek.
  ///
  /// In en, this message translates to:
  /// **'Default: {model} — the only DeepSeek model that accepts photos.'**
  String modelHelperDeepseek(String model);

  /// No description provided for @modelHelperOpenrouter.
  ///
  /// In en, this message translates to:
  /// **'Default: {model}. Any vendor/model slug from openrouter.ai/models that accepts images works.'**
  String modelHelperOpenrouter(String model);

  /// No description provided for @apiInactiveFooter.
  ///
  /// In en, this message translates to:
  /// **'A subscription is currently active. Pick a provider above to switch to a pay-per-photo API key.'**
  String get apiInactiveFooter;

  /// No description provided for @subPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get subPageTitle;

  /// No description provided for @planHeader.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get planHeader;

  /// No description provided for @planFooter.
  ///
  /// In en, this message translates to:
  /// **'Flat-rate: your own cloud machine signs in to ONE plan and analyses photos under it — each photo costs nothing extra. Plan credentials stay on that machine.'**
  String get planFooter;

  /// No description provided for @planClaude.
  ///
  /// In en, this message translates to:
  /// **'Claude Plan'**
  String get planClaude;

  /// No description provided for @planClaudeNote.
  ///
  /// In en, this message translates to:
  /// **'Anthropic'**
  String get planClaudeNote;

  /// No description provided for @planGlmNote.
  ///
  /// In en, this message translates to:
  /// **'Zhipu'**
  String get planGlmNote;

  /// No description provided for @planDoubaoNote.
  ///
  /// In en, this message translates to:
  /// **'Volcengine'**
  String get planDoubaoNote;

  /// No description provided for @noteManyModels.
  ///
  /// In en, this message translates to:
  /// **'many models'**
  String get noteManyModels;

  /// No description provided for @nlDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete meals?'**
  String get nlDeleteTitle;

  /// No description provided for @nlCannotUndo.
  ///
  /// In en, this message translates to:
  /// **'This cannot be undone.'**
  String get nlCannotUndo;

  /// No description provided for @planGlm.
  ///
  /// In en, this message translates to:
  /// **'GLM Coding Plan'**
  String get planGlm;

  /// No description provided for @planDoubao.
  ///
  /// In en, this message translates to:
  /// **'Doubao Agent Plan'**
  String get planDoubao;

  /// No description provided for @serverHeader.
  ///
  /// In en, this message translates to:
  /// **'Your server'**
  String get serverHeader;

  /// No description provided for @serverFooter.
  ///
  /// In en, this message translates to:
  /// **'The cloud machine that holds your plan sign-in and runs the analysis — not this phone. This phone keeps only the upload key it uses to talk to that machine.'**
  String get serverFooter;

  /// No description provided for @serverAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get serverAddressLabel;

  /// No description provided for @serverUploadKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Server upload key'**
  String get serverUploadKeyLabel;

  /// No description provided for @connectClaude.
  ///
  /// In en, this message translates to:
  /// **'Connect Claude'**
  String get connectClaude;

  /// No description provided for @connectClaudeFooter.
  ///
  /// In en, this message translates to:
  /// **'Signs this server in to your Anthropic subscription. Needs a VPN in mainland China.'**
  String get connectClaudeFooter;

  /// No description provided for @subInactiveFooter.
  ///
  /// In en, this message translates to:
  /// **'An API key is currently active. Pick a plan above to switch to subscription analysis via your server.'**
  String get subInactiveFooter;

  /// No description provided for @connectDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Finish connecting Claude'**
  String get connectDialogTitle;

  /// No description provided for @connectDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Sign in on the Anthropic page that just opened. It will show you a code — paste it here.'**
  String get connectDialogBody;

  /// No description provided for @connectCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Authorization code'**
  String get connectCodeLabel;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @connectStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not start the sign-in.'**
  String get connectStartFailed;

  /// No description provided for @connectBrowserFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the browser.'**
  String get connectBrowserFailed;

  /// No description provided for @connectDone.
  ///
  /// In en, this message translates to:
  /// **'Claude connected — analyses run on your subscription.'**
  String get connectDone;

  /// No description provided for @profilePageTitle.
  ///
  /// In en, this message translates to:
  /// **'Dietary Profile'**
  String get profilePageTitle;

  /// No description provided for @profileFooter.
  ///
  /// In en, this message translates to:
  /// **'Preferences and cultural context the AI reads alongside every photo — e.g. \"vegetarian\", \"Cantonese home cooking, light oil\", \"cutting, high protein\". Saves as you type.'**
  String get profileFooter;

  /// No description provided for @profileHint.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet — the AI assumes no special preferences.'**
  String get profileHint;

  /// No description provided for @addSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Log a meal'**
  String get addSheetTitle;

  /// No description provided for @addFromPhotos.
  ///
  /// In en, this message translates to:
  /// **'From recent photos'**
  String get addFromPhotos;

  /// No description provided for @addDescribe.
  ///
  /// In en, this message translates to:
  /// **'Describe a meal'**
  String get addDescribe;

  /// No description provided for @addDescribeNote.
  ///
  /// In en, this message translates to:
  /// **'any language'**
  String get addDescribeNote;

  /// No description provided for @addManual.
  ///
  /// In en, this message translates to:
  /// **'Enter manually'**
  String get addManual;

  /// No description provided for @addManualNote.
  ///
  /// In en, this message translates to:
  /// **'no AI'**
  String get addManualNote;

  /// No description provided for @addFix.
  ///
  /// In en, this message translates to:
  /// **'Fix or delete a meal'**
  String get addFix;

  /// No description provided for @addFixFooter.
  ///
  /// In en, this message translates to:
  /// **'\"meal 2 was roast duck\" · \"删除第一餐\"'**
  String get addFixFooter;

  /// No description provided for @addPhotosTip.
  ///
  /// In en, this message translates to:
  /// **'Tip: chopsticks or a hand in the shot helps the AI judge portion sizes.'**
  String get addPhotosTip;

  /// No description provided for @addNoPhotos.
  ///
  /// In en, this message translates to:
  /// **'No recent photos found.'**
  String get addNoPhotos;

  /// No description provided for @analyzing.
  ///
  /// In en, this message translates to:
  /// **'Analyzing…'**
  String get analyzing;

  /// No description provided for @reportTitle.
  ///
  /// In en, this message translates to:
  /// **'Daily intake'**
  String get reportTitle;

  /// No description provided for @reportMeals.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 meal} other{{count} meals}}'**
  String reportMeals(int count);

  /// No description provided for @reportNoMeals.
  ///
  /// In en, this message translates to:
  /// **'No meals logged.'**
  String get reportNoMeals;

  /// No description provided for @reportFooter.
  ///
  /// In en, this message translates to:
  /// **'Logged with Bitewise'**
  String get reportFooter;

  /// No description provided for @typicalDayHeadroom.
  ///
  /// In en, this message translates to:
  /// **'Typical day: ~{typical} kcal · ~{delta} kcal headroom'**
  String typicalDayHeadroom(String typical, String delta);

  /// No description provided for @typicalDayOver.
  ///
  /// In en, this message translates to:
  /// **'Typical day: ~{typical} kcal · ~{delta} kcal above typical'**
  String typicalDayOver(String typical, String delta);

  /// intl DateFormat PATTERN for dated history-day labels, not display text. en: "Tuesday, Jul 15"; zh: "7月15日 星期二".
  ///
  /// In en, this message translates to:
  /// **'EEEE, MMM dd'**
  String get historyDayPattern;

  /// No description provided for @garminBurnLine.
  ///
  /// In en, this message translates to:
  /// **'Active burn: ~{burn} kcal (Garmin) · net ~{net} kcal'**
  String garminBurnLine(String burn, String net);

  /// The Garmin line when the active burn is at least the day's intake: the net would be zero or negative, which is not an intake figure, so only the burn is stated.
  ///
  /// In en, this message translates to:
  /// **'Active burn: ~{burn} kcal (Garmin)'**
  String garminBurnOnlyLine(String burn);

  /// No description provided for @settingsRowUnits.
  ///
  /// In en, this message translates to:
  /// **'Units'**
  String get settingsRowUnits;

  /// No description provided for @unitsMetric.
  ///
  /// In en, this message translates to:
  /// **'Metric'**
  String get unitsMetric;

  /// No description provided for @unitsImperial.
  ///
  /// In en, this message translates to:
  /// **'Imperial'**
  String get unitsImperial;

  /// No description provided for @unitsMetricDetail.
  ///
  /// In en, this message translates to:
  /// **'Metric — kg · cm'**
  String get unitsMetricDetail;

  /// No description provided for @unitsImperialDetail.
  ///
  /// In en, this message translates to:
  /// **'Imperial — lb · in'**
  String get unitsImperialDetail;

  /// No description provided for @unitsSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Units'**
  String get unitsSheetTitle;

  /// No description provided for @unitsFooter.
  ///
  /// In en, this message translates to:
  /// **'How body weight and measurements are shown and entered. Food stays in grams and kcal either way.'**
  String get unitsFooter;

  /// bodyEmptyHint for imperial units (en-only surface; zh never renders imperial).
  ///
  /// In en, this message translates to:
  /// **'Tap Log to record your weight or your waist, chest and hip measurements. Weight logged by chat (\"I weigh 180 lb\") lands here too.'**
  String get bodyEmptyHintImperial;

  /// No description provided for @bodySince.
  ///
  /// In en, this message translates to:
  /// **'since {date}'**
  String bodySince(String date);

  /// No description provided for @addLeftover.
  ///
  /// In en, this message translates to:
  /// **'Leftovers'**
  String get addLeftover;

  /// No description provided for @addLeftoverNote.
  ///
  /// In en, this message translates to:
  /// **'deduct what\'s left'**
  String get addLeftoverNote;

  /// No description provided for @leftoverTitle.
  ///
  /// In en, this message translates to:
  /// **'Leftovers'**
  String get leftoverTitle;

  /// No description provided for @leftoverPickMeal.
  ///
  /// In en, this message translates to:
  /// **'Which meal was this?'**
  String get leftoverPickMeal;

  /// No description provided for @leftoverPickPhoto.
  ///
  /// In en, this message translates to:
  /// **'Pick the photo of what\'s LEFT — the meal\'s calories shrink to what you ate.'**
  String get leftoverPickPhoto;

  /// No description provided for @leftoverChangeMeal.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get leftoverChangeMeal;

  /// No description provided for @leftoverNotSame.
  ///
  /// In en, this message translates to:
  /// **'This doesn\'t look like the same meal'**
  String get leftoverNotSame;

  /// No description provided for @leftoverUseAnyway.
  ///
  /// In en, this message translates to:
  /// **'Use anyway'**
  String get leftoverUseAnyway;

  /// No description provided for @leftoverResultTitle.
  ///
  /// In en, this message translates to:
  /// **'Deduct leftovers?'**
  String get leftoverResultTitle;

  /// No description provided for @leftoverResultLine.
  ///
  /// In en, this message translates to:
  /// **'Eaten ~{pct}% — deducting {kcal} kcal, this meal is now {now} kcal.'**
  String leftoverResultLine(String pct, String kcal, String now);

  /// No description provided for @leftoverDupRemoved.
  ///
  /// In en, this message translates to:
  /// **'This photo was also logged as its own {kcal} kcal meal — that duplicate will be removed.'**
  String leftoverDupRemoved(String kcal);

  /// No description provided for @leftoverApplied.
  ///
  /// In en, this message translates to:
  /// **'Leftovers deducted.'**
  String get leftoverApplied;

  /// No description provided for @leftoverFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t estimate the leftovers from that photo.'**
  String get leftoverFailed;

  /// No description provided for @leftoverNoMeals.
  ///
  /// In en, this message translates to:
  /// **'No meals from today or yesterday to deduct from.'**
  String get leftoverNoMeals;

  /// No description provided for @planTuningHeader.
  ///
  /// In en, this message translates to:
  /// **'Model & thinking'**
  String get planTuningHeader;

  /// No description provided for @planTuningFooter.
  ///
  /// In en, this message translates to:
  /// **'Which Claude model analyzes on your server, and how hard it thinks. Default follows the server\'s own setting; only the Claude plan offers this — the other plans choose models themselves.'**
  String get planTuningFooter;

  /// No description provided for @planModelRow.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get planModelRow;

  /// No description provided for @planEffortRow.
  ///
  /// In en, this message translates to:
  /// **'Thinking effort'**
  String get planEffortRow;

  /// No description provided for @planChoiceDefault.
  ///
  /// In en, this message translates to:
  /// **'Server default'**
  String get planChoiceDefault;

  /// No description provided for @planModelOpus.
  ///
  /// In en, this message translates to:
  /// **'Opus — most accurate'**
  String get planModelOpus;

  /// No description provided for @planModelSonnet.
  ///
  /// In en, this message translates to:
  /// **'Sonnet — balanced'**
  String get planModelSonnet;

  /// No description provided for @planModelHaiku.
  ///
  /// In en, this message translates to:
  /// **'Haiku — fastest'**
  String get planModelHaiku;

  /// No description provided for @planEffortLow.
  ///
  /// In en, this message translates to:
  /// **'Low — fastest'**
  String get planEffortLow;

  /// No description provided for @planEffortMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get planEffortMedium;

  /// No description provided for @planEffortHigh.
  ///
  /// In en, this message translates to:
  /// **'High — most thorough'**
  String get planEffortHigh;

  /// No description provided for @planEffortLowShort.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get planEffortLowShort;

  /// No description provided for @planEffortHighShort.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get planEffortHighShort;

  /// No description provided for @planModelFable.
  ///
  /// In en, this message translates to:
  /// **'Fable — frontier · needs credits on Pro'**
  String get planModelFable;

  /// No description provided for @typicalDayOnly.
  ///
  /// In en, this message translates to:
  /// **'Typical day: ~{typical} kcal'**
  String typicalDayOnly(String typical);

  /// No description provided for @garminIdleLine.
  ///
  /// In en, this message translates to:
  /// **'Garmin connected · no activity recorded yet today'**
  String get garminIdleLine;

  /// No description provided for @coachTitle.
  ///
  /// In en, this message translates to:
  /// **'Today: {kcal} kcal'**
  String coachTitle(String kcal);

  /// Notification title when a throttled background run delivers the summary after midnight — saying 'Today' then would name the wrong day.
  ///
  /// In en, this message translates to:
  /// **'Yesterday: {kcal} kcal'**
  String coachTitleYesterday(String kcal);

  /// No description provided for @coachEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing logged today. Snap your next meal and it lands here automatically.'**
  String get coachEmpty;

  /// No description provided for @coachEmptyYesterday.
  ///
  /// In en, this message translates to:
  /// **'Nothing logged yesterday. Snap your next meal and it lands here automatically.'**
  String get coachEmptyYesterday;

  /// No description provided for @coachUnderGoal.
  ///
  /// In en, this message translates to:
  /// **'{delta} kcal under your goal — that\'s a real cut. Discipline like this compounds. 💪'**
  String coachUnderGoal(String delta);

  /// No description provided for @coachUnderTypical.
  ///
  /// In en, this message translates to:
  /// **'{delta} kcal below your usual day. Strong work — that\'s the kind of day that moves the needle.'**
  String coachUnderTypical(String delta);

  /// Coach line for a day logged far below the goal: more likely missing meals than a real cut, so it invites them instead of praising a deficit.
  ///
  /// In en, this message translates to:
  /// **'{delta} kcal under your goal — any meals not logged yet? Add them in BiteWise.'**
  String coachPartialGoal(String delta);

  /// Coach line for a day logged far below the usual day: more likely missing meals than a real cut.
  ///
  /// In en, this message translates to:
  /// **'{delta} kcal below your usual day — any meals not logged yet? Add them in BiteWise.'**
  String coachPartialTypical(String delta);

  /// No description provided for @coachOnTarget.
  ///
  /// In en, this message translates to:
  /// **'Right on target. Consistency beats intensity — keep stacking days like this.'**
  String get coachOnTarget;

  /// No description provided for @coachOverGoal.
  ///
  /// In en, this message translates to:
  /// **'{delta} kcal over your goal. One day doesn\'t undo a week — just keep going.'**
  String coachOverGoal(String delta);

  /// No description provided for @coachOverTypical.
  ///
  /// In en, this message translates to:
  /// **'{delta} kcal above your usual. Worth knowing, not worth worrying about — the next meal\'s a clean slate.'**
  String coachOverTypical(String delta);

  /// No description provided for @coachNoReference.
  ///
  /// In en, this message translates to:
  /// **'Logged and counted. A few more days and I can tell you how this compares to your usual.'**
  String get coachNoReference;

  /// No description provided for @coachDetail.
  ///
  /// In en, this message translates to:
  /// **'{meals} meals · {protein} g protein'**
  String coachDetail(String meals, String protein);

  /// No description provided for @settingsRowGoal.
  ///
  /// In en, this message translates to:
  /// **'Daily calorie goal'**
  String get settingsRowGoal;

  /// No description provided for @goalSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Daily calorie goal'**
  String get goalSheetTitle;

  /// No description provided for @goalNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get goalNotSet;

  /// No description provided for @goalFooter.
  ///
  /// In en, this message translates to:
  /// **'The daily summary measures against this. Leave it empty and it compares against your typical day instead.'**
  String get goalFooter;

  /// No description provided for @goalFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'kcal per day'**
  String get goalFieldLabel;

  /// No description provided for @goalClear.
  ///
  /// In en, this message translates to:
  /// **'Clear goal'**
  String get goalClear;

  /// No description provided for @macroProtein.
  ///
  /// In en, this message translates to:
  /// **'Protein'**
  String get macroProtein;

  /// No description provided for @macroCarbs.
  ///
  /// In en, this message translates to:
  /// **'Carbs'**
  String get macroCarbs;

  /// No description provided for @macroFat.
  ///
  /// In en, this message translates to:
  /// **'Fat'**
  String get macroFat;

  /// No description provided for @macroProteinShort.
  ///
  /// In en, this message translates to:
  /// **'P'**
  String get macroProteinShort;

  /// No description provided for @macroCarbsShort.
  ///
  /// In en, this message translates to:
  /// **'C'**
  String get macroCarbsShort;

  /// No description provided for @macroFatShort.
  ///
  /// In en, this message translates to:
  /// **'F'**
  String get macroFatShort;

  /// No description provided for @editorProteinLabel.
  ///
  /// In en, this message translates to:
  /// **'Protein (g)'**
  String get editorProteinLabel;

  /// No description provided for @editorCarbsLabel.
  ///
  /// In en, this message translates to:
  /// **'Carbs (g)'**
  String get editorCarbsLabel;

  /// No description provided for @editorFatLabel.
  ///
  /// In en, this message translates to:
  /// **'Fat (g)'**
  String get editorFatLabel;

  /// No description provided for @diagTitle.
  ///
  /// In en, this message translates to:
  /// **'Test AI provider'**
  String get diagTitle;

  /// No description provided for @diagIntro.
  ///
  /// In en, this message translates to:
  /// **'Checks your AI setup step by step and names exactly what is broken: configuration, network (VPN), key, account credit, reply format, and quota. Running the test spends two small AI calls.'**
  String get diagIntro;

  /// No description provided for @diagRunning.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get diagRunning;

  /// No description provided for @diagRunAgain.
  ///
  /// In en, this message translates to:
  /// **'Run again'**
  String get diagRunAgain;

  /// No description provided for @diagRunChecks.
  ///
  /// In en, this message translates to:
  /// **'Run the checks'**
  String get diagRunChecks;

  /// No description provided for @diagVerdictOk.
  ///
  /// In en, this message translates to:
  /// **'Everything works. If a photo still fails, it is photo-specific — try \"Analyze again\" on it.'**
  String get diagVerdictOk;

  /// No description provided for @diagVerdictProblems.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 problem found — the red/orange rows below say what to do.} other{{count} problems found — the red/orange rows below say what to do.}}'**
  String diagVerdictProblems(int count);

  /// No description provided for @diagStageTestRun.
  ///
  /// In en, this message translates to:
  /// **'Test run'**
  String get diagStageTestRun;

  /// No description provided for @diagTestRunFailed.
  ///
  /// In en, this message translates to:
  /// **'The check itself failed part-way through.'**
  String get diagTestRunFailed;

  /// No description provided for @diagFixTestRun.
  ///
  /// In en, this message translates to:
  /// **'Re-run; if it keeps failing here, the provider is answering something the app cannot parse at all.'**
  String get diagFixTestRun;

  /// No description provided for @diagStageConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Configuration'**
  String get diagStageConfiguration;

  /// No description provided for @diagStageEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Endpoint reachability'**
  String get diagStageEndpoint;

  /// No description provided for @diagStageAuth.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get diagStageAuth;

  /// No description provided for @diagStageText.
  ///
  /// In en, this message translates to:
  /// **'Text analysis'**
  String get diagStageText;

  /// No description provided for @diagStagePhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo analysis'**
  String get diagStagePhoto;

  /// No description provided for @diagStageQuota.
  ///
  /// In en, this message translates to:
  /// **'Quota'**
  String get diagStageQuota;

  /// No description provided for @diagNoServerAddress.
  ///
  /// In en, this message translates to:
  /// **'No server address is set.'**
  String get diagNoServerAddress;

  /// No description provided for @diagFixEnterServer.
  ///
  /// In en, this message translates to:
  /// **'Enter your server address in Settings, then re-run.'**
  String get diagFixEnterServer;

  /// No description provided for @diagNoUploadKey.
  ///
  /// In en, this message translates to:
  /// **'No server upload key is set.'**
  String get diagNoUploadKey;

  /// No description provided for @diagNoApiKey.
  ///
  /// In en, this message translates to:
  /// **'No API key is set for this provider.'**
  String get diagNoApiKey;

  /// No description provided for @diagFixPasteKey.
  ///
  /// In en, this message translates to:
  /// **'Paste the key in Settings, then re-run.'**
  String get diagFixPasteKey;

  /// No description provided for @diagServerConfigured.
  ///
  /// In en, this message translates to:
  /// **'Server address and upload key are set (backend: {backend}).'**
  String diagServerConfigured(String backend);

  /// No description provided for @diagProviderConfigured.
  ///
  /// In en, this message translates to:
  /// **'Provider \"{provider}\" with a key and model \"{model}\".'**
  String diagProviderConfigured(String provider, String model);

  /// No description provided for @diagTargetServer.
  ///
  /// In en, this message translates to:
  /// **'server'**
  String get diagTargetServer;

  /// No description provided for @diagTargetYourServer.
  ///
  /// In en, this message translates to:
  /// **'your server'**
  String get diagTargetYourServer;

  /// No description provided for @diagEndpointAnswered.
  ///
  /// In en, this message translates to:
  /// **'The {target} endpoint answered.'**
  String diagEndpointAnswered(String target);

  /// No description provided for @diagEndpointUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach {target} at all.'**
  String diagEndpointUnreachable(String target);

  /// No description provided for @diagFixVpn.
  ///
  /// In en, this message translates to:
  /// **'This provider is blocked in mainland China without a VPN. Turn the VPN on, or switch to Qwen/Doubao/GLM (no VPN needed).'**
  String get diagFixVpn;

  /// No description provided for @diagFixServerUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Check the server address, that the server is running, and your network.'**
  String get diagFixServerUnreachable;

  /// No description provided for @diagFixNetwork.
  ///
  /// In en, this message translates to:
  /// **'Check your network connection and try again.'**
  String get diagFixNetwork;

  /// No description provided for @diagKeyAccepted.
  ///
  /// In en, this message translates to:
  /// **'The provider accepted your key.'**
  String get diagKeyAccepted;

  /// No description provided for @diagOutOfCredit.
  ///
  /// In en, this message translates to:
  /// **'The key works, but the account cannot pay right now.'**
  String get diagOutOfCredit;

  /// No description provided for @diagFixTopUp.
  ///
  /// In en, this message translates to:
  /// **'Top up the provider account, or switch to a free tier (Zhipu GLM\'s default vision model is free, no VPN needed in mainland China).'**
  String get diagFixTopUp;

  /// No description provided for @diagRateLimited.
  ///
  /// In en, this message translates to:
  /// **'The key works, but the provider is rate-limiting right now.'**
  String get diagRateLimited;

  /// No description provided for @diagFixWaitRateLimit.
  ///
  /// In en, this message translates to:
  /// **'Wait a minute and re-run; photos are kept and retried automatically meanwhile.'**
  String get diagFixWaitRateLimit;

  /// No description provided for @diagKeyRejected.
  ///
  /// In en, this message translates to:
  /// **'The key was not accepted.'**
  String get diagKeyRejected;

  /// No description provided for @diagFixRecopyKey.
  ///
  /// In en, this message translates to:
  /// **'Re-copy the key from the provider console — and check it belongs to THIS provider (keys are not interchangeable).'**
  String get diagFixRecopyKey;

  /// No description provided for @diagModelNotFound.
  ///
  /// In en, this message translates to:
  /// **'The key works, but the model \"{model}\" was not found.'**
  String diagModelNotFound(String model);

  /// No description provided for @diagTextOk.
  ///
  /// In en, this message translates to:
  /// **'The model answered JSON — chat fixes and \"describe a meal\" work.'**
  String get diagTextOk;

  /// No description provided for @diagTextBad.
  ///
  /// In en, this message translates to:
  /// **'The text request did not succeed (busy server, rate limit or closed usage window, timeout, or no JSON from the model).'**
  String get diagTextBad;

  /// No description provided for @diagTextBadDetail.
  ///
  /// In en, this message translates to:
  /// **'Chat fixes and \"describe a meal\" may fail; photo analysis can still work.'**
  String get diagTextBadDetail;

  /// No description provided for @diagFixPickModel.
  ///
  /// In en, this message translates to:
  /// **'If this persists, pick a different model in Settings.'**
  String get diagFixPickModel;

  /// No description provided for @diagTextBadPhotoAlsoFailed.
  ///
  /// In en, this message translates to:
  /// **'Chat fixes and \"describe a meal\" may fail. The photo request below failed too, so its reason is the likely cause of both.'**
  String get diagTextBadPhotoAlsoFailed;

  /// No description provided for @diagFixTextPickModel.
  ///
  /// In en, this message translates to:
  /// **'If photo analysis works but this keeps failing, pick a different model in Settings.'**
  String get diagFixTextPickModel;

  /// No description provided for @diagFixTextFollowPhoto.
  ///
  /// In en, this message translates to:
  /// **'Follow the fix on the photo row, then run the test again.'**
  String get diagFixTextFollowPhoto;

  /// No description provided for @diagPhotoOk.
  ///
  /// In en, this message translates to:
  /// **'The model analyzed a test image and answered the meal format.'**
  String get diagPhotoOk;

  /// No description provided for @diagPhotoThoughtFood.
  ///
  /// In en, this message translates to:
  /// **'It even thought the test disc was food.'**
  String get diagPhotoThoughtFood;

  /// No description provided for @diagPhotoNotFood.
  ///
  /// In en, this message translates to:
  /// **'Verdict \"not food\" — correct for the test image.'**
  String get diagPhotoNotFood;

  /// No description provided for @diagPhotoTempFail.
  ///
  /// In en, this message translates to:
  /// **'Photo analysis failed with a TEMPORARY problem.'**
  String get diagPhotoTempFail;

  /// No description provided for @diagPhotoPermFail.
  ///
  /// In en, this message translates to:
  /// **'Photo analysis failed and a retry will NOT fix it.'**
  String get diagPhotoPermFail;

  /// No description provided for @diagFixPhotoTemp.
  ///
  /// In en, this message translates to:
  /// **'Usually a rate limit or a busy server — photos are kept and retried automatically.'**
  String get diagFixPhotoTemp;

  /// No description provided for @diagFixPhotoPerm.
  ///
  /// In en, this message translates to:
  /// **'Read the message above — it names the broken piece (model, format, or account).'**
  String get diagFixPhotoPerm;

  /// No description provided for @diagQuotaPaused.
  ///
  /// In en, this message translates to:
  /// **'Analyses are PAUSED — the daily quota was hit.'**
  String get diagQuotaPaused;

  /// No description provided for @diagQuotaPausedUntil.
  ///
  /// In en, this message translates to:
  /// **'Paused until {until}.'**
  String diagQuotaPausedUntil(String until);

  /// No description provided for @diagFixQuota.
  ///
  /// In en, this message translates to:
  /// **'Wait it out (photos are kept), or change the key or provider to resume immediately.'**
  String get diagFixQuota;

  /// No description provided for @diagQuotaOk.
  ///
  /// In en, this message translates to:
  /// **'No quota pause is active.'**
  String get diagQuotaOk;

  /// No description provided for @addPhotosTitle.
  ///
  /// In en, this message translates to:
  /// **'Recent photos'**
  String get addPhotosTitle;

  /// No description provided for @addPhotoUnreadable.
  ///
  /// In en, this message translates to:
  /// **'That photo could not be read (too large or removed).'**
  String get addPhotoUnreadable;

  /// No description provided for @addPhotosLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load photos: {error}'**
  String addPhotosLoadFailed(String error);

  /// No description provided for @photoPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Bitewise isn\'t allowed to see your photos.'**
  String get photoPermissionDenied;

  /// No description provided for @openSystemSettings.
  ///
  /// In en, this message translates to:
  /// **'Open system settings'**
  String get openSystemSettings;

  /// No description provided for @outcomeSaved.
  ///
  /// In en, this message translates to:
  /// **'Meal logged'**
  String get outcomeSaved;

  /// No description provided for @outcomeSkipped.
  ///
  /// In en, this message translates to:
  /// **'No food detected'**
  String get outcomeSkipped;

  /// No description provided for @outcomeDuplicate.
  ///
  /// In en, this message translates to:
  /// **'Duplicate photo'**
  String get outcomeDuplicate;

  /// No description provided for @outcomeAlreadyTracked.
  ///
  /// In en, this message translates to:
  /// **'Already logged'**
  String get outcomeAlreadyTracked;

  /// No description provided for @outcomeInFlight.
  ///
  /// In en, this message translates to:
  /// **'Still analyzing'**
  String get outcomeInFlight;

  /// No description provided for @outcomeFailed.
  ///
  /// In en, this message translates to:
  /// **'Analysis failed'**
  String get outcomeFailed;

  /// No description provided for @outcomeLeftoverApplied.
  ///
  /// In en, this message translates to:
  /// **'Leftovers deducted'**
  String get outcomeLeftoverApplied;

  /// No description provided for @outcomeLogManuallyHint.
  ///
  /// In en, this message translates to:
  /// **'If this IS food, log it yourself — the photo stays attached to the meal.'**
  String get outcomeLogManuallyHint;

  /// No description provided for @okButton.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get okButton;

  /// No description provided for @logManually.
  ///
  /// In en, this message translates to:
  /// **'Log manually'**
  String get logManually;

  /// No description provided for @describeTitle.
  ///
  /// In en, this message translates to:
  /// **'Describe a meal'**
  String get describeTitle;

  /// No description provided for @describeLabel.
  ///
  /// In en, this message translates to:
  /// **'What did you eat?'**
  String get describeLabel;

  /// No description provided for @describeHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. \"two eggs and toast with butter\"\nor \"一碗牛肉面加一个鸡蛋\"'**
  String get describeHint;

  /// No description provided for @describeHelp.
  ///
  /// In en, this message translates to:
  /// **'Any language works. You will see the estimate and can fix it before it is saved.'**
  String get describeHelp;

  /// No description provided for @describeEstimating.
  ///
  /// In en, this message translates to:
  /// **'Estimating…'**
  String get describeEstimating;

  /// No description provided for @describeEstimate.
  ///
  /// In en, this message translates to:
  /// **'Estimate this meal'**
  String get describeEstimate;

  /// No description provided for @notificationsOffHint.
  ///
  /// In en, this message translates to:
  /// **'Notifications are off — the daily summary can\'t be delivered.'**
  String get notificationsOffHint;

  /// No description provided for @outcomeSavedMsg.
  ///
  /// In en, this message translates to:
  /// **'Meal logged: {summary}'**
  String outcomeSavedMsg(String summary);

  /// No description provided for @outcomeLeftoverMsg.
  ///
  /// In en, this message translates to:
  /// **'Leftovers deducted: {summary}'**
  String outcomeLeftoverMsg(String summary);

  /// No description provided for @outcomeFailedKeptMsg.
  ///
  /// In en, this message translates to:
  /// **'Photo analysis failed — kept for retry. {reason}'**
  String outcomeFailedKeptMsg(String reason);

  /// No description provided for @backlogTruncatedWarning.
  ///
  /// In en, this message translates to:
  /// **'Photo library backlog is very large — some older photos may need to be added manually.'**
  String get backlogTruncatedWarning;

  /// No description provided for @outcomeNotFoodMsg.
  ///
  /// In en, this message translates to:
  /// **'No food detected in this photo.'**
  String get outcomeNotFoodMsg;

  /// No description provided for @outcomeDuplicateMsg.
  ///
  /// In en, this message translates to:
  /// **'Looks like a duplicate of a photo logged minutes ago.'**
  String get outcomeDuplicateMsg;

  /// No description provided for @outcomeAlreadyTrackedMsg.
  ///
  /// In en, this message translates to:
  /// **'This photo was already logged.'**
  String get outcomeAlreadyTrackedMsg;

  /// No description provided for @outcomeInFlightMsg.
  ///
  /// In en, this message translates to:
  /// **'This photo is still being analyzed — check back in a moment.'**
  String get outcomeInFlightMsg;

  /// No description provided for @errNoApiKey.
  ///
  /// In en, this message translates to:
  /// **'No API key is set for this provider — add one in Settings.'**
  String get errNoApiKey;

  /// No description provided for @errNoServerKey.
  ///
  /// In en, this message translates to:
  /// **'No server address or upload key is set — add them in Settings.'**
  String get errNoServerKey;

  /// No description provided for @errRejectedKey.
  ///
  /// In en, this message translates to:
  /// **'The provider rejected the API key. Check the key in Settings.'**
  String get errRejectedKey;

  /// No description provided for @errRateLimited.
  ///
  /// In en, this message translates to:
  /// **'The provider is rate-limiting right now — the photo is kept and retried later.'**
  String get errRateLimited;

  /// No description provided for @errQuotaPaused.
  ///
  /// In en, this message translates to:
  /// **'Analysis is paused: the daily quota was hit. The photo is kept and retried later.'**
  String get errQuotaPaused;

  /// No description provided for @errNetwork.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the provider (network or service issue). The photo is kept and retried later.'**
  String get errNetwork;

  /// No description provided for @errBadModel.
  ///
  /// In en, this message translates to:
  /// **'The provider rejected the model — check the model name in Settings.'**
  String get errBadModel;

  /// No description provided for @errBadResponse.
  ///
  /// In en, this message translates to:
  /// **'The AI answered in a form the app could not use.'**
  String get errBadResponse;

  /// No description provided for @errBadPhoto.
  ///
  /// In en, this message translates to:
  /// **'This photo could not be processed (it could not be decoded).'**
  String get errBadPhoto;

  /// No description provided for @errServerBusy.
  ///
  /// In en, this message translates to:
  /// **'Your server is busy with another analysis — the photo is kept and retried later.'**
  String get errServerBusy;

  /// No description provided for @mealCardAutoTitle.
  ///
  /// In en, this message translates to:
  /// **'🍽️ Meal logged automatically'**
  String get mealCardAutoTitle;

  /// No description provided for @dayLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load this day: {error}'**
  String dayLoadFailed(String error);

  /// No description provided for @dayEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing logged on this day yet. Tap + to add a meal.'**
  String get dayEmpty;

  /// No description provided for @notFoodTag.
  ///
  /// In en, this message translates to:
  /// **'not food'**
  String get notFoodTag;

  /// No description provided for @fixRequestFailed.
  ///
  /// In en, this message translates to:
  /// **'That request failed: {error}'**
  String fixRequestFailed(String error);

  /// No description provided for @fixTitle.
  ///
  /// In en, this message translates to:
  /// **'Fix a meal'**
  String get fixTitle;

  /// No description provided for @fixIntro.
  ///
  /// In en, this message translates to:
  /// **'Say what to change or delete — describe the meal however you like (\"the noodles\", \"breakfast\", \"the 600 kcal one\"), in any language. To move a meal to another day or time, tap it on Today or in History and change its date or time.'**
  String get fixIntro;

  /// No description provided for @fixNamingTip.
  ///
  /// In en, this message translates to:
  /// **'Naming the food is safest — meal numbers count across the last 7 days, not just today.'**
  String get fixNamingTip;

  /// No description provided for @fixLabel.
  ///
  /// In en, this message translates to:
  /// **'What should change?'**
  String get fixLabel;

  /// No description provided for @fixHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. \"the noodles were roast duck rice\"\nor \"删除刚才那杯咖啡\"'**
  String get fixHint;

  /// No description provided for @working.
  ///
  /// In en, this message translates to:
  /// **'Working…'**
  String get working;

  /// No description provided for @fixApply.
  ///
  /// In en, this message translates to:
  /// **'Apply the fix'**
  String get fixApply;

  /// No description provided for @fixAppliedHeader.
  ///
  /// In en, this message translates to:
  /// **'Applied this session'**
  String get fixAppliedHeader;

  /// No description provided for @editorSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save: {error}'**
  String editorSaveFailed(String error);

  /// No description provided for @editorDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete: {error}'**
  String editorDeleteFailed(String error);

  /// No description provided for @editorDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this meal?'**
  String get editorDeleteTitle;

  /// No description provided for @editorDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'It will be removed from your history and totals. This cannot be undone.'**
  String get editorDeleteBody;

  /// No description provided for @editorTitleAdd.
  ///
  /// In en, this message translates to:
  /// **'Add meal'**
  String get editorTitleAdd;

  /// No description provided for @editorTitleEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit meal'**
  String get editorTitleEdit;

  /// No description provided for @editorDeleteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete meal'**
  String get editorDeleteTooltip;

  /// No description provided for @editorDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'What was it?'**
  String get editorDescriptionLabel;

  /// No description provided for @editorTotalsHeader.
  ///
  /// In en, this message translates to:
  /// **'Totals'**
  String get editorTotalsHeader;

  /// No description provided for @editorCaloriesLabel.
  ///
  /// In en, this message translates to:
  /// **'Calories (kcal)'**
  String get editorCaloriesLabel;

  /// No description provided for @editorItemsHeader.
  ///
  /// In en, this message translates to:
  /// **'Items'**
  String get editorItemsHeader;

  /// No description provided for @editorTotalsDerivedHint.
  ///
  /// In en, this message translates to:
  /// **'Totals follow these items'**
  String get editorTotalsDerivedHint;

  /// No description provided for @editorAddItem.
  ///
  /// In en, this message translates to:
  /// **'Add item'**
  String get editorAddItem;

  /// No description provided for @editorAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get editorAdd;

  /// No description provided for @editorItemLabel.
  ///
  /// In en, this message translates to:
  /// **'Item'**
  String get editorItemLabel;

  /// No description provided for @editorRemoveItemTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove item'**
  String get editorRemoveItemTooltip;

  /// No description provided for @editorErrNotNumber.
  ///
  /// In en, this message translates to:
  /// **'{label} must be a number.'**
  String editorErrNotNumber(String label);

  /// No description provided for @editorErrNegative.
  ///
  /// In en, this message translates to:
  /// **'{label} cannot be negative.'**
  String editorErrNegative(String label);

  /// No description provided for @editorErrTooLarge.
  ///
  /// In en, this message translates to:
  /// **'{label} looks too large (max {max}).'**
  String editorErrTooLarge(String label, String max);

  /// No description provided for @editorErrDescTooLong.
  ///
  /// In en, this message translates to:
  /// **'Description is too long (max {max}).'**
  String editorErrDescTooLong(String max);

  /// No description provided for @editorErrDate.
  ///
  /// In en, this message translates to:
  /// **'Date must be a real YYYY-MM-DD date.'**
  String get editorErrDate;

  /// No description provided for @editorErrTime.
  ///
  /// In en, this message translates to:
  /// **'Time must look like 07:30 PM.'**
  String get editorErrTime;

  /// No description provided for @editorErrTooManyItems.
  ///
  /// In en, this message translates to:
  /// **'Too many items (max {max}).'**
  String editorErrTooManyItems(String max);

  /// No description provided for @editorErrsNeedFixing.
  ///
  /// In en, this message translates to:
  /// **'{count} things need fixing — see the top.'**
  String editorErrsNeedFixing(int count);

  /// No description provided for @editorFieldCalories.
  ///
  /// In en, this message translates to:
  /// **'Calories'**
  String get editorFieldCalories;

  /// No description provided for @editorItemFieldCalories.
  ///
  /// In en, this message translates to:
  /// **'Item {n} calories'**
  String editorItemFieldCalories(int n);

  /// No description provided for @editorItemFieldProtein.
  ///
  /// In en, this message translates to:
  /// **'Item {n} protein'**
  String editorItemFieldProtein(int n);

  /// No description provided for @editorItemFieldCarbs.
  ///
  /// In en, this message translates to:
  /// **'Item {n} carbs'**
  String editorItemFieldCarbs(int n);

  /// No description provided for @editorItemFieldFat.
  ///
  /// In en, this message translates to:
  /// **'Item {n} fat'**
  String editorItemFieldFat(int n);

  /// No description provided for @editorItemKcalLabel.
  ///
  /// In en, this message translates to:
  /// **'kcal'**
  String get editorItemKcalLabel;

  /// No description provided for @covPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Photo permission is required for the check.'**
  String get covPermissionRequired;

  /// No description provided for @covCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Check failed: {error}'**
  String covCheckFailed(String error);

  /// No description provided for @covNoAnalysis.
  ///
  /// In en, this message translates to:
  /// **'No analysis is possible right now — add a key for the selected provider, or wait for the quota pause to end.'**
  String get covNoAnalysis;

  /// No description provided for @covBulkTitle.
  ///
  /// In en, this message translates to:
  /// **'{verb} {count, plural, =1{1 photo} other{{count} photos}}?'**
  String covBulkTitle(String verb, int count);

  /// No description provided for @covBulkBody.
  ///
  /// In en, this message translates to:
  /// **'Each photo is analyzed separately, one after another — expect roughly {minutes, plural, =1{1 minute} other{{minutes} minutes}} and {count, plural, =1{1 model call} other{{count} model calls}}. You can leave this screen; the work continues.'**
  String covBulkBody(int minutes, int count);

  /// No description provided for @covPhotoUnreadable.
  ///
  /// In en, this message translates to:
  /// **'That photo is no longer readable.'**
  String get covPhotoUnreadable;

  /// No description provided for @covTitle.
  ///
  /// In en, this message translates to:
  /// **'Photo coverage'**
  String get covTitle;

  /// No description provided for @covIntro.
  ///
  /// In en, this message translates to:
  /// **'Checks every photo of the last {days} day(s) against the log: each one is fingerprinted and looked up — nothing is sent to the AI by the check itself.'**
  String covIntro(int days);

  /// No description provided for @covChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get covChecking;

  /// No description provided for @covRun.
  ///
  /// In en, this message translates to:
  /// **'Run check'**
  String get covRun;

  /// No description provided for @covNeverScanned.
  ///
  /// In en, this message translates to:
  /// **'Never scanned ({count})'**
  String covNeverScanned(int count);

  /// No description provided for @covLogAll.
  ///
  /// In en, this message translates to:
  /// **'Log all'**
  String get covLogAll;

  /// No description provided for @covMoreLogAll.
  ///
  /// In en, this message translates to:
  /// **'…and {count} more — \"Log all\" still covers every one.'**
  String covMoreLogAll(int count);

  /// No description provided for @covJudgedNotFood.
  ///
  /// In en, this message translates to:
  /// **'Judged \"not food\" ({count})'**
  String covJudgedNotFood(int count);

  /// No description provided for @covAnalyzeAgain.
  ///
  /// In en, this message translates to:
  /// **'Analyze again'**
  String get covAnalyzeAgain;

  /// No description provided for @covNotFoodHelp.
  ///
  /// In en, this message translates to:
  /// **'Drinks, order screenshots and unusual dishes land here. \"Analyze again\" re-asks the AI (useful after the rules improve); tap a row to enter it yourself.'**
  String get covNotFoodHelp;

  /// No description provided for @covFailedEarlier.
  ///
  /// In en, this message translates to:
  /// **'Failed earlier ({count})'**
  String covFailedEarlier(int count);

  /// No description provided for @covRetryAll.
  ///
  /// In en, this message translates to:
  /// **'Retry all'**
  String get covRetryAll;

  /// No description provided for @covFailedHelp.
  ///
  /// In en, this message translates to:
  /// **'\"Retry all\" asks the AI again (the same error often comes back); tap a row to enter it yourself.'**
  String get covFailedHelp;

  /// No description provided for @covMoreRetryAll.
  ///
  /// In en, this message translates to:
  /// **'…and {count} more — \"Retry all\" still covers every one.'**
  String covMoreRetryAll(int count);

  /// No description provided for @covAllAccounted.
  ///
  /// In en, this message translates to:
  /// **'All {count} photos are accounted for.'**
  String covAllAccounted(int count);

  /// No description provided for @covSummary.
  ///
  /// In en, this message translates to:
  /// **'{scanned} photos checked — {missing} never scanned.'**
  String covSummary(int scanned, int missing);

  /// No description provided for @covLimitedAccess.
  ///
  /// In en, this message translates to:
  /// **'Note: the app has LIMITED photo access — only the selected photos can be checked. Grant full access in system settings for a complete answer.'**
  String get covLimitedAccess;

  /// No description provided for @covTruncated.
  ///
  /// In en, this message translates to:
  /// **'Note: over 2000 photos in this window — older ones were not checked. Shorten the window for a complete answer.'**
  String get covTruncated;

  /// No description provided for @covVerbLog.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get covVerbLog;

  /// No description provided for @covVerbRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get covVerbRetry;

  /// No description provided for @covProgLogging.
  ///
  /// In en, this message translates to:
  /// **'Logging'**
  String get covProgLogging;

  /// No description provided for @covProgReanalyzing.
  ///
  /// In en, this message translates to:
  /// **'Re-analyzing'**
  String get covProgReanalyzing;

  /// No description provided for @covProgRetrying.
  ///
  /// In en, this message translates to:
  /// **'Retrying'**
  String get covProgRetrying;

  /// No description provided for @covStopped.
  ///
  /// In en, this message translates to:
  /// **'{label} stopped after {attempted} of {total}: analysis is unavailable right now (quota pause or missing key). The remaining {remaining, plural, =1{1 photo was} other{{remaining} photos were}} not touched — run this again later.'**
  String covStopped(String label, int attempted, int total, int remaining);

  /// No description provided for @covStoppedBecause.
  ///
  /// In en, this message translates to:
  /// **'{label} stopped after {attempted} of {total}: {reason} The remaining {remaining, plural, =1{1 photo was} other{{remaining} photos were}} not touched — run this again later.'**
  String covStoppedBecause(
    String label,
    int attempted,
    int total,
    String reason,
    int remaining,
  );

  /// No description provided for @covMoreNotFood.
  ///
  /// In en, this message translates to:
  /// **'…and {count} more.'**
  String covMoreNotFood(int count);

  /// No description provided for @covUnnamedPhoto.
  ///
  /// In en, this message translates to:
  /// **'(unnamed photo)'**
  String get covUnnamedPhoto;

  /// No description provided for @covDone.
  ///
  /// In en, this message translates to:
  /// **'{label} done ({count} photos).'**
  String covDone(String label, int count);

  /// No description provided for @covDoneFailures.
  ///
  /// In en, this message translates to:
  /// **'{label} done — {failures} of {count} could not be processed (kept in the Failed list for retry).'**
  String covDoneFailures(String label, int failures, int count);

  /// No description provided for @covDaysShort.
  ///
  /// In en, this message translates to:
  /// **'{days} d'**
  String covDaysShort(int days);

  /// No description provided for @covLoggedAsMeals.
  ///
  /// In en, this message translates to:
  /// **'{count} logged as meals'**
  String covLoggedAsMeals(int count);

  /// No description provided for @covNotFoodCount.
  ///
  /// In en, this message translates to:
  /// **'{count} not food'**
  String covNotFoodCount(int count);

  /// No description provided for @covLeftoverCount.
  ///
  /// In en, this message translates to:
  /// **'{count} leftover photos (deducted from their meal)'**
  String covLeftoverCount(int count);

  /// No description provided for @covFailedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} failed'**
  String covFailedCount(int count);

  /// No description provided for @covDeletedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} deleted by you'**
  String covDeletedCount(int count);

  /// No description provided for @covInFlightCount.
  ///
  /// In en, this message translates to:
  /// **'{count} in progress'**
  String covInFlightCount(int count);

  /// No description provided for @covUnreadableCount.
  ///
  /// In en, this message translates to:
  /// **'{count} unreadable'**
  String covUnreadableCount(int count);

  /// No description provided for @covTooLargeCount.
  ///
  /// In en, this message translates to:
  /// **'{count} too large to analyze'**
  String covTooLargeCount(int count);

  /// No description provided for @macroNoBreakdown.
  ///
  /// In en, this message translates to:
  /// **'No macro breakdown recorded.'**
  String get macroNoBreakdown;

  /// No description provided for @setupLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up server from this link?'**
  String get setupLinkTitle;

  /// No description provided for @setupLinkBody.
  ///
  /// In en, this message translates to:
  /// **'Server: {server}\nPlan: {backend}\nUpload key: ••••{keyTail}\n\nYour meal photos will be sent to this server for analysis. Confirm only if it is yours.'**
  String setupLinkBody(String server, String backend, String keyTail);

  /// No description provided for @setupLinkConfirm.
  ///
  /// In en, this message translates to:
  /// **'Use this server'**
  String get setupLinkConfirm;

  /// No description provided for @setupLinkDone.
  ///
  /// In en, this message translates to:
  /// **'Server configured — photos will be analyzed through your plan.'**
  String get setupLinkDone;

  /// No description provided for @setupLinkInvalid.
  ///
  /// In en, this message translates to:
  /// **'That setup link is not valid.'**
  String get setupLinkInvalid;

  /// No description provided for @serverLoginRow.
  ///
  /// In en, this message translates to:
  /// **'Server Claude sign-in'**
  String get serverLoginRow;

  /// No description provided for @serverLoginOk.
  ///
  /// In en, this message translates to:
  /// **'Signed in ✓'**
  String get serverLoginOk;

  /// No description provided for @serverLoginMissing.
  ///
  /// In en, this message translates to:
  /// **'Not signed in'**
  String get serverLoginMissing;

  /// No description provided for @serverLoginUnknown.
  ///
  /// In en, this message translates to:
  /// **'Could not check'**
  String get serverLoginUnknown;

  /// No description provided for @serverLoginChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get serverLoginChecking;

  /// No description provided for @serverLoginFooter.
  ///
  /// In en, this message translates to:
  /// **'Signed in: nothing to connect. Not signed in: use Connect Claude below. Could not check: the server is unreachable or rejected the key.'**
  String get serverLoginFooter;

  /// No description provided for @errServerFailed.
  ///
  /// In en, this message translates to:
  /// **'Your server could not analyze this photo this time — it is kept and retried later.'**
  String get errServerFailed;

  /// No description provided for @errServerRejected.
  ///
  /// In en, this message translates to:
  /// **'Your server rejected this request ({code}). Update the app and the server to matching versions, then retry from Settings › Coverage.'**
  String errServerRejected(String code);

  /// No description provided for @watcherPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Photo library permission is required for automatic intake.'**
  String get watcherPermissionDenied;

  /// No description provided for @watcherOnQuotaPaused.
  ///
  /// In en, this message translates to:
  /// **'Watching is on, but analyses are paused by the daily quota — new photos will wait.'**
  String get watcherOnQuotaPaused;

  /// No description provided for @watcherOnNoKey.
  ///
  /// In en, this message translates to:
  /// **'Watching is on, but photos won\'t be analyzed until a working API key is set above.'**
  String get watcherOnNoKey;

  /// No description provided for @watcherLimitedAccess.
  ///
  /// In en, this message translates to:
  /// **'Only SELECTED photos are shared, so new food photos won\'t be seen automatically. Grant access to ALL photos for automatic logging.'**
  String get watcherLimitedAccess;

  /// No description provided for @fixAction.
  ///
  /// In en, this message translates to:
  /// **'Fix'**
  String get fixAction;

  /// No description provided for @importDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Import exported data'**
  String get importDialogTitle;

  /// No description provided for @importDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Paste the contents of an exported JSON file. Existing meals are kept; only new ones are added.'**
  String get importDialogBody;

  /// No description provided for @importAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// No description provided for @importNothingNew.
  ///
  /// In en, this message translates to:
  /// **'Nothing new to import — everything in that file is already here.'**
  String get importNothingNew;

  /// No description provided for @importDone.
  ///
  /// In en, this message translates to:
  /// **'Imported {meals, plural, =1{1 meal} other{{meals} meals}} ({rows} rows total).'**
  String importDone(int meals, int rows);

  /// No description provided for @importDoneKept.
  ///
  /// In en, this message translates to:
  /// **'Imported {meals, plural, =1{1 meal} other{{meals} meals}} ({rows} rows total); {kept} already here.'**
  String importDoneKept(int meals, int rows, int kept);

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String importFailed(String error);

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @exportShareSubject.
  ///
  /// In en, this message translates to:
  /// **'CalorieTracker data export'**
  String get exportShareSubject;

  /// No description provided for @importErrNotJson.
  ///
  /// In en, this message translates to:
  /// **'That file is not JSON.'**
  String get importErrNotJson;

  /// No description provided for @importErrNotExport.
  ///
  /// In en, this message translates to:
  /// **'That file is not a CalorieTracker export.'**
  String get importErrNotExport;

  /// No description provided for @importErrWrongFormatTag.
  ///
  /// In en, this message translates to:
  /// **'That file is not a CalorieTracker export (wrong format tag).'**
  String get importErrWrongFormatTag;

  /// No description provided for @importErrBadVersion.
  ///
  /// In en, this message translates to:
  /// **'That export has an unusable version tag.'**
  String get importErrBadVersion;

  /// No description provided for @importErrNoTables.
  ///
  /// In en, this message translates to:
  /// **'That export has no tables section.'**
  String get importErrNoTables;

  /// No description provided for @nlSomethingWrong.
  ///
  /// In en, this message translates to:
  /// **'❌ Something went wrong handling that message. Please try again.'**
  String get nlSomethingWrong;

  /// No description provided for @nlMissingServer.
  ///
  /// In en, this message translates to:
  /// **'❌ No server is configured — set your server address and upload key in Settings first.'**
  String get nlMissingServer;

  /// No description provided for @nlMissingKey.
  ///
  /// In en, this message translates to:
  /// **'❌ No {provider} API key yet — add one in Settings to use text logging.'**
  String nlMissingKey(String provider);

  /// No description provided for @nlTypeFirst.
  ///
  /// In en, this message translates to:
  /// **'Type what you ate first.'**
  String get nlTypeFirst;

  /// No description provided for @nlErrorContactingAi.
  ///
  /// In en, this message translates to:
  /// **'❌ Error contacting AI. Please try again.'**
  String get nlErrorContactingAi;

  /// No description provided for @nlNoFoodDetected.
  ///
  /// In en, this message translates to:
  /// **'🚫 I couldn\'t detect food in that description.'**
  String get nlNoFoodDetected;

  /// shown is the model's raw meal_index, already truncated to 40 chars.
  ///
  /// In en, this message translates to:
  /// **'❌ Invalid meal index ({shown}). You have {count} recent meals.'**
  String nlInvalidMealIndex(String shown, int count);

  /// No description provided for @nlCorrectedMeal.
  ///
  /// In en, this message translates to:
  /// **'✏️ Corrected meal {n}!'**
  String nlCorrectedMeal(int n);

  /// oldKcal/newKcal are already kcalAmount-formatted; diff is the signed delta.
  ///
  /// In en, this message translates to:
  /// **'🔥 {oldKcal} → {newKcal} ({diff})'**
  String nlKcalChange(String oldKcal, String newKcal, String diff);

  /// No description provided for @nlDeleteAsk.
  ///
  /// In en, this message translates to:
  /// **'🗑️ Delete {count} meal(s)?'**
  String nlDeleteAsk(int count);

  /// No description provided for @nlDeleteCancelled.
  ///
  /// In en, this message translates to:
  /// **'👍 Cancelled — nothing was deleted.'**
  String get nlDeleteCancelled;

  /// No description provided for @nlDeletedMeals.
  ///
  /// In en, this message translates to:
  /// **'🗑️ Deleted {count} meal(s):'**
  String nlDeletedMeals(int count);

  /// No description provided for @nlAddedManualMeal.
  ///
  /// In en, this message translates to:
  /// **'✅ Added new manual meal:'**
  String get nlAddedManualMeal;

  /// One staged-delete line. time is already in the locale clock; kcal is already kcalAmount-formatted.
  ///
  /// In en, this message translates to:
  /// **'{desc} ({date} {time}, ~{kcal})'**
  String nlMealLabel(String desc, String date, String time, String kcal);

  /// No description provided for @nlNoActions.
  ///
  /// In en, this message translates to:
  /// **'❌ I couldn\'t work out what to do with that. Try one request at a time, e.g. “change meal 2 to roast duck rice”.'**
  String get nlNoActions;

  /// No description provided for @nlRequestFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ That request failed. Please try again.'**
  String get nlRequestFailed;

  /// Every action in a compound request failed; must never claim partial success.
  ///
  /// In en, this message translates to:
  /// **'❌ All {count} requested actions failed. Please try again.'**
  String nlAllActionsFailed(int count);

  /// No description provided for @nlSomeActionsFailed.
  ///
  /// In en, this message translates to:
  /// **'⚠️ {failed} of {total} requested action(s) failed — the rest were applied.'**
  String nlSomeActionsFailed(int failed, int total);

  /// No description provided for @nlCannotCorrectNoMeals.
  ///
  /// In en, this message translates to:
  /// **'❌ Cannot correct because no meals are logged recently.'**
  String get nlCannotCorrectNoMeals;

  /// Silent-delete guard: an empty or non-food analysis would hide the meal without the delete confirmation.
  ///
  /// In en, this message translates to:
  /// **'❌ That correction didn\'t include a usable updated analysis, so I left the meal unchanged. Try restating it, e.g. “meal 2 was roast duck rice, ~780 kcal”.'**
  String get nlCorrectionUnusable;

  /// No description provided for @nlCannotDeleteNoMeals.
  ///
  /// In en, this message translates to:
  /// **'❌ Cannot delete because no meals are logged recently.'**
  String get nlCannotDeleteNoMeals;

  /// No description provided for @nlDeleteWhich.
  ///
  /// In en, this message translates to:
  /// **'❌ Didn\'t catch which meals to delete. Try being more specific.'**
  String get nlDeleteWhich;

  /// No description provided for @nlDeleteNoMatch.
  ///
  /// In en, this message translates to:
  /// **'❌ Couldn\'t match those meals to the recent list.'**
  String get nlDeleteNoMatch;

  /// No description provided for @nlDescribedMultiple.
  ///
  /// In en, this message translates to:
  /// **'That described {count} meals — only the first is shown. Describe the others one at a time.'**
  String nlDescribedMultiple(int count);

  /// No description provided for @nlWeightUnreadable.
  ///
  /// In en, this message translates to:
  /// **'⚖️ I couldn\'t read a valid body weight (30–300 kg). Try “I weigh 72.5 kg”.'**
  String get nlWeightUnreadable;

  /// kg is already %g-formatted (72.5, 80); date is ISO yyyy-MM-dd.
  ///
  /// In en, this message translates to:
  /// **'⚖️ Logged {kg} kg for {date}.'**
  String nlWeightLogged(String kg, String date);

  /// No description provided for @nlActivityUnreadable.
  ///
  /// In en, this message translates to:
  /// **'🏃 I couldn\'t find any activity numbers to log. Try “burned 450 kcal running 5 km”.'**
  String get nlActivityUnreadable;

  /// bits is the ' · '-joined list of kcalAmount / nlStepsAmount / nlKmAmount parts that were non-zero.
  ///
  /// In en, this message translates to:
  /// **'🏃 Logged activity: {bits} ({date}).'**
  String nlActivityLogged(String bits, String date);

  /// steps is already thousands-grouped (8,000).
  ///
  /// In en, this message translates to:
  /// **'{steps} steps'**
  String nlStepsAmount(String steps);

  /// No description provided for @nlKmAmount.
  ///
  /// In en, this message translates to:
  /// **'{km} km'**
  String nlKmAmount(String km);

  /// No description provided for @nlChatFallback.
  ///
  /// In en, this message translates to:
  /// **'I\'m not sure what you mean. Try describing a meal or correction!'**
  String get nlChatFallback;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
