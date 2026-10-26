import 'package:flutter/material.dart';

import 'package:exam_corrector/shared/ui/app_dialog.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/marking/exam/answer_key.dart';
import 'package:exam_corrector/shared/ui/status_pill.dart';

/// What the teacher did with the key: their text for each question, and
/// whether they have checked the AI's part of it.
typedef AnswerKeyReview = ({Map<String, String> edits, bool checked});

/// The paper's answer key, question by question, for the teacher to check
/// and correct — as a chief examiner settles the scheme before marking.
///
/// Checking is optional: marking does not wait for it. Returns the key text
/// for each question and whether the AI's key was checked, or null when
/// cancelled. Owns its text fields' controllers, so they outlive the closing
/// animation.
class AnswerKeyDialog extends StatefulWidget {
  const AnswerKeyDialog({super.key, required this.paper, this.answerKey, this.aiStatus});

  final QuestionPaper paper;
  final AnswerKey? answerKey;

  /// Who wrote the AI's part of the key and whether it was checked; null
  /// when no question is marked against an AI key.
  final ({String writer, bool checked})? aiStatus;

  static Future<AnswerKeyReview?> show(
    BuildContext context, {
    required QuestionPaper paper,
    AnswerKey? key,
    ({String writer, bool checked})? aiStatus,
  }) =>
      showAppDialog<AnswerKeyReview>(
        context: context,
        builder: (BuildContext context) => AnswerKeyDialog(paper: paper, answerKey: key, aiStatus: aiStatus),
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
  late bool _checked = widget.aiStatus?.checked ?? false;
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

  /// The key before the teacher's corrections: their own key, else the AI's.
  String _base(String id) => widget.answerKey?.baseTextFor(id) ?? '';

  bool _fromTeacherKey(String id) => !(widget.answerKey?.teacher[id]?.isEmpty ?? true);

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
                    'Questions your answer key covers are marked against it; the rest use a key the AI '
                    'prepares from the questions alone, before any answer is read. Correct anything a '
                    'real examiner would not accept — the marks each point is worth, what earns them, how '
                    'long a full answer is ("about 300 words"). Changes apply when the scripts are re-marked.'
                    '${_printed > 0 ? ' $_printed question${_printed == 1 ? '' : 's'} with a printed mark scheme follow it instead.' : ''}',
                    style: small?.copyWith(color: context.colors.textMuted),
                  ),
                  if (widget.aiStatus case final ({String writer, bool checked}) ai) ...<Widget>[
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        StatusPill(
                          key: const Key('answer-key-writer'),
                          label: ai.writer.isEmpty ? 'AI key' : 'AI key by ${ai.writer}',
                          tone: _checked ? ToneKind.success : ToneKind.warning,
                          dense: true,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: CheckboxListTile(
                            key: const Key('answer-key-checked'),
                            value: _checked,
                            onChanged: (bool? value) => setState(() => _checked = value ?? false),
                            title: Text("I have checked the AI's key", style: theme.textTheme.bodyMedium),
                            subtitle: Text('Optional — marking does not wait for it.', style: small),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                          ),
                        ),
                      ],
                    ),
                  ],
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
              : () => Navigator.of(context).pop((
                    edits: <String, String>{
                      for (final MapEntry<String, TextEditingController> e in _text.entries) e.key: e.value.text,
                    },
                    checked: _checked,
                  )),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _question(Question q, ThemeData theme) {
    final TextEditingController text = _text[q.questionId]!;
    final String ai = _base(q.questionId);
    final bool edited = text.text.trim() != ai.trim();
    final bool own = _fromTeacherKey(q.questionId);
    final (String label, ToneKind tone) source = edited && text.text.trim().isNotEmpty
        ? ('Your correction', ToneKind.primary)
        : own
            ? ('Your key', ToneKind.success)
            : ai.isNotEmpty
                ? ('AI key', ToneKind.neutral)
                : ('Prepared when marking starts', ToneKind.neutral);
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
              const SizedBox(width: 8),
              StatusPill(
                key: ValueKey<String>('answer-key-source-${q.questionId}'),
                label: source.$1,
                tone: source.$2,
                dense: true,
              ),
              if (edited && ai.isNotEmpty)
                TextButton(
                  key: ValueKey<String>('answer-key-reset-${q.questionId}'),
                  onPressed: () => setState(() => text.text = ai),
                  child: Text(own ? 'Use your key' : 'Use the AI’s key'),
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
              helperText: edited ? (own ? 'Your correction — used in place of your key.' : 'Your key — used in place of the AI’s.') : null,
              contentPadding: const EdgeInsets.all(10),
            ),
          ),
        ],
      ),
    );
  }
}
