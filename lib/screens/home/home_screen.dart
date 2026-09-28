import 'package:flutter/material.dart';

import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/screens/inspector/page_inspector_screen.dart';
import 'package:exam_corrector/screens/requests/requests_screen.dart';
import 'package:exam_corrector/screens/students/student_status_screen.dart';
import 'package:exam_corrector/screens/results/question_detail_screen.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/answer_key_dialog.dart';
import 'package:exam_corrector/widgets/answer_key_section.dart';
import 'package:exam_corrector/widgets/moderation_chip.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/widgets/class_results_view.dart';
import 'package:exam_corrector/widgets/guidance_input.dart';
import 'package:exam_corrector/widgets/marking_standard_dialog.dart';
import 'package:exam_corrector/widgets/model_usage_indicator.dart';
import 'package:exam_corrector/widgets/pdf_upload.dart';
import 'package:exam_corrector/widgets/processing_panel.dart';
import 'package:exam_corrector/widgets/results_view.dart';
import 'package:exam_corrector/widgets/settings_dialog.dart';
import 'package:exam_corrector/widgets/syllabus_library_dialog.dart';
import 'package:exam_corrector/widgets/syllabus_section.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

part 'publish_dialogs.dart';
part 'result_actions.dart';
part 'setup_rail.dart';
part 'top_bar.dart';

/// The main window: a top bar, the setup rail beside the results, and a
/// status line.
///
/// The screen owns no marking logic. It collects input, calls the controller,
/// shows processing as it happens, and opens each question's evidence.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, this.onSwitchRole, this.account});

  final CorrectionController controller;

  /// Back to signing in; null when there is only the teacher.
  final VoidCallback? onSwitchRole;

  /// Who is signed in, and their menu; null without an account.
  final Widget? account;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _guidanceField;
  bool _showingError = false;

  /// The pinned command's height in the narrow layout, measured, so the
  /// page scrolls clear of it.
  double _stackedFoot = 96;
  bool _wasProcessing = false;

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

    // Marking that finishes on its own gets a soft chime; a cancelled or
    // failed run does not.
    final bool processing = widget.controller.isProcessing;
    final ProcessingStage? stage = widget.controller.job?.stage;
    if (_wasProcessing && !processing &&
        (stage == ProcessingStage.completed || stage == ProcessingStage.reviewRequired)) {
      UiSound.instance.play(UiSoundKind.done);
    }
    _wasProcessing = processing;

    final String? error = widget.controller.pendingError;
    if (error != null && !_showingError) {
      _showingError = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showError(error));
    }
  }

  Future<void> _export() async {
    final ReportFormat? format = await showAppDialog<ReportFormat>(
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
        await showAppDialog<({String rollNo, String student, String subjectCode, String exam})>(
      context: context,
      builder: (BuildContext context) => _PublishDialog(
        fileName: script.document.fileName,
        rollNo: defaults.rollNo,
        subjectCode: defaults.subjectCode,
        exam: defaults.exam,
        registered: controller.registeredRolls(),
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
        await showAppDialog<({String subjectCode, String exam, Map<int, String> rollNos})>(
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
    final QuestionPaper? paper = controller.keyPaper;
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
    UiSound.instance.play(UiSoundKind.problem);

    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Row(
          children: <Widget>[
            Icon(Icons.error_outline, color: context.colors.danger, size: 20),
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
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListenableBuilder(
              listenable: controller,
              // The workspace fills the window; the top bar floats over it,
              // frosted, and what scrolls beneath shows softly through.
              builder: (BuildContext context, _) => Stack(
                children: <Widget>[
                  Positioned.fill(child: _workflow(controller)),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Frosted(
                      bottom: true,
                      child: _TopBar(
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
                    account: widget.account,
                    openRequests: controller.canPublish ? controller.openRequestCount : null,
                    onRequests: controller.canPublish ? () => RequestsScreen.open(context, controller) : null,
                    onStudents: controller.canPublish ? () => StudentStatusScreen.open(context, controller) : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _StatusFooter(controller: controller),
        ],
      ),
    );
  }

  Widget _workflow(CorrectionController controller) {
    final bool busy = controller.isBusy;

    final List<MarkedScript> scripts = controller.scripts;
    final Widget answerSheet = PdfUpload(
      title: controller.isClass ? "Students' answer sheets" : "Student's answer sheet",
      hint: 'Choose the completed script — or select a '
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
      title: 'Question paper',
      hint: 'Choose the paper with the questions and marks. '
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
    );

    final Widget? standard = !controller.hasMarkingStandards
        ? null
        : MarkingStandardSection(
            standard: controller.markingStandard,
            onLevel: busy
                ? null
                : (MarkingLevel level) =>
                    controller.setMarkingStandard(controller.markingStandard.copyWith(level: level)),
            onRules: busy ? null : () => _editStandard(controller),
            moderation: controller.markedPaper != null
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

    // One line above the command: can marking start, and if not, what is
    // still needed.
    final List<String> missing = <String>[
      if (controller.answerSheet == null && scripts.isEmpty) 'the answer sheet',
      if (controller.questionPaper == null) 'the question paper',
    ];
    final (String, ToneKind) readiness = controller.isProcessing
        ? ('Correction in progress', ToneKind.primary)
        : controller.canCorrect
            ? (controller.isClass ? '${scripts.length} scripts ready to mark' : 'Ready to correct', ToneKind.success)
            : missing.isNotEmpty
                ? ('Needs ${missing.join(' and ')}', ToneKind.neutral)
                : ('', ToneKind.neutral);

    final Widget action = _RailAction(
      readiness: readiness.$1,
      readinessTone: readiness.$2,
      label: controller.isClass ? 'Mark all ${scripts.length} scripts' : 'Correct paper',
      onCorrect: !controller.canCorrect
          ? null
          : controller.isClass
              ? controller.markAll
              : controller.startCorrection,
      onCancel: controller.isProcessing ? controller.cancelProcessing : null,
    );

    final Widget answerKey = AnswerKeySection(
      teacherKey: controller.teacherKey,
      coverage: controller.keyCoverage,
      reading: controller.isReadingKey,
      paperChosen: controller.questionPaper != null,
      onChoose: busy || controller.questionPaper == null || controller.isReadingKey ? null : controller.chooseAnswerKey,
      onRemove: busy || controller.isReadingKey ? null : controller.removeAnswerKey,
      onReview: busy || controller.keyPaper == null ? null : () => _editAnswerKey(controller),
    );

    final List<Widget> sections = <Widget>[
      answerSheet,
      questionPaper,
      answerKey,
      guidance,
      ?standard,
      if (controller.hasSyllabusLibrary) SyllabusSection(controller: controller),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Below this the rail and the results no longer fit side by side:
        // the rail goes above, and the page scrolls.
        final bool stacked = constraints.maxWidth < _sideBySideWidth;
        final double paneWidth =
            constraints.maxWidth - 2 * AppTheme.pagePadding - (stacked ? 0 : _SetupRail.width);
        final Widget results = _results(controller, compact: paneWidth < 760);
        if (stacked) {
          // Once there is something to show, it comes first: the inputs are
          // chosen by then. The command stays in reach at the foot.
          final bool resultsFirst =
              controller.isProcessing || controller.assessment != null || controller.showingClass;
          final Widget pane = Padding(
            padding: const EdgeInsets.all(AppTheme.pagePadding),
            child: SizedBox(
              height: (constraints.maxHeight - 120).clamp(360.0, 640.0),
              child: results,
            ),
          );
          final Widget rail = _SetupRail(sections: sections, action: const SizedBox.shrink(), scrolls: false);
          // The page scrolls under the top bar and under the command,
          // pinned and frosted at the foot.
          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(top: _TopBar.height, bottom: _stackedFoot),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: resultsFirst ? <Widget>[pane, rail] : <Widget>[rail, pane],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MeasureSize(
                  onSize: (Size size) {
                    if (mounted && size.height != _stackedFoot) setState(() => _stackedFoot = size.height);
                  },
                  child: _RailFoot(action: action),
                ),
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: _SetupRail.width,
              child: _SetupRail(sections: sections, action: action, topInset: _TopBar.height),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.pagePadding,
                  AppTheme.pagePadding + _TopBar.height,
                  AppTheme.pagePadding,
                  AppTheme.pagePadding,
                ),
                child: results,
              ),
            ),
          ],
        );
      },
    );
  }

  /// The results pane: processing as it happens, the class, or one script.
  Widget _results(CorrectionController controller, {required bool compact}) {
    final bool busy = controller.isBusy;
    final List<MarkedScript> scripts = controller.scripts;
    final ExamAssessment? assessment = controller.assessment;
    final int? position = controller.batchPosition;
    Widget body;
    final Widget? actions;
    if (controller.isProcessing && controller.job == null) {
      // Marking has started but nothing has been counted yet.
      body = const SkeletonRows(label: 'Starting to mark');
      actions = null;
    } else if (controller.isProcessing && controller.job != null) {
      // Only the panel follows the progress; the rest of the window waits
      // for the next stage.
      body = ListenableBuilder(
        listenable: controller.progress,
        builder: (BuildContext context, _) => ProcessingPanel(
          job: controller.job!,
          scriptLabel: position == null
              ? null
              : 'Script $position of ${scripts.length}: '
                  '${scripts[position - 1].document.fileName}',
        ),
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
        emptyDetail: _EmptyChecklist(
          steps: <({String label, bool done, bool optional})>[
            (
              label: controller.isClass ? "Choose the students' answer sheets" : "Choose the student's answer sheet",
              done: controller.answerSheet != null || scripts.isNotEmpty,
              optional: false,
            ),
            (label: 'Choose the question paper', done: controller.questionPaper != null, optional: false),
            (label: 'Add your answer key', done: controller.teacherKey != null, optional: true),
          ],
          closing: controller.canCorrect
              ? 'Everything needed is here. Press ${controller.isClass ? 'Mark all' : 'Correct paper'} to start.'
              : 'Choose what is still needed in the panel on the left.',
        ),
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
              compact: compact,
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
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextButton.icon(
                  onPressed: controller.showClass,
                  icon: const Icon(Icons.arrow_back, size: 14),
                  label: const Text('All scripts'),
                ),
                ?resultActions,
              ],
            );
    }

    // What the pane shows changes with a short fade, not a jump.
    final String showing = controller.isProcessing
        ? (controller.job == null ? 'starting' : 'processing')
        : controller.showingClass
            ? 'class'
            : 'script-${identityHashCode(assessment)}';
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    body = AnimatedSwitcher(
      duration: still ? Duration.zero : const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (Widget? current, List<Widget> previous) =>
          Stack(fit: StackFit.expand, children: <Widget>[...previous, ?current]),
      child: KeyedSubtree(key: ValueKey<String>(showing), child: body),
    );

    return AppCard(
      divided: true,
      expandChild: true,
      padding: const EdgeInsets.all(AppTheme.pagePadding),
      title: controller.isProcessing
          ? 'Marking'
          : controller.showingClass
              ? 'Class results'
              : controller.isClass && controller.answerSheet != null
                  ? controller.answerSheet!.fileName
                  : 'Correction result',
      subtitle: controller.isProcessing || controller.showingClass || assessment == null
          ? null
          : _ResultActions.summary(assessment),
      trailing: actions,
      child: body,
    );
  }

  /// Below this width the rail and the results stack.
  static const double _sideBySideWidth = 960;
}
