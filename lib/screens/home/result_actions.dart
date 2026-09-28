part of 'home_screen.dart';

/// What was marked and by which model, and what can be done with it.
///
/// The model belongs with the result rather than the command bar: when a
/// model's daily quota runs out mid-batch, marking moves down the chain, and
/// the teacher should be able to see which model produced these marks.
class _ResultActions extends StatelessWidget {
  const _ResultActions({
    required this.assessment,
    required this.compact,
    required this.developerMode,
    required this.onExport,
    required this.onInspect,
    this.onPublish,
    this.publishBlocker,
  });

  final ExamAssessment assessment;

  /// Icons alone, when the results pane is narrow.
  final bool compact;
  final bool developerMode;
  final VoidCallback? onExport;
  final VoidCallback onInspect;

  /// Publishes the result for its student; null where publishing is off.
  final VoidCallback? onPublish;

  /// Why it cannot be published yet.
  final String? publishBlocker;

  /// What was marked and how: shown under the result's title.
  static String summary(ExamAssessment assessment) {
    final CorrectionResult? result = assessment.result;
    final int pages = assessment.answerSheet.pages
        .where((ExamPage page) => !page.isBlank)
        .length;
    return <String>[
      if (result != null)
        '${result.questions.length} question${result.questions.length == 1 ? '' : 's'}',
      '$pages page${pages == 1 ? '' : 's'} read',
      if (result != null && result.model.isNotEmpty)
        'Marked by ${result.model}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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
  }
}
