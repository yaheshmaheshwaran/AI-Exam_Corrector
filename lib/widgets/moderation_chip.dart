import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/moderation.dart';

/// Where moderation stands for the paper: waiting for the teacher's marks,
/// ready to apply, or in force — as real exam moderation works, the teacher
/// marks a few scripts and the rest are brought to their standard.
class ModerationChip extends StatelessWidget {
  const ModerationChip({
    super.key,
    required this.applied,
    required this.suggested,
    required this.samples,
    this.onApply,
    this.onRemove,
    this.agreement,
  });

  /// How far the AI is from the teacher on the questions they marked.
  final ({double before, double after, int questions})? agreement;

  String get _gap {
    final ({double before, double after, int questions})? a = agreement;
    if (a == null) return '';
    return '\n\nOn the ${a.questions} question${a.questions == 1 ? '' : 's'} you marked, the AI is '
        '${Moderation.gap(a.before)}'
        '${(a.after - a.before).abs() < 0.05 ? '' : ' — ${Moderation.gap(a.after)} once moderated'}.';
  }

  /// In force; [Moderation.none] when not.
  final Moderation applied;

  /// What the teacher's marks so far suggest; null until there are enough.
  final Moderation? suggested;

  /// How many questions the teacher has marked.
  final int samples;
  final VoidCallback? onApply;
  final VoidCallback? onRemove;

  static const String _how = 'Mark or accept questions on 2–3 scripts yourself. '
      'Your marks are compared with the AI’s, and every other script of this '
      'paper is scaled to your standard — instantly, without re-marking. '
      'Questions you marked keep your marks.';

  @override
  Widget build(BuildContext context) {
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    final Moderation? ready = suggested;
    final bool outdated = ready != null && ready.differsFrom(applied);

    if (outdated) {
      return Tooltip(
        message: '${ready.factors}, ${ready.basis}.$_gap\n\n$_how',
        child: FilledButton.tonalIcon(
          key: const Key('moderation-apply'),
          onPressed: onApply,
          icon: const Icon(Icons.balance, size: 16),
          label: Text(applied.isActive
              ? 'Update moderation (${ready.factors})'
              : 'Moderate to your marking (${ready.factors})'),
        ),
      );
    }
    if (applied.isActive) {
      return Tooltip(
        message: 'Unmarked questions are scaled ${applied.factors}, ${applied.basis}.$_gap\n\n$_how',
        child: InputChip(
          key: const Key('moderation-active'),
          avatar: const Icon(Icons.balance, size: 16, color: AppTheme.accent),
          label: Text('Moderated ${applied.factors}'),
          onDeleted: onRemove,
          deleteButtonTooltipMessage: 'Remove moderation',
        ),
      );
    }
    return Tooltip(
      message: '$_how$_gap',
      child: Row(
        key: const Key('moderation-waiting'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.balance, size: 15, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(
            samples == 0
                ? 'Moderation: mark a few questions yourself'
                : 'Moderation: $samples of ${Moderation.minimumQuestions} questions marked',
            style: small?.copyWith(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}
