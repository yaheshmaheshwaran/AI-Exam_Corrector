import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/widgets/section_card.dart';

/// Step 1 — choose the student's exam paper.
///
/// Extraction happens as soon as a file is chosen, so an unreadable PDF is
/// caught here rather than at correction time.
class PdfUpload extends StatelessWidget {
  const PdfUpload({
    super.key,
    required this.paper,
    required this.isLoading,
    required this.onChoose,
  });

  final ExamPaper? paper;
  final bool isLoading;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final ExamPaper? loaded = paper;
    final bool ready = loaded != null && !isLoading;

    return SectionCard(
      title: '1. Student exam paper (PDF)',
      trailing: OutlinedButton.icon(
        onPressed: onChoose,
        icon: const Icon(Icons.folder_open_outlined, size: 16),
        label: const Text('Choose PDF…'),
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
                ready ? Icons.check_circle : Icons.picture_as_pdf_outlined,
                size: 16,
                color: ready ? AppTheme.success : AppTheme.textSecondary,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _label(loaded),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color:
                          ready ? const Color(0xFF0B5A0B) : AppTheme.textSecondary,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(ExamPaper? paper) {
    if (isLoading) return 'Reading the exam paper…';
    if (paper == null) return 'No file selected.';
    return '${paper.fileName}  '
        '(${formatCount(paper.characterCount)} characters extracted)';
  }
}
