/// Settings › Restaurant nutrition (design R7a): the mode (Off / When
/// unsure / Always), 'Use photo location' (iOS; disabled with a hint for
/// an http:// own server), who receives lookups, the owner's server hints
/// (outdated / lookups off / needs https), a paused row while a new
/// recipient waits for consent, and 'Clear learned places'.
///
/// Turning a mode on asks for consent first unless the consent already
/// names the current recipient (restaurant_consent_sheet.dart); turning it
/// back on stamps a fresh consent time, so meals logged while it was off
/// are never looked up. Turning it Off asks, with 'Also clear learned
/// places'; MealAssist hears the change and cancels what is in flight.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../../../services/assist/clients/lookup_client.dart'
    show LookupRecipient, LookupSupport, LookupUnsupportedReason;
import '../../l10n.dart';
import '../../provider_names.dart' show providerDisplayLabel;
import '../../restaurant_assist_controls.dart';
import '../../services.dart' show SettingsStore;
import '../../widgets/grouped.dart';
import '../../widgets/restaurant_consent_sheet.dart';

class RestaurantAssistSection extends StatefulWidget {
  const RestaurantAssistSection({
    super.key,
    required this.settings,
    required this.controls,
  });

  final SettingsStore settings;
  final RestaurantAssistControls controls;

  @override
  State<RestaurantAssistSection> createState() =>
      RestaurantAssistSectionState();
}

class RestaurantAssistSectionState extends State<RestaurantAssistSection> {
  AssistServerState _server = AssistServerState.unknown;

  /// The server address the hint was asked for ('' = none asked).
  String _serverAskedFor = '';
  int _serverAsk = 0;

  SettingsStore get _s => widget.settings;
  RestaurantAssistControls get _c => widget.controls;

  @override
  void initState() {
    super.initState();
    _maybeAskServer();
  }

  @override
  void didUpdateWidget(RestaurantAssistSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeAskServer();
  }

  /// Claude Plan on the claude backend: what the server says about
  /// lookups, once per address (asked again when the address changes).
  void _maybeAskServer() {
    final ask = _c.serverState;
    final ownServer = _s.provider == 'server' &&
        _s.serverBackend == 'claude' &&
        _s.serverBaseUrl.trim().isNotEmpty;
    final key = ownServer && ask != null ? _s.serverBaseUrl.trim() : '';
    if (key == _serverAskedFor) return;
    _serverAskedFor = key;
    final ticket = ++_serverAsk;
    // No setState: initState and didUpdateWidget are followed by a build.
    _server = AssistServerState.unknown;
    if (key.isEmpty) return;
    unawaited(() async {
      AssistServerState state;
      try {
        state = await ask!();
      } catch (_) {
        state = AssistServerState.unknown;
      }
      if (!mounted || ticket != _serverAsk) return;
      setState(() => _server = state);
    }());
  }

  LookupSupport _support() {
    try {
      return _c.lookupSupport();
    } catch (_) {
      return const LookupSupport.unsupported('error');
    }
  }

  String _modeLabel(AppLocalizations l, String mode) => switch (mode) {
        'auto' => l.restaurantModeAuto,
        'always' => l.restaurantModeAlways,
        _ => l.restaurantModeOff,
      };

  Future<void> _pickMode() async {
    final current = _s.restaurantAssist;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: groupedBackground(Theme.of(context).colorScheme),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(ctx.l10n.restaurantModeSheetTitle,
                    style: Theme.of(ctx)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            GroupedSection(
              separatorInset: 16,
              children: [
                for (final mode in const ['off', 'auto', 'always'])
                  GroupedRow(
                    key: Key('restaurantMode-$mode'),
                    title: _modeLabel(ctx.l10n, mode),
                    showChevron: false,
                    trailing: current == mode
                        ? Icon(Icons.check,
                            size: 20,
                            color: Theme.of(ctx).colorScheme.primary)
                        : const SizedBox(width: 20),
                    onTap: () => Navigator.pop(ctx, mode),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (picked == null || picked == current || !mounted) return;
    await setMode(picked);
  }

  /// [mode] chosen in the picker (tests drive it through the sheet).
  Future<void> setMode(String mode) async {
    final current = _s.restaurantAssist;
    if (mode == current) return;
    if (mode == 'off') {
      final answer = await confirmRestaurantAssistOff(context,
          offerClearPlaces: _c.locationSupported);
      if (answer == null || !mounted) return;
      await _s.updateRestaurantAssist(mode: 'off');
      if (answer.clearPlaces) await _clearPlaces(announce: false);
      if (mounted) setState(() {});
      return;
    }
    if (current != 'off') {
      // When unsure ↔ Always: the consent stays as it is.
      await _s.updateRestaurantAssist(mode: mode);
      if (mounted) setState(() {});
      return;
    }
    final support = _support();
    if (restaurantConsentCovers(_s, support)) {
      // Back on with the same recipient: a fresh consent time, so the
      // meals logged while it was off are not looked up.
      await _s.updateRestaurantAssist(mode: mode, consentAt: _c.now());
    } else {
      await askRestaurantConsent(context,
          settings: _s,
          controls: _c,
          kind: RestaurantConsentKind.enable,
          mode: mode);
    }
    if (mounted) setState(() {});
  }

  /// The paused row: the consent sheet for the current recipient.
  Future<void> _review() async {
    await askRestaurantConsent(context,
        settings: _s,
        controls: _c,
        kind: RestaurantConsentKind.recipientChanged);
    if (mounted) setState(() {});
  }

  /// After the AI provider page: when the recipient a lookup would reach
  /// changed there ([stampBefore] is the one before) and the mode is on,
  /// ask now — the assist is paused until this is answered.
  Future<void> promptIfRecipientChanged(String stampBefore) async {
    if (!mounted || _s.restaurantAssist == 'off') return;
    final support = _support();
    if (!support.supported || support.recipientStamp == stampBefore) return;
    if (restaurantConsentCovers(_s, support)) return;
    await _review();
  }

  /// The stamp of the recipient a lookup would reach now.
  String currentRecipientStamp() => _support().recipientStamp;

  Future<void> _confirmClearPlaces() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('clearPlacesDialog'),
        title: Text(ctx.l10n.clearPlacesTitle),
        content: SingleChildScrollView(child: Text(ctx.l10n.clearPlacesBody)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel)),
          FilledButton(
              key: const Key('clearPlacesConfirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l10n.clearPlacesConfirm)),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _clearPlaces(announce: true);
  }

  Future<void> _clearPlaces({required bool announce}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final done = context.l10n.clearPlacesDone;
    var ok = false;
    try {
      ok = await _c.clearLearnedPlaces();
    } catch (_) {}
    if (ok && announce) {
      messenger?.showSnackBar(SnackBar(content: Text(done)));
    }
  }

  /// The footer lines under the group, in order.
  List<String> _footer(AppLocalizations l, LookupSupport support,
      {required bool on, required bool paused}) {
    final copy = support.supported
        ? restaurantRecipientCopy(l, support.recipient)
        : null;
    final ownServer = _s.provider == 'server';
    final lines = <String>[l.restaurantModeHelper];
    if (paused) lines.add(l.restaurantPausedHint);
    if (copy == null) {
      lines.add(support.reason == LookupUnsupportedReason.noServerAddress
          ? l.restaurantNeedsServerAddress
          : l.restaurantUnsupported(
              providerDisplayLabel(l, _s.provider, _s.serverBackend)));
      return lines;
    }
    if (!_c.locationSupported) {
      if (on) lines.add(l.restaurantLocationAndroidHint);
    } else if (!support.locationAllowed) {
      lines.add(l.restaurantLocationHttpHint);
    } else if (on && !_s.restaurantAssistLocation) {
      lines.add(l.restaurantLocationOffHint);
    }
    lines.add(copy.footnote);
    if (support.recipient == LookupRecipient.claudePlan) {
      lines.add(l.restaurantSuggestOnly);
    }
    if (ownServer) {
      switch (_server) {
        case AssistServerState.outdated:
          lines.add(l.restaurantServerOutdated);
        case AssistServerState.disabled:
          lines.add(l.restaurantServerDisabled);
        case AssistServerState.ready || AssistServerState.unknown:
          break;
      }
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final support = _support();
    final mode = _s.restaurantAssist;
    final on = mode != 'off';
    final available = support.supported &&
        restaurantRecipientCopy(l, support.recipient) != null;
    final paused = on && available && !restaurantConsentCovers(_s, support);
    final locationUsable = _c.locationSupported && support.locationAllowed;
    final modeTappable = available || on;
    return GroupedSection(
      header: l.settingsSectionRestaurant,
      footer: _footer(l, support, on: on, paused: paused).join('\n'),
      children: [
        GroupedRow(
          key: const Key('restaurantModeRow'),
          icon: Icons.restaurant_outlined,
          iconColor: theme.colorScheme.primary,
          title: l.settingsRowRestaurantMode,
          value: _modeLabel(l, mode),
          enabled: modeTappable,
          onTap: modeTappable ? _pickMode : null,
          showChevron: modeTappable,
        ),
        if (on && available)
          GroupedToggleRow(
            key: const Key('restaurantLocationRow'),
            switchKey: const Key('restaurantLocationToggle'),
            icon: Icons.place_outlined,
            iconColor: theme.colorScheme.secondary,
            title: l.settingsRowRestaurantLocation,
            value: locationUsable && _s.restaurantAssistLocation,
            onChanged: locationUsable
                ? (v) async {
                    await _s.updateRestaurantAssist(location: v);
                    if (mounted) setState(() {});
                  }
                : null,
          ),
        if (paused)
          GroupedRow(
            key: const Key('restaurantPausedRow'),
            icon: Icons.pause_circle_outline,
            iconColor: theme.colorScheme.error,
            title: l.settingsRowRestaurantPaused,
            value: l.restaurantPausedReview,
            onTap: _review,
          ),
        if (_c.locationSupported)
          GroupedRow(
            key: const Key('clearLearnedPlacesRow'),
            icon: Icons.location_off_outlined,
            iconColor: theme.colorScheme.tertiary,
            title: l.settingsRowClearLearnedPlaces,
            showChevron: false,
            onTap: _confirmClearPlaces,
          ),
      ],
    );
  }
}
