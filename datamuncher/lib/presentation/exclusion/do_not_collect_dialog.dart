import 'package:flutter/material.dart';

import '../../application/exclusion/exclusion_list.dart';

/// Asks whether to keep something out of scans for [exclusionPeriod]
/// (DAT-32). Returns true if the user confirmed; false if they picked
/// [declineLabel] or dismissed the dialog.
Future<bool> showDoNotCollectDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String declineLabel = 'Cancel',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(declineLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// "30 days", for messages.
String get exclusionPeriodLabel => '${exclusionPeriod.inDays} days';
