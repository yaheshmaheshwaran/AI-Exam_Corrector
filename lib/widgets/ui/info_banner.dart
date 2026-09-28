import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_theme.dart';

/// A message across the top of a panel: something the teacher should know
/// before going on. The [tone] says how much it matters.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.title,
    this.body,
    this.icon,
    this.tone = ToneKind.warning,
    this.action,
    this.margin = const EdgeInsets.only(bottom: 10),
  });

  final String title;
  final String? body;
  final IconData? icon;
  final ToneKind tone;
  final Widget? action;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final Tone t = c.tone(tone);
    final TextTheme text = Theme.of(context).textTheme;
    final String? body = this.body;
    return Container(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        // Half the tint of a chip: across a whole panel the same tint reads
        // far stronger than on a small label. The border keeps the hue.
        color: Color.lerp(c.surface, t.fill, 0.5),
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon ?? _icon, size: 16, color: t.foreground),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: text.titleSmall?.copyWith(color: t.foreground)),
                if (body != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(body, style: text.bodySmall?.copyWith(color: c.text)),
                ],
              ],
            ),
          ),
          if (action != null) ...<Widget>[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }

  IconData get _icon => switch (tone) {
        ToneKind.danger => Icons.error_outline,
        ToneKind.success => Icons.check_circle_outline,
        ToneKind.warning => Icons.warning_amber_rounded,
        _ => Icons.info_outline,
      };
}
