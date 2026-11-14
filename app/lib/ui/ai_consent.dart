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
/// A share of several photos is ONE question: Not now covers that share
/// (and any that arrived before the answer), dropped without being asked
/// about or sent, and one line says how many were not sent
/// ([askSharedPhotoConsent]). A share after the answer asks again.
///
/// These are the questions. Every automatic send already needs the
/// watcher, and the watcher only runs for a consented recipient; the photo
/// pipeline reads the answer once more at each send (photo_pipeline.dart
/// AiSendGate), because an admitted photo can still be waiting its turn
/// when the consent is withdrawn or the provider changes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/ai_consent.dart';
import '../core/contracts.dart' show IntakePhoto, ShareDeliveries;
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
/// share: the gate drops, without asking or sending, every photo of the
/// shares that had arrived by the answer, and the one line says how many
/// were not sent ([SharedPhotoConsentGate.declineOpenQuestion]).
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
/// Pause-transparent: a plain asyncMap, so while a question is open (and
/// while the pipeline holds a photo) the share intake reads no further
/// copy — one shared original in memory, at most one read ahead (review
/// 171, C2). It used to listen without ever pausing, to time each photo's
/// arrival, and that loaded every original of a 20-photo share at once.
///
/// One Not now per share: a 5-photo share answered Not now used to ask
/// five times. The intake numbers each share as its batch event arrives
/// (IntakePhoto.shareDelivery, [ShareDeliveries]); a Not now covers the
/// share asked about, however slowly its files are read, and every share
/// that arrived while the question was open. Their photos are dropped
/// without a question and never sent, even if the recipient is allowed
/// some other way before their turn (the user's answer for them was no),
/// and the intake deletes their copies not read yet, unread. A share
/// already waiting when the question opened, the start-up batch of copies
/// an earlier run left unread (ShareDeliveries.asksAlone, whenever its
/// sweep finishes) and one that arrives after the answer get their own
/// question.
///
/// The shell's question answers true (Allow), false (Not now) or null:
/// no dialog could be shown (the shell is going away). Null is no answer,
/// like a dialog that failed: nothing is declined, and the photo waits for
/// the next shell to ask.
class SharedPhotoConsentGate {
  SharedPhotoConsentGate(this._settings);

  final SettingsStore _settings;
  Future<bool?> Function()? _ask;
  Completer<void> _attached = Completer<void>();

  /// Completed by the next [attach]: what a photo whose question could not
  /// be shown waits for.
  Completer<void> _reattached = Completer<void>();

  /// The share intake's deliveries; null when [gate] was given none (then
  /// a Not now covers the asked photo's delivery as far as photos say).
  ShareDeliveries? _deliveries;

  /// The deliveries a Not now covers.
  final Set<int> _declined = {};

  /// The latest delivery that had arrived when the open question opened.
  int _openedAt = 0;

  /// The latest delivery a photo has come from (without [_deliveries]).
  int _latestSeen = 0;

  /// Photos of each delivery passed on.
  final Map<int, int> _admitted = {};

  /// The photo the open question is about; null when none is open.
  IntakePhoto? _asking;

  /// Whether [declineOpenQuestion] already marked the open question's
  /// answer.
  bool _declineMarked = false;

  /// The app shell's dialog, once it has a navigator; true = allowed (and
  /// recorded). A cold-start share arrives before the first frame and
  /// waits here until then.
  void attach(Future<bool?> Function() ask) {
    _ask = ask;
    if (!_attached.isCompleted) _attached.complete();
    final waiting = _reattached;
    _reattached = Completer<void>();
    waiting.complete();
  }

  void detach(Future<bool?> Function() ask) {
    // ==, not identical: two tear-offs of one method are equal only.
    if (_ask != ask) return;
    _ask = null;
    _attached = Completer<void>();
  }

  /// The open question was answered Not now: covers the asked photo's
  /// delivery and every one that arrived while the question was open (not
  /// one already waiting when it opened), tells the intake to delete their
  /// unread copies, and returns how many shared photos the answer leaves
  /// unsent — those deliveries' photos not passed on, the asked one
  /// included. 1 for a photo with no delivery, or when no question is
  /// open.
  ///
  /// The count can be a little high, never low: a copy not read yet that
  /// turns out unusable (an unsupported type, over 25 MB, a failing read)
  /// is counted too (ShareDeliveries.photoCountOf).
  int declineOpenQuestion() {
    final asking = _asking;
    if (asking == null) return 1;
    _declineMarked = true;
    final delivery = asking.shareDelivery;
    if (delivery == null) return 1;
    final deliveries = _deliveries;
    final now = deliveries?.arrivedDelivery ?? _latestSeen;
    final covered = {
      delivery,
      for (var d = math.max(_openedAt, delivery) + 1; d <= now; d++)
        // The start-up batch of copies left unread is no share being made
        // now: it gets its own question, whenever its sweep finished.
        if (!(deliveries?.asksAlone(d) ?? false)) d,
    }..removeAll(_declined);
    _declined.addAll(covered);
    if (covered.isNotEmpty) deliveries?.declineDeliveries(covered);
    if (deliveries == null) return 1;
    var notSent = 0;
    for (final d in covered) {
      notSent += math.max(0, deliveries.photoCountOf(d) - (_admitted[d] ?? 0));
    }
    return math.max(1, notSent);
  }

  /// [photos] through the consent question, pausing them while it is open;
  /// [deliveries] is the share intake that numbered them.
  Stream<IntakePhoto> gate(Stream<IntakePhoto> photos,
      {ShareDeliveries? deliveries}) {
    _deliveries = deliveries;
    return photos
        .asyncMap(_admit)
        .where((p) => p != null)
        .cast<IntakePhoto>();
  }

  Future<IntakePhoto?> _admit(IntakePhoto photo) async {
    final delivery = photo.shareDelivery;
    if (delivery != null && delivery > _latestSeen) _latestSeen = delivery;
    IntakePhoto passed() {
      if (delivery != null) _admitted[delivery] = (_admitted[delivery] ?? 0) + 1;
      return photo;
    }

    while (true) {
      // Its share was answered Not now: dropped unasked, never sent.
      if (delivery != null && _declined.contains(delivery)) return null;
      // Re-read after every wait: the user may have allowed it meanwhile.
      if (!aiConsentNeeded(_settings)) return passed();
      final ask = _ask;
      if (ask == null) {
        await _attached.future;
        continue;
      }
      final nextShell = _reattached.future;
      _asking = photo;
      _openedAt = _deliveries?.arrivedDelivery ?? _latestSeen;
      _declineMarked = false;
      final bool? answer;
      try {
        answer = await ask();
      } catch (_) {
        _asking = null;
        return null; // a failed dialog is not consent
      }
      if (answer == true) {
        _asking = null;
        return passed();
      }
      if (answer == false) {
        // Not now: the rest of the share is covered too. Marked here when
        // the dialog's own line did not.
        if (!_declineMarked) declineOpenQuestion();
        _asking = null;
        return null;
      }
      // No dialog could be shown: no answer. Nothing is declined; the
      // photo waits for the next shell's question.
      _asking = null;
      await nextShell;
    }
  }
}
