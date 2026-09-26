import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
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
    this.onLoadFile,
    this.sourceFile,
    this.paperScheme,
    this.standard,
    this.onLevel,
    this.onRules,
    this.onAnswerKey,
    this.moderation,
  });

  /// Opens the paper's answer key; null until a script has been marked.
  final VoidCallback? onAnswerKey;

  /// Where moderation to the teacher's marking stands.
  final Widget? moderation;

  /// The paper's marking standard, when the teacher can set one.
  final MarkingStandard? standard;
  final ValueChanged<MarkingLevel>? onLevel;
  final VoidCallback? onRules;

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;

  /// Loads guidance from a text, Markdown or PDF file.
  final VoidCallback? onLoadFile;

  /// The file the current guidance came from, when it did.
  final String? sourceFile;

  /// How much of the question paper carries its own mark scheme, once the
  /// paper has been read and found to print one.
  final ({int withScheme, int questions})? paperScheme;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SectionCard(
      title: '3. Marking guidance (optional)',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: onLoadFile,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: const Text('Load file…'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (paperScheme case (withScheme: final int count, questions: final int total))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.fact_check_outlined, size: 16, color: AppTheme.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'The question paper includes a mark scheme for '
                      '${count == total ? 'every question' : '$count of $total questions'}'
                      ' — marking follows it. Anything added here is applied on '
                      'top, and wins where the two differ.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Text(
            sourceFile != null
                ? 'Loaded from $sourceFile. The question paper still decides '
                    'what each question is worth; this guidance decides what '
                    'earns the marks.'
                : 'The marks come from the question paper. Add notes on what '
                    'earns them — required points, accepted alternatives — and '
                    'marking follows them. Without guidance, the marking points '
                    'are inferred and shown for you to check.',
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
          if (standard case final MarkingStandard chosen) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text('Marking standard', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                SegmentedButton<MarkingLevel>(
                  key: const Key('marking-level'),
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: <ButtonSegment<MarkingLevel>>[
                    for (final MarkingLevel level in MarkingLevel.values)
                      ButtonSegment<MarkingLevel>(
                        value: level,
                        label: Text(level.label),
                        tooltip: level.description,
                      ),
                  ],
                  selected: <MarkingLevel>{chosen.level},
                  onSelectionChanged: onLevel == null
                      ? null
                      : (Set<MarkingLevel> picked) => onLevel!(picked.single),
                ),
                TextButton(
                  key: const Key('marking-rules'),
                  onPressed: onRules,
                  child: const Text('Rules…'),
                ),
                Text(
                  chosen.summary,
                  key: const Key('marking-summary'),
                  style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Tooltip(
                  message: onAnswerKey == null
                      ? 'The answer key is prepared when the first script is marked.'
                      : 'The points every script is marked against, fixed before any '
                          'answer was read — check and correct them.',
                  child: OutlinedButton.icon(
                    key: const Key('answer-key'),
                    onPressed: onAnswerKey,
                    icon: const Icon(Icons.key_outlined, size: 16),
                    label: const Text('Answer key'),
                  ),
                ),
                ?moderation,
              ],
            ),
          ],
        ],
      ),
    );
  }
}
