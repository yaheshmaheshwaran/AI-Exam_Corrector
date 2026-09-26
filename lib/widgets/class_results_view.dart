import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/state/marked_script.dart';

/// The class at a glance: every student, their mark, and what is left to do.
///
/// Marks shown are the ones that count — the teacher's wherever they changed
/// one. A row opens that student's questions.
class ClassResultsView extends StatefulWidget {
  const ClassResultsView({
    super.key,
    required this.scripts,
    required this.onOpen,
    this.onRemove,
  });

  final List<MarkedScript> scripts;
  final ValueChanged<int> onOpen;
  final ValueChanged<int>? onRemove;

  @override
  State<ClassResultsView> createState() => _ClassResultsViewState();
}

class _ClassResultsViewState extends State<ClassResultsView> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<MarkedScript> marked =
        widget.scripts.where((MarkedScript s) => s.result != null).toList();
    final List<double> percentages = <double>[
      for (final MarkedScript s in marked) s.finalPercentage!,
    ];
    final int toReview = widget.scripts
        .where((MarkedScript s) => s.status == ScriptStatus.reviewRequired)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 24,
          runSpacing: 6,
          children: <Widget>[
            _Figure('Scripts', '${widget.scripts.length}'),
            _Figure('Marked', '${marked.length}'),
            _Figure('To review', '$toReview'),
            if (percentages.isNotEmpty)
              _Figure(
                'Class average',
                formatPercentage(
                  percentages.reduce((double a, double b) => a + b) / percentages.length,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.only(right: 10),
              itemCount: widget.scripts.length,
              itemBuilder: (BuildContext context, int index) {
                final MarkedScript script = widget.scripts[index];
                return _Row(
                  key: ValueKey<String>('script-row-$index'),
                  script: script,
                  onOpen: () => widget.onOpen(index),
                  onRemove: widget.onRemove == null ? null : () => widget.onRemove!(index),
                );
              },
            ),
          ),
        ),
        if (widget.scripts.any((MarkedScript s) => s.status == ScriptStatus.failed))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Stopped scripts keep everything read from them; marking all again '
              'continues from where each stopped.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.script, required this.onOpen, this.onRemove});

  final MarkedScript script;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ScriptStatus status = script.status;
    final Color colour = switch (status) {
      ScriptStatus.marked => AppTheme.success,
      ScriptStatus.reviewRequired => AppTheme.caution,
      ScriptStatus.failed => AppTheme.danger,
      ScriptStatus.processing => AppTheme.accent,
      ScriptStatus.waiting => AppTheme.textSecondary,
    };
    final double? total = script.finalTotal;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppTheme.cardBackground,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AppTheme.stroke),
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
        ),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    script.document.fileName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (status == ScriptStatus.processing)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                  ),
                Text(status.label, style: TextStyle(fontSize: 12, color: colour)),
                const SizedBox(width: 16),
                SizedBox(
                  width: 110,
                  child: Text(
                    total == null
                        ? '—'
                        : '${formatMarks(total)} / ${formatMarks(script.result!.maximumTotalMarks)}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    script.finalPercentage == null ? '' : formatPercentage(script.finalPercentage!),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.accent),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove from the class',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: onRemove,
                  ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}
