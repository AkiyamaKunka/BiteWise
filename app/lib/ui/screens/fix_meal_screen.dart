/// Fix/delete meals by free text (spec §4 corrections), reached from the
/// Add-meal sheet. This USED to be a chat bar pinned to the bottom of
/// Today — the user's verdict (2026-07-31): delete the bar, fold the
/// feature into the one meals button. One entry point, zero standing
/// screen clutter.
library;

import 'package:flutter/material.dart';

import '../../core/contracts.dart';
import '../ai_consent.dart';
import '../nl_presenter.dart';
import '../l10n.dart';
import '../services.dart' show SettingsStore;
import '../large_text.dart';
import '../theme/tokens.dart';
import '../widgets/reply_note.dart';
import '../widgets/small_spinner.dart';

class FixMealScreen extends StatefulWidget {
  final NlExecutor executor;

  /// For the AI consent before the request (and the last 7 days of meals
  /// it carries) leaves the phone. Required, so a call site cannot drop
  /// the question silently; tests that are about something else pass a
  /// FakeSettings, which allows every recipient.
  final SettingsStore settings;
  const FixMealScreen(
      {super.key, required this.executor, required this.settings});

  @override
  State<FixMealScreen> createState() => _FixMealScreenState();
}

class _FixMealScreenState extends State<FixMealScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;
  bool _askingConsent = false;
  final List<String> _log = []; // requests that changed something, newest last

  /// The last request's replies that changed nothing (a refusal, an error,
  /// a question), kept on the page until the next request (U11).
  String? _note;
  final GlobalKey _noteKey = GlobalKey();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || _askingConsent) return;
    // App Store 5.1.2(i): permission for this AI recipient first.
    _askingConsent = true;
    final allowed = await ensureAiConsent(context, widget.settings);
    _askingConsent = false;
    if (!allowed || !mounted || _sending) return;
    setState(() => _sending = true);
    try {
      final replies = await widget.executor.handleText(text);
      if (!mounted) return;
      // Sending ends when the executor returns; presentation (incl. the
      // blocking delete-confirmation modal) is not "sending".
      setState(() => _sending = false);
      // Only a request that changed something belongs under "Applied this
      // session": the list used to record every request BEFORE the
      // replies were read, so a cancelled delete, an invalid-index refusal
      // or an AI-contact error read as applied (loop find 2026-10-07).
      // Replies that changed nothing stay on the page (below the field)
      // instead of a 4-second snackbar: an error read as nothing at all
      // 6 s later (U11).
      final unchanged = <String>[];
      final changed = await presentNlReplies(context, widget.executor, replies,
          onNotApplied: (reply) => unchanged.add(reply.text));
      if (!mounted) return;
      _showNote(unchanged.isEmpty ? null : unchanged.join('\n\n'));
      // The field is cleared on the same condition. It used to be cleared
      // as soon as the executor returned, so "❌ 联系 AI 失败，请重试。", a
      // refusal or a cancelled delete asked the user to retry with the
      // sentence they typed already gone (loop find 2026-10-08). Nothing
      // can be typed in between: presentNlReplies awaits only modal
      // dialogs, never a snackbar.
      if (changed && mounted) {
        _controller.clear();
        setState(() => _log.add(text));
      }
    } catch (e) {
      if (!mounted) return;
      // Executor is spec'd never to throw (§4.9); belt-and-braces anyway.
      // Not sending any more, so the note shows in the frame it is set in.
      _sending = false;
      _showNote(context.l10n.fixRequestFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Sets the note and scrolls it into view: with the keyboard up it lands
  /// under it (the same fix as Describe's error, A15).
  void _showNote(String? note) {
    setState(() => _note = note);
    if (note == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _noteKey.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(target,
          duration: AppMotion.of(context, AppMotion.standard),
          curve: AppMotion.curve);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: context.colors.secondaryLabel);
    final note = _note;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.fixTitle)),
      // Scrollable for the same reason as AddTextScreen: autofocused
      // keyboard + multi-line refusal messages must never push the send
      // button off-screen.
      body: SingleChildScrollView(
        // More room on top at large text: the field's floating label rises
        // about 20 pt above it at AX5, past the 16-pt padding.
        padding: EdgeInsets.fromLTRB(
            AppSpace.gutter,
            isLargeText(context) ? AppSpace.s24 : AppSpace.gutter,
            AppSpace.gutter,
            AppSpace.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('fixMealField'),
              controller: _controller,
              maxLines: 3,
              autofocus: true,
              enabled: !_sending,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                labelText: context.l10n.fixLabel,
                hintText: context.l10n.fixHint,
              ),
            ),
            // The instructions read as the field's footer, the way
            // Describe's help sits under its field.
            const SizedBox(height: AppSpace.s8),
            Text(context.l10n.fixIntro, style: muted),
            const SizedBox(height: AppSpace.s4),
            // The old copy promised "the meal numbers match the Today
            // list". They do not: Today renders no numbers at all, and the
            // model resolves an index against a SEVEN-DAY window led by
            // earlier days — so "meal 2" could rewrite yesterday's lunch
            // (review 2026-07-31). Describing the dish is unambiguous.
            Text(context.l10n.fixNamingTip, style: muted),
            // Hidden while a new request runs: it answered the last one.
            if (note != null && !_sending) ...[
              const SizedBox(height: AppSpace.s12),
              ReplyNote(
                key: _noteKey,
                message: note,
                textKey: const Key('fixMealNote'),
              ),
            ],
            const SizedBox(height: AppSpace.s16),
            FilledButton.icon(
              key: const Key('fixMealSend'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SmallSpinner()
                  : const Icon(Icons.build_outlined),
              label: Text(_sending ? context.l10n.working : context.l10n.fixApply),
            ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: AppSpace.s24),
              Semantics(
                header: true,
                child: Text(context.l10n.fixAppliedHeader,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: context.colors.secondaryLabel)),
              ),
              for (final line in _log.reversed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('• $line', style: theme.textTheme.bodyMedium),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
