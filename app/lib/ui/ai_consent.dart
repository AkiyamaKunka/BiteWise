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
/// And once more, by the app shell, when the text changed what is sent
/// since the current recipient was allowed ([askAiConsentUpdate]); the
/// newly described data waits for that Allow.
///
/// A share of several photos is ONE question: Not now covers every
/// shared photo that arrived before that answer, dropped without being
/// asked about or sent, and one line says how many were not sent
/// ([askSharedPhotoConsent]). A share after the answer asks again.
///
/// These are the questions. Every automatic send already needs the
/// watcher, and the watcher only runs for a consented recipient; the photo
/// pipeline reads the answer once more at each send (photo_pipeline.dart
/// AiSendGate), because an admitted photo can still be waiting its turn
/// when the consent is withdrawn or the provider changes.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ai_consent.dart';
import '../core/contracts.dart' show IntakePhoto;
import '../core/server_transport.dart'
    show isCleartextServerUrl, serverAddressRefused;
import 'l10n.dart';
import 'provider_names.dart' show providerDisplayLabel;
import 'services.dart' show SettingsStore;
import 'theme/app_dialog.dart';

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
/// mainland China, plus, for the user's own server, how it travels when
/// the address is not https:// (core/server_transport.dart): with the
/// https switch on, that nothing is sent to it; with it off, that it goes
/// unencrypted. About transport, not about what is sent, so the wording
/// version (aiConsentWordingVersion) stays.
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
  final text = aiRoutesInMainlandChina
          .contains(aiConsentRoute(provider, serverBackend))
      ? '$body\n\n${l.aiConsentChinaNote(company)}'
      : body;
  final transport = provider != 'server'
      ? null
      : serverAddressRefused(serverBaseUrl)
          ? l.serverHttpsRequiredConsentNote
          : isCleartextServerUrl(serverBaseUrl)
              ? l.serverHttpConsentNote
              : null;
  return transport == null ? text : '$text\n\n$transport';
}

String _hostOf(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  return uri != null && uri.host.isNotEmpty ? uri.host : trimmed;
}

/// The consent dialog; true = Allow. Records nothing — callers do, so the
/// route they asked about is the one saved. [title], [appendix] and the
/// keys let the camera-roll switch reuse it with its own notice;
/// [leadWithAppendix] puts that notice above the general text, where the
/// one thing new to the user is read first (the text only moves: what is
/// asked, and when, is the caller's).
Future<bool> showAiConsentDialog(
  BuildContext context, {
  required String provider,
  required String serverBackend,
  required String serverBaseUrl,
  String? title,
  String? appendix,
  bool leadWithAppendix = false,
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
      // The app's scrolling dialog (A1): title and text scroll together,
      // so the disclosure is readable at every text size before Allow.
      return appAlertDialog(
        key: dialogKey,
        title: Text(title ?? l.aiConsentTitle),
        content: Text(appendix == null
            ? text
            : leadWithAppendix
                ? '$appendix\n\n$text'
                : '$text\n\n$appendix'),
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
/// shows [declined] (default: "Nothing was sent.") and returns false;
/// [declinedAtAnswer], when given, words that line instead, read at the
/// moment of the answer.
Future<bool> ensureAiConsent(BuildContext context, SettingsStore settings,
    {String? declined, String Function()? declinedAtAnswer}) async {
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
  messenger?.showSnackBar(SnackBar(
      content: Text(declinedAtAnswer?.call() ?? declinedText)));
  return false;
}

/// The app shell's question for a photo shared into the app
/// ([SharedPhotoConsentGate.attach]). Not now covers the rest of that
/// share: the gate drops, without asking or sending, every shared photo
/// that arrived before the answer, and the one line says how many were
/// not sent — the asked photo and those ([SharedPhotoConsentGate
/// .declineOpenQuestion]).
Future<bool> askSharedPhotoConsent(BuildContext context,
    SettingsStore settings, SharedPhotoConsentGate gate) {
  final l = context.l10n;
  return ensureAiConsent(context, settings, declinedAtAnswer: () {
    final notSent = gate.declineOpenQuestion();
    return notSent > 1
        ? l.shareConsentDeclinedMany(notSent)
        : l.shareConsentDeclined;
  });
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
      // The camera-roll notice first: it is why this is asked now.
      appendix: l.watcherDisclosureBody(
          providerDisplayLabel(l, provider, serverBackend),
          settings.lookbackDays.clamp(1, 30)),
      leadWithAppendix: true);
  if (!ok) return false;
  await settings.setAiConsent(route, granted: true);
  return true;
}

/// Whether the app shell should ask once more for the CURRENT recipient:
/// it is allowed, but under an older consent text than the dialogs show
/// now (core/ai_consent.dart aiConsentWordingVersion), and the user has not
/// answered that yet. Never without a key (nothing could be sent) and
/// never without a grant: the first send's own question covers that.
bool aiConsentUpdateNeeded(SettingsStore s) {
  if (s.apiKey.trim().isEmpty) return false;
  final route = currentAiConsentRoute(s);
  final version = s.aiConsentVersion(route);
  return version > 0 &&
      version < aiConsentWordingVersion &&
      !s.aiConsentUpdateDeclined(route);
}

/// The one-time question for [aiConsentUpdateNeeded], under a title saying
/// what is sent has changed: first what is new (aiConsentUpdateLead — the
/// change sits in a parenthesis of the full text, where nobody would find
/// it), then the camera-roll notice while Watch Camera Roll is on (the
/// order it was turned on with), then the full consent text for the
/// current recipient. Allow records the current text for that recipient,
/// which is what sends the newly described data; anything else is
/// remembered as Not now, and the older grant goes on exactly as before.
/// True = Allow.
Future<bool> askAiConsentUpdate(
    BuildContext context, SettingsStore settings) async {
  final route = currentAiConsentRoute(settings);
  final l = context.l10n;
  final ok = await showAiConsentDialog(context,
      provider: settings.provider,
      serverBackend: settings.serverBackend,
      serverBaseUrl: settings.serverBaseUrl,
      title: l.aiConsentUpdateTitle,
      appendix: [
        l.aiConsentUpdateLead,
        if (settings.watcherEnabled)
          l.watcherDisclosureBody(
              providerDisplayLabel(l, settings.provider, settings.serverBackend),
              settings.lookbackDays.clamp(1, 30)),
      ].join('\n\n'),
      leadWithAppendix: true,
      dialogKey: const Key('aiConsentUpdateDialog'),
      cancelKey: const Key('aiConsentUpdateNotNow'),
      allowKey: const Key('aiConsentUpdateAllow'));
  if (ok) {
    await settings.setAiConsent(route, granted: true);
  } else {
    await settings.declineAiConsentUpdate(route);
  }
  return ok;
}

/// Holds each photo shared into the app until the current recipient is
/// allowed. A photo whose recipient is already allowed (or that nothing
/// could send — no key) passes straight through; otherwise the app shell's
/// dialog ([attach]) asks, and Not now drops the photo (its container copy
/// is already deleted by the share intake). Photos keep their order: the
/// stream waits while a question is open.
///
/// One Not now per share: a 5-photo share answered Not now used to ask
/// five times. Each photo is numbered as it ARRIVES (before it waits for
/// a question), and a Not now covers every photo that arrived before the
/// answer: those are dropped without a question and never sent — even if
/// the recipient is allowed some other way meanwhile, since the user's
/// answer for them was no. A photo that arrives after the answer is asked
/// about again.
///
/// Known, and safe either way (review finding 7): arrival time is not
/// share identity. A second share that arrives while the question is open
/// is covered by that Not now too (dropped, counted, never sent), and a
/// file of the same share read after the answer is asked about again.
/// Telling shares apart needs a per-delivery batch id from share_intake.
class SharedPhotoConsentGate {
  SharedPhotoConsentGate(this._settings);

  final SettingsStore _settings;
  Future<bool> Function()? _ask;
  Completer<void> _attached = Completer<void>();

  /// How many shared photos have arrived: each one's number, given as it
  /// arrives.
  int _arrived = 0;

  /// Every photo numbered up to this is covered by a Not now.
  int _declinedThrough = 0;

  /// The number of the photo the open question is about; null when none
  /// is open.
  int? _asking;

  /// Whether [declineOpenQuestion] already marked the open question's
  /// answer.
  bool _declineMarked = false;

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

  /// The open question was answered Not now: marks every shared photo
  /// that has arrived by now as covered by that answer, and returns how
  /// many shared photos the answer leaves unsent — the asked one and every
  /// one that arrived after it. 1 when no question is open.
  int declineOpenQuestion() {
    final asking = _asking;
    if (asking == null) return 1;
    _declineMarked = true;
    if (_arrived > _declinedThrough) _declinedThrough = _arrived;
    return _arrived - asking + 1;
  }

  /// [photos], each numbered on arrival: the subscription to [photos] is
  /// never paused (asyncMap pauses only the numbered stream while a
  /// question is open), so a photo's number says when it came, not when
  /// its turn did.
  Stream<IntakePhoto> gate(Stream<IntakePhoto> photos) {
    StreamSubscription<IntakePhoto>? source;
    late final StreamController<(IntakePhoto, int)> numbered;
    numbered = StreamController<(IntakePhoto, int)>(
      onListen: () {
        source = photos.listen((p) => numbered.add((p, ++_arrived)),
            onError: numbered.addError, onDone: numbered.close);
      },
      onCancel: () => source?.cancel(),
    );
    return numbered.stream
        .asyncMap(_admit)
        .where((p) => p != null)
        .cast<IntakePhoto>();
  }

  Future<IntakePhoto?> _admit((IntakePhoto, int) arrival) async {
    final (photo, number) = arrival;
    while (true) {
      // Covered by a Not now given after it arrived: dropped unasked,
      // and never sent.
      if (number <= _declinedThrough) return null;
      // Re-read after every wait: the user may have allowed it meanwhile.
      if (!aiConsentNeeded(_settings)) return photo;
      final ask = _ask;
      if (ask == null) {
        await _attached.future;
        continue;
      }
      _asking = number;
      _declineMarked = false;
      try {
        if (await ask()) return photo;
        // Not now (or no dialog could be shown): the rest of the share is
        // covered too. Marked here when the dialog's own line did not.
        if (!_declineMarked) declineOpenQuestion();
        return null;
      } catch (_) {
        return null; // a failed dialog is not consent
      } finally {
        _asking = null;
      }
    }
  }
}
