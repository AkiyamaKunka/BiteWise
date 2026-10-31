/// Small pieces the Settings pages share.
///
/// - [cellFieldDecoration]: text fields that sit INSIDE a grouped cell (the
///   API key, the model id, the server address and upload key, the
///   dietary profile). The cell is the field's frame, so the field draws
///   no outline and no fill. A field's own `border: InputBorder.none` is
///   not enough under the app theme: InputDecoration.applyDefaults fills a
///   null enabledBorder / focusedBorder from inputDecorationTheme, which
///   outlines every field, so these cells showed a box inside the box.
/// - [showChoiceSheet]: a grouped sheet with one checkmark row per option
///   (Language, Units, the own server's Model and Thinking effort).
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/grouped.dart';

/// The decoration for a field inside a grouped cell.
InputDecoration cellFieldDecoration({String? labelText, String? hintText}) =>
    InputDecoration(
      labelText: labelText,
      hintText: hintText,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      filled: false,
    );

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
