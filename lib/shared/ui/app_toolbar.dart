import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/shared/ui/backdrop.dart';
import 'package:exam_corrector/shared/ui/frosted.dart';

/// A floating glass toolbar at the top of a pane: a way back, the pane's
/// title and a quieter subtitle, and its actions at the right.
///
/// It floats over the pane's content, which scrolls up under it and is
/// blurred as it passes: lay it at the top of a [Stack] and start the
/// content [AppTheme.underBar] down. Its empty space moves the window where
/// the app draws its own title bar.
class AppToolbar extends StatelessWidget {
  const AppToolbar({
    super.key,
    this.title,
    this.subtitle,
    this.leading,
    this.onBack,
    this.backLabel = 'Back',
    this.backTooltip,
    this.actions = const <Widget>[],
    this.margin = const EdgeInsets.fromLTRB(AppTheme.floatInset, AppTheme.floatInset, AppTheme.floatInset, 0),
  });

  final String? title;
  final String? subtitle;

  /// Before the title, after any way back: a switcher, a status.
  final Widget? leading;

  /// Shows a way back when set.
  final VoidCallback? onBack;
  final String backLabel;

  /// Where the way back goes, shown on hover.
  final String? backTooltip;

  final List<Widget> actions;

  /// How far the bar floats in from the pane's edges.
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final String? title = this.title;
    final String? subtitle = this.subtitle;
    final Widget? leading = this.leading;
    return Padding(
      padding: margin,
      child: SizedBox(
        height: AppTheme.barHeight,
        child: Frosted(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const Positioned.fill(child: WindowDragArea()),
              Padding(
                padding: EdgeInsets.only(left: onBack == null ? 16 : 6, right: 8),
                child: Row(
                  children: <Widget>[
                    if (onBack != null) ...<Widget>[
                      Tooltip(
                        message: backTooltip ?? '',
                        child: TextButton.icon(
                          key: const Key('toolbar-back'),
                          onPressed: onBack,
                          style: TextButton.styleFrom(foregroundColor: c.text, iconColor: c.textMuted),
                          icon: const Icon(Icons.chevron_left, size: 18),
                          label: Text(backLabel),
                        ),
                      ),
                      Container(width: 1, height: 20, margin: const EdgeInsets.only(left: 4, right: 12), color: c.text.withValues(alpha: 0.08)),
                    ],
                    if (leading != null) ...<Widget>[leading, const SizedBox(width: 10)],
                    Expanded(
                      // The title is for reading; drags over it move the window.
                      child: IgnorePointer(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            if (title != null)
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.text.title.copyWith(fontSize: 14, letterSpacing: -0.1),
                              ),
                            if (subtitle != null)
                              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.caption.copyWith(height: 1.3)),
                          ],
                        ),
                      ),
                    ),
                    for (int i = 0; i < actions.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: 8),
                      actions[i],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A pane with a floating [AppToolbar] and a body that scrolls up under it.
///
/// The body is given the space below the bar as padding, so it starts clear
/// of the bar and slides beneath it as it scrolls; pass [scrolls] false for
/// a body that manages its own scrolling and takes [AppToolbarPane.inset].
class AppToolbarPane extends StatelessWidget {
  const AppToolbarPane({super.key, required this.toolbar, required this.body});

  final AppToolbar toolbar;

  /// Lays itself out under the bar, using [inset] as its top padding.
  final Widget body;

  /// How far a body's content starts below the top of the pane.
  static const double inset = AppTheme.underBar;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: body),
        Positioned(top: 0, left: 0, right: 0, child: toolbar),
      ],
    );
  }
}
