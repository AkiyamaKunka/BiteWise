/// What a meal's restaurant-assist block shows (design R7b): the meal
/// card's chip and the editor's source card both read it from here.
///
/// The block is read as untrusted (an imported meal can carry anything):
/// every text is cleaned again and capped, every number re-checked, and
/// the source address is shown and launched only in its normalized https,
/// ASCII form (restaurant_assist_logic.dart normalizeSourceUrl) — a
/// `javascript:`, `http:` or IDN address is never a link. What is shown:
/// the chain's name from BiteWise's own table (the Chinese name in the
/// Chinese UI), the menu items, options, servings and published numbers
/// the lookup returned, the source host, who looked it up and when, and
/// the notes as plain text. Nothing from Apple Maps exists in a block to
/// show (design "Chain-first data minimization", Apple's developer
/// license Attachment 6), and a context-only block names no restaurant.
library;

import '../core/chain_match.dart' show chainByKey, isChainHost;
import '../core/coerce.dart' show coerceQty;
import '../core/restaurant_assist_logic.dart';
import '../core/restaurant_lookup_contract.dart' show kLookupMaxItems;
import '../l10n/app_localizations.dart';
import 'format.dart' show formatKcal;
import 'outcome_text.dart' show assistBrandLabel;
import 'provider_names.dart' show providerLabel;

/// What the block on a meal amounts to for the screen.
enum AssistViewKind {
  /// No assist block (or one of another version).
  none,

  /// Published numbers stand on the meal, exactly as applied.
  applied,

  /// Published numbers were applied, but the meal changed since: no chip,
  /// no revert.
  appliedStale,

  /// A one-tap suggestion the meal can still take.
  suggested,

  /// A suggestion made for numbers the meal no longer has.
  suggestedStale,

  /// A lookup that found nothing usable (context_only, not_published,
  /// no_match): "No published nutrition found — AI estimate kept".
  contextOnly,

  /// A finished record with nothing to show (unavailable, declined,
  /// reverted, superseded).
  other,
}

/// One covered item as the source card lists it.
final class AssistItemView {
  const AssistItemView({
    required this.menuItem,
    required this.option,
    required this.serving,
    required this.qty,
    this.calories,
    this.caloriesRange,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.sizes = const [],
  });

  final String menuItem;
  final String option;
  final String serving;

  /// Servings the photo shows (×qty on the line when it is not 1).
  final num qty;

  /// One serving as published; null for a range.
  final int? calories;
  final List<int>? caloriesRange;
  final num? proteinG;
  final num? carbsG;
  final num? fatG;

  /// Every size the chain publishes for it, as a suggestion stores them
  /// (only when there is more than one), so the user sees which one the
  /// photo was matched to and what the others are.
  final List<AssistSize> sizes;
}

/// Suggestion reasons whose published numbers may not fit what was eaten
/// — a shared or partly eaten plate, a combo, an unclear size or unit:
/// 'Use published numbers' asks first, with the meal's new total.
const Set<String> assistConfirmReasons = {
  AssistReason.portionNotWhole,
  AssistReason.combo,
  AssistReason.sizeAmbiguous,
  AssistReason.unitMismatch,
};

final RegExp _isoDateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final RegExp _providerRe = RegExp(r'^[a-z0-9_]{1,20}$');
final RegExp _reasonRe = RegExp(r'^[a-z0-9_]{1,40}$');

/// A block's published sizes, read as untrusted.
List<AssistSize> _sizes(Object? raw) {
  final out = <AssistSize>[];
  for (final z in (raw is List ? raw : const []).take(kAssistMaxOptions)) {
    if (z is! Map) continue;
    final range = z['calories_range'];
    List<int>? caloriesRange;
    if (range is List && range.length == 2) {
      final lo = _kcal(range[0]);
      final hi = _kcal(range[1]);
      if (lo != null && hi != null && lo <= hi) caloriesRange = [lo, hi];
    }
    final calories = _kcal(z['calories']);
    if (calories == null && caloriesRange == null) continue;
    out.add(
      AssistSize(
        label: sanitizeAssistText(z['label'], kAssistOptionLabelMax),
        serving: sanitizeAssistText(z['serving'], kAssistServingMax),
        calories: calories,
        caloriesRange: caloriesRange,
      ),
    );
  }
  return out.length > 1 ? List.unmodifiable(out) : const [];
}

int? _kcal(Object? v) {
  if (v is bool || v is! num || !v.isFinite) return null;
  if (v < 0 || v > kAssistMaxPublishedKcal || v != v.roundToDouble()) {
    return null;
  }
  return v.toInt();
}

num? _grams(Object? v) {
  if (v is bool || v is! num || !v.isFinite) return null;
  if (v < 0 || v > kAssistMaxPublishedGrams) return null;
  return v;
}

final class AssistView {
  const AssistView._({
    required this.kind,
    this.chainKey,
    this.brandName = '',
    this.items = const [],
    this.sourceUrl,
    this.sourceHost,
    this.sourceOfficial = false,
    this.provider = '',
    this.decidedOn = '',
    this.grounded = false,
    this.notes = '',
    this.evidence,
    this.reason = '',
  });

  static const AssistView none = AssistView._(kind: AssistViewKind.none);

  final AssistViewKind kind;

  /// A key of BiteWise's chain table, or null.
  final String? chainKey;

  /// The chain's canonical name from the table, else the block's cleaned
  /// brand name.
  final String brandName;
  final List<AssistItemView> items;

  /// The normalized https URL to open, or null (never a link then).
  final String? sourceUrl;
  final String? sourceHost;

  /// The source is on the chain's own website (a table domain).
  final bool sourceOfficial;

  /// claude_plan | anthropic | openrouter, or ''.
  final String provider;

  /// YYYY-MM-DD, or ''.
  final String decidedOn;

  /// Every covered figure was found in text taken from the source page.
  final bool grounded;

  /// The lookup's notes, cleaned, at most 200 characters: plain text.
  final String notes;

  /// How the meal was tied to the chain (data_contracts §3 evidence).
  final AssistEvidenceKind? evidence;

  /// Why the block is what it is: for a suggestion, the first rule that
  /// kept the numbers from being used by themselves (AssistReason), or ''.
  final String reason;

  /// The place step named the chain at the photo's spot (evidence location
  /// or location_confirmed): only then can 'Correct' teach the spot.
  bool get namedByPlace =>
      evidence == AssistEvidenceKind.location ||
      evidence == AssistEvidenceKind.locationConfirmed;

  /// 'Use published numbers' asks first ([assistConfirmReasons]).
  bool get acceptNeedsConfirm =>
      kind == AssistViewKind.suggested && assistConfirmReasons.contains(reason);

  /// The meal card shows a chip (design R7b: only while the stamps still
  /// hold).
  bool get showsChip =>
      kind == AssistViewKind.applied || kind == AssistViewKind.suggested;

  /// A block that names a chain and its numbers (applied or suggested,
  /// current or stale).
  bool get hasSource =>
      kind == AssistViewKind.applied ||
      kind == AssistViewKind.appliedStale ||
      kind == AssistViewKind.suggested ||
      kind == AssistViewKind.suggestedStale;

  /// [analysis]'s assist block as the screen shows it. Never throws.
  static AssistView of(dynamic analysis) {
    try {
      return _of(analysis);
    } catch (_) {
      return none;
    }
  }

  static AssistView _of(dynamic analysis) {
    if (analysis is! Map) return none;
    final block = analysis['assist'];
    if (block is! Map || block['v'] != kAssistVersion) return none;
    final status = block['status'];
    final kind = switch (status) {
      AssistStatus.applied =>
        assistStampValid(analysis)
            ? AssistViewKind.applied
            : AssistViewKind.appliedStale,
      AssistStatus.suggested =>
        assistStampValid(analysis)
            ? AssistViewKind.suggested
            : AssistViewKind.suggestedStale,
      AssistStatus.contextOnly ||
      AssistStatus.notPublished ||
      AssistStatus.noMatch => AssistViewKind.contextOnly,
      _ => AssistViewKind.other,
    };
    if (kind == AssistViewKind.contextOnly || kind == AssistViewKind.other) {
      // A context-only record names no restaurant, so neither does this.
      return AssistView._(kind: kind);
    }
    final key = block['chain_key'];
    final chain = key is String ? chainByKey(key) : null;
    final brand = chain != null
        ? sanitizeAssistText(chain.name, kAssistBrandNameMax)
        : sanitizeAssistText(block['brand_name'], kAssistBrandNameMax);
    final items = <AssistItemView>[];
    final matches = block['matches'];
    for (final m in (matches is List ? matches : const []).take(
      kLookupMaxItems,
    )) {
      if (m is! Map) continue;
      final pub = m['published'];
      final p = pub is Map ? pub : const {};
      final range = m['calories_range'];
      List<int>? caloriesRange;
      if (range is List && range.length == 2) {
        final lo = _kcal(range[0]);
        final hi = _kcal(range[1]);
        if (lo != null && hi != null && lo <= hi) caloriesRange = [lo, hi];
      }
      items.add(
        AssistItemView(
          menuItem: sanitizeAssistText(m['menu_item'], kAssistMenuItemMax),
          option: sanitizeAssistText(m['option_label'], kAssistOptionLabelMax),
          serving: sanitizeAssistText(m['serving'], kAssistServingMax),
          qty: coerceQty(m['qty']),
          calories: _kcal(p['calories']),
          caloriesRange: caloriesRange,
          proteinG: _grams(p['protein_g']),
          carbsG: _grams(p['carbs_g']),
          fatG: _grams(p['fat_g']),
          sizes: _sizes(m['sizes']),
        ),
      );
    }
    final source = block['source'];
    final url = normalizeSourceUrl(source is Map ? source['url'] : null);
    final host = url?.substring(8).split('/').first;
    final provider = block['provider'];
    final decided = block['decided_on'];
    final notes = block['notes'];
    final reason = block['reason'];
    return AssistView._(
      kind: kind,
      chainKey: chain?.key,
      brandName: brand,
      items: List.unmodifiable(items),
      sourceUrl: url,
      sourceHost: host,
      sourceOfficial:
          host != null &&
          source is Map &&
          source['type'] == 'official' &&
          isChainHost(host, chain?.key),
      provider: provider is String && _providerRe.hasMatch(provider)
          ? provider
          : '',
      decidedOn: decided is String && _isoDateRe.hasMatch(decided)
          ? decided
          : '',
      grounded: block['grounded'] == true,
      notes: sanitizeAssistText(notes, kAssistNotesMax),
      evidence: AssistEvidenceKind.fromWire(block['evidence']),
      reason: reason is String && _reasonRe.hasMatch(reason) ? reason : '',
    );
  }

  /// The covered items' published calories × servings: "590", or a range
  /// "540–620" when a covered item publishes one; null when none
  /// publishes a number.
  String? get publishedKcalText {
    num lo = 0, hi = 0;
    var any = false;
    for (final i in items) {
      final c = i.calories;
      final r = i.caloriesRange;
      if (c != null) {
        lo += c * i.qty;
        hi += c * i.qty;
        any = true;
      } else if (r != null) {
        lo += r[0] * i.qty;
        hi += r[1] * i.qty;
        any = true;
      }
    }
    if (!any) return null;
    final a = formatKcal(lo), b = formatKcal(hi);
    return a == b ? a : '$a–$b';
  }

  /// The chain's name in the app language: the table's Chinese name in the
  /// Chinese UI, else its canonical name.
  String brandLabel(AppLocalizations l) =>
      assistBrandLabel(l, chainKey, brandName);

  /// The meal card's chip, or null when there is none (design R7b).
  String? chipText(AppLocalizations l) {
    if (brandName.isEmpty && chainKey == null) return null;
    switch (kind) {
      case AssistViewKind.applied:
        return l.assistChipApplied(brandLabel(l), items.length);
      case AssistViewKind.suggested:
        final kcal = publishedKcalText;
        if (kcal == null) return null;
        // A shared or partly eaten plate: the number is one whole serving,
        // not something to "review" into the meal.
        return reason == AssistReason.portionNotWhole
            ? l.assistChipSuggestedWhole(brandLabel(l), kcal)
            : l.assistChipSuggested(brandLabel(l), kcal);
      default:
        return null;
    }
  }

  /// Why a suggestion was not used by itself, in a line the user can act
  /// on, or null for a reason with nothing to add (the grounding line and
  /// the source already say the rest).
  String? whyText(AppLocalizations l) {
    if (kind != AssistViewKind.suggested) return null;
    return switch (reason) {
      AssistReason.portionNotWhole => l.assistWhyPortion,
      AssistReason.sizeAmbiguous => l.assistWhySize,
      AssistReason.combo => l.assistWhyCombo,
      AssistReason.closestItem => l.assistWhyClosest,
      AssistReason.unitMismatch => l.assistWhyUnits,
      AssistReason.declinedBefore => l.assistWhyDeclined,
      _ => null,
    };
  }
}

/// [item]'s published sizes as one line ("Small 230 kcal · Medium 320
/// kcal"), or null when it lists fewer than two.
String? assistSizesText(AppLocalizations l, AssistItemView item) {
  if (item.sizes.length < 2) return null;
  final parts = <String>[];
  for (final z in item.sizes) {
    final c = z.calories;
    final r = z.caloriesRange;
    final kcal = c != null
        ? l.kcalAmount(formatKcal(c))
        : l.kcalAmount('${formatKcal(r![0])}–${formatKcal(r[1])}');
    final name = z.label.isNotEmpty ? z.label : z.serving;
    parts.add(name.isEmpty ? kcal : '$name $kcal');
  }
  return l.assistSizes(parts.join(' · '));
}

/// Who looked the numbers up, as Settings names the provider: Claude Plan
/// (the owner's server), Claude (an Anthropic key) or OpenRouter; '' for
/// anything else.
String assistProviderLabel(AppLocalizations l, String provider) =>
    switch (provider) {
      'claude_plan' => l.planShortClaude,
      'anthropic' => providerLabel('anthropic'),
      'openrouter' => providerLabel('openrouter'),
      _ => '',
    };
