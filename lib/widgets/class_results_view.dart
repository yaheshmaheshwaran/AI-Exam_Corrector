import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/models/section_totals.dart';
import 'package:exam_corrector/domain/moderation.dart';
import 'package:exam_corrector/state/marked_script.dart';

/// The class at a glance: every student, their mark, and what is left to do.
///
/// Marks shown are the ones that count — the teacher's wherever they changed
/// one — with each section's marks beside the total on a paper that has
/// sections. A row opens that student's questions.
class ClassResultsView extends StatefulWidget {
  const ClassResultsView({
    super.key,
    required this.scripts,
    required this.onOpen,
    this.onRemove,
    this.marksLookHigh = false,
    this.agreement,
  });

  /// How far the AI is from the teacher on the questions they marked.
  final ({double before, double after, int questions})? agreement;

  /// The class average is above what real classes get, and nothing
  /// moderates it.
  final bool marksLookHigh;

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
    // The whole class sits the same paper, so its sections come from any
    // marked script.
    final List<String?> sections = marked.isEmpty
        ? const <String?>[]
        : <String?>[for (final SectionTotal t in marked.first.sectionTotals) t.sectionId];

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
            if (widget.agreement case final ({double before, double after, int questions}) a)
              Tooltip(
                message: 'On the ${a.questions} question${a.questions == 1 ? '' : 's'} you marked yourself. '
                    'Before moderation the AI was ${Moderation.gap(a.before)}.',
                child: _Figure(
                  'AI vs you',
                  a.after.abs() < 0.05 ? 'level' : '${a.after > 0 ? '+' : '−'}${a.after.abs().toStringAsFixed(1)} a question',
                ),
              ),
            if (percentages.isNotEmpty)
              _Figure(
                'Class average',
                formatPercentage(
                  percentages.reduce((double a, double b) => a + b) / percentages.length,
                ),
              ),
          ],
        ),
        if (widget.marksLookHigh) ...<Widget>[
          const SizedBox(height: 8),
          Container(
            key: const Key('class-marks-high'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.cautionFill,
              border: Border.all(color: AppTheme.caution.withValues(alpha: 0.35)),
              borderRadius: BorderRadius.circular(AppTheme.controlRadius),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.trending_up, size: 18, color: AppTheme.caution),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Marks look high for a real class — a class average above '
                    '${Moderation.classHighAverage.round()}%. Open 2–3 scripts and mark or '
                    'accept their questions yourself, then use "Moderate to your marking" to bring '
                    'every script to your standard. Check the Answer key too.',
                    style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.caution),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // A column per section while they fit; a line under the name
              // when they do not.
              final bool columns = sections.isNotEmpty &&
                  constraints.maxWidth >= 440 + _Row.sectionWidth * sections.length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (columns)
                    _Header(sections: sections, removable: widget.onRemove != null),
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
                            sections: sections,
                            columns: columns,
                            onOpen: () => widget.onOpen(index),
                            onRemove: widget.onRemove == null ? null : () => widget.onRemove!(index),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              );
            },
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

/// Names the columns when the sections have columns of their own.
class _Header extends StatelessWidget {
  const _Header({required this.sections, required this.removable});

  final List<String?> sections;
  final bool removable;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppTheme.textSecondary, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 22, 4),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('Student', style: style)),
          SizedBox(width: _Row.statusWidth, child: Text('Status', style: style)),
          for (final String? id in sections)
            SizedBox(
              width: _Row.sectionWidth,
              child: Text(id == null ? 'Other' : 'Section $id', textAlign: TextAlign.right, style: style),
            ),
          SizedBox(width: 110, child: Text('Total', textAlign: TextAlign.right, style: style)),
          const SizedBox(width: 56),
          if (removable) const SizedBox(width: 40),
          const SizedBox(width: 18),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.script,
    required this.onOpen,
    this.onRemove,
    this.sections = const <String?>[],
    this.columns = false,
  });

  final MarkedScript script;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  /// The paper's sections, in order.
  final List<String?> sections;

  /// Each section in a column of its own, rather than a line under the name.
  final bool columns;

  static const double sectionWidth = 72;
  static const double statusWidth = 92;

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
    final List<SectionTotal> totals = script.sectionTotals;

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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        script.document.fileName,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      if (!columns && totals.isNotEmpty)
                        Text(
                          totals.map((SectionTotal t) => '${t.shortName} ${formatMarks(t.awarded)}').join('  ·  '),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                        ),
                    ],
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
                SizedBox(
                  width: columns ? statusWidth : null,
                  child: Text(status.label, style: TextStyle(fontSize: 12, color: colour)),
                ),
                if (!columns) const SizedBox(width: 16),
                if (columns)
                  for (final String? id in sections)
                    SizedBox(
                      width: sectionWidth,
                      child: Text(
                        switch (totals.where((SectionTotal t) => t.sectionId == id).firstOrNull) {
                          final SectionTotal t => '${formatMarks(t.awarded)}/${formatMarks(t.maximum)}',
                          null => '—',
                        },
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
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
