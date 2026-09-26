import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/widgets/section_card.dart';

/// One of the two documents a correction needs.
///
/// Both slots use this. A chosen file is checked straight away — readable,
/// not encrypted, how many pages, typed or scanned — so a bad file is refused
/// here rather than minutes into processing.
class PdfUpload extends StatelessWidget {
  const PdfUpload({
    super.key,
    required this.title,
    required this.hint,
    required this.document,
    required this.isLoading,
    required this.onChoose,
    this.summary,
    this.onAdd,
    this.footer,
  });

  /// Shown under the file: for the question paper, the syllabus it is marked
  /// against.
  final Widget? footer;

  /// Shown instead of the file name — for a class set of scripts.
  final String? summary;

  /// Adds more files to those chosen.
  final VoidCallback? onAdd;

  final String title;

  /// What to choose, shown while the slot is empty.
  final String hint;

  final SelectedDocument? document;
  final bool isLoading;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final SelectedDocument? chosen = document;
    final bool ready = chosen != null && !isLoading;

    return SectionCard(
      title: title,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (onAdd != null) ...<Widget>[
            IconButton(
              tooltip: 'Add more scripts',
              onPressed: onAdd,
              icon: const Icon(Icons.library_add_outlined, size: 18),
            ),
            const SizedBox(width: 4),
          ],
          OutlinedButton.icon(
            onPressed: onChoose,
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            label: const Text('Choose…'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _file(context, chosen, ready),
          if (footer != null) ...<Widget>[const SizedBox(height: 6), footer!],
        ],
      ),
    );
  }

  Widget _file(BuildContext context, SelectedDocument? chosen, bool ready) {
    return Container(
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
                    ? ((chosen?.needsRendering ?? false) ? Icons.draw_outlined : Icons.check_circle)
                    : Icons.picture_as_pdf_outlined,
                size: 16,
                color: ready ? AppTheme.success : AppTheme.textSecondary,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _label(chosen),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: ready ? const Color(0xFF0B5A0B) : AppTheme.textSecondary,
                    ),
              ),
            ),
          ],
        ),
      );
  }

  String _label(SelectedDocument? document) {
    if (isLoading) return 'Checking…';
    if (summary != null) return summary!;
    if (document == null) return hint;

    final String pages =
        '${document.pageCount} page${document.pageCount == 1 ? '' : 's'}';
    // Saying scanned rather than typed tells the teacher which path the paper
    // will take, and why it may take longer.
    final String kind = switch (document.source) {
      DocumentSource.textLayer => 'typed',
      DocumentSource.scanned => 'scanned — handwriting will be read',
      DocumentSource.mixed => '${document.textLayerPages} typed, '
          '${document.pageCount - document.textLayerPages} scanned',
      DocumentSource.image => 'photograph — handwriting will be read',
    };
    return '${document.fileName}  ($pages, $kind)';
  }
}
