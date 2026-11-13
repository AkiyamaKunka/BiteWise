/// User-editable settings + persistence (spec §8 knobs).
///
/// Non-secret values live in shared_preferences; EVERY provider credential
/// (Gemini, OpenAI, Anthropic, the own-server upload key, and the
/// Qwen/Doubao/GLM keys) lives in flutter_secure_storage (spec §8:
/// "user-supplied, stored in secure storage").
/// The analyzer's daily-quota pause latch (spec §3.3) is persisted here too so
/// it survives restarts. A simple [ChangeNotifier] so UI can listen.
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ai_consent.dart';
import '../../core/shared_generated.dart';

/// Narrow seam over the secure-storage plugin so tests can substitute an
/// in-memory store (the platform channel is unavailable in unit tests).
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production [SecureKeyStore] backed by flutter_secure_storage.
class FlutterSecureKeyStore implements SecureKeyStore {
  const FlutterSecureKeyStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Android's [SecureKeyStore]: the plain store, except that a key it
/// cannot read is no key.
///
/// flutter_secure_storage keeps each key in a shared_prefs file, encrypted
/// with a key that lives in this phone's Android Keystore. A copy of that
/// file that outlives its Keystore key (restored or transferred onto
/// another phone, or kept through an uninstall that keeps the app's data)
/// can never be read again, and the plugin's resetOnError covers only its
/// key-mismatch exceptions. Any other failure stopped [AppSettings.load],
/// and the startup error's Retry could never succeed; now the app starts
/// without that key and asks for it. The diagnostics line names the key
/// and the error's type, never the value or the plugin's message. Reads
/// only: a failed write or delete still throws, and the unreadable entry
/// is left as it is (saving a key overwrites it).
///
/// Never on iOS, where a locked phone's failed read must propagate
/// ([MigratingKeyStore]).
class AndroidSecureKeyStore extends FlutterSecureKeyStore {
  const AndroidSecureKeyStore();

  @override
  Future<String?> read(String key) async {
    try {
      return await super.read(key);
    } catch (e) {
      debugPrint('Settings: the stored $key could not be read '
          '(${e.runtimeType}); treated as no key');
      return null;
    }
  }
}

/// iOS keychain class for every credential: readable from the first unlock
/// after a reboot onward, locked screen included. The BGAppRefresh photo
/// scan usually runs in a pocket with the screen locked, and under the
/// plugin default (`unlocked`, kSecAttrAccessibleWhenUnlocked) its very
/// first key read failed, so the whole run died before scanning anything
/// (2026-10-09). Deliberately NOT `first_unlock_this_device`: a
/// this-device item never leaves the phone, so a backup restored onto a
/// new iPhone would come back without its keys; plain first_unlock
/// restores exactly like `unlocked` always did. iOS-only — the plugin
/// reads iOptions on iOS alone, so Android is untouched.
const IOSOptions keychainIOSOptions =
    IOSOptions(accessibility: KeychainAccessibility.first_unlock);

/// The store [AppSettings.load] uses when none is injected. On iOS it is
/// [MigratingKeyStore] over the first_unlock keychain class, carrying the
/// keys earlier builds saved under the plugin default. Android gets the
/// plain store whose reads forgive a broken store
/// ([AndroidSecureKeyStore]); every other platform the plain store.
///
/// [migrate] false is the BACKGROUND engine's store: it only reads (it
/// never writes keys), so the one-time move has a single, sequential
/// mover — the UI engine — and two engines can never race on it.
SecureKeyStore platformKeyStore({bool migrate = true}) =>
    defaultTargetPlatform == TargetPlatform.iOS
        ? MigratingKeyStore(
            primary: const FlutterSecureKeyStore(
                FlutterSecureStorage(iOptions: keychainIOSOptions)),
            legacy: const FlutterSecureKeyStore(),
            migrate: migrate,
          )
        : defaultTargetPlatform == TargetPlatform.android
            ? const AndroidSecureKeyStore()
            : const FlutterSecureKeyStore();

/// Moves each key saved under the old keychain class ([legacy]) into the
/// new one ([primary]) the first time it is read, without ever losing it.
///
/// Why not simply switch the options: the plugin puts kSecAttrAccessible
/// into EVERY query, reads included, so a first_unlock read never sees an
/// item stored as `unlocked` — every upgraded phone's keys would read as
/// missing. And accessibility is NOT part of a keychain item's identity,
/// so adding a first_unlock item while the `unlocked` one exists fails as
/// a duplicate. The plugin's delete, though, matches every accessibility,
/// so either seam's delete clears both copies. Hence the order in [read]:
/// read the old copy, delete it, write the new one, and if that write
/// fails put the old copy back.
///
/// Pure over two seams so the order is unit-testable with in-memory fakes;
/// it does not assume the seams share storage (it deletes through both).
class MigratingKeyStore implements SecureKeyStore {
  const MigratingKeyStore(
      {required this.primary, required this.legacy, this.migrate = true});
  final SecureKeyStore primary;
  final SecureKeyStore legacy;

  /// False: read-only (the background engine). Finds a key in either class
  /// or in a stage, never moves anything — and, because it never writes,
  /// may treat an unreadable old copy as absent for this run.
  final bool migrate;

  /// Where a key sits (in the new class) while it is being moved, so an
  /// app kill between deleting the old copy and writing the new one cannot
  /// lose it. A different account name: never collides with the item.
  static String stagingKey(String key) => '$key.migrating';

  @override
  Future<String?> read(String key) async {
    final current = await primary.read(key);
    if (current != null) return current;
    if (!migrate) {
      String? old;
      try {
        old = await legacy.read(key);
      } catch (_) {
        // Locked phone, old class: absent FOR THIS RUN. Safe only because
        // this store never writes; the UI engine migrates it when unlocked.
      }
      if (old != null) return old;
      final staged = await primary.read(stagingKey(key));
      return await primary.read(key) ?? staged;
    }
    // A locked phone cannot read an `unlocked` item. That failure MUST
    // propagate. Reporting the key as missing made a locked first launch
    // look like "no key": the UI then showed an empty key field whose next
    // save deleted the still-stored item (review 2026-10-09). The
    // background run already survives a failed load (background_glue).
    final old = await legacy.read(key);
    if (old == null) {
      // The move runs: stage written → old deleted → new written → stage
      // dropped. A null old copy means we are past "old deleted", so read
      // the STAGE FIRST and the item second: either the stage is still
      // there, or it was dropped after the new item was written and the
      // item read below sees it. (Item first, stage second let a move
      // finishing in between read as "missing" — review 2026-10-09.)
      final staged = await primary.read(stagingKey(key));
      final again = await primary.read(key);
      if (again != null) return again;
      if (staged == null) return null;
      await primary.write(key, staged);
      await _dropStage(key);
      return staged;
    }
    try {
      await primary.write(stagingKey(key), old);
    } catch (_) {
      return old; // nothing moved; the old copy is intact for later
    }
    try {
      // Delete before the real write: a first_unlock add next to the
      // `unlocked` item would be rejected as a duplicate.
      await legacy.delete(key);
    } catch (_) {
      await _dropStage(key);
      return old; // the old copy is intact; migrate on a later read
    }
    try {
      await primary.write(key, old);
    } catch (_) {
      try {
        // Never lose a key: put it back exactly as it was stored.
        await legacy.write(key, old);
      } catch (_) {
        return old; // the staged copy stays; the next read finishes the move
      }
    }
    await _dropStage(key);
    return old;
  }

  /// Try the plugin's in-place update first: once migrated it is atomic,
  /// so a key is never absent between keystrokes. Only an old-class copy
  /// makes the add fail (duplicate) — then clear every copy and add.
  @override
  Future<void> write(String key, String value) async {
    try {
      await primary.write(key, value);
    } on PlatformException catch (e) {
      // ONLY a duplicate (an old-class copy) justifies clearing every copy;
      // any other failure must leave the stored key alone. The plugin puts
      // the OSStatus in `details`.
      if ('${e.details}' != '$errSecDuplicateItem') rethrow;
      await _deleteBoth(key);
      await primary.write(key, value);
    }
  }

  /// OSStatus errSecDuplicateItem.
  static const int errSecDuplicateItem = -25299;

  @override
  Future<void> delete(String key) async {
    await _deleteBoth(key);
    await _dropStage(key); // a stale stage must not resurrect the key
  }

  Future<void> _deleteBoth(String key) async {
    await legacy.delete(key);
    await primary.delete(key);
  }

  Future<void> _dropStage(String key) async {
    try {
      await primary.delete(stagingKey(key));
    } catch (_) {
      // Harmless: a stage is only consulted when both classes are empty.
    }
  }
}

/// AI providers the analyzer can call. Gemini is the original and default;
/// OpenAI/Anthropic are BYO-key alternatives (also the escape hatch from
/// Gemini's free-tier daily cap).
/// `server` routes analysis through the user's OWN CalorieTracker server,
/// which runs the Claude Code CLI under their Claude subscription — the
/// analysis costs no API money. No credential for Anthropic ever reaches
/// the phone: the device holds only this server's own upload key.
/// `qwen`/`doubao`/`glm` are the mainland-China providers (Alibaba,
/// ByteDance, Zhipu) — BYO key like OpenAI, all OpenAI-compatible APIs.
/// They exist because the other four are unreachable from mainland China
/// without a VPN; for those users a domestic provider is the only way the
/// app works at all.
/// New values are APPENDED: the stored value is the name, but tests and
/// the provider picker iterate in declaration order.
enum AiProvider {
  gemini,
  openai,
  anthropic,
  server,
  qwen,
  doubao,
  glm,
  deepseek,
  xai,
  openrouter,
}

/// The Claude-plan model/effort choices (2026-08-05), mirroring the
/// server's closed whitelists (claude_analyzer.CLAUDE_PLAN_MODELS /
/// _EFFORTS) — the server 400s anything else, so these lists ARE the UI.
const List<String> kServerPlanModels = ['opus', 'sonnet', 'haiku', 'fable'];
const List<String> kServerPlanEfforts = ['low', 'medium', 'high'];

/// `settings.restaurant_assist` values (design R7a): Off, 'When unsure',
/// Always. MealAssist's AssistMode reads the same wire values.
const List<String> restaurantAssistModes = ['off', 'auto', 'always'];

/// A consent recipient as stored: a provider id, plus `:` and 8 lowercase
/// hex characters for Claude Plan (LookupSupport.recipientStamp).
final RegExp _consentRecipientRe = RegExp(r'^[a-z_]{1,20}(?::[0-9a-f]{8})?$');

/// Sanity ceiling for the daily goal — a typo of 20000 must not become
/// a permanent 'you are 18,000 under' message.
const int maxDailyGoalKcal = 20000;

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, this._keys);

  final SharedPreferences _prefs;
  final SecureKeyStore _keys;

  // Secure-storage keys (never written to shared_preferences).
  static const String _kApiKey = 'gemini_api_key';
  static const String _kOpenaiKey = 'openai_api_key';
  static const String _kAnthropicKey = 'anthropic_api_key';
  static const String _kServerKey = 'server_api_key';
  static const String _kQwenKey = 'qwen_api_key';
  static const String _kDoubaoKey = 'doubao_api_key';
  static const String _kGlmKey = 'glm_api_key';
  static const String _kDeepseekKey = 'deepseek_api_key';
  static const String _kXaiKey = 'xai_api_key';
  static const String _kOpenrouterKey = 'openrouter_api_key';

  // shared_preferences keys.
  static const String _kModel = 'settings.model';
  static const String _kLookbackDays = 'settings.lookback_days';
  static const String _kReportTime = 'settings.report_time';
  static const String _kAppLanguage = 'settings.app_language';
  static const String _kUnits = 'settings.units';
  static const String _kServerModel = 'settings.server_model';
  static const String _kServerEffort = 'settings.server_effort';
  static const String _kCalorieGoal = 'settings.calorie_goal';
  static const String _kSummaryPostedDate = 'settings.summary_posted_date';
  static const String _kWatcherEnabled = 'settings.watcher_enabled';
  static const String _kWatcherDisclosureSeen =
      'settings.watcher_disclosure_seen';
  static const String _kWatchGlasses = 'settings.watch_glasses';
  // The restaurant assist (design R7a; data_contracts §9a).
  static const String _kRestaurantAssist = 'settings.restaurant_assist';
  static const String _kRestaurantAssistLocation =
      'settings.restaurant_assist_location';
  static const String _kRestaurantAssistConsentAt =
      'settings.restaurant_assist_consent_at';
  static const String _kRestaurantAssistConsentRecipient =
      'settings.restaurant_assist_consent_recipient';
  static const String _kSummaryEnabled = 'settings.summary_enabled';
  static const String _kDietaryProfile = 'settings.dietary_profile';
  static const String _kQuotaPauseUntil = 'settings.quota_pause_until';
  static const String _kProvider = 'settings.provider';
  static const String _kQuotaPauseProvider = 'settings.quota_pause_provider';
  static const String _kAnalysisBlockedUntil =
      'settings.analysis_blocked_until';
  static const String _kAnalysisBlockedKind = 'settings.analysis_blocked_kind';
  static const String _kAnalysisBlockedProvider =
      'settings.analysis_blocked_provider';
  static const String _kCredentialRevision = 'settings.credential_revision';
  static const String _kAiConsentRoutes = 'settings.ai_consent_routes';
  // `route=version` entries: the consent text each grant was given under,
  // and the wording update the user answered Not now to.
  static const String _kAiConsentVersions = 'settings.ai_consent_versions';
  static const String _kAiConsentUpdateDeclined =
      'settings.ai_consent_update_declined';
  static const String _kOpenaiModel = 'settings.openai_model';
  static const String _kAnthropicModel = 'settings.anthropic_model';
  static const String _kServerBaseUrl = 'settings.server_base_url';
  static const String _kServerBackend = 'settings.server_backend';
  static const String _kQwenModel = 'settings.qwen_model';
  static const String _kDoubaoModel = 'settings.doubao_model';
  static const String _kGlmModel = 'settings.glm_model';
  static const String _kDeepseekModel = 'settings.deepseek_model';
  static const String _kXaiModel = 'settings.xai_model';
  static const String _kOpenrouterModel = 'settings.openrouter_model';
  static const String _kMealLogged = 'settings.meal_logged';

  /// Spec §8: Gemini model default (config.py:26), from shared/.
  static const String defaultModel = SharedConstants.geminiModelDefault;

  /// Spec §8: SYNC_LOOKBACK_DAYS default 2, clamp 1–30 (upload_photo.py:68),
  /// default/max from shared/.
  static const int defaultLookbackDays = SharedConstants.syncLookbackDaysDefault;
  static const int minLookbackDays = 1;
  static const int maxLookbackDays = SharedConstants.syncLookbackDaysMax;

  static const String defaultReportTime = '21:30';
  static final RegExp _reportTimeRe = RegExp(r'^([01]?\d|2[0-3]):[0-5]\d$');

  /// Vision-capable, cost-sane defaults; user-editable like the Gemini one.
  /// Refreshed 2026-09-30 against the vendors' model pages: gpt-6-luna is
  /// OpenAI's current small model (gpt-4o-mini is two generations back),
  /// claude-sonnet-5-5 the current Sonnet.
  static const String defaultOpenaiModel = 'gpt-6-luna';
  static const String defaultAnthropicModel = 'claude-sonnet-5-5';

  /// Added 2026-09-30 (docs verified the same day).
  /// deepseek-flash: DeepSeek's V4.1 Flash, the only DeepSeek model that
  /// accepts images (deepseek-v4-pro is text-only) — and the most-used
  /// model family on the market by tokens.
  /// grok-4.7: xAI's current model on the chat-completions endpoint.
  /// OpenRouter: a `~…-latest` alias, so the default follows the vendor's
  /// newest Flash instead of going stale like the IDs above eventually do.
  static const String defaultDeepseekModel = 'deepseek-flash';
  static const String defaultXaiModel = 'grok-4.7';
  static const String defaultOpenrouterModel = '~google/gemini-flash-latest';
  /// China-provider defaults, verified against provider docs 2026-07-29.
  /// qwen3-vl-flash: ¥0.15/M input — a food photo costs well under a fen.
  /// Doubao REQUIRES the exact versioned ID (undated names 404); the
  /// seed-1.6/1.8 family is flagged retiring, so pin the 2.0 generation.
  /// glm-4.6v-flash is Zhipu's PERMANENTLY FREE vision tier — the right
  /// default for a personal tracker's few photos a day (stricter
  /// concurrency caps than paid glm-4.6v, which the user can type in).
  static const String defaultQwenModel = 'qwen3-vl-flash';
  static const String defaultDoubaoModel = 'doubao-seed-2-0-mini-260428';
  static const String defaultGlmModel = 'glm-4.6v-flash';

  String? _geminiApiKey;
  String? _openaiApiKey;
  String? _anthropicApiKey;
  String? _serverApiKey;
  String? _qwenApiKey;
  String? _doubaoApiKey;
  String? _glmApiKey;
  String? _deepseekApiKey;
  String? _xaiApiKey;
  String? _openrouterApiKey;
  String _serverBaseUrl = '';
  String _serverBackend = 'claude';
  AiProvider _provider = AiProvider.gemini;
  String _openaiModel = defaultOpenaiModel;
  String _anthropicModel = defaultAnthropicModel;
  String _qwenModel = defaultQwenModel;
  String _doubaoModel = defaultDoubaoModel;
  String _glmModel = defaultGlmModel;
  String _deepseekModel = defaultDeepseekModel;
  String _xaiModel = defaultXaiModel;
  String _openrouterModel = defaultOpenrouterModel;
  String _model = defaultModel;
  int _lookbackDays = defaultLookbackDays;
  String _reportTime = defaultReportTime;
  String _appLanguage = 'system'; // 'system' | 'en' | 'zh'
  String _units = 'metric'; // 'metric' | 'imperial'
  String _serverModel = ''; // '' = server default | opus/sonnet/haiku
  String _serverEffort = ''; // '' = server default | low/medium/high
  int _calorieGoal = 0; // 0 = unset -> the daily summary uses the median
  bool _watcherEnabled = false;
  bool _watcherDisclosureSeen = false;
  bool _watchGlasses = true;
  String _restaurantAssist = 'off';
  bool _restaurantAssistLocation = false;
  DateTime? _restaurantAssistConsentAt;
  String? _restaurantAssistConsentRecipient;
  bool _summaryEnabled = true;
  String? _dietaryProfile;
  DateTime? _quotaPauseUntil;
  DateTime? _analysisBlockedUntil;
  String? _analysisBlockedKind;
  bool _mealLogged = false;

  static Future<AppSettings> load(
      {SharedPreferences? prefs, SecureKeyStore? keyStore}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final k = keyStore ?? platformKeyStore();
    final s = AppSettings._(p, k);
    final storedKey = (await k.read(_kApiKey))?.trim();
    s._geminiApiKey = (storedKey == null || storedKey.isEmpty) ? null : storedKey;
    final oaKey = (await k.read(_kOpenaiKey))?.trim();
    s._openaiApiKey = (oaKey == null || oaKey.isEmpty) ? null : oaKey;
    final anKey = (await k.read(_kAnthropicKey))?.trim();
    s._anthropicApiKey = (anKey == null || anKey.isEmpty) ? null : anKey;
    final svKey = (await k.read(_kServerKey))?.trim();
    s._serverApiKey = (svKey == null || svKey.isEmpty) ? null : svKey;
    final qwKey = (await k.read(_kQwenKey))?.trim();
    s._qwenApiKey = (qwKey == null || qwKey.isEmpty) ? null : qwKey;
    final dbKey = (await k.read(_kDoubaoKey))?.trim();
    s._doubaoApiKey = (dbKey == null || dbKey.isEmpty) ? null : dbKey;
    final glKey = (await k.read(_kGlmKey))?.trim();
    s._glmApiKey = (glKey == null || glKey.isEmpty) ? null : glKey;
    final dsKey = (await k.read(_kDeepseekKey))?.trim();
    s._deepseekApiKey = (dsKey == null || dsKey.isEmpty) ? null : dsKey;
    final xaKey = (await k.read(_kXaiKey))?.trim();
    s._xaiApiKey = (xaKey == null || xaKey.isEmpty) ? null : xaKey;
    final orKey = (await k.read(_kOpenrouterKey))?.trim();
    s._openrouterApiKey = (orKey == null || orKey.isEmpty) ? null : orKey;
    s._serverBaseUrl = (p.getString(_kServerBaseUrl) ?? '').trim();
    final backend = (p.getString(_kServerBackend) ?? '').trim();
    s._serverBackend =
        serverBackends.contains(backend) ? backend : 'claude';
    s._provider = AiProvider.values.firstWhere(
        (v) => v.name == (p.getString(_kProvider) ?? ''),
        orElse: () => AiProvider.gemini);
    s._model = _modelOr(p.getString(_kModel), defaultModel);
    s._openaiModel = _modelOr(p.getString(_kOpenaiModel), defaultOpenaiModel);
    s._anthropicModel =
        _modelOr(p.getString(_kAnthropicModel), defaultAnthropicModel);
    s._qwenModel = _modelOr(p.getString(_kQwenModel), defaultQwenModel);
    s._doubaoModel = _modelOr(p.getString(_kDoubaoModel), defaultDoubaoModel);
    s._glmModel = _modelOr(p.getString(_kGlmModel), defaultGlmModel);
    s._deepseekModel =
        _modelOr(p.getString(_kDeepseekModel), defaultDeepseekModel);
    s._xaiModel = _modelOr(p.getString(_kXaiModel), defaultXaiModel);
    s._openrouterModel =
        _modelOr(p.getString(_kOpenrouterModel), defaultOpenrouterModel);
    s._lookbackDays = (p.getInt(_kLookbackDays) ?? defaultLookbackDays)
        .clamp(minLookbackDays, maxLookbackDays);
    final rt = p.getString(_kReportTime) ?? defaultReportTime;
    s._reportTime = _reportTimeRe.hasMatch(rt) ? rt : defaultReportTime;
    final lang = p.getString(_kAppLanguage) ?? 'system';
    s._appLanguage = const {'system', 'en', 'zh'}.contains(lang)
        ? lang
        : 'system';
    final units = p.getString(_kUnits) ?? 'metric';
    s._units =
        const {'metric', 'imperial'}.contains(units) ? units : 'metric';
    final sm = p.getString(_kServerModel) ?? '';
    s._serverModel = kServerPlanModels.contains(sm) ? sm : '';
    final se = p.getString(_kServerEffort) ?? '';
    s._serverEffort = kServerPlanEfforts.contains(se) ? se : '';
    final goal = p.getInt(_kCalorieGoal) ?? 0;
    s._calorieGoal = (goal > 0 && goal <= maxDailyGoalKcal) ? goal : 0;
    s._watcherEnabled = p.getBool(_kWatcherEnabled) ?? false;
    s._watcherDisclosureSeen = p.getBool(_kWatcherDisclosureSeen) ?? false;
    s._watchGlasses = p.getBool(_kWatchGlasses) ?? true;
    final assist = p.getString(_kRestaurantAssist) ?? 'off';
    s._restaurantAssist =
        restaurantAssistModes.contains(assist) ? assist : 'off';
    s._restaurantAssistLocation =
        p.getBool(_kRestaurantAssistLocation) ?? false;
    // Written as UTC, read back local (as the quota pause is).
    s._restaurantAssistConsentAt = DateTime.tryParse(
            p.getString(_kRestaurantAssistConsentAt) ?? '')
        ?.toLocal();
    final recipient =
        (p.getString(_kRestaurantAssistConsentRecipient) ?? '').trim();
    s._restaurantAssistConsentRecipient =
        _consentRecipientRe.hasMatch(recipient) ? recipient : null;
    s._summaryEnabled = p.getBool(_kSummaryEnabled) ?? true;
    final profile = (p.getString(_kDietaryProfile) ?? '').trim();
    s._dietaryProfile = profile.isEmpty ? null : profile;
    s._mealLogged = p.getBool(_kMealLogged) ?? false;
    // Written as UTC, read back local: a zone-less string would re-parse
    // in the zone the phone is in NOW, so a pause armed in Shanghai lasted
    // 13 hours longer after landing in Chicago. A pre-fix zone-less value
    // still parses as local, exactly as before.
    s._quotaPauseUntil =
        DateTime.tryParse(p.getString(_kQuotaPauseUntil) ?? '')?.toLocal();
    s._readAnalysisBlock();
    await s._loadAiConsent();
    return s;
  }

  /// User's Gemini API key; null until the user supplies one.
  String? get geminiApiKey => _geminiApiKey;

  /// Persists to secure storage only. Null/blank clears the key.
  Future<void> setGeminiApiKey(String? value) async {
    final v = (value ?? '').trim();
    final changed = v != (_geminiApiKey ?? '');
    if (v.isEmpty) {
      _geminiApiKey = null;
      await _keys.delete(_kApiKey);
    } else {
      _geminiApiKey = v;
      await _keys.write(_kApiKey, v);
    }
    if (changed && _quotaPauseUntil != null) {
      // The pause latch belongs to the PREVIOUS key's quota. A different
      // key (fresh project, fresh quota) must not inherit up to 12 h of
      // dead air — without this, "Key OK" on a new key while the stale
      // latch silently skips every analysis.
      _quotaPauseUntil = null;
      await _prefs.remove(_kQuotaPauseUntil);
    }
    await _credentialsEdited();
    notifyListeners();
  }

  String get model => _model;

  /// Blank resets to [defaultModel] (spec §8: user-editable model string).
  Future<void> setModel(String value) =>
      _setProviderModel(value, _kModel, defaultModel, (v) => _model = v);

  /// The provider all analyses route through (delegated per call — no
  /// restart needed). Switching clears the quota-pause latch: it belongs
  /// to the OLD provider's quota.
  AiProvider get provider => _provider;

  Future<void> setProvider(AiProvider value) async {
    final changed = value != _provider;
    _provider = value;
    await _prefs.setString(_kProvider, value.name);
    if (changed && _quotaPauseUntil != null) {
      _quotaPauseUntil = null;
      await _prefs.remove(_kQuotaPauseUntil);
    }
    await _credentialsEdited();
    notifyListeners();
  }

  String? get openaiApiKey => _openaiApiKey;
  String? get anthropicApiKey => _anthropicApiKey;
  String? get qwenApiKey => _qwenApiKey;
  String? get doubaoApiKey => _doubaoApiKey;
  String? get glmApiKey => _glmApiKey;
  String? get deepseekApiKey => _deepseekApiKey;
  String? get xaiApiKey => _xaiApiKey;
  String? get openrouterApiKey => _openrouterApiKey;
  String get openaiModel => _openaiModel;
  String get anthropicModel => _anthropicModel;
  String get qwenModel => _qwenModel;
  String get doubaoModel => _doubaoModel;
  String get glmModel => _glmModel;
  String get deepseekModel => _deepseekModel;
  String get xaiModel => _xaiModel;
  String get openrouterModel => _openrouterModel;

  /// The ACTIVE provider's key (what every "can analysis succeed" guard
  /// must check — a Gemini key does nothing when OpenAI is selected).
  String? get activeApiKey => switch (_provider) {
        AiProvider.gemini => _geminiApiKey,
        AiProvider.openai => _openaiApiKey,
        AiProvider.anthropic => _anthropicApiKey,
        AiProvider.qwen => _qwenApiKey,
        AiProvider.doubao => _doubaoApiKey,
        AiProvider.glm => _glmApiKey,
        AiProvider.deepseek => _deepseekApiKey,
        AiProvider.xai => _xaiApiKey,
        AiProvider.openrouter => _openrouterApiKey,
        // The server path needs BOTH a URL and a key to be usable; the
        // guards treat a missing URL as "no key configured".
        AiProvider.server =>
          _serverBaseUrl.isEmpty ? null : _serverApiKey,
      };

  /// Human-readable name of the active provider — for user-facing
  /// messages ("No Qwen key yet…"), NOT for wire values.
  String get providerDisplayName => switch (_provider) {
        AiProvider.gemini => 'Gemini',
        AiProvider.openai => 'OpenAI',
        AiProvider.anthropic => 'Anthropic',
        AiProvider.server => 'your server',
        AiProvider.qwen => 'Qwen',
        AiProvider.doubao => 'Doubao',
        AiProvider.glm => 'GLM',
        AiProvider.deepseek => 'DeepSeek',
        AiProvider.xai => 'xAI',
        AiProvider.openrouter => 'OpenRouter',
      };

  /// The ACTIVE provider's model string.
  String get activeModel => switch (_provider) {
        AiProvider.gemini => _model,
        AiProvider.openai => _openaiModel,
        AiProvider.anthropic => _anthropicModel,
        AiProvider.qwen => _qwenModel,
        AiProvider.doubao => _doubaoModel,
        AiProvider.glm => _glmModel,
        AiProvider.deepseek => _deepseekModel,
        AiProvider.xai => _xaiModel,
        AiProvider.openrouter => _openrouterModel,
        // The server picks the model (CLAUDE_ANALYZER_MODEL on the VM);
        // the phone deliberately has no say, so nothing is user-editable.
        AiProvider.server => 'server (Claude subscription)',
      };

  Future<void> setOpenaiApiKey(String? value) =>
      _setProviderKey(value, _kOpenaiKey, (v) => _openaiApiKey = v,
          () => _openaiApiKey, AiProvider.openai);

  Future<void> setAnthropicApiKey(String? value) =>
      _setProviderKey(value, _kAnthropicKey, (v) => _anthropicApiKey = v,
          () => _anthropicApiKey, AiProvider.anthropic);

  Future<void> setQwenApiKey(String? value) =>
      _setProviderKey(value, _kQwenKey, (v) => _qwenApiKey = v,
          () => _qwenApiKey, AiProvider.qwen);

  Future<void> setDoubaoApiKey(String? value) =>
      _setProviderKey(value, _kDoubaoKey, (v) => _doubaoApiKey = v,
          () => _doubaoApiKey, AiProvider.doubao);

  Future<void> setGlmApiKey(String? value) =>
      _setProviderKey(value, _kGlmKey, (v) => _glmApiKey = v,
          () => _glmApiKey, AiProvider.glm);

  Future<void> setDeepseekApiKey(String? value) =>
      _setProviderKey(value, _kDeepseekKey, (v) => _deepseekApiKey = v,
          () => _deepseekApiKey, AiProvider.deepseek);

  Future<void> setXaiApiKey(String? value) =>
      _setProviderKey(value, _kXaiKey, (v) => _xaiApiKey = v,
          () => _xaiApiKey, AiProvider.xai);

  Future<void> setOpenrouterApiKey(String? value) =>
      _setProviderKey(value, _kOpenrouterKey, (v) => _openrouterApiKey = v,
          () => _openrouterApiKey, AiProvider.openrouter);

  /// The upload key for the user's own server (same X-API-Key the phone
  /// watcher uses). Secure storage — never shared_preferences.
  String? get serverApiKey => _serverApiKey;

  Future<void> setServerApiKey(String? value) =>
      _setProviderKey(value, _kServerKey, (v) => _serverApiKey = v,
          () => _serverApiKey, AiProvider.server);

  /// Base URL of the user's server, e.g. http://1.2.3.4 — trailing slashes
  /// trimmed so path joins never double up.
  String get serverBaseUrl => _serverBaseUrl;

  Future<void> setServerBaseUrl(String value) async {
    var v = value.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    _serverBaseUrl = v;
    await _prefs.setString(_kServerBaseUrl, v);
    await _credentialsEdited();
    notifyListeners();
  }

  /// Wire values of /api/analyze_photo's `backend` field — whose
  /// subscription pays on the SERVER: the Claude plan (default), Zhipu's
  /// GLM Coding Plan, or Volcengine's Doubao Agent Plan. The plan keys are
  /// server-side .env entries (GLM_PLAN_KEY / DOUBAO_PLAN_KEY); the phone
  /// stores only which one to ask for.
  static const List<String> serverBackends = ['claude', 'glm', 'doubao'];

  String get serverBackend => _serverBackend;

  Future<void> setServerBackend(String value) async {
    final v = serverBackends.contains(value) ? value : 'claude';
    _serverBackend = v;
    await _prefs.setString(_kServerBackend, v);
    await _credentialsEdited();
    notifyListeners();
  }

  Future<void> _setProviderKey(
      String? value,
      String storeKey,
      void Function(String?) assign,
      String? Function() current,
      AiProvider owner) async {
    final v = (value ?? '').trim();
    final changed = v != (current() ?? '');
    if (v.isEmpty) {
      assign(null);
      await _keys.delete(storeKey);
    } else {
      assign(v);
      await _keys.write(storeKey, v);
    }
    // Same rule as the Gemini setter: a changed key on the ACTIVE provider
    // must not inherit the previous key's quota pause.
    if (changed && _provider == owner && _quotaPauseUntil != null) {
      _quotaPauseUntil = null;
      await _prefs.remove(_kQuotaPauseUntil);
    }
    await _credentialsEdited();
    notifyListeners();
  }

  /// Every provider's model string: trimmed, blank resets to [fallback]
  /// (what is then stored), and the edit lifts the automatic-analysis
  /// latch as a key edit does.
  Future<void> _setProviderModel(String value, String prefsKey,
      String fallback, void Function(String) assign) async {
    final v = _modelOr(value, fallback);
    assign(v);
    await _prefs.setString(prefsKey, v);
    await _credentialsEdited();
    notifyListeners();
  }

  /// [raw] trimmed, or [fallback] when that leaves nothing: a model string
  /// is never blank, typed or stored.
  static String _modelOr(String? raw, String fallback) {
    final v = (raw ?? '').trim();
    return v.isEmpty ? fallback : v;
  }

  Future<void> setOpenaiModel(String value) =>
      _setProviderModel(value, _kOpenaiModel, defaultOpenaiModel,
          (v) => _openaiModel = v);

  Future<void> setAnthropicModel(String value) =>
      _setProviderModel(value, _kAnthropicModel, defaultAnthropicModel,
          (v) => _anthropicModel = v);

  Future<void> setQwenModel(String value) =>
      _setProviderModel(value, _kQwenModel, defaultQwenModel,
          (v) => _qwenModel = v);

  Future<void> setDoubaoModel(String value) =>
      _setProviderModel(value, _kDoubaoModel, defaultDoubaoModel,
          (v) => _doubaoModel = v);

  Future<void> setDeepseekModel(String value) =>
      _setProviderModel(value, _kDeepseekModel, defaultDeepseekModel,
          (v) => _deepseekModel = v);

  Future<void> setXaiModel(String value) =>
      _setProviderModel(value, _kXaiModel, defaultXaiModel,
          (v) => _xaiModel = v);

  Future<void> setOpenrouterModel(String value) =>
      _setProviderModel(value, _kOpenrouterModel, defaultOpenrouterModel,
          (v) => _openrouterModel = v);

  Future<void> setGlmModel(String value) =>
      _setProviderModel(value, _kGlmModel, defaultGlmModel,
          (v) => _glmModel = v);

  /// Backfill-scan window, spec §6.4 / §8 (SYNC_LOOKBACK_DAYS, clamp 1–30).
  int get lookbackDays => _lookbackDays;

  Future<void> setLookbackDays(int value) async {
    _lookbackDays = value.clamp(minLookbackDays, maxLookbackDays);
    await _prefs.setInt(_kLookbackDays, _lookbackDays);
    notifyListeners();
  }

  /// UI language override: 'system' follows the OS; 'en'/'zh' force it.
  /// App-only (spec §9 localization row) — never a wire value.
  String get appLanguage => _appLanguage;

  /// Whether the EFFECTIVE UI language is Chinese: 'zh', or 'system' on a
  /// Chinese phone (resolved as localizationsFor does). The analyzers ask
  /// the model to name meals in it (the server path sends lang: zh).
  bool get repliesInChinese => switch (_appLanguage) {
        'zh' => true,
        'en' => false,
        _ => systemLanguageCode().toLowerCase() == 'zh',
      };

  /// The phone's language code, as 'system' resolves it. A seam because
  /// PlatformDispatcher.instance ignores a widget test's locale.
  @visibleForTesting
  static String Function() systemLanguageCode =
      () => PlatformDispatcher.instance.locale.languageCode;

  Future<void> setAppLanguage(String value) async {
    final v = const {'system', 'en', 'zh'}.contains(value)
        ? value
        : 'system';
    _appLanguage = v;
    await _prefs.setString(_kAppLanguage, v);
    notifyListeners();
  }

  /// Body-data unit system for DISPLAY ('metric' | 'imperial'). Storage
  /// stays metric everywhere; the Chinese UI ignores this and renders
  /// metric regardless (user decision 2026-08-03). App-only (spec §9).
  String get units => _units;

  /// Daily calorie goal for the coach notification; 0 = unset, and the
  /// summary falls back to the typical-day median (owner decision
  /// 2026-08-06: "target if set, else typical").
  int get calorieGoal => _calorieGoal;

  Future<void> setCalorieGoal(int value) async {
    final v = (value > 0 && value <= maxDailyGoalKcal) ? value : 0;
    _calorieGoal = v;
    await _prefs.setInt(_kCalorieGoal, v);
    notifyListeners();
  }

  /// Whether a meal was ever saved in the app on this install. A key-less
  /// install that logs by hand then opens on Today instead of the Settings
  /// onboarding. A one-way preferences flag; nothing on screen listens, so
  /// it notifies no one.
  bool get mealLogged => _mealLogged;

  Future<void> markMealLogged() async {
    if (_mealLogged) return;
    _mealLogged = true;
    await _prefs.setBool(_kMealLogged, true);
  }

  /// Watermark: the last date whose summary was already posted, so the
  /// Timer path and the WorkManager catch-up do not double-notify.
  ///
  /// Read FRESH, and deliberately no synchronous getter: the WorkManager
  /// heartbeat posts from another isolate (same process, new engine), and
  /// this isolate's SharedPreferences cache never sees its write. On
  /// Android the freezer can hold the overdue Timer until the heartbeat
  /// thaws the process, so a cached read let the Timer post the summary
  /// the heartbeat had just posted — a second alert sound for the same
  /// card. Same rule as lastBackgroundRun() in background_glue.
  Future<String> freshSummaryPostedDate() async {
    await _prefs.reload();
    return _prefs.getString(_kSummaryPostedDate) ?? '';
  }

  Future<void> markSummaryPosted(String isoDate) =>
      _prefs.setString(_kSummaryPostedDate, isoDate);

  /// Claude-plan model/effort choice (2026-08-05): '' = server default.
  /// CLAUDE-ONLY — the vendor plans map model names server-side and the
  /// API 400s overrides for them, so the UI only offers these on the
  /// Claude plan. Values mirror the server's closed whitelists.
  String get serverModel => _serverModel;
  String get serverEffort => _serverEffort;

  Future<void> setServerModel(String value) async {
    final v = kServerPlanModels.contains(value) ? value : '';
    _serverModel = v;
    await _prefs.setString(_kServerModel, v);
    await _credentialsEdited();
    notifyListeners();
  }

  Future<void> setServerEffort(String value) async {
    final v = kServerPlanEfforts.contains(value) ? value : '';
    _serverEffort = v;
    await _prefs.setString(_kServerEffort, v);
    notifyListeners();
  }

  Future<void> setUnits(String value) async {
    final v =
        const {'metric', 'imperial'}.contains(value) ? value : 'metric';
    _units = v;
    await _prefs.setString(_kUnits, v);
    notifyListeners();
  }

  /// Local time (24h "HH:mm") for the daily-report notification (spec §5.5).
  String get reportTime => _reportTime;

  Future<void> setReportTime(String value) async {
    final v = value.trim();
    if (!_reportTimeRe.hasMatch(v)) {
      throw ArgumentError.value(value, 'reportTime', 'expected HH:mm (24h)');
    }
    _reportTime = v;
    await _prefs.setString(_kReportTime, v);
    notifyListeners();
  }

  /// Whether the daily coach summary is delivered at all. Defaults TRUE —
  /// the summary predates this switch and every existing install expects
  /// it — but it is the only way to stop the nightly card short of muting
  /// the whole notification channel, which also silences meal cards
  /// (friend-cohort finding 2026-10-10). Every delivery path reads it:
  /// the launch Timer + catch-up (di.dart), the Android heartbeat
  /// (background_glue.dart) and the iOS OS card (os_summary.dart).
  bool get summaryEnabled => _summaryEnabled;

  Future<void> setSummaryEnabled(bool value) async {
    _summaryEnabled = value;
    await _prefs.setBool(_kSummaryEnabled, value);
    notifyListeners();
  }

  /// The AI recipients (aiConsentRoute: a provider id, or `server:<plan>`)
  /// the user allowed meal data to go to — App Store 5.1.2(i) asks for
  /// explicit permission per third party, before the first send. Not a
  /// secret; device-local, never exported. The UI asks: every automatic
  /// path already needs [watcherEnabled], and the switch, a provider/plan
  /// change while it is on, and a setup link all ask first. The photo
  /// pipeline reads it once more at each send (AiSendGate), so a photo
  /// already queued never goes to a recipient stopped or switched to
  /// meanwhile; it also reads [previousDayLeftoverContext].
  Set<String> _aiConsentRoutes = const {};

  /// The route the current provider choice sends to.
  String get activeAiConsentRoute =>
      aiConsentRoute(_provider.name, _serverBackend);

  bool hasAiConsent(String route) => _aiConsentRoutes.contains(route);

  /// The consent text ([aiConsentWordingVersion]) each grant was given
  /// under, and the wording update the user answered Not now to, by route.
  Map<String, int> _aiConsentVersions = const {};
  Map<String, int> _aiConsentUpdateDeclined = const {};

  /// The consent text [route] was allowed under: 0 = not allowed; 1 = a
  /// grant with no version recorded (every grant from before versions
  /// existed, the one-time seed included — they never saw a later text).
  int aiConsentVersion(String route) =>
      hasAiConsent(route) ? (_aiConsentVersions[route] ?? 1) : 0;

  /// Whether the user answered Not now when asked to allow [route] again
  /// for the current text (ui/ai_consent.dart askAiConsentUpdate): it is
  /// not asked again, and the older grant stands as it was.
  bool aiConsentUpdateDeclined(String route) =>
      (_aiConsentUpdateDeclined[route] ?? 0) >= aiConsentWordingVersion;

  Future<void> declineAiConsentUpdate(String route) async {
    _aiConsentUpdateDeclined = {
      ..._aiConsentUpdateDeclined,
      route: aiConsentWordingVersion,
    };
    await _prefs.setStringList(
        _kAiConsentUpdateDeclined, _versionEntries(_aiConsentUpdateDeclined));
    notifyListeners();
  }

  /// Whether a photo taken before 04:00 may also carry the previous day's
  /// meals (B14): only when the CURRENT recipient was allowed under the
  /// text that says so. An older grant keeps sending that day's meals
  /// only, as it agreed to. Read per photo by PhotoPipeline in both
  /// engines.
  bool get previousDayLeftoverContext =>
      aiConsentVersion(activeAiConsentRoute) >= aiConsentPreviousDayVersion;

  /// Allow ([granted]) or stop sending to [route]. Every grant is given
  /// under the text the dialogs show now, so it records
  /// [aiConsentWordingVersion]; withdrawing forgets the version and any
  /// answer to a wording update.
  Future<void> setAiConsent(String route, {required bool granted}) async {
    final next = {..._aiConsentRoutes};
    final versions = {..._aiConsentVersions};
    final declined = {..._aiConsentUpdateDeclined};
    if (granted) {
      next.add(route);
      versions[route] = aiConsentWordingVersion;
    } else {
      next.remove(route);
      versions.remove(route);
    }
    declined.remove(route);
    _aiConsentRoutes = next;
    _aiConsentVersions = versions;
    _aiConsentUpdateDeclined = declined;
    // The routes first: a grant interrupted before its version is written
    // reads as version 1 — the narrower of the two.
    await _prefs.setStringList(_kAiConsentRoutes, next.toList()..sort());
    await _prefs.setStringList(_kAiConsentVersions, _versionEntries(versions));
    await _prefs.setStringList(
        _kAiConsentUpdateDeclined, _versionEntries(declined));
    notifyListeners();
  }

  static List<String> _versionEntries(Map<String, int> m) =>
      [for (final e in m.entries) '${e.key}=${e.value}']..sort();

  /// `route=version` entries back into a map; a malformed one is dropped
  /// (a grant without its version reads as version 1).
  static Map<String, int> _readVersionEntries(List<String>? stored) {
    final out = <String, int>{};
    for (final entry in stored ?? const <String>[]) {
      final at = entry.lastIndexOf('=');
      if (at <= 0) continue;
      final v = int.tryParse(entry.substring(at + 1));
      if (v != null && v > 0) out[entry.substring(0, at)] = v;
    }
    return out;
  }

  /// Reads the routes, or — the first launch of a build that has them —
  /// seeds them ONCE: an install that accepted the camera-roll notice or
  /// runs the watcher already agreed to its current recipient, and keeps
  /// sending to it without a new prompt. Deliberately NOT gated on a
  /// configured key: a watcher that is on without a key would otherwise
  /// start sending, unasked, the moment a key is pasted. Every other
  /// install starts with none and is asked before its first send. A seed
  /// is written at once (by whichever engine loads first — both compute
  /// the same value), so a later provider change never re-derives it. An
  /// empty one needs no write: in this build the watcher switch and the
  /// notice flag only turn on together with a saved consent.
  Future<void> _loadAiConsent() async {
    // A seed below writes no version: it is a version-1 grant.
    _aiConsentVersions =
        _readVersionEntries(_prefs.getStringList(_kAiConsentVersions));
    _aiConsentUpdateDeclined =
        _readVersionEntries(_prefs.getStringList(_kAiConsentUpdateDeclined));
    final stored = _prefs.getStringList(_kAiConsentRoutes);
    if (stored != null) {
      _aiConsentRoutes = stored.toSet();
      return;
    }
    if (!_watcherEnabled && !_watcherDisclosureSeen) {
      _aiConsentRoutes = const {};
      return;
    }
    _aiConsentRoutes = {activeAiConsentRoute};
    await _prefs.setStringList(
        _kAiConsentRoutes, _aiConsentRoutes.toList());
  }

  /// Re-reads the allowed recipients from disk. For the BACKGROUND run
  /// only — another isolate with its own preferences cache: the open app
  /// may have withdrawn a consent (Settings › Stop Sharing) since this
  /// engine loaded, and its photo pipeline asks again at each send
  /// (AiSendGate.refresh). The app's own engine never calls it: it is the
  /// one that writes the list, and a reload overlapping its own write
  /// could bring a consent just withdrawn back into memory. No stored
  /// list: the copy in memory stands. The text each grant was given under
  /// is re-read with it, so [previousDayLeftoverContext] follows an update
  /// question answered in the open app as well.
  Future<void> reloadAiConsent() async {
    await _prefs.reload();
    final stored = _prefs.getStringList(_kAiConsentRoutes);
    if (stored == null) return;
    _aiConsentRoutes = stored.toSet();
    _aiConsentVersions =
        _readVersionEntries(_prefs.getStringList(_kAiConsentVersions));
  }

  /// Spec §6 auto intake toggle — defaults false until permissions granted.
  bool get watcherEnabled => _watcherEnabled;

  Future<void> setWatcherEnabled(bool value) async {
    _watcherEnabled = value;
    await _prefs.setBool(_kWatcherEnabled, value);
    notifyListeners();
  }

  /// Whether the user has accepted the one-time "photos will be sent to
  /// your AI service" notice that turning on 监控相册 shows (App Store
  /// 5.1.2(i): explicit consent before personal data goes to a third-party
  /// AI). Device-local: never exported, never set by a setup link.
  bool get watcherDisclosureSeen => _watcherDisclosureSeen;

  Future<void> setWatcherDisclosureSeen(bool value) async {
    _watcherDisclosureSeen = value;
    await _prefs.setBool(_kWatcherDisclosureSeen, value);
    notifyListeners();
  }

  /// Whether the automatic intake logs photos it recognizes as taken with
  /// Meta glasses (design G3, the 'Meta glasses photos' switch; default on).
  /// Off, they are not offered at all — PhotoPipeline.includeGlasses — and
  /// photos the user adds on purpose still go through. Read by both
  /// engines: the background run loads it with the rest at its start.
  bool get watchGlasses => _watchGlasses;

  Future<void> setWatchGlasses(bool value) async {
    _watchGlasses = value;
    await _prefs.setBool(_kWatchGlasses, value);
    notifyListeners();
  }

  /// The restaurant assist's mode (design R7a, `settings.restaurant_assist`):
  /// 'off' (the default) | 'auto' ('When unsure') | 'always'. Anything else
  /// stored reads as 'off'. Only the app engine reads it (MealAssist).
  String get restaurantAssist => _restaurantAssist;

  /// 'Use photo location' (`settings.restaurant_assist_location`): whether
  /// automatic lookups of restaurant meals may add the chains around where
  /// the photo was taken. iOS only — Android reads no photo location in v1,
  /// so it reads false there whatever is stored.
  bool get restaurantAssistLocation =>
      _restaurantAssistLocation &&
      defaultTargetPlatform == TargetPlatform.iOS;

  /// When the user agreed to the consent sheet, or null (no consent). Meals
  /// logged before it are never looked up automatically.
  DateTime? get restaurantAssistConsentAt => _restaurantAssistConsentAt;

  /// Whom that consent names: LookupSupport.recipientStamp — the provider id,
  /// plus for Claude Plan `:` and 8 hex characters of SHA-256 of the server
  /// host (never the host itself). Null without a consent.
  String? get restaurantAssistConsentRecipient =>
      _restaurantAssistConsentRecipient;

  /// Writes the restaurant assist's settings together, with ONE change
  /// notification, so MealAssist never sees a mode turned on without the
  /// consent stamped with it. Null leaves a value as it is; [clearConsent]
  /// forgets the consent. An unknown [mode] is stored as 'off'; a malformed
  /// [consentRecipient] is not stored (and the consent is cleared with it).
  Future<void> setRestaurantAssist({
    String? mode,
    bool? location,
    DateTime? consentAt,
    String? consentRecipient,
    bool clearConsent = false,
  }) async {
    if (mode != null) {
      _restaurantAssist = restaurantAssistModes.contains(mode) ? mode : 'off';
    }
    if (location != null) _restaurantAssistLocation = location;
    var forget = clearConsent;
    if (consentRecipient != null &&
        !_consentRecipientRe.hasMatch(consentRecipient)) {
      forget = true;
    }
    if (forget) {
      _restaurantAssistConsentAt = null;
      _restaurantAssistConsentRecipient = null;
    } else {
      if (consentAt != null) _restaurantAssistConsentAt = consentAt;
      if (consentRecipient != null) {
        _restaurantAssistConsentRecipient = consentRecipient;
      }
    }
    if (mode != null) {
      await _prefs.setString(_kRestaurantAssist, _restaurantAssist);
    }
    if (location != null) {
      await _prefs.setBool(_kRestaurantAssistLocation, location);
    }
    final at = _restaurantAssistConsentAt;
    final who = _restaurantAssistConsentRecipient;
    if (forget || at == null) {
      await _prefs.remove(_kRestaurantAssistConsentAt);
    } else {
      await _prefs.setString(
          _kRestaurantAssistConsentAt, at.toUtc().toIso8601String());
    }
    if (forget || who == null) {
      await _prefs.remove(_kRestaurantAssistConsentRecipient);
    } else {
      await _prefs.setString(_kRestaurantAssistConsentRecipient, who);
    }
    notifyListeners();
  }

  /// Spec §1.3 dietary-profile text; null when unset/blank.
  String? get dietaryProfile => _dietaryProfile;

  Future<void> setDietaryProfile(String? value) async {
    final v = (value ?? '').trim();
    _dietaryProfile = v.isEmpty ? null : v;
    if (_dietaryProfile == null) {
      await _prefs.remove(_kDietaryProfile);
    } else {
      await _prefs.setString(_kDietaryProfile, _dietaryProfile!);
    }
    notifyListeners();
  }

  /// Daily-quota pause latch (spec §3.3): while now < this, photo analysis is
  /// skipped and NL requests are refused. Null = not paused.
  DateTime? get quotaPauseUntil => _quotaPauseUntil;

  /// [forProvider] tags WHOSE quota this pause belongs to (defaults to the
  /// current provider). An analyzer must pass its own identity: a Gemini
  /// call still in flight after the user switched to OpenAI would
  /// otherwise arm a pause the clear-on-switch rule already ran for —
  /// dead-airing the NEW provider for up to 12 h.
  Future<void> setQuotaPauseUntil(DateTime? value,
      {AiProvider? forProvider}) async {
    _quotaPauseUntil = value;
    if (value == null) {
      await _prefs.remove(_kQuotaPauseUntil);
      await _prefs.remove(_kQuotaPauseProvider);
    } else {
      await _prefs.setString(
          _kQuotaPauseUntil, value.toUtc().toIso8601String());
      await _prefs.setString(
          _kQuotaPauseProvider, (forProvider ?? _provider).name);
    }
    notifyListeners();
  }

  /// Paused only when the latch is live AND belongs to the CURRENT
  /// provider — another provider's quota never gates this one.
  /// "An analysis attempted right now could actually succeed": the ACTIVE
  /// provider has a key and the §3.3 quota latch is not armed. Every
  /// byte-reading trigger (launch/resume catch-up, watcher toggle, headless
  /// run) gates on this. Spelled out per call site it drifted once already —
  /// the check read the Gemini-only key, so server-provider users silently
  /// lost their catch-up scans.
  bool get canAnalyze =>
      (activeApiKey ?? '').trim().isNotEmpty && !isQuotaPaused;

  bool get isQuotaPaused {
    if (_quotaPauseUntil == null ||
        !DateTime.now().isBefore(_quotaPauseUntil!)) {
      return false;
    }
    final owner = _prefs.getString(_kQuotaPauseProvider);
    return owner == null || owner == _provider.name;
  }

  /// [canAnalyze] for the AUTOMATIC scan (watcher, launch/resume catch-up,
  /// background run): also false while the automatic-analysis latch below
  /// is armed. Deliberate adds (picker, share, 照片覆盖检查) keep using
  /// [canAnalyze] — a deliberate photo is how the user checks the fix.
  bool get canAutoAnalyze => canAnalyze && !isAnalysisBlocked;

  /// How long a refusal parks the automatic scan. A rejected key stays
  /// rejected until the user edits it (which clears the latch at once);
  /// a region block lifts with the VPN node, and an empty balance with a
  /// top-up at the provider's console — neither edits anything here, so
  /// both are re-tried sooner (a passing Test This Provider or a
  /// deliberate add resumes them at once). Not shorter: each re-arm by a
  /// background run posts the paused notice again.
  static const Duration rejectedKeyBlockTtl = Duration(hours: 24);
  static const Duration regionBlockTtl = Duration(hours: 2);
  static const Duration billingBlockTtl = Duration(hours: 2);

  /// Automatic-analysis latch (2026-10-12): armed when an AUTOMATIC photo
  /// came back 'rejectedKey', 'regionBlocked' or (run 7) 'billing'.
  /// Without it, every scan —
  /// Android's 30-minute job, each launch/resume/library change, iOS's
  /// refresh — re-uploaded the whole lookback window against a key or
  /// region that refuses each photo. Stores the KIND and the provider only,
  /// never anything derived from the key. Owned by the provider that set
  /// it, like the quota pause.
  bool get isAnalysisBlocked {
    final until = _analysisBlockedUntil;
    final now = DateTime.now();
    if (until == null || !now.isBefore(until)) return false;
    // No pause outlasts its kind's TTL: an end further out than that was
    // armed under a clock that has since been set back, and would park the
    // scan for as long as the skew. Minutes of slack for NTP nudges.
    final ttl = _analysisBlockTtl(_analysisBlockedKind);
    if (ttl == null ||
        until.isAfter(now.add(ttl + const Duration(minutes: 5)))) {
      return false;
    }
    // Unlike the quota pause, a pause WITHOUT its provider is not one: the
    // provider is written first, so a missing one is a torn arm (2026-10-12).
    final owner = _prefs.getString(_kAnalysisBlockedProvider);
    return owner != null && owner == _provider.name;
  }

  /// 'rejectedKey' | 'regionBlocked' | 'billing' while [isAnalysisBlocked],
  /// else null.
  String? get analysisBlockedKind =>
      isAnalysisBlocked ? _analysisBlockedKind : null;

  /// When the latch lifts by itself; null while it is not armed.
  DateTime? get analysisBlockedUntil =>
      isAnalysisBlocked ? _analysisBlockedUntil : null;

  /// Bumped by every credential/provider/model/server edit and PERSISTED,
  /// so the background engine (another isolate, its own preferences
  /// cache) sees the foreground's edits. Read BEFORE an analysis and handed
  /// to [blockAutomaticAnalysis], so a refusal of the key the user has
  /// just replaced does not park the new one. A plain counter — nothing
  /// derived from a key is ever stored.
  int get credentialRevision => _prefs.getInt(_kCredentialRevision) ?? 0;

  /// Arm the latch for [kind] ('rejectedKey' | 'regionBlocked' |
  /// 'billing'; anything else is ignored). [revision] stale = dropped: compared against the
  /// revision ON DISK, before and after the write, because the edit that
  /// made it stale may have happened in the other isolate. [now] is a
  /// test seam.
  Future<void> blockAutomaticAnalysis(String kind,
      {int? revision, DateTime? now}) async {
    final ttl = _analysisBlockTtl(kind);
    if (ttl == null) return;
    if (revision != null) {
      await _prefs.reload();
      if (revision != credentialRevision) return;
    }
    final until = (now ?? DateTime.now()).add(ttl);
    _analysisBlockedUntil = until;
    _analysisBlockedKind = kind;
    // Provider FIRST: a pause without its owner reads as no pause, so an
    // arm cut short in between parks nothing.
    await _prefs.setString(_kAnalysisBlockedProvider, _provider.name);
    await _prefs.setString(_kAnalysisBlockedKind, kind);
    await _prefs.setString(
        _kAnalysisBlockedUntil, until.toUtc().toIso8601String());
    if (revision != null) {
      // An edit that landed between the check above and these writes has
      // already removed the keys — or will find these and remove them; one
      // that removed them BEFORE the writes is caught here.
      await _prefs.reload();
      if (revision != credentialRevision) {
        await _removeAnalysisBlock();
        return;
      }
    }
    // Re-read what is now on disk: a reloadAnalysisBlock (a resume, the
    // pipeline's refresh) that ran between the writes above read them half
    // done and cleared the in-memory pause set at the top, and this notify
    // then showed the Settings footer "not paused" (2026-10-12).
    _readAnalysisBlock();
    notifyListeners();
  }

  static Duration? _analysisBlockTtl(String? kind) => switch (kind) {
        'rejectedKey' => rejectedKeyBlockTtl,
        'regionBlocked' => regionBlockTtl,
        'billing' => billingBlockTtl,
        _ => null,
      };

  /// Lift the latch: an analysis succeeded, so the key and region work.
  /// Touches the stored keys only when a pause is actually set — in this
  /// isolate's copy, or on disk (the background engine may have armed it
  /// since this one loaded): every successful photo comes through here.
  Future<void> clearAnalysisBlock() async {
    final wasSet = _analysisBlockedUntil != null;
    if (!wasSet && !_analysisBlockStored()) {
      await _prefs.reload();
      if (!_analysisBlockStored()) return;
    }
    await _removeAnalysisBlock();
    if (wasSet) notifyListeners();
  }

  /// Something proved the ACTIVE provider's credentials work (测试 AI 服务's
  /// key probe answered OK): lift a 'rejectedKey' pause it owns, and a
  /// 'regionBlocked' one only when [reachedGeneration] — the probe went
  /// through the provider's generation endpoint, which is where a region
  /// is refused (the server's probe is its auth check, which is not).
  Future<void> credentialsProven({required bool reachedGeneration}) async {
    await reloadAnalysisBlock();
    final kind = _prefs.getString(_kAnalysisBlockedKind);
    if (kind == null) return;
    final owner = _prefs.getString(_kAnalysisBlockedProvider);
    if (owner != null && owner != _provider.name) return;
    if (kind == 'regionBlocked' && !reachedGeneration) return;
    final wasSet = _analysisBlockedUntil != null;
    await _removeAnalysisBlock();
    if (wasSet) notifyListeners();
  }

  bool _analysisBlockStored() =>
      _prefs.getString(_kAnalysisBlockedUntil) != null ||
      _prefs.getString(_kAnalysisBlockedKind) != null ||
      _prefs.getString(_kAnalysisBlockedProvider) != null;

  Future<void> _removeAnalysisBlock() async {
    _analysisBlockedUntil = null;
    _analysisBlockedKind = null;
    await _prefs.remove(_kAnalysisBlockedUntil);
    await _prefs.remove(_kAnalysisBlockedKind);
    await _prefs.remove(_kAnalysisBlockedProvider);
  }

  /// Re-read the latch from disk: the background engine (another isolate,
  /// its own preferences cache) may have armed or cleared it since this
  /// one loaded. Called before the resume catch-up.
  Future<void> reloadAnalysisBlock() async {
    final before = (_analysisBlockedUntil, _analysisBlockedKind);
    await _prefs.reload();
    _readAnalysisBlock();
    if ((_analysisBlockedUntil, _analysisBlockedKind) != before) {
      notifyListeners();
    }
  }

  void _readAnalysisBlock() {
    final kind = _prefs.getString(_kAnalysisBlockedKind);
    final until = DateTime.tryParse(
            _prefs.getString(_kAnalysisBlockedUntil) ?? '')
        ?.toLocal();
    // Every kind _analysisBlockTtl knows: an arm of any other kind would
    // be erased by blockAutomaticAnalysis's own trailing re-read.
    final known = _analysisBlockTtl(kind) != null;
    _analysisBlockedUntil = known ? until : null;
    _analysisBlockedKind = known && until != null ? kind : null;
  }

  /// Every edit that can change whether a photo is accepted — a key, the
  /// provider, a model, the server address, plan or model — lifts the
  /// latch: the next automatic photo is the test of the new setup. Even a
  /// same-value re-save counts (the user may have fixed the account at the
  /// provider's console). The revision is bumped BEFORE the removal and
  /// the removal is unconditional: the background engine may have armed
  /// the pause on disk without this isolate's copy knowing.
  Future<void> _credentialsEdited() async {
    await _prefs.setInt(_kCredentialRevision, credentialRevision + 1);
    await _removeAnalysisBlock();
  }
}
