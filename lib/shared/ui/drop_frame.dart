import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';

/// An empty slot waiting for a file: a dashed outline on a muted ground,
/// the way desktop apps mark where something goes. Clicking it does what the
/// slot's own button does.
class DropFrame extends StatelessWidget {
  const DropFrame({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.onTap,
    this.detailKey,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onTap;
  final Key? detailKey;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final String? detail = this.detail;
    return CustomPaint(
      foregroundPainter: _Dashes(color: c.borderStrong, radius: AppTheme.controlRadius),
      child: Material(
        color: c.surfaceMuted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.controlRadius)),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.controlRadius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: c.surface,
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(AppTheme.controlRadius),
                  ),
                  child: Icon(icon, size: 16, color: onTap == null ? c.textFaint : c.textMuted),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: context.text.small.copyWith(fontWeight: FontWeight.w500, color: c.text)),
                      if (detail != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(detail, key: detailKey, style: context.text.caption),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dashes extends CustomPainter {
  const _Dashes({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final Path outline = Path()
      ..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(0.5), Radius.circular(radius)));
    for (final PathMetric metric in outline.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 7) {
        canvas.drawPath(metric.extractPath(d, d + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color || old.radius != radius;
}
