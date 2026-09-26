import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/screens/inspector/page_inspector_screen.dart';
import 'package:exam_corrector/screens/results/question_detail_screen.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/class_results_view.dart';
import 'package:exam_corrector/widgets/correction_progress.dart';
import 'package:exam_corrector/widgets/guidance_input.dart';
import 'package:exam_corrector/widgets/pdf_upload.dart';
import 'package:exam_corrector/widgets/processing_panel.dart';
import 'package:exam_corrector/widgets/results_view.dart';
import 'package:exam_corrector/widgets/section_card.dart';
import 'package:exam_corrector/widgets/settings_dialog.dart';

/// The main window: command bar, four workflow steps, status bar.
///
/// The screen owns no marking logic. It collects input, calls the controller,
/// shows processing as it happens, and opens each question's evidence.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final CorrectionController controller;

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
    );

    final Widget guidance = GuidanceInput(
      controller: _guidanceField,
      onChanged: controller.setGuidance,
      onClear: busy ? null : controller.clearGuidance,
      onLoadFile: busy ? null : controller.loadGuidanceFile,
      sourceFile: controller.guidanceFile,
      paperScheme: controller.paperScheme,
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
      );
      actions = OutlinedButton.icon(
        onPressed: scripts.any((MarkedScript s) => s.result != null)
            ? controller.exportClass
            : null,
        icon: const Icon(Icons.download_outlined, size: 16),
        label: const Text('Export class…'),
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
          guidance,
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
class _CommandBar extends StatelessWidget {
  const _CommandBar({
    required this.model,
    required this.hasApiKey,
    required this.onSettings,
  });

  final String model;
  final bool hasApiKey;
  final VoidCallback onSettings;

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
              if (showChip) ...<Widget>[
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
              OutlinedButton.icon(
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('Settings'),
              ),
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
  });

  final ExamAssessment assessment;
  final bool developerMode;
  final VoidCallback? onExport;
  final VoidCallback onInspect;

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
