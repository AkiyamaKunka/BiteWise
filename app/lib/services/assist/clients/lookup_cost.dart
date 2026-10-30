/// Cost accounting and caps for the direct lookup clients.
///
/// Prices are the vendors' published list prices as of 2026-10 (design
/// costs section; platform.claude.com models overview and web-search tool
/// page; openrouter.ai web-search guide; xAI and OpenAI pricing pages via
/// the feature research). They feed ESTIMATES only: a provider that
/// reports its own charge (OpenRouter `usage.cost`, xAI
/// `usage.cost_in_usd_ticks`) wins over the table.
///
/// Two caps, both checked BEFORE money is spent:
///   - per lookup: before every HTTP request (the first, and each
///     pause_turn continuation) the client adds the request's WORST case to
///     what the lookup already spent; over [LookupCostPolicy.maxUsdPerLookup]
///     the request is not sent;
///   - per day: [LookupBudget] counts lookups and dollars (the app's
///     20/day cap from the design lives in an implementation of it).
///
/// The per-lookup cap is HARD where we know the model's price (Anthropic,
/// OpenAI, xAI: the worst case is computed from the price table). It is
/// ADVISORY for OpenRouter: the user picks the model, its price is unknown
/// here, and the pre-flight uses the flat
/// [LookupCostPolicy.unknownModelAllowanceUsd] for its tokens — an
/// expensive OpenRouter model can pass the cap in one call. The reply's
/// `usage.cost` then records what it really cost, so the daily ledger sees
/// the true spend afterwards.
library;

import 'lookup_client.dart';

class ModelPrice {
  const ModelPrice(this.inputPerM, this.outputPerM);
  final double inputPerM;
  final double outputPerM;

  double usd(int inputTokens, int outputTokens) =>
      inputTokens * inputPerM / 1e6 + outputTokens * outputPerM / 1e6;
}

/// Anthropic: claude-haiku-5-5 is $0.10 / $0.50 per MTok for prompts up to
/// 100K tokens and $0.50 / $2.50 above (models overview, cached
/// 2026-10-06). Web search: $10 per 1,000 searches; failed searches are
/// not billed.
const ModelPrice kHaiku55Price = ModelPrice(0.10, 0.50);
const ModelPrice kHaiku55LongPrice = ModelPrice(0.50, 2.50);
const int kHaiku55LongPromptThreshold = 100000;
const double kAnthropicSearchUsd = 10 / 1000;

/// OpenRouter web plugin pinned to Exa: $0.007 per request (up to 10
/// results included). Model tokens: the provider reports `usage.cost`.
const double kOpenRouterExaRequestUsd = 0.007;

/// OpenAI Responses web_search: $10 per 1,000 calls plus tokens. The
/// lookup model (gpt-4.1-mini) is $0.40 / $1.60 per MTok; its search
/// content is billed as input tokens.
const double kOpenAiSearchCallUsd = 10 / 1000;
const ModelPrice kGpt41MiniPrice = ModelPrice(0.40, 1.60);

/// xAI web_search: $5 per 1,000 calls; grok-4.7 $2 / $6 per MTok (<200k).
const double kXaiSearchCallUsd = 5 / 1000;
const ModelPrice kGrok47Price = ModelPrice(2.00, 6.00);

/// xAI reports cost in ticks: 1 USD = 1e10 ticks (docs.x.ai cost-tracking).
const double kXaiTicksPerUsd = 1e10;

/// Knobs for one lookup. Defaults are the design's: max_uses 2, at most 2
/// pause_turn continuations, and a 5¢ ceiling per lookup (hard for priced
/// models, advisory for the user's OpenRouter model — see the library
/// comment).
class LookupCostPolicy {
  const LookupCostPolicy({
    this.maxUsdPerLookup = 0.05,
    this.maxSearches = 2,
    this.maxContinuations = 2,
    this.maxOutputTokens = 1500,
    this.promptTokensAllowance = 4000,
    this.tokensPerSearchAllowance = 10000,
    this.unknownModelAllowanceUsd = 0.02,
  })  : assert(maxSearches >= 1, 'a lookup needs at least one search'),
        assert(maxContinuations >= 0),
        assert(maxOutputTokens > 0);

  /// The ceiling for one lookup, all HTTP calls included (advisory for
  /// OpenRouter, whose model price is unknown before the call).
  final double maxUsdPerLookup;

  /// Searches per request (Anthropic max_uses, OpenAI max_tool_calls).
  final int maxSearches;

  /// pause_turn continuations (Anthropic only).
  final int maxContinuations;
  final int maxOutputTokens;

  /// Worst-case input assumptions for the pre-flight check: the prompt —
  /// lane B's shared lookup prompt (~1.4k tokens) plus the largest request
  /// its composer emits (12 items, about 1.7k tokens when the names are
  /// CJK) — with margin, and one search's results as input.
  final int promptTokensAllowance;
  final int tokensPerSearchAllowance;

  /// Token cost allowance where we cannot know the model's price (the
  /// user's OpenRouter model). The reported `usage.cost` replaces it after
  /// the call.
  final double unknownModelAllowanceUsd;
}

/// The daily ledger the clients consult before each lookup and report to
/// after it. Implementations persist it (R6b: `assist.daily.v1`).
abstract class LookupBudget {
  /// Whether one more lookup whose worst case is [worstCaseUsd] may start
  /// now. A true answer COUNTS the lookup (abandoned calls still cost).
  bool tryStartLookup(double worstCaseUsd);

  /// What the lookup actually cost (also called for failed lookups).
  void recordSpend(LookupCost cost);
}

/// No daily limit (tests, or a caller that enforces its own).
class UnlimitedLookupBudget implements LookupBudget {
  const UnlimitedLookupBudget();
  @override
  bool tryStartLookup(double worstCaseUsd) => true;
  @override
  void recordSpend(LookupCost cost) {}
}

/// An in-memory day ledger: at most [maxLookupsPerDay] lookups and
/// [maxUsdPerDay] dollars per local calendar day. A lookup is refused when
/// what was spent today plus its worst case would pass the dollar cap.
class DailyLookupBudget implements LookupBudget {
  DailyLookupBudget({
    this.maxLookupsPerDay = 20,
    this.maxUsdPerDay = 0.50,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxLookupsPerDay;
  final double maxUsdPerDay;
  final DateTime Function() _clock;

  String _day = '';
  int _count = 0;
  double _usd = 0;

  int get lookupsToday {
    _rollover();
    return _count;
  }

  double get usdToday {
    _rollover();
    return _usd;
  }

  void _rollover() {
    final now = _clock();
    final day = '${now.year}-${now.month}-${now.day}';
    if (day != _day) {
      _day = day;
      _count = 0;
      _usd = 0;
    }
  }

  @override
  bool tryStartLookup(double worstCaseUsd) {
    _rollover();
    if (_count >= maxLookupsPerDay) return false;
    if (_usd + worstCaseUsd > maxUsdPerDay + 1e-12) return false;
    _count++;
    return true;
  }

  @override
  void recordSpend(LookupCost cost) {
    _rollover();
    _usd += cost.usd;
  }
}

/// Anthropic token price for one request: the long-context rate applies
/// when the prompt passes 100K tokens.
double haikuUsd(int inputTokens, int outputTokens) =>
    (inputTokens > kHaiku55LongPromptThreshold ? kHaiku55LongPrice : kHaiku55Price)
        .usd(inputTokens, outputTokens);
