import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/section_card.dart';
import 'package:exam_corrector/widgets/syllabus_library_dialog.dart';

/// The uploaded syllabus files, always in view on the main screen: each file,
/// the courses read from it, and which one the chosen paper is marked
/// against. Files are dropped straight onto it.
class SyllabusSection extends StatefulWidget {
  const SyllabusSection({super.key, required this.controller});

  final CorrectionController controller;

  @override
  State<SyllabusSection> createState() => _SyllabusSectionState();
}

class _SyllabusSectionState extends State<SyllabusSection> {
  bool _hovering = false;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CorrectionController controller = widget.controller;
    final bool busy = controller.isBusy;

    // Courses grouped by the file they were read from, in upload order.
    final Map<String, List<Syllabus>> files = <String, List<Syllabus>>{};
    final List<Syllabus> ordered = List<Syllabus>.of(controller.syllabi)
      ..sort((Syllabus a, Syllabus b) =>
          (a.addedAt ?? DateTime(0)).compareTo(b.addedAt ?? DateTime(0)));
    for (final Syllabus syllabus in ordered) {
      files.putIfAbsent(syllabus.sourceId, () => <Syllabus>[]).add(syllabus);
    }
    final String? inUse = controller.syllabusInUse?.name;

    return SectionCard(
      title: 'Syllabi (${controller.syllabi.length})',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          OutlinedButton.icon(
            key: const Key('syllabus-section-add'),
            onPressed: busy ? null : controller.addSyllabus,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: const Text('Add…'),
          ),
        ],
      ),
      child: DropTarget(
        enable: !busy,
        onDragEntered: (_) => setState(() => _hovering = true),
        onDragExited: (_) => setState(() => _hovering = false),
        onDragDone: (DropDoneDetails details) {
          setState(() => _hovering = false);
          controller.addSyllabusFiles(<String>[
            for (final DropItem item in details.files) item.path,
          ]);
        },
        child: AnimatedContainer(
          key: const Key('syllabus-section-drop'),
          duration: const Duration(milliseconds: 120),
          height: 118,
          decoration: BoxDecoration(
            color: _hovering ? const Color(0xFFEAF3FC) : null,
            border: Border.all(
              color: _hovering ? AppTheme.accent : AppTheme.stroke,
              width: _hovering ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          ),
          child: controller.isAddingSyllabus
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          controller.statusMessage,
                          key: const Key('syllabus-progress'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        key: const Key('syllabus-cancel'),
                        onPressed: controller.cancelSyllabusReading,
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                )
              : files.isEmpty || _hovering
                  ? _Hint(hovering: _hovering, onTap: busy ? null : controller.addSyllabus)
                  : Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
                        children: <Widget>[
                          for (final MapEntry<String, List<Syllabus>> file in files.entries)
                            _File(
                              courses: file.value,
                              inUse: inUse,
                              busy: busy,
                              onRemove: () => _confirmRemove(context, file.value),
                            ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, List<Syllabus> courses) async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove this syllabus file?'),
        content: Text(courses.length == 1
            ? '${courses.single.name} will no longer be used for marking.'
            : 'All ${courses.length} courses read from ${courses.first.fileName} will '
                'no longer be used for marking.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure ?? false) await widget.controller.removeSyllabusFile(courses.first.sourceId);
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.hovering, required this.onTap});

  final bool hovering;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.file_download_outlined,
                size: 24, color: hovering ? AppTheme.accent : AppTheme.textSecondary),
            const SizedBox(height: 4),
            Text(hovering ? 'Drop to add' : 'Drop syllabus files here, or click to choose',
                style: theme.textTheme.titleSmall),
            Text('PDF, PowerPoint (.pptx), Word (.docx), .txt or .md',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// One uploaded file and the courses read from it.
class _File extends StatelessWidget {
  const _File({
    required this.courses,
    required this.inUse,
    required this.busy,
    required this.onRemove,
  });

  final List<Syllabus> courses;
  final String? inUse;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Syllabus first = courses.first;
    final DateTime? added = first.addedAt;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                switch (first.fileName.split('.').last.toLowerCase()) {
                  'pdf' => Icons.picture_as_pdf_outlined,
                  'pptx' => Icons.slideshow_outlined,
                  _ => Icons.description_outlined,
                },
                size: 16,
                color: AppTheme.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  first.fileName,
                  key: ValueKey<String>('syllabus-file-${first.sourceId}'),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                '${courses.length == 1 ? '1 course' : '${courses.length} courses'}'
                '${added == null ? '' : ' · ${added.toString().substring(0, 10)}'}',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
              IconButton(
                tooltip: 'Remove this file',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 16),
                onPressed: busy ? null : onRemove,
              ),
            ],
          ),
          for (final String note in <String>{for (final Syllabus c in courses) ...c.notes})
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 4, 2),
              child: Text(note,
                  style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.caution, fontSize: 11)),
            ),
          for (final Syllabus course in courses)
            InkWell(
              key: ValueKey<String>('syllabus-course-${course.id}'),
              onTap: () => SyllabusView.show(context, course),
              borderRadius: BorderRadius.circular(AppTheme.controlRadius),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 2, 4, 2),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${course.name} · ${course.units.length} '
                        'unit${course.units.length == 1 ? '' : 's'}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (inUse == course.name)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppTheme.successFill,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('used for this paper',
                            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.success, fontSize: 11)),
                      ),
                    const SizedBox(width: 4),
                    const Icon(Icons.visibility_outlined, size: 14, color: AppTheme.textSecondary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
