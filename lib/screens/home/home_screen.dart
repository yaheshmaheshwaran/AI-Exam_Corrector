import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/screens/inspector/page_inspector_screen.dart';
import 'package:exam_corrector/screens/requests/requests_screen.dart';
import 'package:exam_corrector/screens/students/student_status_screen.dart';
import 'package:exam_corrector/screens/results/question_detail_screen.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/answer_key_dialog.dart';
import 'package:exam_corrector/widgets/moderation_chip.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/widgets/class_results_view.dart';
import 'package:exam_corrector/widgets/correction_progress.dart';
import 'package:exam_corrector/widgets/guidance_input.dart';
import 'package:exam_corrector/widgets/marking_standard_dialog.dart';
import 'package:exam_corrector/widgets/model_usage_indicator.dart';
import 'package:exam_corrector/widgets/pdf_upload.dart';
import 'package:exam_corrector/widgets/processing_panel.dart';
import 'package:exam_corrector/widgets/results_view.dart';
import 'package:exam_corrector/widgets/section_card.dart';
import 'package:exam_corrector/widgets/settings_dialog.dart';
import 'package:exam_corrector/widgets/syllabus_library_dialog.dart';
import 'package:exam_corrector/widgets/syllabus_section.dart';

/// The main window: command bar, four workflow steps, status bar.
///
/// The screen owns no marking logic. It collects input, calls the controller,
/// shows processing as it happens, and opens each question's evidence.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.onSwitchRole});

  final CorrectionController controller;

  /// Back to choosing a role; null when there is only the teacher.
  final VoidCallback? onSwitchRole;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _guidanceField;
  bool _showingError = false;

  /// Below this height the workflow no longer fits, so the page scrolls
  /// instead of overflowing, and the results get a fixed, usable height.
  static const double _comfortableHeight = 760;

  @override
  void initState() {
    super.initState();
    _guidanceField =
        TextEditingController(text: widget.controller.guidance.text);
    widget.controller.addListener(_onControllerChanged);
    // Students may have asked for corrections since the teacher last looked.
    widget.controller.refreshRequests();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _guidanceField.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    // Keep the field in step when the guidance changes from outside it —
    // cleared, most often.
    final String text = widget.controller.guidance.text;
    if (_guidanceField.text != text) {
      _guidanceField.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    final String? error = widget.controller.pendingError;
    if (error != null && !_showingError) {
      _showingError = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showError(error));
    }
  }

  Future<void> _export() async {
    final ReportFormat? format = await showDialog<ReportFormat>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('Export the marks'),
        children: <Widget>[
          for (final ReportFormat format in ReportFormat.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(format),
              child: Text(format.label),
            ),
        ],
      ),
    );
    if (format != null) await widget.controller.exportReport(format);
  }

  /// Asks under which roll number, subject and exam to publish the script
  /// on screen, then publishes it.
  Future<void> _publish(CorrectionController controller) async {
    final MarkedScript? script = controller.currentScript;
    if (script == null) return;
    final ({String rollNo, String subjectCode, String exam}) defaults =
        await controller.publishDefaults(script);
    if (!mounted) return;
    final ({String rollNo, String student, String subjectCode, String exam})? chosen =
        await showDialog<({String rollNo, String student, String subjectCode, String exam})>(
      context: context,
      builder: (BuildContext context) => _PublishDialog(
        fileName: script.document.fileName,
        rollNo: defaults.rollNo,
        subjectCode: defaults.subjectCode,
        exam: defaults.exam,
      ),
    );
    if (chosen == null) return;
    await controller.publishCurrent(
      rollNo: chosen.rollNo,
      student: chosen.student,
      subjectCode: chosen.subjectCode,
      exam: chosen.exam,
    );
  }

  /// Publishes the whole class under one subject and exam, each script under
  /// its own roll number.
  Future<void> _publishClass(CorrectionController controller) async {
    final List<MarkedScript> scripts = controller.scripts;
    final int first = scripts.indexWhere((MarkedScript s) => s.result != null);
    if (first < 0) return;
    final ({String rollNo, String subjectCode, String exam}) defaults =
        await controller.publishDefaults(scripts[first]);
    if (!mounted) return;
    final ({String subjectCode, String exam, Map<int, String> rollNos})? chosen =
        await showDialog<({String subjectCode, String exam, Map<int, String> rollNos})>(
      context: context,
      builder: (BuildContext context) => _PublishClassDialog(
        scripts: scripts,
        subjectCode: defaults.subjectCode,
        exam: defaults.exam,
      ),
    );
    if (chosen == null) return;
    await controller.publishClass(
      subjectCode: chosen.subjectCode,
      exam: chosen.exam,
      rollNos: chosen.rollNos,
    );
  }

  Future<void> _editAnswerKey(CorrectionController controller) async {
    final AnswerKey? key = await controller.answerKey();
    final QuestionPaper? paper = controller.markedPaper;
    if (!mounted || paper == null) return;
    final Map<String, String>? edits = await AnswerKeyDialog.show(context, paper: paper, key: key);
    if (edits != null) await controller.saveAnswerKeyEdits(edits);
  }

    Future<void> _editStandard(CorrectionController controller) async {
    final ({MarkingStandard standard, bool asDefault})? chosen = await MarkingStandardDialog.show(
      context,
      controller.markingStandard,
      sections: <String>[
        for (final QuestionSection section
            in controller.assessment?.questionPaper.sections ?? const <QuestionSection>[])
          section.sectionId,
      ],
    );
    if (chosen != null) {
      await controller.setMarkingStandard(chosen.standard, asDefault: chosen.asDefault);
    }
  }

  Future<void> _showError(String message) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Row(
          children: <Widget>[
            Icon(Icons.error_outline, color: AppTheme.danger, size: 20),
            SizedBox(width: 10),
            Text('Correction could not continue'),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );

    _showingError = false;
    widget.controller.clearError();
  }

  @override
  Widget build(BuildContext context) {
    final CorrectionController controller = widget.controller;

    return Scaffold(
      body: ListenableBuilder(
        listenable: controller,
        builder: (BuildContext context, _) {
          return Column(
            children: <Widget>[
              _CommandBar(
                model: controller.config.model,
                hasApiKey: controller.config.hasApiKey,
                onSettings: () => SettingsDialog.show(context, controller),
                onSyllabi: controller.hasSyllabusLibrary
                    ? () => SyllabusLibraryDialog.show(context, controller)
                    : null,
                usage: controller.usage == null
                    ? null
                    : ModelUsageIndicator(config: controller.config, usage: controller.usage!),
                onSwitchRole: widget.onSwitchRole,
                openRequests: controller.canPublish ? controller.openRequestCount : null,
                onRequests: controller.canPublish ? () => RequestsScreen.open(context, controller) : null,
                onStudents: controller.canPublish ? () => StudentStatusScreen.open(context, controller) : null,
              ),
              Expanded(child: _workflow(controller)),
              CorrectionProgress(
                statusMessage: controller.statusMessage,
                isError: controller.statusIsError,
                isCorrecting: false,
                isTranscribing: controller.isProcessing,
                transcriptionProgress: controller.job?.overallFraction ?? 0,
                correctLabel: controller.isClass
                    ? 'Mark all ${controller.scripts.length} scripts'
                    : 'Correct paper',
                onCorrect: !controller.canCorrect
                    ? null
                    : controller.isClass
                        ? controller.markAll
                        : controller.startCorrection,
                onCancel: controller.isProcessing ? controller.cancelProcessing : null,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _workflow(CorrectionController controller) {
    final bool busy = controller.isBusy;

    final List<MarkedScript> scripts = controller.scripts;
    final Widget answerSheet = PdfUpload(
      title: controller.isClass
          ? "1. Students' answer sheets"
          : "1. Student's answer sheet",
      hint: 'No file selected. Choose the completed script — or select a '
          "whole class's scripts at once (PDF or photo).",
      document: controller.answerSheet,
      summary: controller.isClass
          ? '${scripts.length} answer sheets · '
              '${scripts.where((MarkedScript s) => s.document.needsRendering).length} scanned'
          : null,
      isLoading: controller.isChoosing && controller.answerSheet == null,
      onChoose: busy ? null : controller.chooseAnswerSheet,
      onAdd: busy || scripts.isEmpty ? null : controller.addAnswerSheets,
    );

    final Widget questionPaper = PdfUpload(
      title: '2. Question paper',
      hint: 'No file selected. Choose the paper with the questions and marks. '
          'If it includes the mark scheme or answers, marking follows them.',
      document: controller.questionPaper,
      isLoading: controller.isChoosing && controller.questionPaper == null,
      onChoose: busy ? null : controller.chooseQuestionPaper,
      footer: controller.hasSyllabusLibrary && controller.questionPaper != null
          ? _SyllabusLine(controller: controller)
          : null,
    );

    final Widget guidance = GuidanceInput(
      controller: _guidanceField,
      onChanged: controller.setGuidance,
      onClear: busy ? null : controller.clearGuidance,
      onLoadFile: busy ? null : controller.loadGuidanceFile,
      sourceFile: controller.guidanceFile,
      paperScheme: controller.paperScheme,
      standard: controller.hasMarkingStandards ? controller.markingStandard : null,
      onLevel: busy
          ? null
          : (MarkingLevel level) =>
              controller.setMarkingStandard(controller.markingStandard.copyWith(level: level)),
      onRules: busy ? null : () => _editStandard(controller),
      onAnswerKey: busy || controller.markedPaper == null ? null : () => _editAnswerKey(controller),
      moderation: controller.hasMarkingStandards && controller.markedPaper != null
          ? ModerationChip(
              applied: controller.moderation,
              suggested: controller.suggestedModeration,
              samples: controller.moderationSampleCount,
              agreement: controller.agreement,
              onApply: busy ? null : controller.applyModeration,
              onRemove: busy ? null : controller.removeModeration,
            )
          : null,
    );

    final ExamAssessment? assessment = controller.assessment;
    final ProcessingJob? job = controller.job;
    final int? position = controller.batchPosition;
    final Widget body;
    final Widget? actions;
    if (controller.isProcessing && job != null) {
      body = ProcessingPanel(
        job: job,
        onCancel: controller.cancelProcessing,
        scriptLabel: position == null
            ? null
            : 'Script $position of ${scripts.length}: '
                '${scripts[position - 1].document.fileName}',
      );
      actions = null;
    } else if (controller.showingClass) {
      body = ClassResultsView(
        scripts: scripts,
        onOpen: controller.openScript,
        onRemove: busy ? null : controller.removeScript,
        marksLookHigh: controller.classMarksLookHigh,
        agreement: controller.agreement,
      );
      final bool anyMarked = scripts.any((MarkedScript s) => s.result != null);
      actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (controller.canPublish) ...<Widget>[
            OutlinedButton.icon(
              key: const Key('publish-class'),
              onPressed: anyMarked && !busy ? () => _publishClass(controller) : null,
              icon: const Icon(Icons.campaign_outlined, size: 16),
              label: const Text('Publish to students'),
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton.icon(
            onPressed: anyMarked ? controller.exportClass : null,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Export class…'),
          ),
        ],
      );
    } else {
      body = ResultsView(
        assessment: assessment,
        reviews: controller.reviews,
        pendingCorrections: controller.hasPendingCorrections,
        onRemark: controller.canCorrect ? controller.startCorrection : null,
        onOpenQuestion: (String questionId) =>
            QuestionDetailScreen.open(context, controller, questionId),
      );
      final Widget? resultActions = assessment == null
          ? null
          : _ResultActions(
              assessment: assessment,
              developerMode: controller.config.developerMode,
              onExport: assessment.result == null ? null : _export,
              onInspect: () => PageInspectorScreen.open(context, assessment),
              onPublish: !controller.canPublish || assessment.result == null || busy
                  ? null
                  : () => _publish(controller),
              publishBlocker: controller.currentScript == null
                  ? null
                  : controller.publishBlocker(controller.currentScript!),
            );
      actions = !controller.isClass
          ? resultActions
          : Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextButton.icon(
                    onPressed: controller.showClass,
                    icon: const Icon(Icons.arrow_back, size: 14),
                    label: const Text('All scripts'),
                  ),
                  ?resultActions,
                ],
              ),
            );
    }

    final Widget results = SectionCard(
      title: controller.showingClass
          ? '4. Class results'
          : controller.isClass && controller.answerSheet != null
              ? '4. ${controller.answerSheet!.fileName}'
              : '4. Correction result',
      expandChild: true,
      trailing: actions,
      child: body,
    );

    // The two documents sit side by side. They are the same shape and are
    // chosen one after the other, and stacking them would push the results
    // pane off the bottom of an ordinary window.
    final Widget documents = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: answerSheet),
        const SizedBox(width: AppTheme.gap),
        Expanded(child: questionPaper),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Below this the two documents no longer fit beside each other.
        final bool narrow = constraints.maxWidth < 820;

        final List<Widget> steps = <Widget>[
          if (narrow) ...<Widget>[
            answerSheet,
            const SizedBox(height: AppTheme.gap),
            questionPaper,
          ] else
            documents,
          const SizedBox(height: AppTheme.gap),
          // The syllabus library sits beside the guidance: both shape how the
          // answers are judged.
          if (!controller.hasSyllabusLibrary)
            guidance
          else if (narrow) ...<Widget>[
            guidance,
            const SizedBox(height: AppTheme.gap),
            SyllabusSection(controller: controller),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(flex: 3, child: guidance),
                const SizedBox(width: AppTheme.gap),
                Expanded(flex: 2, child: SyllabusSection(controller: controller)),
              ],
            ),
          const SizedBox(height: AppTheme.gap),
        ];

        // A short window scrolls rather than overflowing; a normal one gives
        // the results pane every remaining pixel.
        if (constraints.maxHeight < _comfortableHeight) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ...steps,
                SizedBox(height: 420, child: results),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(AppTheme.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ...steps,
              Expanded(child: results),
            ],
          ),
        );
      },
    );
  }
}

/// The bar across the top: what the application is, and its one command.
/// Which syllabus the chosen paper is marked against, and a way to change it.
class _SyllabusLine extends StatelessWidget {
  const _SyllabusLine({required this.controller});

  final CorrectionController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ({String name, String how})? inUse = controller.syllabusInUse;
    final String text = inUse != null
        ? 'Syllabus: ${inUse.name} · ${inUse.how}'
        : controller.syllabusChoice == SyllabusLibrary.none
            ? 'Marked without a syllabus · chosen by you'
            : controller.syllabi.isEmpty
                ? 'No syllabi saved yet — add one with Syllabi above'
                : 'No saved syllabus matches this paper';

    return Row(
      children: <Widget>[
        Icon(Icons.menu_book_outlined,
            size: 15, color: inUse == null ? AppTheme.textSecondary : AppTheme.accent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            key: const Key('syllabus-line'),
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: inUse == null ? AppTheme.textSecondary : null,
            ),
          ),
        ),
        if (controller.syllabi.isNotEmpty)
          PopupMenuButton<String>(
            key: const Key('syllabus-choose'),
            enabled: !controller.isBusy,
            tooltip: 'Choose the syllabus for this paper',
            onSelected: (String value) =>
                controller.chooseSyllabus(value == _auto ? null : value),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: _auto,
                checked: controller.syllabusChoice == null,
                child: const Text('Match automatically'),
              ),
              const PopupMenuDivider(),
              for (final Syllabus syllabus in controller.syllabi)
                CheckedPopupMenuItem<String>(
                  value: syllabus.id,
                  checked: controller.syllabusChoice == syllabus.id,
                  child: Text(syllabus.name),
                ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem<String>(
                value: SyllabusLibrary.none,
                checked: controller.syllabusChoice == SyllabusLibrary.none,
                child: const Text('No syllabus'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text('Change…',
                  style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.accent)),
            ),
          ),
      ],
    );
  }

  static const String _auto = '__auto__';
}

class _CommandBar extends StatelessWidget {
  const _CommandBar({
    required this.model,
    required this.hasApiKey,
    required this.onSettings,
    this.onSyllabi,
    this.usage,
    this.onSwitchRole,
    this.openRequests,
    this.onRequests,
    this.onStudents,
  });

  /// Opens the table of where every student stands.
  final VoidCallback? onStudents;

  final VoidCallback? onSwitchRole;

  /// Students' correction requests waiting; null where there are none to
  /// show.
  final int? openRequests;
  final VoidCallback? onRequests;

  /// What the AI is doing and how much it has been used; replaces the model
  /// name where available.
  final Widget? usage;

  final String model;
  final bool hasApiKey;
  final VoidCallback onSettings;

  /// Opens the syllabus library; null where there is none.
  final VoidCallback? onSyllabi;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.pagePadding),
      decoration: const BoxDecoration(
        color: AppTheme.cardBackground,
        border: Border(bottom: BorderSide(color: AppTheme.stroke)),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // The model chip is context, not a control: it is the first thing to
          // go when the window is narrow.
          final bool showChip = constraints.maxWidth >= 620;
          // The tools shrink to icons before anything overflows.
          final bool compact = constraints.maxWidth < 1000;
          Widget tool({
            required Key key,
            required VoidCallback onPressed,
            required IconData icon,
            required String label,
          }) =>
              compact
                  ? IconButton(key: key, tooltip: label, onPressed: onPressed, icon: Icon(icon, size: 18))
                  : OutlinedButton.icon(
                      key: key,
                      onPressed: onPressed,
                      icon: Icon(icon, size: 16),
                      label: Text(label),
                    );

          return Row(
            children: <Widget>[
              const Icon(Icons.rule_folder_outlined,
                  size: 18, color: AppTheme.accent),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Exam Corrector',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (usage != null) ...<Widget>[
                const SizedBox(width: 12),
                Flexible(child: usage!),
              ] else if (showChip) ...<Widget>[
                const SizedBox(width: 12),
                Flexible(
                  child: _Chip(
                    label: model,
                    icon: Icons.auto_awesome_outlined,
                    warn: !hasApiKey,
                  ),
                ),
              ],
              const Spacer(),
              if (onStudents != null) ...<Widget>[
                tool(
                  key: const Key('open-students'),
                  onPressed: onStudents!,
                  icon: Icons.groups_outlined,
                  label: 'Students',
                ),
                const SizedBox(width: 8),
              ],
              if (onRequests != null) ...<Widget>[
                Badge(
                  isLabelVisible: (openRequests ?? 0) > 0,
                  label: Text('${openRequests ?? 0}'),
                  child: tool(
                    key: const Key('open-requests'),
                    onPressed: onRequests!,
                    icon: Icons.rate_review_outlined,
                    label: 'Requests',
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (onSyllabi != null) ...<Widget>[
                tool(
                  key: const Key('open-syllabi'),
                  onPressed: onSyllabi!,
                  icon: Icons.menu_book_outlined,
                  label: 'Syllabi',
                ),
                const SizedBox(width: 8),
              ],
              OutlinedButton.icon(
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('Settings'),
              ),
              if (onSwitchRole != null) ...<Widget>[
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('switch-role'),
                  tooltip: 'Switch role',
                  onPressed: onSwitchRole,
                  icon: const Icon(Icons.logout, size: 18),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon, this.warn = false});

  final String label;
  final IconData icon;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final Color colour = warn ? AppTheme.caution : AppTheme.textSecondary;

    return Tooltip(
      message: warn
          ? 'No API key set — open Settings to add one.'
          : 'Marking runs on $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: warn ? AppTheme.cautionFill : AppTheme.pageBackground,
          border: Border.all(
            color: warn ? const Color(0xFFE8CE6A) : AppTheme.stroke,
          ),
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(warn ? Icons.key_off_outlined : icon, size: 13, color: colour),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colour),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What was marked and by which model, and what can be done with it.
///
/// The model belongs with the result rather than the command bar: when a
/// model's daily quota runs out mid-batch, marking moves down the chain, and
/// the teacher should be able to see which model produced these marks.
class _ResultActions extends StatelessWidget {
  const _ResultActions({
    required this.assessment,
    required this.developerMode,
    required this.onExport,
    required this.onInspect,
    this.onPublish,
    this.publishBlocker,
  });

  final ExamAssessment assessment;
  final bool developerMode;
  final VoidCallback? onExport;
  final VoidCallback onInspect;

  /// Publishes the result for its student; null where publishing is off.
  final VoidCallback? onPublish;

  /// Why it cannot be published yet.
  final String? publishBlocker;

  @override
  Widget build(BuildContext context) {
    final CorrectionResult? result = assessment.result;
    final TextStyle? style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppTheme.textSecondary);
    final int pages = assessment.answerSheet.pages
        .where((ExamPage page) => !page.isBlank)
        .length;

    final String summary = <String>[
      if (result != null)
        '${result.questions.length} question${result.questions.length == 1 ? '' : 's'}',
      '$pages page${pages == 1 ? '' : 's'} read',
      if (result != null && result.model.isNotEmpty) 'Marked by ${result.model}',
    ].join('   ·   ');

    return Flexible(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Buttons shrink to icons before anything overflows.
          final bool compact = constraints.maxWidth < 440;
          return Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Flexible(
                child: Text(summary, overflow: TextOverflow.ellipsis, style: style),
              ),
              const SizedBox(width: 8),
              if (developerMode)
                compact
                    ? IconButton(
                        tooltip: 'Inspect pages',
                        onPressed: onInspect,
                        icon: const Icon(Icons.bug_report_outlined, size: 18),
                      )
                    : Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: OutlinedButton.icon(
                          onPressed: onInspect,
                          icon: const Icon(Icons.bug_report_outlined, size: 16),
                          label: const Text('Inspect pages'),
                        ),
                      ),
              if (onPublish != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Tooltip(
                    message: publishBlocker == null
                        ? 'Let the student see these marks'
                        : 'Review the flagged questions first: $publishBlocker',
                    child: compact
                        ? IconButton(
                            key: const Key('publish'),
                            onPressed: publishBlocker == null ? onPublish : null,
                            icon: const Icon(Icons.campaign_outlined, size: 18),
                          )
                        : OutlinedButton.icon(
                            key: const Key('publish'),
                            onPressed: publishBlocker == null ? onPublish : null,
                            icon: const Icon(Icons.campaign_outlined, size: 16),
                            label: const Text('Publish'),
                          ),
                  ),
                ),
              if (compact)
                IconButton(
                  tooltip: 'Export…',
                  onPressed: onExport,
                  icon: const Icon(Icons.download_outlined, size: 18),
                )
              else
                OutlinedButton.icon(
                  onPressed: onExport,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('Export…'),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Where a script is published: the student's roll number, the subject and
/// the exam — what the student signs in with.
class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.fileName,
    required this.rollNo,
    required this.subjectCode,
    required this.exam,
  });

  final String fileName;
  final String rollNo;
  final String subjectCode;
  final String exam;

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  late final TextEditingController _roll = TextEditingController(text: widget.rollNo);
  final TextEditingController _name = TextEditingController();
  late final TextEditingController _subject = TextEditingController(text: widget.subjectCode);
  late final TextEditingController _exam = TextEditingController(text: widget.exam);

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_roll, _name, _subject, _exam]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ready => _roll.text.trim().isNotEmpty && _subject.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Publish to the student'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('${widget.fileName}. The student sees the final marks, section totals, '
                'each question’s explanation and your comments, and can ask you to look '
                'again at a mark.'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('publish-roll'),
              controller: _roll,
              autofocus: widget.rollNo.isEmpty,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Roll number *'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('publish-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Student name (optional)'),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('publish-subject'),
                    controller: _subject,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Subject code *', hintText: 'CCS356'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('publish-exam'),
                    controller: _exam,
                    decoration: const InputDecoration(labelText: 'Exam', hintText: 'CAT 1'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('publish-confirm'),
          onPressed: _ready
              ? () => Navigator.of(context).pop((
                    rollNo: _roll.text,
                    student: _name.text,
                    subjectCode: _subject.text,
                    exam: _exam.text,
                  ))
              : null,
          child: const Text('Publish'),
        ),
      ],
    );
  }
}

/// A class published at once: one subject and exam, each script's roll
/// number found in its file name or typed in.
class _PublishClassDialog extends StatefulWidget {
  const _PublishClassDialog({required this.scripts, required this.subjectCode, required this.exam});

  final List<MarkedScript> scripts;
  final String subjectCode;
  final String exam;

  @override
  State<_PublishClassDialog> createState() => _PublishClassDialogState();
}

class _PublishClassDialogState extends State<_PublishClassDialog> {
  late final TextEditingController _subject = TextEditingController(text: widget.subjectCode);
  late final TextEditingController _exam = TextEditingController(text: widget.exam);
  late final Map<int, TextEditingController> _rolls = <int, TextEditingController>{
    for (int i = 0; i < widget.scripts.length; i++)
      if (widget.scripts[i].result != null)
        i: TextEditingController(
          text: PublishedResult.rollFromFileName(widget.scripts[i].document.fileName) ?? '',
        ),
  };

  @override
  void dispose() {
    _subject.dispose();
    _exam.dispose();
    for (final TextEditingController c in _rolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Publish the class to students'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('class-subject'),
                    controller: _subject,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Subject code *'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(controller: _exam, decoration: const InputDecoration(labelText: 'Exam')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Roll number for each script — scripts left blank are not published.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            Expanded(
              child: ListView(
                children: <Widget>[
                  for (final MapEntry<int, TextEditingController> entry in _rolls.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(widget.scripts[entry.key].document.fileName,
                                overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 160,
                            child: TextField(
                              controller: entry.value,
                              decoration: const InputDecoration(isDense: true, hintText: 'Roll number'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('class-publish-confirm'),
          onPressed: _subject.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop((
                    subjectCode: _subject.text,
                    exam: _exam.text,
                    rollNos: <int, String>{
                      for (final MapEntry<int, TextEditingController> e in _rolls.entries) e.key: e.value.text,
                    },
                  )),
          child: const Text('Publish'),
        ),
      ],
    );
  }
}

