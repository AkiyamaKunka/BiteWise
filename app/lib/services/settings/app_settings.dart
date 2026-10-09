/// User-editable settings + persistence (spec §8 knobs).
///
/// Non-secret values live in shared_preferences; EVERY provider credential
/// (Gemini, OpenAI, Anthropic, the own-server upload key, and the
/// Qwen/Doubao/GLM keys) lives in flutter_secure_storage (spec §8:
/// "user-supplied, stored in secure storage").
/// The analyzer's daily-quota pause latch (spec §3.3) is persisted here too so
/// it survives restarts. A simple [ChangeNotifier] so UI can listen.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const String _kDietaryProfile = 'settings.dietary_profile';
  static const String _kQuotaPauseUntil = 'settings.quota_pause_until';
  static const String _kProvider = 'settings.provider';
  static const String _kQuotaPauseProvider = 'settings.quota_pause_provider';
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
  String? _dietaryProfile;
  DateTime? _quotaPauseUntil;

  static Future<AppSettings> load(
      {SharedPreferences? prefs, SecureKeyStore? keyStore}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final k = keyStore ?? const FlutterSecureKeyStore();
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
    final model = (p.getString(_kModel) ?? '').trim();
    s._model = model.isEmpty ? defaultModel : model;
    final oaModel = (p.getString(_kOpenaiModel) ?? '').trim();
    s._openaiModel = oaModel.isEmpty ? defaultOpenaiModel : oaModel;
    final anModel = (p.getString(_kAnthropicModel) ?? '').trim();
    s._anthropicModel = anModel.isEmpty ? defaultAnthropicModel : anModel;
    final qwModel = (p.getString(_kQwenModel) ?? '').trim();
    s._qwenModel = qwModel.isEmpty ? defaultQwenModel : qwModel;
    final dbModel = (p.getString(_kDoubaoModel) ?? '').trim();
    s._doubaoModel = dbModel.isEmpty ? defaultDoubaoModel : dbModel;
    final glModel = (p.getString(_kGlmModel) ?? '').trim();
    s._glmModel = glModel.isEmpty ? defaultGlmModel : glModel;
    final dsModel = (p.getString(_kDeepseekModel) ?? '').trim();
    s._deepseekModel = dsModel.isEmpty ? defaultDeepseekModel : dsModel;
    final xaModel = (p.getString(_kXaiModel) ?? '').trim();
    s._xaiModel = xaModel.isEmpty ? defaultXaiModel : xaModel;
    final orModel = (p.getString(_kOpenrouterModel) ?? '').trim();
    s._openrouterModel = orModel.isEmpty ? defaultOpenrouterModel : orModel;
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
    final profile = (p.getString(_kDietaryProfile) ?? '').trim();
    s._dietaryProfile = profile.isEmpty ? null : profile;
    // Written as UTC, read back local: a zone-less string would re-parse
    // in the zone the phone is in NOW, so a pause armed in Shanghai lasted
    // 13 hours longer after landing in Chicago. A pre-fix zone-less value
    // still parses as local, exactly as before.
    s._quotaPauseUntil =
        DateTime.tryParse(p.getString(_kQuotaPauseUntil) ?? '')?.toLocal();
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
    notifyListeners();
  }

  String get model => _model;

  /// Blank resets to [defaultModel] (spec §8: user-editable model string).
  Future<void> setModel(String value) async {
    final v = value.trim();
    _model = v.isEmpty ? defaultModel : v;
    await _prefs.setString(_kModel, _model);
    notifyListeners();
  }

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
    notifyListeners();
  }

  Future<void> setOpenaiModel(String value) async {
    final v = value.trim();
    _openaiModel = v.isEmpty ? defaultOpenaiModel : v;
    await _prefs.setString(_kOpenaiModel, _openaiModel);
    notifyListeners();
  }

  Future<void> setAnthropicModel(String value) async {
    final v = value.trim();
    _anthropicModel = v.isEmpty ? defaultAnthropicModel : v;
    await _prefs.setString(_kAnthropicModel, _anthropicModel);
    notifyListeners();
  }

  Future<void> setQwenModel(String value) async {
    final v = value.trim();
    _qwenModel = v.isEmpty ? defaultQwenModel : v;
    await _prefs.setString(_kQwenModel, _qwenModel);
    notifyListeners();
  }

  Future<void> setDoubaoModel(String value) async {
    final v = value.trim();
    _doubaoModel = v.isEmpty ? defaultDoubaoModel : v;
    await _prefs.setString(_kDoubaoModel, _doubaoModel);
    notifyListeners();
  }

  Future<void> setDeepseekModel(String value) async {
    final v = value.trim();
    _deepseekModel = v.isEmpty ? defaultDeepseekModel : v;
    await _prefs.setString(_kDeepseekModel, _deepseekModel);
    notifyListeners();
  }

  Future<void> setXaiModel(String value) async {
    final v = value.trim();
    _xaiModel = v.isEmpty ? defaultXaiModel : v;
    await _prefs.setString(_kXaiModel, _xaiModel);
    notifyListeners();
  }

  Future<void> setOpenrouterModel(String value) async {
    final v = value.trim();
    _openrouterModel = v.isEmpty ? defaultOpenrouterModel : v;
    await _prefs.setString(_kOpenrouterModel, _openrouterModel);
    notifyListeners();
  }

  Future<void> setGlmModel(String value) async {
    final v = value.trim();
    _glmModel = v.isEmpty ? defaultGlmModel : v;
    await _prefs.setString(_kGlmModel, _glmModel);
    notifyListeners();
  }

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

  /// Spec §6 auto intake toggle — defaults false until permissions granted.
  bool get watcherEnabled => _watcherEnabled;

  Future<void> setWatcherEnabled(bool value) async {
    _watcherEnabled = value;
    await _prefs.setBool(_kWatcherEnabled, value);
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
}
