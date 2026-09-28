import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/widgets/ui/app_dialog.dart';
import 'package:exam_corrector/app/press_feedback.dart';
import 'package:exam_corrector/services/ui_sound.dart';

/// Asks before something that cannot be undone. Returns true only when the
/// teacher confirms.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'Remove',
  bool destructive = true,
}) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(message),
      ),
      actions: <Widget>[
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: context.colors.danger,
                  foregroundColor: context.colors.surface,
                  splashFactory: const PressFeedback(sound: UiSoundKind.remove),
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
