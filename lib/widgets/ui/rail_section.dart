import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';

/// Where a rail step stands, shown beside its name so the teacher can read
/// the whole rail at a glance: what is done, and what is still needed.
enum RailStatus {
  /// Nothing to show: an optional step, or one that is never "done".
  none,

  /// Required, and not yet done.
  pending,

  /// Done.
  ready,
}

/// One step in the rail: its name and state, actions at the right, and its
/// body.
///
/// Text buttons in [trailing] are drawn as compact outlined controls, so
/// "Choose…" reads as a button rather than a link.
class RailSection extends StatelessWidget {
  const RailSection({
    super.key,
    required this.label,
    required this.child,
    this.trailing,
    this.optional = false,
    this.status = RailStatus.none,
  });

  final String label;
  final Widget child;
  final Widget? trailing;

  /// Marked "Optional" so a box that looks required is not filled in
  /// unnecessarily.
  final bool optional;
  final RailStatus status;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final Widget? trailing = this.trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, 14, AppTheme.pagePadding - 4, AppTheme.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: AppTheme.controlHeight,
            child: Row(
              children: <Widget>[
                if (status != RailStatus.none) ...<Widget>[
                  _StatusMark(status: status),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.titleSmall.copyWith(color: c.text, letterSpacing: 0),
                        ),
                      ),
                      if (optional) ...<Widget>[
                        const SizedBox(width: 8),
                        Text('Optional', style: context.text.faint),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) _HeaderControls(child: trailing),
                // Header controls end where the step's content ends.
                const SizedBox(width: 4),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.only(right: 4), child: child),
        ],
      ),
    );
  }
}

/// ✓ in a filled circle when done; an empty ring while still needed.
class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.status});

  final RailStatus status;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final bool ready = status == RailStatus.ready;
    return Semantics(
      label: ready ? 'Done' : 'Still needed',
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: ready ? c.success : null,
          border: ready ? null : Border.all(color: c.borderStrong, width: 1.5),
        ),
        child: ready ? Icon(Icons.check, size: 11, color: c.surface) : null,
      ),
    );
  }
}

/// Compact outlined controls for a step's header: 28 px, text in the text
/// colour, a hairline border — the size a desktop toolbar button is.
class _HeaderControls extends StatelessWidget {
  const _HeaderControls({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ThemeData theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 28)),
            maximumSize: const WidgetStatePropertyAll<Size>(Size(double.infinity, 28)),
            padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 10)),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
                s.contains(WidgetState.disabled) ? c.textFaint : c.text),
            backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) {
              if (s.contains(WidgetState.disabled)) return Colors.transparent;
              if (s.contains(WidgetState.hovered)) return c.surfaceMuted;
              return c.surface;
            }),
            side: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
                BorderSide(color: s.contains(WidgetState.disabled) ? c.border : c.borderStrong)),
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.controlRadius)),
            ),
            textStyle: WidgetStatePropertyAll<TextStyle>(
              theme.textTheme.labelMedium!.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
            splashFactory: theme.textButtonTheme.style?.splashFactory,
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll<Size>(Size(28, 28)),
            maximumSize: const WidgetStatePropertyAll<Size>(Size(28, 28)),
            padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.zero),
            iconSize: const WidgetStatePropertyAll<double>(16),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
                s.contains(WidgetState.disabled) ? c.textFaint : c.textMuted),
            backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) =>
                s.contains(WidgetState.hovered) ? c.surfaceMuted : Colors.transparent),
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.controlRadius)),
            ),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // A gap between neighbouring header controls.
          IconTheme.merge(data: const IconThemeData(size: 16), child: _Spaced(child: child)),
        ],
      ),
    );
  }
}

/// Puts 6 px between the controls of a header row.
class _Spaced extends StatelessWidget {
  const _Spaced({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Widget child = this.child;
    if (child is Row) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < child.children.length; i++) ...<Widget>[
            if (i > 0 && child.children[i] is! SizedBox && child.children[i - 1] is! SizedBox)
              const SizedBox(width: 6),
            child.children[i],
          ],
        ],
      );
    }
    return child;
  }
}
