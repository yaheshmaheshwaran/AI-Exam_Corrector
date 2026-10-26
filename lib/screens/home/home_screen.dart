import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:exam_corrector/ai/model_roles.dart';
import 'package:exam_corrector/app/observable_listenable.dart';
import 'package:exam_corrector/core/utils/duration_format.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/syllabus.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/published_result.dart';
import 'package:exam_corrector/features/results/ui/page_inspector_screen.dart';
import 'package:exam_corrector/features/accounts/ui/requests_screen.dart';
import 'package:exam_corrector/features/accounts/ui/student_status_screen.dart';
import 'package:exam_corrector/features/results/ui/question_detail_screen.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/services/syllabus/syllabus_library.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/features/exam_setup/ui/answer_key_dialog.dart';
import 'package:exam_corrector/features/exam_setup/ui/answer_key_section.dart';
import 'package:exam_corrector/features/marking_style/ui/moderation_chip.dart';
import 'package:exam_corrector/marking/exam/answer_key.dart';
import 'package:exam_corrector/features/results/ui/class_results_view.dart';
import 'package:exam_corrector/features/exam_setup/ui/guidance_input.dart';
import 'package:exam_corrector/features/marking_style/ui/marking_standard_dialog.dart';
import 'package:exam_corrector/features/marking_run/ui/model_usage_indicator.dart';
import 'package:exam_corrector/features/exam_setup/ui/pdf_upload.dart';
import 'package:exam_corrector/features/marking_run/ui/processing_panel.dart';
import 'package:exam_corrector/features/results/ui/results_view.dart';
import 'package:exam_corrector/features/settings/ui/settings_dialog.dart';
import 'package:exam_corrector/features/syllabus/ui/syllabus_library_dialog.dart';
import 'package:exam_corrector/features/syllabus/ui/syllabus_section.dart';
import 'package:exam_corrector/shared/ui/ui.dart';

part 'publish_dialogs.dart';
part 'result_actions.dart';
part 'setup_rail.dart';

/// The main window: the navigation rail down the left, the place chosen in
/// it beside the rail, and a status line along the foot.
///
/// Marking is the setup column beside the results. Students and Requests
/// open beside the rail too, and so does anything opened from them — a
/// question's evidence, the page inspector — so the rail is always there.
/// Syllabi and Settings open as dialogs.
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

/// The places in the rail that open beside it.
enum _Place { marking, students, requests }

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _guidanceField;
  bool _showingError = false;

  /// The pinned command's height in the narrow layout, measured, so the
  /// page scrolls clear of it.
  final ValueNotifier<double> _stackedFoot = ValueNotifier<double>(96);
  bool _wasProcessing = false;

  /// Where the places beside the rail open, and which one is showing.
  final GlobalKey<NavigatorState> _content = GlobalKey<NavigatorState>();
  final _PlaceObserver _places = _PlaceObserver();

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
    _stackedFoot.dispose();
    _places.dispose();
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

  /// Opens [place] beside the rail, closing whatever was open there.
  void _go(_Place place) {
    final NavigatorState? content = _content.currentState;
    if (content == null) return;
    content.popUntil((Route<dynamic> route) => route.isFirst);
    switch (place) {
      case _Place.marking:
        break;
      case _Place.students:
        StudentStatusScreen.open(content.context, widget.controller);
      case _Place.requests:
        RequestsScreen.open(content.context, widget.controller);
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
    final ({String writer, bool checked})? ai = controller.aiKeyStatus;
    final AnswerKeyReview? review = await AnswerKeyDialog.show(context, paper: paper, key: key, aiStatus: ai);
    if (review != null) await controller.saveAnswerKeyEdits(review.edits, checked: ai == null ? null : review.checked);
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ListenableBuilder(
                  listenable: Listenable.merge(<Listenable>[controller, _places]),
                  builder: (BuildContext context, _) => _rail(controller),
                ),
                Expanded(
                  // The places beside the rail, and whatever they open.
                  child: Navigator(
                    key: _content,
                    observers: <NavigatorObserver>[_places],
                    onGenerateRoute: (RouteSettings settings) => PageRouteBuilder<void>(
                      settings: const RouteSettings(name: 'marking'),
                      transitionDuration: Duration.zero,
                      pageBuilder: (BuildContext page, _, _) => ListenableBuilder(
                        listenable: Listenable.merge(<Listenable>[controller, _stackedFoot]),
                        builder: (BuildContext page, _) => _workflow(controller, page),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _StatusFooter(controller: controller),
        ],
      ),
    );
  }

  Widget _rail(CorrectionController controller) {
    final _Place here = _places.place;
    return AppRail(
      items: <Widget>[
        AppRailItem(
          key: const Key('open-marking'),
          icon: Icons.fact_check_outlined,
          label: 'Marking',
          selected: here == _Place.marking,
          onPressed: () => _go(_Place.marking),
        ),
        if (controller.canPublish) ...<Widget>[
          AppRailItem(
            key: const Key('open-students'),
            icon: Icons.groups_outlined,
            label: 'Students',
            tooltip: 'Where every student stands',
            selected: here == _Place.students,
            onPressed: () => _go(_Place.students),
          ),
          AppRailItem(
            key: const Key('open-requests'),
            icon: Icons.rate_review_outlined,
            label: 'Requests',
            tooltip: "Students' correction requests",
            count: controller.openRequestCount,
            selected: here == _Place.requests,
            onPressed: () => _go(_Place.requests),
          ),
        ],
        if (controller.hasSyllabusLibrary)
          AppRailItem(
            key: const Key('open-syllabi'),
            icon: Icons.menu_book_outlined,
            label: 'Syllabi',
            tooltip: 'Syllabus library',
            onPressed: () => SyllabusLibraryDialog.show(context, controller),
          ),
      ],
      footer: <Widget>[
        AppRailItem(
          key: const Key('open-settings'),
          icon: Icons.settings_outlined,
          label: 'Settings',
          onPressed: () => SettingsDialog.show(context, controller),
        ),
        if (widget.account case final Widget account)
          account
        else if (widget.onSwitchRole case final VoidCallback onSwitchRole)
          AppRailItem(
            key: const Key('switch-role'),
            icon: Icons.login,
            label: 'Sign in',
            tooltip: 'Back to sign in',
            onPressed: onSwitchRole,
          ),
      ],
    );
  }

  /// Marking: the setup column beside the results, each under its own
  /// floating toolbar. [page] is inside the place's navigator, so what the
  /// results open appears beside the rail.
  Widget _workflow(CorrectionController controller, BuildContext page) {
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
      onAdd: controller.canAddScripts ? controller.addAnswerSheets : null,
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
      // A background run marks while the teacher checks the key: what they
      // change is applied to the scripts it has already marked.
      onReview: (busy && !controller.isBackgroundRun) || controller.keyPaper == null
          ? null
          : () => _editAnswerKey(controller),
      aiKey: controller.aiKeyStatus,
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
        // Below this the setup column and the results no longer fit side by
        // side: the setup goes above, and the page scrolls.
        final bool stacked = constraints.maxWidth < _sideBySideWidth;
        final double paneWidth =
            constraints.maxWidth - AppTheme.floatInset - (stacked ? AppTheme.floatInset : AppTheme.setupWidth);
        final _ResultsPane pane = _results(controller, page, compact: paneWidth < 760);
        final Widget card = AppCard(
          expandChild: true,
          padding: const EdgeInsets.all(AppTheme.pagePadding),
          child: pane.body,
        );
        if (stacked) {
          // Once there is something to show, it comes first: the inputs are
          // chosen by then. The command stays in reach at the foot.
          final bool resultsFirst =
              controller.isProcessing || controller.assessment != null || controller.showingClass;
          final Widget results = Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.floatInset, 0, AppTheme.floatInset, AppTheme.floatInset),
            child: SizedBox(
              height: (constraints.maxHeight - 120).clamp(360.0, 640.0),
              child: card,
            ),
          );
          final Widget setup = _SetupRail(sections: sections, action: const SizedBox.shrink(), scrolls: false);
          // The page scrolls under the toolbar and under the command,
          // pinned in floating glass at the foot.
          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(top: AppTheme.underBar, bottom: _stackedFoot.value),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: resultsFirst ? <Widget>[results, setup] : <Widget>[setup, results],
                  ),
                ),
              ),
              Positioned(top: 0, left: 0, right: 0, child: pane.toolbar()),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MeasureSize(
                  onSize: (Size size) {
                    if (mounted && size.height != _stackedFoot.value) _stackedFoot.value = size.height;
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
              width: AppTheme.setupWidth,
              child: _SetupRail(sections: sections, action: action),
            ),
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, AppTheme.underBar, AppTheme.floatInset, AppTheme.floatInset),
                      child: card,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: pane.toolbar(
                      margin: const EdgeInsets.fromLTRB(0, AppTheme.floatInset, AppTheme.floatInset, 0),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// The results pane: processing as it happens, the class, or one script.
  _ResultsPane _results(CorrectionController controller, BuildContext page, {required bool compact}) {
    final bool busy = controller.isBusy;
    final List<MarkedScript> scripts = controller.scripts;
    final ExamAssessment? assessment = controller.assessment;
    final int? position = controller.batchPosition;
    // In a background run the class stays usable: the progress panel shows
    // only for the script being marked, when the teacher opens it.
    final bool watching = controller.isProcessing &&
        (!controller.isBackgroundRun ||
            (!controller.showingClass && (controller.currentScript?.processing ?? false)));
    Widget body;
    final List<Widget> actions;
    if (watching && controller.job == null) {
      // Marking has started but nothing has been counted yet.
      body = const SkeletonRows(label: 'Starting to mark');
      actions = const <Widget>[];
    } else if (watching && controller.job != null) {
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
      actions = const <Widget>[];
    } else if (controller.showingClass) {
      final DateTime? backAt = controller.markingBackAt;
      body = ClassResultsView(
        scripts: scripts,
        onOpen: controller.openScript,
        onRemove: busy ? null : controller.removeScript,
        marksLookHigh: controller.classMarksLookHigh,
        agreement: controller.agreement,
        markingBackAt: backAt,
        lastRun: controller.lastRun,
      );
      final bool anyMarked = scripts.any((MarkedScript s) => s.result != null);
      actions = <Widget>[
        if (controller.canPublish)
          OutlinedButton.icon(
            key: const Key('publish-class'),
            onPressed: anyMarked && !busy ? () => _publishClass(controller) : null,
            icon: const Icon(Icons.campaign_outlined, size: 16),
            label: const Text('Publish to students'),
          ),
        OutlinedButton.icon(
          onPressed: anyMarked ? controller.exportClass : null,
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('Export class…'),
        ),
      ];
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
            QuestionDetailScreen.open(page, controller, questionId),
      );
      actions = <Widget>[
        if (controller.isClass)
          TextButton.icon(
            onPressed: controller.showClass,
            icon: const Icon(Icons.arrow_back, size: 14),
            label: const Text('All scripts'),
          ),
        if (assessment != null)
          _ResultActions(
            assessment: assessment,
            compact: compact,
            developerMode: controller.config.developerMode,
            onExport: assessment.result == null ? null : _export,
            onInspect: () => PageInspectorScreen.open(page, assessment),
            onPublish: !controller.canPublish || assessment.result == null || busy
                ? null
                : () => _publish(controller),
            publishBlocker: controller.currentScript == null
                ? null
                : controller.publishBlocker(controller.currentScript!),
          ),
      ];
    }

    // What the pane shows changes with a short fade, not a jump.
    final String showing = watching
        ? (controller.job == null ? 'starting' : 'processing')
        : controller.showingClass
            ? 'class'
            : 'script-${identityHashCode(assessment)}';
    final bool still = MediaQuery.maybeDisableAnimationsOf(page) ?? false;
    body = AnimatedSwitcher(
      duration: still ? Duration.zero : AppMotion.normal,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (Widget? current, List<Widget> previous) =>
          Stack(fit: StackFit.expand, children: <Widget>[...previous, ?current]),
      child: KeyedSubtree(key: ValueKey<String>(showing), child: body),
    );

    return _ResultsPane(
      title: watching
          ? 'Marking'
          : controller.showingClass
              ? 'Class results'
              : controller.isClass && controller.answerSheet != null
                  ? controller.answerSheet!.fileName
                  : 'Correction result',
      subtitle: watching || controller.showingClass || assessment == null
          ? null
          : _ResultActions.summary(assessment),
      actions: actions,
      body: body,
    );
  }

  /// Below this width the setup column and the results stack.
  static const double _sideBySideWidth = 880;
}

/// The results pane's parts: its toolbar's title and actions, and its body.
class _ResultsPane {
  const _ResultsPane({required this.title, required this.subtitle, required this.actions, required this.body});

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget body;

  AppToolbar toolbar({EdgeInsets? margin}) => AppToolbar(
        key: const Key('results-toolbar'),
        title: title,
        subtitle: subtitle,
        actions: actions,
        margin: margin ?? const EdgeInsets.fromLTRB(AppTheme.floatInset, AppTheme.floatInset, AppTheme.floatInset, 0),
      );
}

/// Which place beside the rail is showing: the nearest one to the top of
/// the places' navigator, whatever has been opened from it since.
class _PlaceObserver extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _stack = <Route<dynamic>>[];

  _Place get place {
    for (final Route<dynamic> route in _stack.reversed) {
      switch (route.settings.name) {
        case StudentStatusScreen.routeName:
          return _Place.students;
        case RequestsScreen.routeName:
          return _Place.requests;
      }
    }
    return _Place.marking;
  }

  void _changed() {
    // Navigators report while they build; the rail follows once they have.
    SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final int at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (at >= 0 && newRoute != null) {
      _stack[at] = newRoute;
    } else if (newRoute != null) {
      _stack.add(newRoute);
    }
    _changed();
  }
}
