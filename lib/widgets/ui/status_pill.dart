import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_theme.dart';

/// A short status label — "Published", "Needs review", "Gemini 2.5 Flash".
///
/// The [tone] says what the status means; the theme decides its colour. A
/// [dense] pill is for inside table rows and beside question titles.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.tone = ToneKind.neutral,
    this.icon,
    this.dense = false,
    this.outlined = true,
    this.wrap = false,
    this.tooltip,
    this.onTap,
  });

  final String label;
  final ToneKind tone;
  final IconData? icon;
  final bool dense;

  /// False for a pill with a fill but no border — quieter, for long text.
  final bool outlined;

  /// True for a sentence that must be read in full — a teacher's reply —
  /// rather than cut to one line.
  final bool wrap;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Tone t = context.colors.tone(tone);
    final double size = dense ? 12 : 12.5;
    Widget pill = Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1.5 : 3),
      decoration: BoxDecoration(
        color: t.fill,
        border: outlined ? Border.all(color: t.border) : null,
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: size + 1, color: t.foreground),
            SizedBox(width: dense ? 4 : 5),
          ],
          Flexible(
            child: Text(
              label,
              overflow: wrap ? null : TextOverflow.ellipsis,
              style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, color: t.foreground, height: 1.3, letterSpacing: 0.1),
            ),
          ),
        ],
      ),
    );
    if (onTap != null) {
      pill = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: pill),
      );
    }
    if (tooltip != null) pill = Tooltip(message: tooltip, child: pill);
    return pill;
  }
}

/// A small coloured dot: the state of something at a glance.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, this.tone = ToneKind.neutral, this.size = 8});

  final ToneKind tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: context.colors.tone(tone).foreground, shape: BoxShape.circle),
    );
  }
}
