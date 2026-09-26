import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/marking_standard.dart';

/// Everything the syllabus bonus touches is gold.
Color syllabusBadgeColour(SyllabusBadge badge) => AppTheme.gold;

/// A small badge for an answer that covers what the syllabus teaches for its
/// question: "Syllabus match +1". Nothing for [SyllabusBadge.none].
class SyllabusBadgeChip extends StatelessWidget {
  const SyllabusBadgeChip({
    super.key,
    required this.badge,
    this.bonus = 0,
    this.tooltip,
  });

  final SyllabusBadge badge;

  /// The bonus actually given; shown when above 0.
  final double bonus;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (badge == SyllabusBadge.none) return const SizedBox.shrink();
    final Color colour = syllabusBadgeColour(badge);
    final Widget chip = Container(
      key: ValueKey<String>('syllabus-badge-${badge.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.goldFill,
        border: Border.all(color: colour.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(badge == SyllabusBadge.exact ? Icons.workspace_premium : Icons.military_tech_outlined,
              size: 13, color: colour),
          const SizedBox(width: 4),
          Text(
            '${badge.label}${bonus > 0 ? ' +${formatMarks(bonus)}' : ''}',
            style: TextStyle(fontSize: 11.5, color: colour, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }
}
