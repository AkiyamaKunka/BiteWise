/// Who receives meal data when the app asks an AI, as the per-recipient
/// consent sees it (App Store guideline 5.1.2(i): disclose where personal
/// data goes, "including with third-party AI", and get explicit permission
/// first). Pure, so AppSettings and the UI name a recipient the same way.
library;

/// The consent route of a provider choice: the provider id for an API key
/// ('gemini', 'openai', …), and `server:<plan>` for the user's own server.
/// The AI company behind the server is the PLAN (Claude, GLM or Doubao),
/// so switching plans on the same server is a new recipient and asks
/// again; editing the server's address is not.
String aiConsentRoute(String provider, String serverBackend) =>
    provider == 'server'
        ? 'server:${const {'glm', 'doubao'}.contains(serverBackend) ? serverBackend : 'claude'}'
        : provider;

/// Every route the app can send to (the provider ids plus the three
/// server plans), for tests and for code that must enumerate them.
const Set<String> allAiConsentRoutes = {
  'gemini',
  'openai',
  'anthropic',
  'xai',
  'openrouter',
  'deepseek',
  'qwen',
  'doubao',
  'glm',
  'server:claude',
  'server:glm',
  'server:doubao',
};

/// Routes whose AI company processes the data in mainland China:
/// api.deepseek.com, dashscope.aliyuncs.com, ark.cn-beijing.volces.com and
/// open.bigmodel.cn — the GLM and Doubao plans reach the last two from the
/// user's server (claude_analyzer.py). The consent dialog says so.
const Set<String> aiRoutesInMainlandChina = {
  'deepseek',
  'qwen',
  'doubao',
  'glm',
  'server:glm',
  'server:doubao',
};

/// The version of the consent TEXT a grant was given under. Every new
/// grant records the current one (AppSettings.setAiConsent); a grant with
/// none recorded — every grant from before versions existed, the one-time
/// seed of a pre-consent install included — is version 1.
///
/// - 1: the original text.
/// - 2: a photo taken before 4 a.m. also carries the day before's meals
///   (B14, run 7).
///
/// When the text changes what is sent, bump this: the app shell then asks
/// once more for a grant from an older version (ui/ai_consent.dart
/// askAiConsentUpdate), and the new data waits for that answer.
const int aiConsentWordingVersion = 2;

/// The first [aiConsentWordingVersion] that says a photo taken before
/// 04:00 also carries the previous day's meals. A grant from before it
/// keeps exactly what it agreed to: that day's meals only
/// (AppSettings.previousDayLeftoverContext → PhotoPipeline).
const int aiConsentPreviousDayVersion = 2;
