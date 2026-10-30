/// Explicit permission before meal data goes to a third-party AI (App Store
/// guideline 5.1.2(i): "clearly disclose where personal data will be shared
/// with third parties, including with third-party AI, and obtain explicit
/// permission before doing so").
///
/// Consent is per RECIPIENT (core/ai_consent.dart aiConsentRoute), asked:
/// - before a foreground send: a picked photo, Describe/Fix a meal,
///   Leftovers, Test This Provider, Photo Coverage ([ensureAiConsent]);
/// - for a photo shared into the app, held until answered
///   ([SharedPhotoConsentGate]);
/// - when Watch Camera Roll is turned on (settings_screen.dart), and when
///   the recipient changes while it is on ([confirmAiRecipientChange]).
///
/// Nothing here touches the photo pipeline: every automatic send already
/// needs the watcher, and the watcher only runs for a consented recipient.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ai_consent.dart';
import '../core/contracts.dart' show IntakePhoto;
import 'l10n.dart';
import 'provider_names.dart' show providerDisplayLabel;
import 'services.dart' show SettingsStore;

/// The recipient the current provider choice sends to.
String currentAiConsentRoute(SettingsStore s) =>
    aiConsentRoute(s.provider, s.serverBackend);

/// Whether a send right now would need the user's permission first: a
/// recipient is configured (without a key nothing can leave the phone, and
/// the send fails with its own 'no key' message) and it is not allowed yet.
bool aiConsentNeeded(SettingsStore s) =>
    s.apiKey.trim().isNotEmpty && !s.hasAiConsent(currentAiConsentRoute(s));

/// The AI company itself, e.g. 'Google (Gemini)' or, for the user's own
/// server, the company behind its plan.
String aiConsentCompanyName(AppLocalizations l,
        {required String provider, required String serverBackend}) =>
    provider == 'server'
        ? l.aiConsentPlanCompany(serverBackend)
        : l.aiConsentCompany(provider);

/// The full consent text for a provider choice — the body naming the
/// recipient, plus where its company processes the data when that is
/// mainland China.
String aiConsentText(AppLocalizations l,
    {required String provider,
    required String serverBackend,
    required String serverBaseUrl}) {
  final company = aiConsentCompanyName(l,
      provider: provider, serverBackend: serverBackend);
  final String recipient;
  if (provider == 'server') {
    final host = _hostOf(serverBaseUrl);
    recipient = host.isEmpty
        ? l.aiConsentServerRecipientNoHost(company)
        : l.aiConsentServerRecipient(host, company);
  } else if (provider == 'openrouter') {
    recipient = l.aiConsentRelayRecipient;
  } else {
    recipient = company;
  }
  final body = l.aiConsentBody(recipient);
  return aiRoutesInMainlandChina
          .contains(aiConsentRoute(provider, serverBackend))
      ? '$body\n\n${l.aiConsentChinaNote(company)}'
      : body;
}

String _hostOf(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  return uri != null && uri.host.isNotEmpty ? uri.host : trimmed;
}

/// The consent dialog; true = Allow. Records nothing — callers do, so the
/// route they asked about is the one saved. [title], [appendix] and the
/// keys let the camera-roll switch reuse it with its own notice.
Future<bool> showAiConsentDialog(
  BuildContext context, {
  required String provider,
  required String serverBackend,
  required String serverBaseUrl,
  String? title,
  String? appendix,
  String? allowLabel,
  String? cancelLabel,
  Key dialogKey = const Key('aiConsentDialog'),
  Key cancelKey = const Key('aiConsentNotNow'),
  Key allowKey = const Key('aiConsentAllow'),
}) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final l = ctx.l10n;
      final text = aiConsentText(l,
          provider: provider,
          serverBackend: serverBackend,
          serverBaseUrl: serverBaseUrl);
      return AlertDialog(
        key: dialogKey,
        title: Text(title ?? l.aiConsentTitle),
        content: SingleChildScrollView(
            child: Text(appendix == null ? text : '$text\n\n$appendix')),
        actions: [
          TextButton(
              key: cancelKey,
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelLabel ?? l.aiConsentNotNow)),
          FilledButton(
              key: allowKey,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(allowLabel ?? l.aiConsentAllow)),
        ],
      );
    },
  );
  return go == true;
}

/// Before a FOREGROUND send: true = go ahead (already allowed, nothing can
/// be sent yet, or the user just allowed it — which is saved). Not now
/// shows [declined] (default: "Nothing was sent.") and returns false.
Future<bool> ensureAiConsent(BuildContext context, SettingsStore settings,
    {String? declined}) async {
  if (!aiConsentNeeded(settings)) return true;
  final route = currentAiConsentRoute(settings);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final declinedText = declined ?? context.l10n.aiConsentDeclined;
  final ok = await showAiConsentDialog(context,
      provider: settings.provider,
      serverBackend: settings.serverBackend,
      serverBaseUrl: settings.serverBaseUrl);
  if (ok) {
    await settings.setAiConsent(route, granted: true);
    return true;
  }
  messenger?.showSnackBar(SnackBar(content: Text(declinedText)));
  return false;
}

/// A provider or plan choice that would change the recipient. With Watch
/// Camera Roll ON the next automatic photo would go to the new recipient,
/// so it is asked now (the notice included) and Not now keeps the previous
/// choice: false = do not switch. With the watcher off the switch simply
/// happens and the next foreground send asks.
Future<bool> confirmAiRecipientChange(BuildContext context,
    SettingsStore settings,
    {required String provider, required String serverBackend}) async {
  if (!settings.watcherEnabled) return true;
  final route = aiConsentRoute(provider, serverBackend);
  if (settings.hasAiConsent(route)) return true;
  final l = context.l10n;
  final ok = await showAiConsentDialog(context,
      provider: provider,
      serverBackend: serverBackend,
      serverBaseUrl: settings.serverBaseUrl,
      appendix: l.watcherDisclosureBody(
          providerDisplayLabel(l, provider, serverBackend),
          settings.lookbackDays.clamp(1, 30)));
  if (!ok) return false;
  await settings.setAiConsent(route, granted: true);
  return true;
}

/// Holds each photo shared into the app until the current recipient is
/// allowed. A photo whose recipient is already allowed (or that nothing
/// could send — no key) passes straight through; otherwise the app shell's
/// dialog ([attach]) asks, and Not now drops the photo (its container copy
/// is already deleted by the share intake). Photos keep their order: the
/// stream waits while a question is open.
class SharedPhotoConsentGate {
  SharedPhotoConsentGate(this._settings);

  final SettingsStore _settings;
  Future<bool> Function()? _ask;
  Completer<void> _attached = Completer<void>();

  /// The app shell's dialog, once it has a navigator; true = allowed (and
  /// recorded). A cold-start share arrives before the first frame and
  /// waits here until then.
  void attach(Future<bool> Function() ask) {
    _ask = ask;
    if (!_attached.isCompleted) _attached.complete();
  }

  void detach(Future<bool> Function() ask) {
    // ==, not identical: two tear-offs of one method are equal only.
    if (_ask != ask) return;
    _ask = null;
    _attached = Completer<void>();
  }

  Stream<IntakePhoto> gate(Stream<IntakePhoto> photos) => photos
      .asyncMap(_admit)
      .where((p) => p != null)
      .cast<IntakePhoto>();

  Future<IntakePhoto?> _admit(IntakePhoto photo) async {
    while (true) {
      // Re-read after every wait: the user may have allowed it meanwhile.
      if (!aiConsentNeeded(_settings)) return photo;
      final ask = _ask;
      if (ask == null) {
        await _attached.future;
        continue;
      }
      try {
        return await ask() ? photo : null;
      } catch (_) {
        return null; // a failed dialog is not consent
      }
    }
  }
}
