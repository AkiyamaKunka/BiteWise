/// The app's AlertDialog: title and content scroll TOGETHER (A1).
///
/// With Material's default (scrollable: false) the title is laid out at
/// full height and only the content flexes, so at the largest text sizes
/// the title and stacked actions used up the dialog: the daily-goal field
/// got 0 pt, the Stop sharing explanation and the leftover delete warning
/// were cut off. DialogTheme has no `scrollable` field, so every dialog
/// passes it — build them through [appAlertDialog] (or pass
/// `scrollable: true` yourself). The actions stay pinned and visible; the
/// default-size layout is unchanged (AlertDialog is IntrinsicWidth either
/// way). The result IS an AlertDialog, so `find.byType(AlertDialog)` and
/// the dialog theme still apply.
library;

import 'package:flutter/material.dart';

AlertDialog appAlertDialog({
  Key? key,
  Widget? icon,
  Widget? title,
  EdgeInsetsGeometry? titlePadding,
  Widget? content,
  EdgeInsetsGeometry? contentPadding,
  List<Widget>? actions,
  MainAxisAlignment? actionsAlignment,
  String? semanticLabel,
}) =>
    AlertDialog(
      key: key,
      scrollable: true,
      icon: icon,
      title: title,
      titlePadding: titlePadding,
      content: content,
      contentPadding: contentPadding,
      actions: actions,
      actionsAlignment: actionsAlignment,
      semanticLabel: semanticLabel,
    );
