/// A reply that stays on the page: Describe's failed estimate and
/// Fix-a-meal's refusals and errors (U11).
///
/// Fix used to show these as a 4-second snackbar, gone before a slow
/// reader got to "The provider rejected the API key…" (nothing on screen
/// 6 s later), while Describe showed the same sentence as red body text.
/// Both now use this note, which stays until the next attempt.
///
/// InlineError's look (a danger glyph beside label-colour text) on a cell,
/// so it reads as part of the form. The executor's replies often bring
/// their own status glyph (❌, ⏸️, 🚫, from the Telegram bot's wording);
/// then that glyph leads and no second one is drawn beside it. The text is
/// shown exactly as given.
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class ReplyNote extends StatelessWidget {
  const ReplyNote({super.key, required this.message, this.textKey});

  final String message;

  /// On the Text itself (Describe keeps Key('addTextError')).
  final Key? textKey;

  /// True when [text] already starts with a status pictograph (arrows,
  /// dingbats, symbols and emoji: ❌ U+274C, ⏸ U+23F8, ⚠ U+26A0,
  /// 🚫 U+1F6AB). CJK text and punctuation (U+2E80 and up) are not.
  static bool leadsWithGlyph(String text) {
    final t = text.trimLeft();
    if (t.isEmpty) return false;
    final r = t.runes.first;
    return (r >= 0x2190 && r <= 0x2BFF) || r >= 0x1F000;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final glyph = !leadsWithGlyph(message);
    // A live region: the note appears after a round trip the screen
    // reader was not watching.
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: colors.cell,
        borderRadius: BorderRadius.circular(AppRadius.l),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.s16, vertical: AppSpace.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (glyph) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: ExcludeSemantics(
                    child: Icon(Icons.error_outline_rounded,
                        size: 20, color: colors.danger),
                  ),
                ),
                const SizedBox(width: AppSpace.s8),
              ],
              Expanded(
                child: Text(message,
                    key: textKey,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: colors.label)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
