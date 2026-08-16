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
  });

  final String statusMessage;
  final bool isError;
  final bool isCorrecting;
  final VoidCallback? onCorrect;

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
          _StatusDot(isError: isError, isBusy: isCorrecting),
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
          if (isCorrecting) ...<Widget>[
            const SizedBox(
              width: 120,
              child: LinearProgressIndicator(),
            ),
            const SizedBox(width: AppTheme.gap),
          ],
          FilledButton.icon(
            onPressed: onCorrect,
            icon: isCorrecting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(isCorrecting ? 'Marking…' : 'Correct paper'),
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
