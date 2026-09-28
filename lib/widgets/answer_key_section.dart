import 'package:flutter/material.dart';

import 'package:exam_corrector/pipeline/marking/teacher_key.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// The teacher's own answer key, as a step in the setup rail.
///
/// Optional in the real sense: without a key the paper is marked exactly as
/// before, and with one only the questions it answers change. The line under
/// the file says how much of the paper that is.
class AnswerKeySection extends StatelessWidget {
  const AnswerKeySection({
    super.key,
    required this.teacherKey,
    required this.coverage,
    required this.reading,
    required this.paperChosen,
    required this.onChoose,
    required this.onRemove,
    required this.onReview,
  });

  final TeacherKey? teacherKey;
  final ({int covered, int total, int printed})? coverage;
  final bool reading;
  final bool paperChosen;
  final VoidCallback? onChoose;
  final VoidCallback? onRemove;

  /// Opens the key question by question; null until the paper's questions
  /// are known.
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final TeacherKey? key = teacherKey;
    return RailSection(
      label: 'Answer key',
      optional: key == null,
      status: key == null ? RailStatus.none : RailStatus.ready,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (key != null)
            IconButton(
              key: const Key('answer-key-remove'),
              tooltip: 'Remove your answer key',
              onPressed: onRemove,
              icon: const Icon(Icons.close),
            ),
          TextButton(
            key: const Key('answer-key-choose'),
            onPressed: onChoose,
            child: Text(key == null ? 'Add…' : 'Replace…'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (reading)
            const _Frame(child: SkeletonLines(lines: 1, label: 'Reading your answer key'))
          else if (key == null)
            _Empty(paperChosen: paperChosen, onChoose: onChoose)
          else
            _Ready(teacherKey: key, coverage: coverage),
          if (onReview != null) ...<Widget>[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('answer-key'),
                onPressed: onReview,
                icon: const Icon(Icons.fact_check_outlined, size: 16),
                label: const Text('Review key…'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A plain bordered surface for a file row or a loading placeholder.
class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: child,
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.paperChosen, required this.onChoose});

  final bool paperChosen;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    return DropFrame(
      icon: Icons.key_outlined,
      title: paperChosen ? 'No answer key' : 'Waiting for the question paper',
      detail: paperChosen
          ? 'Mark with your own key — a PDF with text, a Word file or a text file. '
              'Questions it does not cover are marked as usual.'
          : 'Choose the question paper first; your answer key is matched to its questions.',
      detailKey: const Key('answer-key-hint'),
      onTap: onChoose,
    );
  }
}

class _Ready extends StatelessWidget {
  const _Ready({required this.teacherKey, required this.coverage});

  final TeacherKey teacherKey;
  final ({int covered, int total, int printed})? coverage;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ({int covered, int total, int printed})? cover = coverage;
    final String detail = cover == null
        ? 'Matched to the questions when marking starts'
        : <String>[
            'Covers ${cover.covered} of ${cover.total} question${cover.total == 1 ? '' : 's'}',
            if (cover.total - cover.covered - cover.printed > 0)
              '${cover.total - cover.covered - cover.printed} marked the usual way',
            if (cover.printed > 0) '${cover.printed} use the paper\'s own scheme',
          ].join(' · ');
    final List<String> notes = <String>[
      if (teacherKey.unmatched.isNotEmpty)
        'Not on the paper: ${teacherKey.unmatched.take(6).join(', ')}'
            '${teacherKey.unmatched.length > 6 ? ' and ${teacherKey.unmatched.length - 6} more' : ''}.',
      ...teacherKey.warnings,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Frame(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.primarySoft,
                  border: Border.all(color: c.primaryBorder),
                  borderRadius: BorderRadius.circular(AppTheme.controlRadius),
                ),
                child: Icon(Icons.key_outlined, size: 16, color: c.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      teacherKey.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.small.copyWith(fontWeight: FontWeight.w500),
                    ),
                    Text(detail, key: const Key('answer-key-coverage'), style: context.text.caption),
                  ],
                ),
              ),

            ],
          ),
        ),
        for (final String note in notes.take(3))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.info_outline, size: 14, color: c.warning),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(note, style: context.text.caption)),
              ],
            ),
          ),
        if (notes.length > 3)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 20),
            child: Text('${notes.length - 3} more — see Review key…', style: context.text.faint),
          ),
      ],
    );
  }
}
