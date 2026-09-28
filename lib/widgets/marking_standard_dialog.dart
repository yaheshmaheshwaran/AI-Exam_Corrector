import 'package:flutter/material.dart';

import 'package:exam_corrector/widgets/ui/app_dialog.dart';

import 'package:exam_corrector/services/ui_sound.dart';

import 'package:exam_corrector/app/press_feedback.dart';

import 'package:exam_corrector/widgets/ui/select_field.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/domain/marking_standard.dart';

/// Sets how strictly a paper is marked and the college's own rules, showing
/// exactly what the chosen level changes.
class MarkingStandardDialog extends StatefulWidget {
  const MarkingStandardDialog({
    super.key,
    required this.initial,
    this.sections = const <String>[],
  });

  final MarkingStandard initial;

  /// The paper's sections, offered as all-multiple-choice ones.
  final List<String> sections;

  /// The chosen standard, and whether it becomes the default for new papers.
  static Future<({MarkingStandard standard, bool asDefault})?> show(
    BuildContext context,
    MarkingStandard initial, {
    List<String> sections = const <String>[],
  }) => showAppDialog<({MarkingStandard standard, bool asDefault})>(
    context: context,
    builder: (BuildContext context) =>
        MarkingStandardDialog(initial: initial, sections: sections),
  );

  @override
  State<MarkingStandardDialog> createState() => _MarkingStandardDialogState();
}

class _MarkingStandardDialogState extends State<MarkingStandardDialog> {
  late MarkingStandard _standard = widget.initial;
  late final TextEditingController _rules = TextEditingController(
    text: widget.initial.collegeRules,
  );
  bool _asDefault = false;

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? label = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final bool judgementChanged =
        _standard.copyWith(collegeRules: _rules.text).judgementKey !=
        widget.initial.judgementKey;

    return AlertDialog(
      title: const Text('Marking standard'),
      content: SizedBox(
        width: 640,
        height: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('How strictly to mark', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              SegmentedButton<MarkingLevel>(
                key: const Key('dialog-level'),
                showSelectedIcon: false,
                segments: <ButtonSegment<MarkingLevel>>[
                  for (final MarkingLevel level in MarkingLevel.values)
                    ButtonSegment<MarkingLevel>(
                      value: level,
                      label: Text(level.label),
                    ),
                ],
                selected: <MarkingLevel>{_standard.level},
                onSelectionChanged: (Set<MarkingLevel> picked) => setState(
                  () => _standard = _standard.copyWith(level: picked.single),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _standard.level.description,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              // What this level changes, rule by rule.
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.colors.surfaceMuted,
                  border: Border.all(color: context.colors.border),
                  borderRadius: BorderRadius.circular(AppTheme.controlRadius),
                ),
                child: Table(
                  columnWidths: const <int, TableColumnWidth>{
                    0: FixedColumnWidth(150),
                    1: FlexColumnWidth(),
                  },
                  children: <TableRow>[
                    for (final ({String rule, String effect}) rule
                        in _standard.level.rules)
                      TableRow(
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(rule.rule, style: label),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              rule.effect,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('College rules', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _Choice<double>(
                    label: 'Marks in steps of',
                    value: _standard.markStep,
                    options: <double, String>{
                      1: 'whole marks',
                      0.5: 'half marks',
                      0.25: 'quarter marks',
                    },
                    onChanged: (double v) => setState(
                      () => _standard = _standard.copyWith(markStep: v),
                    ),
                  ),
                  _Choice<TotalRounding>(
                    label: 'Paper total',
                    value: _standard.totalRounding,
                    options: <TotalRounding, String>{
                      for (final TotalRounding r in TotalRounding.values)
                        r: r.words,
                    },
                    onChanged: (TotalRounding v) => setState(
                      () => _standard = _standard.copyWith(totalRounding: v),
                    ),
                  ),
                  _Choice<double>(
                    key: const Key('dialog-mcq-penalty'),
                    label: 'Wrong multiple-choice answer',
                    value: _standard.mcqPenalty,
                    options: <double, String>{
                      for (final double p in MarkingStandard.penalties)
                        p: p == 0 ? 'no penalty' : '−$p',
                    },
                    onChanged: (double v) => setState(
                      () => _standard = _standard.copyWith(mcqPenalty: v),
                    ),
                  ),
                ],
              ),
              if (_standard.mcqPenalty > 0 &&
                  widget.sections.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      'All multiple choice:',
                      style: theme.textTheme.bodySmall,
                    ),
                    for (final String section in widget.sections)
                      FilterChip(
                        label: Text('Section $section'),
                        selected: _standard.mcqSections.contains(section),
                        onSelected: (bool on) => setState(
                          () => _standard = _standard.copyWith(
                            mcqSections: <String>[
                              for (final String s in _standard.mcqSections)
                                if (s != section) s,
                              if (on) section,
                            ],
                          ),
                        ),
                      ),
                    Text(
                      '(questions with a) b) c) options are found on their own)',
                      style: context.text.caption,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const Key('dialog-college-rules'),
                controller: _rules,
                minLines: 3,
                maxLines: 5,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Written college rules (optional)',
                  hintText:
                      'e.g. Section C answers without a diagram get at most 70%.\n'
                      'Award step marks for derivations.',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              _RealismSection(
                realism: _standard.realism,
                level: _standard.level,
                onChanged: (RealismRules r) =>
                    setState(() => _standard = _standard.copyWith(realism: r)),
              ),
              const SizedBox(height: 8),
              _SyllabusBonusSection(
                bonus: _standard.syllabusBonus,
                onChanged: (SyllabusBonus b) => setState(
                  () => _standard = _standard.copyWith(syllabusBonus: b),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                judgementChanged
                    ? 'The level or written rules changed: already-marked scripts need '
                          're-marking, which uses the AI.'
                    : 'Mark steps, rounding, penalties, the realistic-marking checks and '
                          'the syllabus bonus apply at once to marks already made — no '
                          're-marking, no requests.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: judgementChanged
                      ? context.colors.warning
                      : context.colors.textMuted,
                ),
              ),
              ToggleRow(
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _asDefault,
                  onChanged: toggled(
                    (bool? on) => setState(() => _asDefault = on ?? false),
                  ),
                  title: const Text('Use for new question papers too'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('dialog-apply'),
          onPressed: () => Navigator.of(context).pop((
            standard: _standard.copyWith(collegeRules: _rules.text.trim()),
            asDefault: _asDefault,
          )),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    // Label above the list, so a long option never runs off the dialog.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        SelectField<T>(
          value: value,
          items: <DropdownMenuItem<T>>[
            for (final MapEntry<T, String> option in options.entries)
              DropdownMenuItem<T>(value: option.key, child: Text(option.value)),
          ],
          onChanged: (T? v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

/// The syllabus badge and bonus: on or off, how close counts, and how much
/// it adds.
class _SyllabusBonusSection extends StatelessWidget {
  const _SyllabusBonusSection({required this.bonus, required this.onChanged});

  final SyllabusBonus bonus;
  final ValueChanged<SyllabusBonus> onChanged;

  static String _percent(double v) => '${(v * 100).round()}%';

  static String _marks(double v) => v == 0
      ? 'badge only'
      : '+${v == v.roundToDouble() ? v.toStringAsFixed(0) : v}';

  static Map<double, String> _options(
    List<double> values,
    double current,
    String Function(double) words,
  ) => <double, String>{
    for (final double v in <double>{...values, current}.toList()..sort())
      v: words(v),
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? small = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ToggleRow(
          child: SwitchListTile(
            key: const Key('dialog-syllabus-bonus'),
            contentPadding: EdgeInsets.zero,
            value: bonus.enabled,
            onChanged: toggled(
              (bool on) => onChanged(bonus.copyWith(enabled: on)),
            ),
            title: Text('Syllabus bonus', style: theme.textTheme.titleSmall),
            subtitle: Text(
              'A badge — and a bonus mark — for an answer that covers what the '
              'syllabus teaches for its question, almost or exactly.',
              style: small,
            ),
          ),
        ),
        if (bonus.enabled) ...<Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 190,
                child: Text(
                  'Close to syllabus from ${_percent(bonus.almostThreshold)}',
                  style: small,
                ),
              ),
              Expanded(
                child: Slider(
                  key: const Key('dialog-almost-threshold'),
                  value: bonus.almostThreshold.clamp(0.5, 0.95),
                  min: 0.5,
                  max: 0.95,
                  divisions: 9,
                  label: _percent(bonus.almostThreshold),
                  onChanged: (double v) => onChanged(
                    bonus.copyWith(
                      almostThreshold: v,
                      exactThreshold: bonus.exactThreshold <= v + 1e-9
                          ? (v + 0.05).clamp(0.6, 1).toDouble()
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              SizedBox(
                width: 190,
                child: Text(
                  'Syllabus match from ${_percent(bonus.exactThreshold)}',
                  style: small,
                ),
              ),
              Expanded(
                child: Slider(
                  key: const Key('dialog-exact-threshold'),
                  value: bonus.exactThreshold.clamp(0.6, 1),
                  min: 0.6,
                  max: 1,
                  divisions: 8,
                  label: _percent(bonus.exactThreshold),
                  onChanged: (double v) => onChanged(
                    bonus.copyWith(
                      exactThreshold: v,
                      almostThreshold: bonus.almostThreshold >= v - 1e-9
                          ? (v - 0.05).clamp(0.5, 0.95).toDouble()
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: <Widget>[
              _Choice<double>(
                key: const Key('dialog-almost-bonus'),
                label: 'Close to syllabus adds',
                value: bonus.almostBonus,
                options: _options(
                  SyllabusBonus.bonuses,
                  bonus.almostBonus,
                  _marks,
                ),
                onChanged: (double v) =>
                    onChanged(bonus.copyWith(almostBonus: v)),
              ),
              _Choice<double>(
                key: const Key('dialog-exact-bonus'),
                label: 'Syllabus match adds',
                value: bonus.exactBonus,
                options: _options(
                  SyllabusBonus.bonuses,
                  bonus.exactBonus,
                  _marks,
                ),
                onChanged: (double v) =>
                    onChanged(bonus.copyWith(exactBonus: v)),
              ),
              _Choice<double>(
                key: const Key('dialog-minimum-share'),
                label: 'Only when the answer already earned',
                value: bonus.minimumShare,
                options: _options(
                  SyllabusBonus.minimumShares,
                  bonus.minimumShare,
                  (double v) =>
                      v == 0 ? 'any mark' : '${_percent(v)} of the marks',
                ),
                onChanged: (double v) =>
                    onChanged(bonus.copyWith(minimumShare: v)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Measured against the syllabus topics the question touches, and the '
            'printed mark scheme where there is one. The bonus never takes a '
            'question above its maximum.',
            style: small?.copyWith(color: context.colors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// Checks that keep marks where a real teacher would put them.
class _RealismSection extends StatelessWidget {
  const _RealismSection({
    required this.realism,
    required this.level,
    required this.onChanged,
  });

  final RealismRules realism;
  final MarkingLevel level;
  final ValueChanged<RealismRules> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? small = theme.textTheme.bodySmall;
    String pct(double v) => '${(v * 100).round()}%';
    Widget rule(
      Key key,
      bool value,
      String title,
      String detail,
      ValueChanged<bool> changed,
    ) => ToggleRow(
      child: SwitchListTile(
        key: key,
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: toggled(changed),
        title: Text(title, style: theme.textTheme.bodyMedium),
        subtitle: Text(detail, style: small),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Realistic marking', style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          'Marks the way a real examiner does, so a class is not marked far above what its '
          'students would get. Step the strictness until the totals match your own marking — '
          'it applies at once, without re-marking.',
          style: small?.copyWith(color: context.colors.textMuted),
        ),
        const SizedBox(height: 8),
        SegmentedButton<RealismStrictness>(
          key: const Key('realism-strictness'),
          showSelectedIcon: false,
          segments: <ButtonSegment<RealismStrictness>>[
            for (final RealismStrictness s in RealismStrictness.values)
              ButtonSegment<RealismStrictness>(value: s, label: Text(s.label)),
          ],
          selected: <RealismStrictness>{realism.strictness},
          onSelectionChanged: (Set<RealismStrictness> picked) =>
              onChanged(realism.copyWith(strictness: picked.single)),
        ),
        const SizedBox(height: 4),
        Text(realism.strictness.description, style: small),
        const SizedBox(height: 6),
        Container(
          key: const Key('realism-rules'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: context.colors.surfaceMuted,
            border: Border.all(color: context.colors.border),
            borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          ),
          child: Table(
            columnWidths: const <int, TableColumnWidth>{
              0: FixedColumnWidth(150),
              1: FlexColumnWidth(),
            },
            children: <TableRow>[
              for (final ({String rule, String effect}) rule
                  in realism.strictness.rules)
                TableRow(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        rule.rule,
                        style: small?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(rule.effect, style: small),
                    ),
                  ],
                ),
            ],
          ),
        ),
        rule(
          const Key('realism-band'),
          realism.bandCap,
          'Quality band cap',
          'An answer’s mark stays within its band — at ${level.label}, Good up to '
              '${pct(QualityBand.good.shareAt(level, realism.strictness))}, '
              'Satisfactory ${pct(QualityBand.satisfactory.shareAt(level, realism.strictness))}, '
              'Weak ${pct(QualityBand.weak.shareAt(level, realism.strictness))}, '
              'Poor ${pct(QualityBand.poor.shareAt(level, realism.strictness))}.',
          (bool on) => onChanged(realism.copyWith(bandCap: on)),
        ),
        rule(
          const Key('realism-length'),
          realism.lengthCap,
          'Length cap',
          'An answer far shorter than a full one cannot earn most of the marks — five lines '
              'do not earn 11 of 13. A diagram counts as ${RealismRules.visualWords} words.',
          (bool on) => onChanged(realism.copyWith(lengthCap: on)),
        ),
        if (realism.lengthCap)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: _Choice<double>(
              key: const Key('realism-words'),
              label: 'A full answer, where the answer key does not say',
              value: realism.wordsPerMark,
              options: <double, String>{
                for (final double v in <double>{
                  ...RealismRules.wordsPerMarkOptions,
                  realism.wordsPerMark,
                }.toList()..sort())
                  v: '${v.round()} words per mark',
              },
              onChanged: (double v) =>
                  onChanged(realism.copyWith(wordsPerMark: v)),
            ),
          ),
        rule(
          const Key('realism-full-marks'),
          realism.fullMarksGate,
          'Full marks only for a complete answer',
          'Full marks need every point complete, nothing resting on an uncertain reading, and '
              'confident marking — otherwise one step below.',
          (bool on) => onChanged(realism.copyWith(fullMarksGate: on)),
        ),
      ],
    );
  }
}
