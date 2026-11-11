/// The restaurant assist's consent sheet and its Off dialog (design R7a,
/// decisions "Consent" and "Chain-first data minimization"; App Review
/// 5.1.1, 5.1.2(i)).
///
/// The sheet names the recipient chain — the user's own server (Claude web
/// search), Anthropic, or OpenRouter, the maker of the model picked in
/// Settings (OpenRouter passes the lookup on to it) and Exa — and says
/// exactly what leaves the phone: on iPhone, the photo's location goes
/// only to Apple Maps on the phone; the recipient gets the name of a chain from the app's own
/// table and the food names and amounts, never the photo, its location,
/// the city, the street or the distance. On Claude Plan it also says the
/// https rule and that lookups there are suggestions only (amendment to
/// decision 13: the server's search text is not verbatim page text).
///
/// It is shown when the mode is first turned on, when the recipient
/// changes (the assist is paused until it is answered), and before a
/// manual lookup without consent. A recipient the app has no copy for can
/// never be consented to: its lookups stay off.
///
/// Also here: what Settings' Stop Sharing does to the assist
/// ([restaurantAssistStopFor], [stopRestaurantAssistFor]). Withdrawing the
/// AI consent for a company or server turns the assist off, and forgets
/// its consent, when its lookups go to that same recipient — so the sheet
/// is shown again before the next lookup there.
library;

import 'package:flutter/material.dart';

import '../../services/assist/clients/lookup_client.dart'
    show
        LookupRecipient,
        LookupSupport,
        lookupAiConsentRoute,
        lookupRecipientOfStamp;
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

/// The recipient's wording, or null when the app has none for it (an
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
/// stamped). [mode] is written with it (the first enable).
///
/// The 'Use photo location' setting is written in the same store call as
/// the consent, so no lookup gate ever reads the new consent with the old
/// setting:
///
///   * Brand only turns it off, under every kind. The stamp is a standing
///     consent for this recipient — the editor's sheet
///     ([RestaurantConsentKind.manual]) is only reachable while the mode is
///     on and the consent names someone else, so its answer un-pauses the
///     automatic lookups too — and the only answer the user gave about this
///     recipient is "skip the location". Left on from the recipient before,
///     the next sweep would read a photo's position, ask Apple Maps and send
///     the chain found there.
///   * Use location turns it on, except for the manual kind, where it is
///     left as it was: that answer is used for the one lookup the editor
///     starts, and never widens what the automatic lookups read.
///
/// Returns the answer, or null.
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
    location: choice == RestaurantConsentChoice.brandOnly
        ? false
        : kind == RestaurantConsentKind.manual
            ? null
            : true,
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

/// The Off dialog: 'Pending lookups are cancelled.' with a box, unticked,
/// to clear what the lookups kept on this phone at the same time:
/// 'Also clear learned places and saved lookup answers' where places are
/// learned ([placesKept], iOS: the places, the saved lookup answers and the
/// waiting lookups), else
/// 'Also clear saved lookup answers' (Android: no places are kept). Either
/// way, the answer's clearPlaces asks for that one clear
/// (RestaurantAssistControls.clearLearnedPlaces).
/// Without the box the saved answers stay, as the policy says. Null:
/// Cancel (the mode stays on).
Future<({bool clearPlaces})?> confirmRestaurantAssistOff(
  BuildContext context, {
  required bool offerClearPlaces,
  required bool placesKept,
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
                  key: Key(
                    placesKept
                        ? 'restaurantOffClearPlaces'
                        : 'restaurantOffClearAnswers',
                  ),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: clear,
                  onChanged: (v) => setDialog(() => clear = v ?? false),
                  title: Text(
                    placesKept
                        ? ctx.l10n.restaurantOffClearPlaces
                        : ctx.l10n.restaurantOffClearAnswers,
                  ),
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

/// What Settings' Stop Sharing does to the restaurant assist
/// ([restaurantAssistStopFor]): turn its mode Off, forget its consent, both
/// or neither.
typedef RestaurantAssistStop = ({bool turnOff, bool forgetConsent});

/// What Settings › Stop Sharing with … must do to the restaurant assist
/// when it withdraws the AI consent for [route] (core/ai_consent.dart
/// aiConsentRoute). That row says "nothing more is sent to …", and no
/// lookup reads the AI consent — the assist has its own, per recipient —
/// so the assist stops with it when its lookups go to that same company or
/// server (docs/RELEASING.md). Pure: read from the settings as they are.
///
///   * on: the mode is not Off;
///   * named: the assist's consent names a recipient of [route] (the wire
///     id of its stamp; for the own server, any host of that plan — the AI
///     consent is per plan);
///   * reaches: on, and a lookup now would go to [route] — or that cannot
///     be told (no [controls], or `lookupSupport` throws): fail closed.
///
/// `turnOff` = on and (reaches or named); `forgetConsent` = named:
///
///   1. on, reaches, the consent names [route]           → Off, forgotten
///   2. on, reaches, it names another host of the plan   → Off, forgotten
///   3. on, reaches, it names another route, or none     → Off, kept (the
///      assist was only paused for this recipient; left on, the app shell
///      would ask to consent to the recipient just stopped)
///   4. on, no lookup possible now, it names [route]     → Off, forgotten
///   5. on, does not reach, another route or none        → untouched
///   6. on, cannot be told                               → Off (forgotten
///      when it names [route])
///   7. off, it names [route]                            → forgotten
///   8. off, another route or none                       → untouched
///
/// Afterwards no consent covers a recipient of [route]: turning lookups
/// back on for it shows the consent sheet again, and allowing AI analysis
/// again never turns them back on. 'Use photo location', the learned
/// places, the answer cache, the decision log and the assist blocks on
/// meals are kept: nothing is sent by keeping them.
RestaurantAssistStop restaurantAssistStopFor(SettingsStore settings,
    RestaurantAssistControls? controls, String route) {
  final on = settings.restaurantAssist != 'off';
  final named =
      lookupRecipientOfStamp(settings.restaurantAssistConsentRecipient);
  final forget = named != null && lookupAiConsentRoute(named) == route;
  var reaches = false;
  if (on) {
    try {
      final support = controls?.lookupSupport();
      reaches = support == null ||
          (support.supported &&
              lookupAiConsentRoute(support.recipient) == route);
    } catch (_) {
      reaches = true;
    }
  }
  return (turnOff: on && (reaches || forget), forgetConsent: forget);
}

/// Carries out [restaurantAssistStopFor] for [route] and returns what it
/// did: ONE settings write — the mode row's own Off, with `clearConsent`
/// when the consent names [route] — or no write at all when the assist has
/// nothing to do with [route]. MealAssist hears that one notification and,
/// when the mode was on, cancels the call in flight, drops its pending jobs
/// and retries and withdraws its consent prompt.
///
/// The write is started before this function's first await, and the store
/// flips the mode and the consent in memory before ITS first await
/// (AppSettings.setRestaurantAssist). So from the moment this is called —
/// before anything is saved, before the notification — every lookup gate,
/// and the engine's own check at the send (MealAssist._maySend), reads Off
/// and the consent as forgotten. Stop Sharing calls it FIRST and withdraws
/// the AI consent after it: nothing but the assist's own mode and consent
/// stops a lookup, and the Stop Sharing row (shown only while the AI
/// consent stands) stays for a retry when this throws.
///
/// Known and accepted (remote: it takes a failing preferences write): when
/// the store throws after that in-memory flip, Stop Sharing ends there
/// with the AI consent still given; a retry in the same session finds the
/// assist already Off in memory, writes nothing here and withdraws the AI
/// consent, and after a restart the mode and the consent are back as they
/// were last saved. Also known and accepted: a direct Anthropic lookup
/// already in flight may still send one continuation of the request it
/// started (a paused turn) between that flip and the notification, which
/// cancels its token (up to three preference writes later, a few
/// milliseconds by estimate).
Future<RestaurantAssistStop> stopRestaurantAssistFor(SettingsStore settings,
    RestaurantAssistControls? controls, String route) async {
  final plan = restaurantAssistStopFor(settings, controls, route);
  if (plan.turnOff || plan.forgetConsent) {
    await settings.updateRestaurantAssist(
        mode: 'off', clearConsent: plan.forgetConsent);
  }
  return plan;
}
