import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_glass.dart';
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

/// One step in the setup column, on its own glass card: its name and
/// state, actions at the right, and its body.
///
/// Text buttons in [trailing] are drawn as compact raised pills, so
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
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, AppTheme.floatInset, AppTheme.floatInset),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 14),
      decoration: AppGlass.card(),
      foregroundDecoration: AppGlass.rimOf(),
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

/// Compact controls for a step's header: 28 px raised pills with text in the
/// text colour — the size a desktop toolbar button is.
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
            backgroundColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
            overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
            shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
            backgroundBuilder: RaisedPill.secondary,
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
                s.contains(WidgetState.hovered) ? Colors.white.withValues(alpha: 0.7) : Colors.transparent),
            shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
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
