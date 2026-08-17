import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/widgets/section_card.dart';

/// One of the two documents a correction needs.
///
/// Both slots use this: the student's answer sheet and the question paper are
/// chosen and extracted identically, and differ only in what they are called
/// and what the teacher is told to pick. Extraction happens as soon as a file
/// is chosen, so an unreadable file is caught here rather than at marking time.
class PdfUpload extends StatelessWidget {
  const PdfUpload({
    super.key,
    required this.title,
    required this.hint,
    required this.paper,
    required this.isLoading,
    required this.onChoose,
    this.onReviewTranscript,
  });

  final String title;

  /// What to choose, shown while the slot is empty.
  final String hint;

  final ExamPaper? paper;
  final bool isLoading;
  final VoidCallback? onChoose;

  /// Offered once a document has been recognised from handwriting, so the
  /// teacher can go back to the transcript after accepting it.
  final VoidCallback? onReviewTranscript;

  @override
  Widget build(BuildContext context) {
    final ExamPaper? loaded = paper;
    final bool ready = loaded != null && !isLoading;
    final bool recognised = ready && loaded.isHandwritten;

    return SectionCard(
      title: title,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (recognised && onReviewTranscript != null) ...<Widget>[
            OutlinedButton.icon(
              onPressed: onReviewTranscript,
              icon: const Icon(Icons.fact_check_outlined, size: 16),
              label: const Text('Transcript'),
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton.icon(
            onPressed: onChoose,
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            label: const Text('Choose…'),
          ),
        ],
      ),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: ready ? AppTheme.successFill : AppTheme.subtleBackground,
          border: Border.all(
            color: ready ? const Color(0xFFBFE3BC) : AppTheme.stroke,
          ),
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        ),
        child: Row(
          children: <Widget>[
            if (isLoading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                ready
                    ? (recognised ? Icons.draw_outlined : Icons.check_circle)
                    : Icons.picture_as_pdf_outlined,
                size: 16,
                color: ready ? AppTheme.success : AppTheme.textSecondary,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _label(loaded),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: ready
                          ? const Color(0xFF0B5A0B)
                          : AppTheme.textSecondary,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(ExamPaper? paper) {
    if (isLoading) return 'Reading…';
    if (paper == null) return hint;

    // Saying the text was recognised rather than extracted matters: it tells
    // the teacher why the transcript button is there and why it is worth using.
    final String how = paper.isHandwritten
        ? '${formatCount(paper.characterCount)} characters recognised'
        : '${formatCount(paper.characterCount)} characters extracted';

    return '${paper.fileName}  ($how)';
  }
}
