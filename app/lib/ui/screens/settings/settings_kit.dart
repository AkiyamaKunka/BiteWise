/// Small pieces the Settings pages share.
///
/// - [cellFieldDecoration]: text fields that sit INSIDE a grouped cell (the
///   API key, the model id, the server address and upload key, the
///   dietary profile). The cell is the field's frame, so the field draws
///   no outline and no fill. A field's own `border: InputBorder.none` is
///   not enough under the app theme: InputDecoration.applyDefaults fills a
///   null enabledBorder / focusedBorder from inputDecorationTheme, which
///   outlines every field, so these cells showed a box inside the box.
///   The cell's own 16-pt inset is the field's: no theme content padding
///   on top, so the label lines up with the rows and headers. At the
///   accessibility text sizes a floating label is one line and was cut
///   to 'Gemini …', so there the label becomes a wrapping placeholder
///   (the section header above the cell still names the field).
/// - [cellField]: the padding around such a field in its cell.
/// - [showChoiceSheet]: a grouped sheet with one checkmark row per option
///   (Language, Units, the own server's Model and Thinking effort).
/// - [announceSelected]: the same "selected" for screen readers on rows
///   that draw their own checkmark (the AI provider, the own server's
///   plan, the restaurant mode, the connection type).
library;

import 'package:flutter/material.dart';

import '../../large_text.dart';
import '../../theme/tokens.dart';
import '../../widgets/grouped.dart';

/// The decoration for a field inside a grouped cell.
InputDecoration cellFieldDecoration(
  BuildContext context, {
  String? labelText,
  String? hintText,
}) {
  final large = isLargeText(context);
  return InputDecoration(
    labelText: large ? null : labelText,
    hintText: large ? labelText ?? hintText : hintText,
    hintMaxLines: large ? 4 : null,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    filled: false,
    contentPadding: const EdgeInsets.symmetric(vertical: 6),
  );
}

/// [field] in its grouped cell: the cell's 16-pt side inset, so the label
/// lines up with the rows and headers, and 10 pt above and below.
Widget cellField(Widget field) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
  child: field,
);

/// [row], announced selected when [selected]: for a row whose checkmark is
/// its own trailing icon, which screen readers do not read, so without
/// this VoiceOver and TalkBack read every choice alike. An unselected row
/// stays unmarked, as in [showChoiceSheet].
Widget announceSelected({required bool selected, required Widget row}) =>
    Semantics(selected: selected ? true : null, child: row);

/// A grouped sheet titled [title] listing (value, label) [options], the
/// [current] one checked (and announced selected). Resolves to the tapped
/// value, or null when dismissed. Rows are keyed '[keyPrefix]-value'
/// ([keyOf] overrides the value part). Scrolls when taller than the
/// screen, so the last option stays reachable at AX5 on an SE (A2).
Future<String?> showChoiceSheet(
  BuildContext context, {
  required String title,
  required String keyPrefix,
  required String current,
  required List<(String, String)> options,
  String Function(String value)? keyOf,
}) => showGroupedSheet<String>(
  context,
  title: title,
  builder: (ctx) => GroupedSection(
    separatorInset: AppSpace.separatorInset,
    children: [
      for (final (value, label) in options)
        GroupedRow.custom(
          key: Key('$keyPrefix-${keyOf?.call(value) ?? value}'),
          selected: current == value,
          showChevron: false,
          onTap: () => Navigator.pop(ctx, value),
          child: Text(
            label,
            style: Theme.of(
              ctx,
            ).textTheme.bodyLarge?.copyWith(color: ctx.colors.label),
          ),
        ),
    ],
  ),
);
