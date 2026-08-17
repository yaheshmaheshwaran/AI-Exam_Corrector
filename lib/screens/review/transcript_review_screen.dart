import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/state/correction_controller.dart';
import 'package:exam_corrector/widgets/transcript_line_tile.dart';

/// The gate between recognition and marking.
///
/// Handwriting recognition is good, not reliable, and a misread line becomes a
/// wrong mark with a confident explanation attached — the worst possible
/// failure for a marking tool. This screen makes that visible and fixable: the
/// teacher sees each line beside the strip of page it was read from, and the
/// ones the recogniser was unsure of are highlighted and can be filtered down
/// to on their own.
class TranscriptReviewScreen extends StatefulWidget {
  const TranscriptReviewScreen({super.key, required this.controller});

  final CorrectionController controller;

  static const String routeName = '/transcript-review';

  @override
  State<TranscriptReviewScreen> createState() => _TranscriptReviewScreenState();
}

class _TranscriptReviewScreenState extends State<TranscriptReviewScreen> {
  bool _onlyUncertain = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (BuildContext context, _) {
          final DocumentTranscript? transcript = widget.controller.transcript;

          if (transcript == null) {
            return const Center(child: Text('Nothing to review.'));
          }

          return Column(
            children: <Widget>[
              _Header(
                transcript: transcript,
                uncertain: widget.controller.uncertainLineCount,
                onlyUncertain: _onlyUncertain,
                onToggleFilter: (bool value) =>
                    setState(() => _onlyUncertain = value),
              ),
              Expanded(child: _body(transcript)),
              _Footer(
                transcript: transcript,
                uncertain: widget.controller.uncertainLineCount,
                onConfirm: () {
                  widget.controller.confirmTranscript();
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _body(DocumentTranscript transcript) {
    final double threshold =
        widget.controller.config.ocrConfidenceThreshold;
    final List<_Entry> entries = _entries(transcript, threshold);

    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Every line was recognised confidently. Nothing needs checking.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppTheme.pagePadding),
      itemCount: entries.length,
      itemBuilder: (BuildContext context, int index) {
        final _Entry entry = entries[index];

        if (entry.heading != null) {
          return Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 16, bottom: 8),
            child: Text(
              entry.heading!,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          );
        }

        return TranscriptLineTile(
          // Keyed by position so the list recycles tiles onto the right line
          // instead of carrying a half-typed correction to its neighbour.
          key: ValueKey<String>('${entry.pageIndex}:${entry.lineIndex}'),
          line: entry.line!,
          threshold: threshold,
          onChanged: (String text) => widget.controller.updateLine(
            entry.pageIndex,
            entry.lineIndex,
            text,
          ),
          onRevert: () => widget.controller.revertLine(
            entry.pageIndex,
            entry.lineIndex,
          ),
        );
      },
    );
  }

  /// Flattens the transcript into headings and lines, honouring the filter.
  ///
  /// A page whose every line is confident is dropped entirely while filtering,
  /// heading included — otherwise the filtered view is mostly page headers.
  List<_Entry> _entries(DocumentTranscript transcript, double threshold) {
    final List<_Entry> entries = <_Entry>[];

    for (int pageIndex = 0; pageIndex < transcript.pages.length; pageIndex++) {
      final PageTranscript page = transcript.pages[pageIndex];

      final List<_Entry> pageEntries = <_Entry>[];
      for (int lineIndex = 0; lineIndex < page.lines.length; lineIndex++) {
        final TextLine line = page.lines[lineIndex];
        if (_onlyUncertain && !line.isUncertain(threshold)) continue;

        pageEntries.add(
          _Entry.line(pageIndex: pageIndex, lineIndex: lineIndex, line: line),
        );
      }

      if (pageEntries.isEmpty) continue;

      entries.add(_Entry.heading('Page ${page.pageNumber}'));
      entries.addAll(pageEntries);
    }

    return entries;
  }
}

class _Entry {
  const _Entry.heading(this.heading)
      : line = null,
        pageIndex = -1,
        lineIndex = -1;

  const _Entry.line({
    required this.pageIndex,
    required this.lineIndex,
    required this.line,
  }) : heading = null;

  final String? heading;
  final TextLine? line;
  final int pageIndex;
  final int lineIndex;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.transcript,
    required this.uncertain,
    required this.onlyUncertain,
    required this.onToggleFilter,
  });

  final DocumentTranscript transcript;
  final int uncertain;
  final bool onlyUncertain;
  final ValueChanged<bool> onToggleFilter;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.pagePadding,
        vertical: 10,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.cardBackground,
        border: Border(bottom: BorderSide(color: AppTheme.stroke)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.fact_check_outlined,
              size: 18, color: AppTheme.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Check the transcript', style: theme.textTheme.titleMedium),
                Text(
                  '${transcript.lineCount} line(s) read from '
                  '${transcript.pages.length} page(s) by '
                  '${transcript.engine.split('/').last}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          if (uncertain > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Switch(
                  value: onlyUncertain,
                  onChanged: onToggleFilter,
                ),
                const SizedBox(width: 4),
                Text(
                  'Show only the $uncertain uncertain line(s)',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.transcript,
    required this.uncertain,
    required this.onConfirm,
  });

  final DocumentTranscript transcript;
  final int uncertain;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final int edited = transcript.editedCount;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.pagePadding,
        vertical: 10,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.cardBackground,
        border: Border(top: BorderSide(color: AppTheme.stroke)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              uncertain == 0
                  ? '$edited correction(s) made. Nothing is still flagged.'
                  : '$edited correction(s) made. $uncertain line(s) are still '
                      'flagged as uncertain — they will be marked as they read '
                      'now.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: uncertain == 0
                        ? AppTheme.textSecondary
                        : AppTheme.caution,
                  ),
            ),
          ),
          const SizedBox(width: AppTheme.gap),
          FilledButton.icon(
            onPressed: onConfirm,
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Use this transcript'),
          ),
        ],
      ),
    );
  }
}
