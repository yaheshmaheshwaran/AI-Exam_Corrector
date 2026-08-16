import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/correction_progress.dart';
import 'package:exam_corrector/widgets/mark_scheme_input.dart';
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
  late final TextEditingController _markSchemeField;
  bool _showingError = false;

  /// Below this height the workflow no longer fits, so the page scrolls
  /// instead of overflowing.
  static const double _comfortableHeight = 600;

  @override
  void initState() {
    super.initState();
    _markSchemeField =
        TextEditingController(text: widget.controller.markScheme.text);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _markSchemeField.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    // Keep the field in step when the mark scheme changes from outside it
    // (loaded from a PDF, or cleared).
    final String text = widget.controller.markScheme.text;
    if (_markSchemeField.text != text) {
      _markSchemeField.value = TextEditingValue(
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

    final Widget upload = PdfUpload(
      paper: controller.paper,
      isLoading: controller.stage == CorrectionStage.readingPaper,
      onChoose: busy ? null : controller.chooseExamPaper,
    );

    final Widget markScheme = MarkSchemeInput(
      controller: _markSchemeField,
      isLoading: controller.stage == CorrectionStage.readingMarkScheme,
      onChanged: controller.setMarkScheme,
      onLoadFromPdf: busy ? null : controller.loadMarkSchemeFromPdf,
      onClear: busy ? null : controller.clearMarkScheme,
    );

    final Widget results = SectionCard(
      title: '3. Correction result',
      expandChild: true,
      trailing: controller.result == null
          ? null
          : _ResultSummary(result: controller.result!),
      child: ResultsView(
        result: controller.result,
        isCorrecting: controller.isCorrecting,
      ),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // A short window scrolls rather than overflowing; a normal one gives
        // the results pane every remaining pixel.
        if (constraints.maxHeight < _comfortableHeight) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                upload,
                const SizedBox(height: AppTheme.gap),
                markScheme,
                const SizedBox(height: AppTheme.gap),
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
              upload,
              const SizedBox(height: AppTheme.gap),
              markScheme,
              const SizedBox(height: AppTheme.gap),
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
