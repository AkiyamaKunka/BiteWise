/// One threshold for "the user picked a large accessibility text size".
///
/// Side-by-side layouts sized for normal text (a clock beside a meal title,
/// three or four number fields in one row, the date and time pills sharing
/// a line) stop fitting a 390 pt phone well before the largest iOS size
/// (AX5, ~3.1x): titles squeeze to a couple of glyphs a line and field
/// labels end in '…'. Above this scale those layouts stack instead. Text is
/// never shrunk to fit; the size is the user's choice.
library;

import 'package:flutter/widgets.dart';

/// True when [context]'s text scale is above 1.5x (iOS's accessibility
/// sizes start around there; the standard sizes top out near 1.35x).
bool isLargeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) > 1.5;
