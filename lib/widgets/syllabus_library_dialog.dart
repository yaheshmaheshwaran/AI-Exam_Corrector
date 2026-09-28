import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/app_dialog.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/widgets/ui/confirm_dialog.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/state/correction_controller.dart';

/// The teacher's saved syllabi, one per subject.
///
/// Each is read once when uploaded; "View" shows the units and topics as
/// they were read, so the teacher can see exactly what marking is given.
class SyllabusLibraryDialog extends StatelessWidget {
  const SyllabusLibraryDialog({super.key, required this.controller});

  final CorrectionController controller;

  static Future<void> show(BuildContext context, CorrectionController controller) =>
      showAppDialog<void>(
        context: context,
        builder: (BuildContext context) => SyllabusLibraryDialog(controller: controller),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        final List<Syllabus> syllabi = controller.syllabi;
        return AlertDialog(
          title: const Text('Syllabi'),
          content: SizedBox(
            width: 620,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  "Upload each subject's syllabus once. When a question paper is "
                  'chosen, its syllabus is matched automatically. Marking uses it '
                  "as a reference for what the course teaches and how deeply — "
                  'never as an answer key, so correct answers beyond it still earn '
                  'marks.',
                  style: context.text.caption,
                ),
                const SizedBox(height: 12),
                _DropZone(controller: controller),
                const SizedBox(height: 12),
                Expanded(
                  child: syllabi.isEmpty
                      ? Center(
                          child: Text(
                            'No syllabi yet.',
                            textAlign: TextAlign.center,
                            style: context.text.muted,
                          ),
                        )
                      : ListView(
                          children: <Widget>[
                            for (final Syllabus syllabus in syllabi)
                              _Entry(syllabus: syllabus, controller: controller),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            OutlinedButton.icon(
              key: const Key('syllabus-upload'),
              onPressed: controller.isBusy ? null : controller.addSyllabus,
              icon: controller.isChoosing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file_outlined, size: 16),
              label: const Text('Upload…'),
            ),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ],
        );
      },
    );
  }
}

/// Where syllabus files are dropped from Finder or Explorer — several at a
/// time — or chosen with a click.
class _DropZone extends StatefulWidget {
  const _DropZone({required this.controller});

  final CorrectionController controller;

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CorrectionController controller = widget.controller;
    final bool busy = controller.isBusy;
    final Color edge = _hovering ? context.colors.primary : context.colors.border;

    return DropTarget(
      enable: !busy,
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (DropDoneDetails details) {
        setState(() => _hovering = false);
        controller.addSyllabusFiles(<String>[
          for (final DropItem item in details.files) item.path,
        ]);
      },
      child: InkWell(
        key: const Key('syllabus-drop-zone'),
        onTap: busy ? null : controller.addSyllabus,
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 92),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: _hovering ? context.colors.primarySoft : context.colors.surfaceMuted,
            border: Border.all(color: edge, width: _hovering ? 2 : 1),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          ),
          child: Center(
            child: busy
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(controller.statusMessage,
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                      ),
                      if (controller.isAddingSyllabus)
                        TextButton(onPressed: controller.cancelSyllabusReading, child: const Text('Cancel')),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.file_download_outlined, size: 26, color: _hovering ? context.colors.primary : context.colors.textMuted),
                      const SizedBox(height: 4),
                      Text(
                        _hovering ? 'Drop to add' : 'Drop syllabus files here, or click to choose',
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'PDF, PowerPoint (.pptx), Word (.docx), .txt or .md — several at once is fine',
                        style: context.text.caption,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.syllabus, required this.controller});

  final Syllabus syllabus;
  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime? added = syllabus.addedAt;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: ValueKey<String>('syllabus-${syllabus.id}'),
        title: Text(syllabus.name, style: theme.textTheme.titleSmall),
        subtitle: Text(
          <String>[
            '${syllabus.units.length} unit${syllabus.units.length == 1 ? '' : 's'}',
            if (syllabus.regulation.isNotEmpty) syllabus.regulation,
            syllabus.fileName,
            if (added != null) 'added ${added.toString().substring(0, 10)}',
            if (syllabus.structuredBy == 'model') 'read by the AI',
          ].join(' · '),
          style: context.text.caption,
        ),
        trailing: Wrap(
          spacing: 2,
          children: <Widget>[
            IconButton(
              tooltip: 'View what was read',
              icon: const Icon(Icons.visibility_outlined, size: 18),
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (BuildContext context) => SyllabusView(syllabus: syllabus),
              ),
            ),
            IconButton(
              tooltip: 'Edit course title and code',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _edit(context),
            ),
            IconButton(
              key: ValueKey<String>('syllabus-remove-${syllabus.id}'),
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: controller.isBusy ? null : () => _remove(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final bool sure = await confirmDialog(
      context,
      title: 'Remove this syllabus?',
      message: '${syllabus.name} will no longer be used for marking. '
          'Papers already marked keep their marks until re-marked.',
    );
    if (sure) await controller.removeSyllabus(syllabus.id);
  }

  Future<void> _edit(BuildContext context) async {
    final ({String title, String code})? chosen = await showAppDialog<({String title, String code})>(
      context: context,
      builder: (BuildContext context) => _EditCourseDialog(syllabus: syllabus),
    );
    if (chosen != null) {
      await controller.updateSyllabus(syllabus.id, courseTitle: chosen.title, courseCode: chosen.code);
    }
  }
}

/// The course title and code, which matching relies on. Owns its fields'
/// controllers, so they outlive the dialog's closing animation.
class _EditCourseDialog extends StatefulWidget {
  const _EditCourseDialog({required this.syllabus});

  final Syllabus syllabus;

  @override
  State<_EditCourseDialog> createState() => _EditCourseDialogState();
}

class _EditCourseDialogState extends State<_EditCourseDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.syllabus.courseTitle);
  late final TextEditingController _code = TextEditingController(text: widget.syllabus.courseCode);

  @override
  void dispose() {
    _title.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Course title and code'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Matching a question paper to this syllabus relies on these. '
                'Use them as they are printed on your question papers.'),
            const SizedBox(height: 12),
            TextField(controller: _title, decoration: const InputDecoration(labelText: 'Course title')),
            const SizedBox(height: 8),
            TextField(controller: _code, decoration: const InputDecoration(labelText: 'Course code')),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((title: _title.text, code: _code.text)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The syllabus as it was read: units, topics, outcomes and books.
class SyllabusView extends StatelessWidget {
  const SyllabusView({super.key, required this.syllabus});

  static Future<void> show(BuildContext context, Syllabus syllabus) => showAppDialog<void>(
        context: context,
        builder: (BuildContext context) => SyllabusView(syllabus: syllabus),
      );

  final Syllabus syllabus;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(syllabus.name),
      content: SizedBox(
        width: 640,
        height: 480,
        child: ListView(
          children: <Widget>[
            for (final String note in syllabus.notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(note, style: theme.textTheme.bodySmall?.copyWith(color: context.colors.warning)),
              ),
            for (final SyllabusUnit unit in syllabus.units) ...<Widget>[
              Text(
                '${unit.label}${unit.hours == null ? '' : '  ·  ${unit.hours} hours'}',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final String topic in unit.topics)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 2),
                  child: Text('•  $topic', style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: 10),
            ],
            if (syllabus.outcomes.isNotEmpty) ...<Widget>[
              Text('Course outcomes', style: theme.textTheme.titleSmall),
              for (final String outcome in syllabus.outcomes)
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Text(outcome, style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: 10),
            ],
            if (syllabus.textbooks.isNotEmpty) ...<Widget>[
              Text('Books', style: theme.textTheme.titleSmall),
              for (final String book in syllabus.textbooks)
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Text(book, style: theme.textTheme.bodySmall),
                ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
