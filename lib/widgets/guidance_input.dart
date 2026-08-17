import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/widgets/section_card.dart';

/// Optional marking notes from the teacher.
///
/// Optional in the real sense: the question paper is expected to carry the
/// marking structure on its own, and marking starts whether or not anything is
/// typed here. The heading and hint both say so, because a box that looks
/// required will be filled in unnecessarily.
class GuidanceInput extends StatelessWidget {
  const GuidanceInput({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SectionCard(
      title: '3. Marking guidance (optional)',
      trailing: OutlinedButton(onPressed: onClear, child: const Text('Clear')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'The marks come from the question paper. Add notes here only where '
            'it leaves something unsaid — a question with no printed marks, or '
            'how marks should divide within one. Where the two disagree, the '
            'question paper wins.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('guidance-input'),
            controller: controller,
            onChanged: onChanged,
            minLines: 3,
            maxLines: 3,
            textAlignVertical: TextAlignVertical.top,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(
              hintText: 'Section A: one mark each.\n'
                  'Section B: award marks based on the required points.',
              contentPadding: EdgeInsets.all(10),
            ),
          ),
        ],
      ),
    );
  }
}
