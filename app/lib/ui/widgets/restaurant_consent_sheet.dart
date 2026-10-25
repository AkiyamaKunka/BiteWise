/// The restaurant assist's consent sheet and its Off dialog (design R7a,
/// decisions "Consent" and "Chain-first data minimization"; App Review
/// 5.1.1, 5.1.2(i)).
///
/// The sheet names the recipient chain — the user's own server (Claude web
/// search), Anthropic, or OpenRouter and Exa — and says exactly what leaves
/// the phone: on iPhone, the photo's location goes only to Apple Maps on
/// the phone; the recipient gets the name of a chain from BiteWise's own
/// table and the food names and amounts, never the photo, its location,
/// the city, the street or the distance. On Claude Plan it also says the
/// https rule and that lookups there are suggestions only (amendment to
/// decision 13: the server's search text is not verbatim page text).
///
/// It is shown when the mode is first turned on, when the recipient
/// changes (the assist is paused until it is answered), and before a
/// manual lookup without consent. A recipient BiteWise has no copy for can
/// never be consented to: its lookups stay off.
library;

import 'package:flutter/material.dart';

import '../../services/assist/clients/lookup_client.dart'
    show LookupRecipient, LookupSupport;
import '../../services/assist/meal_assist.dart'
    show AssistMode, AssistSettingsView;
import '../l10n.dart';
import '../restaurant_assist_controls.dart';
import '../services.dart' show SettingsStore;

/// Why the sheet is shown: its buttons differ only for a manual lookup
/// (Cancel instead of Not now).
enum RestaurantConsentKind { enable, recipientChanged, manual }

/// The user's answer. Not now / Cancel / a dismissed sheet is null.
enum RestaurantConsentChoice { useLocation, brandOnly }

/// The recipient's wording, or null when BiteWise has none for it (an
/// unsupported provider, or one built but not yet signed off): such a
/// recipient can never be consented to.
({String name, String footnote})? restaurantRecipientCopy(
        AppLocalizations l, LookupRecipient recipient) =>
    switch (recipient) {
      LookupRecipient.claudePlan => (
          name: l.restaurantRecipientNameClaudePlan,
          footnote: l.restaurantRecipientClaudePlan,
        ),
      LookupRecipient.anthropic => (
          name: l.restaurantRecipientNameAnthropic,
          footnote: l.restaurantRecipientAnthropic,
        ),
      LookupRecipient.openrouter => (
          name: l.restaurantRecipientNameOpenrouter,
          footnote: l.restaurantRecipientOpenrouter,
        ),
      LookupRecipient.openai || LookupRecipient.xai || LookupRecipient.none =>
        null,
    };

/// The settings' consent names exactly the recipient a lookup would reach
/// now — the assist's own rule (AssistSettingsView.consentCovers).
bool restaurantConsentCovers(SettingsStore settings, LookupSupport support) =>
    AssistSettingsView(
      mode: AssistMode.fromWire(settings.restaurantAssist),
      consentAt: settings.restaurantAssistConsentAt,
      consentRecipient: settings.restaurantAssistConsentRecipient,
    ).consentCovers(support);

/// The bullets, in order, for [support] on this phone. Exposed for tests.
List<String> restaurantConsentBullets(
  AppLocalizations l, {
  required LookupSupport support,
  required bool locationSupported,
}) {
  final copy = restaurantRecipientCopy(l, support.recipient);
  if (copy == null) return const [];
  final ownServer = support.recipient == LookupRecipient.claudePlan;
  return [
    l.restaurantConsentWhat,
    if (locationSupported) ...[
      l.restaurantConsentMaps,
      l.restaurantConsentSent(copy.name),
      l.restaurantConsentBrandOnly,
      if (ownServer) l.restaurantConsentHttps,
    ] else
      l.restaurantConsentSentAndroid(copy.name),
    ownServer ? l.restaurantConsentSuggestOnly : l.restaurantConsentApply,
    l.restaurantConsentOff,
  ];
}

class RestaurantConsentSheet extends StatelessWidget {
  const RestaurantConsentSheet({
    super.key,
    required this.kind,
    required this.support,
    required this.locationSupported,
  });

  final RestaurantConsentKind kind;
  final LookupSupport support;
  final bool locationSupported;

  /// 'Use location' is offered only where a location can be used: iOS,
  /// and a recipient that may receive location-derived chains (not an
  /// http:// own server).
  bool get locationOffered => locationSupported && support.locationAllowed;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final bullets = restaurantConsentBullets(l,
        support: support, locationSupported: locationSupported);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.restaurantConsentTitle,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final b in bullets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('•  ', style: theme.textTheme.bodyMedium),
                            Expanded(
                                child: Text(b,
                                    style: theme.textTheme.bodyMedium)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('restaurantConsentUseLocation'),
              onPressed: locationOffered
                  ? () => Navigator.pop(
                      context, RestaurantConsentChoice.useLocation)
                  : null,
              child: Text(l.restaurantConsentUseLocation),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              key: const Key('restaurantConsentBrandOnly'),
              onPressed: () =>
                  Navigator.pop(context, RestaurantConsentChoice.brandOnly),
              child: Text(l.restaurantConsentBrandOnlyButton),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('restaurantConsentDecline'),
              onPressed: () => Navigator.pop(context),
              child: Text(kind == RestaurantConsentKind.manual
                  ? l.cancel
                  : l.restaurantConsentNotNow),
            ),
          ],
        ),
      ),
    );
  }
}

bool _sheetOpen = false;

/// Tests: forget a sheet a torn-down tree never answered.
@visibleForTesting
void debugResetRestaurantConsentSheet() => _sheetOpen = false;

/// Shows the sheet for [support]; null for Not now / Cancel, a dismissed
/// sheet, a recipient without copy, or while another consent sheet is up.
Future<RestaurantConsentChoice?> showRestaurantConsentSheet(
  BuildContext context, {
  required RestaurantConsentKind kind,
  required LookupSupport support,
  required bool locationSupported,
}) async {
  if (_sheetOpen || !support.supported) return null;
  if (restaurantRecipientCopy(context.l10n, support.recipient) == null) {
    return null;
  }
  _sheetOpen = true;
  try {
    return await showModalBottomSheet<RestaurantConsentChoice>(
      context: context,
      isScrollControlled: true,
      // A tall sheet (long bullets, large text) stops below the status bar
      // instead of putting its title under it.
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => RestaurantConsentSheet(
        key: const Key('restaurantConsentSheet'),
        kind: kind,
        support: support,
        locationSupported: locationSupported,
      ),
    );
  } finally {
    _sheetOpen = false;
  }
}

/// Asks for the restaurant assist's consent and, on an answer, stamps it
/// with the CURRENT recipient (re-read after the sheet: a recipient that
/// changed meanwhile is not the one the user agreed to, so nothing is
/// stamped). [mode] is written with it (the first enable); for
/// [RestaurantConsentKind.manual] the 'Use photo location' setting is left
/// alone — the answer is for that one lookup — otherwise it follows the
/// answer. Returns the answer, or null.
Future<RestaurantConsentChoice?> askRestaurantConsent(
  BuildContext context, {
  required SettingsStore settings,
  required RestaurantAssistControls controls,
  required RestaurantConsentKind kind,
  String? mode,
}) async {
  final support = controls.lookupSupport();
  final choice = await showRestaurantConsentSheet(context,
      kind: kind,
      support: support,
      locationSupported: controls.locationSupported);
  if (choice == null) return null;
  final now = controls.lookupSupport();
  if (!now.supported || now.recipientStamp != support.recipientStamp) {
    return null;
  }
  await settings.updateRestaurantAssist(
    mode: mode,
    location: kind == RestaurantConsentKind.manual
        ? null
        : choice == RestaurantConsentChoice.useLocation,
    consentAt: controls.now(),
    consentRecipient: support.recipientStamp,
  );
  return choice;
}

/// The editor's 'Look up restaurant nutrition' (R7b): whether that lookup
/// may use the photo's location, asking first when the consent does not
/// name the current recipient (Use location / Brand only / Cancel). Null:
/// no lookup (cancelled, or a recipient that cannot be consented to).
Future<({bool useLocation})?> restaurantManualLookupChoice(
  BuildContext context, {
  required SettingsStore settings,
  required RestaurantAssistControls controls,
}) async {
  final support = controls.lookupSupport();
  if (!support.supported) return null;
  if (restaurantConsentCovers(settings, support)) {
    return (
      useLocation: controls.locationSupported &&
          support.locationAllowed &&
          settings.restaurantAssistLocation,
    );
  }
  final choice = await askRestaurantConsent(context,
      settings: settings,
      controls: controls,
      kind: RestaurantConsentKind.manual);
  if (choice == null) return null;
  return (useLocation: choice == RestaurantConsentChoice.useLocation);
}

/// The Off dialog: 'Pending lookups are cancelled.' with 'Also clear
/// learned places' (offered only where places are learned at all). Null:
/// Cancel (the mode stays on).
Future<({bool clearPlaces})?> confirmRestaurantAssistOff(
  BuildContext context, {
  required bool offerClearPlaces,
}) async {
  var clear = false;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) => AlertDialog(
        key: const Key('restaurantOffDialog'),
        title: Text(ctx.l10n.restaurantOffTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ctx.l10n.restaurantOffBody),
              if (offerClearPlaces)
                CheckboxListTile(
                  key: const Key('restaurantOffClearPlaces'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: clear,
                  onChanged: (v) => setDialog(() => clear = v ?? false),
                  title: Text(ctx.l10n.restaurantOffClearPlaces),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('restaurantOffConfirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l10n.restaurantOffConfirm)),
        ],
      ),
    ),
  );
  if (go != true) return null;
  return (clearPlaces: clear);
}
