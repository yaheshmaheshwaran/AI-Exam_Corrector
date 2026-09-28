import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/syllabus_library_dialog.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

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
      ..sort(
        (Syllabus a, Syllabus b) =>
            (a.addedAt ?? DateTime(0)).compareTo(b.addedAt ?? DateTime(0)),
      );
    for (final Syllabus syllabus in ordered) {
      files.putIfAbsent(syllabus.sourceId, () => <Syllabus>[]).add(syllabus);
    }
    final String? inUse = controller.syllabusInUse?.name;

    return RailSection(
      label: 'Syllabi (${controller.syllabi.length})',
      trailing: TextButton(
        key: const Key('syllabus-section-add'),
        onPressed: busy ? null : controller.addSyllabus,
        child: const Text('Add…'),
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
        child: Container(
          key: const Key('syllabus-section-drop'),
          // Empty, it is as tall as its hint; with files, a fixed list.
          height: files.isEmpty ? null : 150,
          constraints: files.isEmpty
              ? const BoxConstraints(minHeight: 96)
              : null,
          decoration: BoxDecoration(
            color: _hovering
                ? context.colors.primarySoft
                : context.colors.surfaceMuted,
            border: Border.all(
              color: _hovering ? context.colors.primary : context.colors.border,
              width: _hovering ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          ),
          child: controller.isAddingSyllabus
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
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
              ? _Hint(
                  hovering: _hovering,
                  onTap: busy ? null : controller.addSyllabus,
                )
              : Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
                    children: <Widget>[
                      for (final MapEntry<String, List<Syllabus>> file
                          in files.entries)
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

  Future<void> _confirmRemove(
    BuildContext context,
    List<Syllabus> courses,
  ) async {
    final bool sure = await confirmDialog(
      context,
      title: 'Remove this syllabus file?',
      message: courses.length == 1
          ? '${courses.single.name} will no longer be used for marking.'
          : 'All ${courses.length} courses read from ${courses.first.fileName} will '
                'no longer be used for marking.',
    );
    if (sure) await widget.controller.removeSyllabusFile(courses.first.sourceId);
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.hovering, required this.onTap});

  final bool hovering;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.file_download_outlined,
                size: 20,
                color: hovering
                    ? context.colors.primary
                    : context.colors.textFaint,
              ),
              const SizedBox(height: 4),
              Text(
                hovering
                    ? 'Drop to add'
                    : 'Drop syllabus files here, or click to choose',
                textAlign: TextAlign.center,
                style: context.text.small.copyWith(fontWeight: FontWeight.w500),
              ),
              Text(
                'PDF, .pptx, .docx, .txt or .md',
                style: context.text.caption,
              ),
            ],
          ),
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
                color: context.colors.primary,
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
              Tooltip(
                message: added == null
                    ? ''
                    : 'Added ${added.toString().substring(0, 10)}',
                child: Text(
                  courses.length == 1
                      ? '1 course'
                      : '${courses.length} courses',
                  style: context.text.caption,
                ),
              ),
              IconButton(
                tooltip: 'Remove this file',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 16),
                onPressed: busy ? null : onRemove,
              ),
            ],
          ),
          for (final String note in <String>{
            for (final Syllabus c in courses) ...c.notes,
          })
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 4, 2),
              child: Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.colors.warning,
                  fontSize: 12,
                ),
              ),
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
                      // Shrinks before the rail overflows.
                      const Flexible(
                        child: StatusPill(
                          label: 'used for this paper',
                          tone: ToneKind.success,
                          dense: true,
                          outlined: false,
                        ),
                      ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.visibility_outlined,
                      size: 14,
                      color: context.colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
