/// Material's date and time pickers with the text scale clamped (A6).
///
/// At the largest accessibility sizes Flutter scales the date dialog up
/// to 3x while its day grid clamps at 2x: on a 375-pt phone two-digit days
/// wrapped and lost their second digit ('19 2 21 2 2 2 2' — a wrong-day
/// meal waiting to happen), the zh header overflowed by 24 px, and the
/// 24-hour dial drew '15' and '3' as '153'. Clamping the whole dialog at
/// 1.6x keeps every label whole on every iPhone width; the picker text is
/// still well above the default size. Narrower Android screens clamp the
/// date dialog lower ([datePickerMaxTextScale]).
///
/// Same signatures and return types as [showDatePicker] /
/// [showTimePicker]; swap the call, keep the arguments.
library;

import 'package:flutter/material.dart';

/// The largest text scale inside a picker dialog: the time picker's
/// everywhere, the date picker's on a screen 375 dp or wider.
const double kPickerMaxTextScale = 1.6;

/// Below this width the date picker's clamp comes down
/// [kPickerClampPerDp] per dp, to no less than 1.0 (the user's own size
/// is never shrunk below the default).
const double kPickerFullClampWidth = 375;
const double kPickerClampPerDp = 0.01;

/// The date dialog's clamp on a screen [width] dp wide. Android's largest
/// Display size takes a phone to 320 dp, where at font size 2.0 the 1.6
/// clamp wrapped the selected '13' to a '1' in its circle and cut the
/// month to 'Novembe…' (Android push, UX run screenshot 46). Measured
/// with Roboto (test/ui/picker_width_test.dart), the most each width
/// keeps whole is 1.1 at 320 dp, 1.3 at 340, 1.5 at 360 and 1.6 at 375;
/// this line stays about 0.05 under each.
double datePickerMaxTextScale(double width) =>
    (kPickerMaxTextScale - (kPickerFullClampWidth - width) * kPickerClampPerDp)
        .clamp(1.0, kPickerMaxTextScale);

/// The clamp at [maxScale], with a caller's [builder] running INSIDE it
/// (its context sees the clamped scale, so a MediaQuery copy there cannot
/// undo it).
Widget _clamped(BuildContext context, Widget? child, TransitionBuilder? builder,
        {double maxScale = kPickerMaxTextScale}) =>
    MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxScale,
      child: builder == null
          ? child!
          : Builder(builder: (context) => builder(context, child)),
    );

/// [showDatePicker] with the dialog's text scale clamped at
/// [datePickerMaxTextScale] for the screen's width. A caller's [builder]
/// still runs, inside the clamp.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  DateTime? initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTime? currentDate,
  DatePickerEntryMode initialEntryMode = DatePickerEntryMode.calendar,
  SelectableDayPredicate? selectableDayPredicate,
  String? helpText,
  String? cancelText,
  String? confirmText,
  Locale? locale,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  TextDirection? textDirection,
  TransitionBuilder? builder,
  DatePickerMode initialDatePickerMode = DatePickerMode.day,
  String? errorFormatText,
  String? errorInvalidText,
  String? fieldHintText,
  String? fieldLabelText,
  TextInputType? keyboardType,
  Offset? anchorPoint,
  ValueChanged<DatePickerEntryMode>? onDatePickerModeChange,
  Icon? switchToInputEntryModeIcon,
  Icon? switchToCalendarEntryModeIcon,
}) =>
    showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      currentDate: currentDate,
      initialEntryMode: initialEntryMode,
      selectableDayPredicate: selectableDayPredicate,
      helpText: helpText,
      cancelText: cancelText,
      confirmText: confirmText,
      locale: locale,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      textDirection: textDirection,
      builder: (context, child) => _clamped(context, child, builder,
          maxScale: datePickerMaxTextScale(MediaQuery.sizeOf(context).width)),
      initialDatePickerMode: initialDatePickerMode,
      errorFormatText: errorFormatText,
      errorInvalidText: errorInvalidText,
      fieldHintText: fieldHintText,
      fieldLabelText: fieldLabelText,
      keyboardType: keyboardType,
      anchorPoint: anchorPoint,
      onDatePickerModeChange: onDatePickerModeChange,
      switchToInputEntryModeIcon: switchToInputEntryModeIcon,
      switchToCalendarEntryModeIcon: switchToCalendarEntryModeIcon,
    );

/// [showTimePicker] with the dialog's text scale clamped at
/// [kPickerMaxTextScale]. A caller's [builder] still runs, inside the clamp.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  TransitionBuilder? builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  TimePickerEntryMode initialEntryMode = TimePickerEntryMode.dial,
  String? cancelText,
  String? confirmText,
  String? helpText,
  String? errorInvalidText,
  String? hourLabelText,
  String? minuteLabelText,
  RouteSettings? routeSettings,
  EntryModeChangeCallback? onEntryModeChanged,
  Offset? anchorPoint,
  Orientation? orientation,
  Icon? switchToInputEntryModeIcon,
  Icon? switchToTimerEntryModeIcon,
}) =>
    showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) => _clamped(context, child, builder),
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useRootNavigator: useRootNavigator,
      initialEntryMode: initialEntryMode,
      cancelText: cancelText,
      confirmText: confirmText,
      helpText: helpText,
      errorInvalidText: errorInvalidText,
      hourLabelText: hourLabelText,
      minuteLabelText: minuteLabelText,
      routeSettings: routeSettings,
      onEntryModeChanged: onEntryModeChanged,
      anchorPoint: anchorPoint,
      orientation: orientation,
      switchToInputEntryModeIcon: switchToInputEntryModeIcon,
      switchToTimerEntryModeIcon: switchToTimerEntryModeIcon,
    );
