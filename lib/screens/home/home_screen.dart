import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/screens/review/transcript_review_screen.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/correction_progress.dart';
import 'package:exam_corrector/widgets/guidance_input.dart';
import 'package:exam_corrector/widgets/pdf_upload.dart';
import 'package:exam_corrector/widgets/results_view.dart';
import 'package:exam_corrector/widgets/section_card.dart';
import 'package:exam_corrector/widgets/settings_dialog.dart';

/// The single window: command bar, three workflow steps, status bar.
///
/// The screen owns no marking logic. It collects input, calls the controller,
/// and renders whatever the validation layer approved.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final CorrectionController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _guidanceField;
  bool _showingError = false;
  bool _showingReview = false;

  /// Below this height the workflow no longer fits, so the page scrolls
  /// instead of overflowing.
  static const double _comfortableHeight = 600;

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

    // Recognition finished: the transcript has to be checked before it can be
    // marked, so the review screen is opened rather than merely offered.
    if (widget.controller.isReviewingTranscript && !_showingReview) {
      _showingReview = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openReview());
    }
  }

  Future<void> _openReview() async {
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(
          name: TranscriptReviewScreen.routeName,
        ),
        builder: (BuildContext context) =>
            TranscriptReviewScreen(controller: widget.controller),
      ),
    );

    _showingReview = false;

    // Dismissed with the system back gesture rather than the confirm button;
    // the transcript still has to be accepted before marking can start.
    if (widget.controller.isReviewingTranscript) {
      widget.controller.confirmTranscript();
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
              ),
              Expanded(child: _workflow(controller)),
              CorrectionProgress(
                statusMessage: controller.statusMessage,
                isError: controller.statusIsError,
                isCorrecting: controller.isCorrecting,
                isTranscribing: controller.isTranscribing,
                transcriptionProgress: controller.ocrProgress,
                onCorrect:
                    controller.canCorrect ? controller.startCorrection : null,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _workflow(CorrectionController controller) {
    final bool busy = controller.isBusy;
    final bool reading = controller.stage == CorrectionStage.readingPaper ||
        controller.isTranscribing;

    final Widget answerSheet = PdfUpload(
      title: "1. Student's answer sheet",
      hint: 'No file selected. Choose the completed script.',
      paper: controller.answerSheet,
      isLoading: reading && controller.answerSheet == null,
      onChoose: busy ? null : controller.chooseAnswerSheet,
      onReviewTranscript: busy
          ? null
          : () => controller.reopenTranscript(ReviewTarget.answerSheet),
    );

    final Widget questionPaper = PdfUpload(
      title: '2. Question paper',
      hint: 'No file selected. Choose the paper with the questions and marks.',
      paper: controller.questionPaper,
      isLoading: reading && controller.questionPaper == null,
      onChoose: busy ? null : controller.chooseQuestionPaper,
      onReviewTranscript: busy
          ? null
          : () => controller.reopenTranscript(ReviewTarget.questionPaper),
    );

    final Widget guidance = GuidanceInput(
      controller: _guidanceField,
      onChanged: controller.setGuidance,
      onClear: busy ? null : controller.clearGuidance,
    );

    final Widget results = SectionCard(
      title: '4. Correction result',
      expandChild: true,
      trailing: controller.result == null
          ? null
          : _ResultSummary(result: controller.result!),
      child: ResultsView(
        result: controller.result,
        isCorrecting: controller.isCorrecting,
      ),
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
                SizedBox(height: 320, child: results),
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

/// How many questions were marked, and by which model.
///
/// The model belongs with the result rather than the command bar: when a
/// model's daily quota runs out mid-batch, marking moves down the chain, and
/// the teacher should be able to see which model produced these marks.
class _ResultSummary extends StatelessWidget {
  const _ResultSummary({required this.result});

  final CorrectionResult result;

  @override
  Widget build(BuildContext context) {
    final int count = result.questions.length;
    final TextStyle? style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppTheme.textSecondary);

    return Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$count question${count == 1 ? '' : 's'}', style: style),
          if (result.model.isNotEmpty) ...<Widget>[
            Text('   ·   ', style: style),
            Flexible(
              child: Text(
                'Marked by ${result.model}',
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
