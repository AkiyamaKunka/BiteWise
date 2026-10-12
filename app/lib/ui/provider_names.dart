/// Display names for providers and subscription plans. Not a widget file:
/// the diagnostics engine names the provider with the same words as the
/// settings pages (it showed the raw id 'qwen' in the Chinese UI, loop
/// find 2026-10-08), and provider_page.dart already imports diagnostics.
library;

import '../l10n/app_localizations.dart';

/// Short display name for an API provider id.
String providerLabel(String provider) => switch (provider) {
      'openai' => 'OpenAI',
      'anthropic' => 'Claude',
      'server' => 'My server',
      'qwen' => 'Qwen 通义千问',
      'doubao' => 'Doubao 豆包',
      'glm' => 'GLM 智谱',
      'deepseek' => 'DeepSeek',
      'xai' => 'Grok',
      'openrouter' => 'OpenRouter',
      _ => 'Gemini',
    };

/// Row-value display: the concrete plan name, never an opaque 'My server'.
/// Short ('Doubao Plan', not 'Doubao Agent Plan'): beside the check and
/// chevron of the AI provider page's Subscription row the full names cut
/// the TITLE to 'Subscri…' in English at 375/390 pt (loop find
/// 2026-10-08); the picker one tap further keeps the full names. Pinned
/// with the iPhone's own font by test/ui/row_fit_layout_test.dart.
/// Localized: the Chinese Settings showed 'Claude Plan' as the row value
/// while the 订阅 page one tap later names the same item 'Claude 订阅'.
String providerDisplayLabel(
        AppLocalizations l, String provider, String serverBackend) =>
    provider == 'server'
        ? switch (serverBackend) {
            'glm' => l.planShortGlm,
            'doubao' => l.planShortDoubao,
            _ => l.planShortClaude,
          }
        : providerLabel(provider);
