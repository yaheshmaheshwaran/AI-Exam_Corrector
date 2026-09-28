import 'package:flutter/material.dart';

import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

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
  });

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

    return RailSection(
      label: 'Marking guidance',
      optional: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'Load guidance from a file…',
            onPressed: onLoadFile,
            icon: const Icon(Icons.upload_file_outlined),
          ),
          TextButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (paperScheme case (withScheme: final int count, questions: final int total))
            InfoBanner(
              tone: ToneKind.primary,
              icon: Icons.fact_check_outlined,
              title: 'The paper has its own mark scheme',
              body: 'The question paper includes a mark scheme for '
                  '${count == total ? 'every question' : '$count of $total questions'}'
                  ' — marking follows it. Anything added here is applied on '
                  'top, and wins where the two differ.',
            ),
          TextField(
            key: const Key('guidance-input'),
            controller: controller,
            onChanged: onChanged,
            minLines: 4,
            maxLines: 8,
            textAlignVertical: TextAlignVertical.top,
            style: context.text.small,
            decoration: const InputDecoration(
              hintText: 'Section A: one mark each.\n'
                  'Section B: award marks based on the required points.',
              contentPadding: EdgeInsets.all(10),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            sourceFile != null
                ? 'Loaded from $sourceFile. The question paper still decides '
                    'what each question is worth; this guidance decides what '
                    'earns the marks.'
                : 'The marks come from the question paper. Add what earns them '
                    '— required points, accepted alternatives. Without guidance, '
                    'the marking points are inferred and shown for you to check.',
            style: context.text.caption,
          ),
        ],
      ),
    );
  }
}

/// How strictly the paper is marked, as its own step in the rail: the
/// level, what it means, the college's rules, and where moderation stands.
class MarkingStandardSection extends StatelessWidget {
  const MarkingStandardSection({
    super.key,
    required this.standard,
    this.onLevel,
    this.onRules,
    this.moderation,
  });

  final MarkingStandard standard;
  final ValueChanged<MarkingLevel>? onLevel;
  final VoidCallback? onRules;

  /// Where moderation to the teacher's marking stands.
  final Widget? moderation;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<MarkingLevel>? onLevel = this.onLevel;
    return RailSection(
      label: 'Marking standard',
      trailing: TextButton(
        key: const Key('marking-rules'),
        onPressed: onRules,
        child: const Text('Rules…'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SegmentedButton<MarkingLevel>(
            key: const Key('marking-level'),
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            segments: <ButtonSegment<MarkingLevel>>[
              for (final MarkingLevel level in MarkingLevel.values)
                ButtonSegment<MarkingLevel>(
                  value: level,
                  label: Text(level.label),
                  tooltip: level.description,
                ),
            ],
            selected: <MarkingLevel>{standard.level},
            onSelectionChanged: onLevel == null ? null : (Set<MarkingLevel> picked) => onLevel(picked.single),
          ),
          const SizedBox(height: 8),
          Text(standard.summary, key: const Key('marking-summary'), style: context.text.caption),
          if (moderation != null) ...<Widget>[
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft, child: moderation!),
          ],
        ],
      ),
    );
  }
}
