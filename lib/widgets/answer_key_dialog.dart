import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';

/// The paper's answer key, question by question, for the teacher to check
/// and correct — as a chief examiner settles the scheme before marking.
///
/// Returns the key text for each question, or null when cancelled. Owns its
/// text fields' controllers, so they outlive the closing animation.
class AnswerKeyDialog extends StatefulWidget {
  const AnswerKeyDialog({super.key, required this.paper, this.answerKey});

  final QuestionPaper paper;
  final AnswerKey? answerKey;

  static Future<Map<String, String>?> show(
    BuildContext context, {
    required QuestionPaper paper,
    AnswerKey? key,
  }) =>
      showDialog<Map<String, String>>(
        context: context,
        builder: (BuildContext context) => AnswerKeyDialog(paper: paper, answerKey: key),
      );

  @override
  State<AnswerKeyDialog> createState() => _AnswerKeyDialogState();
}

class _AnswerKeyDialogState extends State<AnswerKeyDialog> {
  late final List<Question> _questions = <Question>[
    for (final Question q in widget.paper.markable)
      if (widget.paper.markSchemeFor(q).trim().isEmpty) q,
  ];
  late final int _printed = widget.paper.markable.length - _questions.length;
  late final Map<String, TextEditingController> _text = <String, TextEditingController>{
    for (final Question q in _questions)
      q.questionId: TextEditingController(text: widget.answerKey?.textFor(q.questionId) ?? ''),
  };

  @override
  void dispose() {
    for (final TextEditingController c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _aiKey(String id) => widget.answerKey?.entries[id]?.text ?? '';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? small = theme.textTheme.bodySmall;
    return AlertDialog(
      title: const Text('Answer key'),
      content: SizedBox(
        width: 720,
        height: 560,
        child: _questions.isEmpty
            ? Text('The question paper prints a mark scheme for every question — marking follows it.',
                style: theme.textTheme.bodyMedium)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Prepared from the questions alone, before any answer was read, so every script '
                    'is marked against the same points. Correct anything a real examiner would not '
                    'accept — the marks each point is worth, what earns them, how long a full answer '
                    'is ("about 300 words"). Changes apply when the scripts are re-marked.'
                    '${_printed > 0 ? ' $_printed question${_printed == 1 ? '' : 's'} with a printed mark scheme follow it instead.' : ''}',
                    style: small?.copyWith(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (final Question q in _questions) _question(q, theme),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('answer-key-save'),
          onPressed: _questions.isEmpty
              ? null
              : () => Navigator.of(context).pop(<String, String>{
                    for (final MapEntry<String, TextEditingController> e in _text.entries) e.key: e.value.text,
                  }),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _question(Question q, ThemeData theme) {
    final TextEditingController text = _text[q.questionId]!;
    final String ai = _aiKey(q.questionId);
    final bool edited = text.text.trim() != ai.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Question ${q.displayNumber} · ${formatMarks(q.maximumMarks ?? 0)} marks'
                  '${q.questionText.trim().isEmpty ? '' : ' — ${q.questionText.trim()}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (edited && ai.isNotEmpty)
                TextButton(
                  key: ValueKey<String>('answer-key-reset-${q.questionId}'),
                  onPressed: () => setState(() => text.text = ai),
                  child: const Text('Use the AI’s key'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            key: ValueKey<String>('answer-key-${q.questionId}'),
            controller: text,
            minLines: 3,
            maxLines: 8,
            onChanged: (_) => setState(() {}),
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              hintText: ai.isEmpty
                  ? 'No key yet — write the points a full answer needs, with their marks.'
                  : null,
              helperText: edited ? 'Your key — used in place of the AI’s.' : null,
              contentPadding: const EdgeInsets.all(10),
            ),
          ),
        ],
      ),
    );
  }
}
