/// The AI Provider chooser (user-designed IA, 2026-08-02 v2): TWO
/// connection types, each on its OWN page —
///
///   API Key · pay per photo        → ApiKeyProviderPage
///   Subscription · via your server → SubscriptionProviderPage
///
/// This page shows which type is active (checkmark + the concrete choice
/// as the row value) and hosts the one Test action; everything else lives
/// one level down. Shared constants for both pages live here.
library;

import 'package:flutter/material.dart';

import '../../../core/contracts.dart';
import '../../diagnostics.dart';
import '../../services.dart' show SettingsStore;
import '../../l10n.dart';
import '../../widgets/grouped.dart';
import '../diagnostics_screen.dart';
import 'api_key_page.dart';
import 'subscription_page.dart';

/// Sentinel value for the model picker's "type it yourself" row.
const String kCustomModelSentinel = '__custom__';

/// Curated vision-capable models per provider (verified 2026-07 research),
/// with the tradeoff IN the label — users pick, they don't memorize vendor
/// id strings like doubao-seed-2-0-mini-260428. The Custom row reveals a
/// text field so a model a vendor ships NEXT month never bricks the app.
const Map<String, List<(String, String)>> kKnownModels = {
  // International lists refreshed 2026-09-30 from each vendor's models
  // page (Google restricts the 2.5 generation to accounts that already
  // used it, so it can no longer be a default for new users).
  'gemini': [
    ('gemini-3.8-flash', 'gemini-3.8-flash — fast, free-tier default'),
    ('gemini-3.5-flash-lite', 'gemini-3.5-flash-lite — cheapest, free tier'),
    ('gemini-3.1-pro-preview', 'gemini-3.1-pro-preview — strongest, slower'),
  ],
  'openai': [
    ('gpt-6-luna', 'gpt-6-luna — cheap, default'),
    ('gpt-6.1-sol', 'gpt-6.1-sol — stronger, pricier'),
    ('gpt-6-astra', 'gpt-6-astra — flagship, priciest'),
  ],
  'anthropic': [
    ('claude-sonnet-5-5', 'claude-sonnet-5-5 — default'),
    ('claude-haiku-4-5', 'claude-haiku-4-5 — fastest, cheapest'),
    ('claude-opus-5-5', 'claude-opus-5-5 — strongest, priciest'),
  ],
  'xai': [
    ('grok-4.7', 'grok-4.7 — default'),
    ('grok-4.6', 'grok-4.6 — previous release'),
  ],
  // OpenRouter: `~…-latest` aliases follow each vendor's newest model, so
  // this list does not go stale the way pinned IDs do.
  'openrouter': [
    ('~google/gemini-flash-latest', 'Gemini Flash (latest) — default'),
    ('~openai/gpt-luna-latest', 'GPT Luna (latest) — cheap'),
    ('~anthropic/claude-sonnet-latest', 'Claude Sonnet (latest)'),
    ('~x-ai/grok-latest', 'Grok (latest)'),
    ('~deepseek/deepseek-flash-latest', 'DeepSeek Flash (latest) — cheapest'),
    ('~z-ai/glm-flash-latest', 'GLM Flash (latest)'),
    ('qwen/qwen3.8-flash', 'Qwen 3.8 Flash'),
    ('~moonshotai/kimi-latest', 'Kimi (latest)'),
    ('meta-llama/llama-4-maverick', 'Llama 4 Maverick'),
    ('mistralai/mistral-small-2603', 'Mistral Small'),
    ('google/gemma-4-31b-it:free', 'Gemma 4 31B — FREE 免费'),
  ],
  // Only deepseek-flash accepts photos; deepseek-v4-pro is text-only.
  'deepseek': [
    ('deepseek-flash', 'deepseek-flash — V4.1, default'),
  ],
  'qwen': [
    ('qwen3-vl-flash', 'qwen3-vl-flash — cheapest, default'),
    ('qwen3-vl-plus', 'qwen3-vl-plus — stronger, paid'),
    ('qwen-vl-max', 'qwen-vl-max — legacy flagship'),
  ],
  'doubao': [
    ('doubao-seed-2-0-mini-260428', 'seed-2.0 mini — cheapest, default'),
    ('doubao-seed-2-0-lite-260428', 'seed-2.0 lite — mid tier'),
    ('doubao-seed-2-1-turbo-260628', 'seed-2.1 turbo — stronger'),
    ('doubao-seed-2-1-pro-260628', 'seed-2.1 pro — strongest'),
  ],
  'glm': [
    ('glm-4.6v-flash', 'glm-4.6v-flash — FREE 免费, default'),
    ('glm-4.6v', 'glm-4.6v — stronger, paid'),
    ('glm-5v-turbo', 'glm-5v-turbo — newest flagship'),
  ],
};

/// The provider's default model as the UI names it: the FIRST curated
/// entry. Pinned equal to the AppSettings defaults by a test, so the
/// screens stay free of module imports and the two cannot drift.
String defaultModelFor(String provider) =>
    (kKnownModels[provider] ?? kKnownModels['gemini']!).first.$1;

bool isCuratedModel(String provider, String model) =>
    (kKnownModels[provider] ?? const []).any((m) => m.$1 == model);

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

/// The two CONNECTION TYPES: an API key is pay-per-photo with the key on
/// this phone; an Agent/Coding plan is a flat-rate subscription the
/// user's own server signs into. The note carries the one deciding fact.
/// The third element is a NOTE TAG resolved by [noteLabel] — the row value
/// is localized (the hardcoded English/hybrid notes ellipsised in the
/// Chinese UI, loop find 2026-10-07).
/// The mainland names carry the CJK brand but NOT the vendor prefix
/// (same names as [providerLabel]): 'Alibaba Qwen 通义千问' and friends
/// were 180–191 px beside a ~117 px English note and ellipsised in the
/// English UI at the default text size (loop find 2026-10-07, round 3);
/// the key footer still names the vendor console. Pinned at 375/390 pt
/// with the iPhone's own font by test/ui/row_fit_layout_test.dart.
const List<(String, String, String)> kApiKeyChoices = [
  ('gemini', 'Google Gemini', 'freeVpn'),
  ('openai', 'OpenAI', 'vpn'),
  ('anthropic', 'Anthropic Claude', 'vpn'),
  ('xai', 'xAI Grok', 'vpn'),
  ('openrouter', 'OpenRouter', 'many'),
  ('deepseek', 'DeepSeek 深度求索', 'direct'),
  ('qwen', 'Qwen 通义千问', 'direct'),
  ('doubao', 'Doubao 豆包', 'direct'),
  ('glm', 'GLM 智谱', 'freeDirect'),
];

/// Localized text for a [kApiKeyChoices] / [kPlanChoices] note tag.
String noteLabel(AppLocalizations l, String tag) => switch (tag) {
      'vpn' => l.noteVpn,
      'freeVpn' => l.noteFreeTierVpn,
      'direct' => l.noteDirect,
      'freeDirect' => l.noteFreeDirect,
      'many' => l.noteManyModels,
      'claude' => l.planClaudeNote,
      'glm' => l.planGlmNote,
      'doubao' => l.planDoubaoNote,
      _ => tag,
    };

/// (backend id, name, note) — all three ride the user's server. Notes
/// name the VENDOR, never a price: plan pricing changes under vendors'
/// feet and a stale number reads as unprofessional (user, 2026-08-05).
/// In English the note is the bare vendor name: 'Volcengine subscription'
/// beside 'Doubao Agent Plan' cut BOTH to fragments (loop find
/// 2026-10-07, round 3).
const List<(String, String, String)> kPlanChoices = [
  ('claude', 'Claude Plan', 'claude'),
  ('glm', 'GLM Coding Plan', 'glm'),
  ('doubao', 'Doubao Agent Plan', 'doubao'),
];

/// Row-value display: the concrete plan name, never an opaque 'My server'.
/// Short ('Doubao Plan', not 'Doubao Agent Plan'): beside the check and
/// chevron of the AI provider page's Subscription row the full names cut
/// the TITLE to 'Subscri…' in English at 375/390 pt (loop find
/// 2026-10-08); the picker one tap further keeps the full names. Pinned
/// with the iPhone's own font by test/ui/row_fit_layout_test.dart.
String providerDisplayLabel(String provider, String serverBackend) =>
    provider == 'server'
        ? switch (serverBackend) {
            'glm' => 'GLM Plan',
            'doubao' => 'Doubao Plan',
            _ => 'Claude Plan',
          }
        : providerLabel(provider);

class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage({
    super.key,
    required this.settings,
    required this.analyzer,
    this.startClaudeAuth,
    this.completeClaudeAuth,
    this.serverLoginState,
    this.openUrl,
  });

  final SettingsStore settings;
  final AnalyzerService analyzer;
  final Future<({String? url, String? error})> Function()? startClaudeAuth;
  final Future<String?> Function(String code)? completeClaudeAuth;
  final Future<String?> Function()? serverLoginState;
  final Future<bool> Function(Uri url)? openUrl;

  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = widget.settings;
    final planActive = settings.provider == 'server';
    return GroupedPage(
      title: context.l10n.providerPageTitle,
      children: [
        if (settings.isQuotaPaused)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Card(
              key: const Key('quotaPauseBanner'),
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                // Its own key, not settingsAiFooterPaused: that one points
                // the reader AT this page.
                child: Text(
                  settings.quotaPauseUntil != null
                      ? context.l10n.providerQuotaPausedUntil(
                          TimeOfDay.fromDateTime(
                                  settings.quotaPauseUntil!.toLocal())
                              .format(context))
                      : context.l10n.providerQuotaPaused,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
              ),
            ),
          ),
        GroupedSection(
          header: context.l10n.connectionTypeHeader,
          footer: context.l10n.connectionTypeFooter,
          children: [
            GroupedRow(
              key: const Key('apiKeyTypeRow'),
              icon: Icons.vpn_key_outlined,
              iconColor: scheme.primary,
              title: context.l10n.typeApiKey,
              value: planActive
                  ? null
                  : providerLabel(settings.provider),
              trailing: planActive
                  ? null
                  : Icon(Icons.check, size: 20, color: scheme.primary),
              showChevron: true,
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      ApiKeyProviderPage(settings: settings),
                ));
                if (mounted) setState(() {});
              },
            ),
            GroupedRow(
              key: const Key('subscriptionTypeRow'),
              icon: Icons.workspace_premium_outlined,
              iconColor: scheme.tertiary,
              title: context.l10n.typeSubscription,
              value: planActive
                  ? providerDisplayLabel('server', settings.serverBackend)
                  : null,
              trailing: planActive
                  ? Icon(Icons.check, size: 20, color: scheme.primary)
                  : null,
              showChevron: true,
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SubscriptionProviderPage(
                    settings: settings,
                    startClaudeAuth: widget.startClaudeAuth,
                    completeClaudeAuth: widget.completeClaudeAuth,
                    serverLoginState: widget.serverLoginState,
                    openUrl: widget.openUrl,
                  ),
                ));
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        GroupedSection(
          footer: context.l10n.testProviderFooter,
          children: [
            GroupedRow(
              key: const Key('testProviderButton'),
              icon: Icons.verified_outlined,
              iconColor: scheme.primary,
              title: context.l10n.testProvider,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DiagnosticsScreen(
                  diagnostics: ProviderDiagnostics(
                    settings: settings,
                    analyzer: widget.analyzer,
                    l10n: context.l10n,
                  ),
                ),
              )),
            ),
          ],
        ),
      ],
    );
  }
}
