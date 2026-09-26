import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';

/// The window's status bar: what is happening, and the button that starts it.
///
/// Windows applications keep the primary command and the current state on one
/// bar at the foot of the window, so that is where they live here.
class CorrectionProgress extends StatelessWidget {
  const CorrectionProgress({
    super.key,
    required this.statusMessage,
    required this.isError,
    required this.isCorrecting,
    required this.onCorrect,
    this.isTranscribing = false,
    this.transcriptionProgress = 0,
    this.onCancel,
    this.correctLabel = 'Correct paper',
  });

  final String correctLabel;

  /// Offered in place of the correct button while processing runs.
  final VoidCallback? onCancel;

  final String statusMessage;
  final bool isError;
  final bool isCorrecting;
  final VoidCallback? onCorrect;

  /// True while the pipeline is running.
  final bool isTranscribing;

  /// How far processing has got, 0..1. Pages and stages are counted up front,
  /// so the bar is determinate: over several minutes that is the difference
  /// between waiting and wondering whether it has hung.
  final double transcriptionProgress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.pagePadding),
      decoration: const BoxDecoration(
        color: AppTheme.cardBackground,
        border: Border(top: BorderSide(color: AppTheme.stroke)),
      ),
      child: Row(
        children: <Widget>[
          _StatusDot(
            isError: isError,
            isBusy: isCorrecting || isTranscribing,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusMessage,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isError ? AppTheme.danger : AppTheme.textSecondary,
              ),
            ),
          ),
          if (isTranscribing) ...<Widget>[
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                // Zero would read as a stalled bar during the sidecar's start,
                // before the first page reports; indeterminate is honest there.
                value: transcriptionProgress > 0 ? transcriptionProgress : null,
              ),
            ),
            const SizedBox(width: AppTheme.gap),
          ] else if (isCorrecting) ...<Widget>[
            const SizedBox(
              width: 120,
              child: LinearProgressIndicator(),
            ),
            const SizedBox(width: AppTheme.gap),
          ],
          if (onCancel != null)
            OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('Cancel'),
            )
          else
            FilledButton.icon(
              onPressed: onCorrect,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(correctLabel),
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.isError, required this.isBusy});

  final bool isError;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final Color colour = isError
        ? AppTheme.danger
        : isBusy
            ? AppTheme.accent
            : AppTheme.success;

    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
    );
  }
}
