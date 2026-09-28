import 'package:flutter/material.dart';

import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// One of the two documents a correction needs, as a step in the setup rail.
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

    return RailSection(
      label: title,
      status: (chosen != null || summary != null) && !isLoading ? RailStatus.ready : RailStatus.pending,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (onAdd != null)
            IconButton(
              tooltip: 'Add more scripts',
              onPressed: onAdd,
              icon: const Icon(Icons.library_add_outlined),
            ),
          TextButton(onPressed: onChoose, child: const Text('Choose…')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _file(context, chosen),
          if (footer != null) ...<Widget>[const SizedBox(height: 8), footer!],
        ],
      ),
    );
  }

  Widget _file(BuildContext context, SelectedDocument? chosen) {
    final AppColors c = context.colors;
    final bool ready = (chosen != null || summary != null) && !isLoading;
    final ({String name, String? detail}) label = _label(chosen);

    if (isLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        ),
        child: const Skeleton(
          label: 'Checking the file',
          child: Row(
            children: <Widget>[
              Bone(width: 18, height: 18, radius: 4),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FractionallySizedBox(widthFactor: 0.6, child: Bone(height: 11)),
                    SizedBox(height: 7),
                    FractionallySizedBox(widthFactor: 0.85, child: Bone(height: 9)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!ready) {
      return DropFrame(
        icon: Icons.upload_file_outlined,
        title: 'No file chosen',
        detail: _label(chosen).name,
        onTap: onChoose,
      );
    }

    // A chosen file: what kind it is, its name, and what was found in it.
    final String kind = summary != null
        ? 'SET'
        : (chosen?.fileName.split('.').last.toLowerCase() ?? '') == 'pdf'
            ? 'PDF'
            : 'IMG';
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
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
            child: Text(
              kind,
              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: c.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.small.copyWith(fontWeight: FontWeight.w500, color: c.text),
                ),
                if (label.detail case final String detail) ...<Widget>[
                  const SizedBox(height: 1),
                  Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.caption),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  ({String name, String? detail}) _label(SelectedDocument? document) {
    if (isLoading) return (name: 'Checking…', detail: null);
    if (summary != null) return (name: summary!, detail: null);
    if (document == null) return (name: hint, detail: null);

    final String pages = '${document.pageCount} page${document.pageCount == 1 ? '' : 's'}';
    // Saying scanned rather than typed tells the teacher which path the paper
    // will take, and why it may take longer.
    final String kind = switch (document.source) {
      DocumentSource.textLayer => 'typed',
      DocumentSource.scanned => 'scanned — handwriting will be read',
      DocumentSource.mixed => '${document.textLayerPages} typed, '
          '${document.pageCount - document.textLayerPages} scanned',
      DocumentSource.image => 'photograph — handwriting will be read',
    };
    return (name: document.fileName, detail: '$pages · $kind');
  }
}
