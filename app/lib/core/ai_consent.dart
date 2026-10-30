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
