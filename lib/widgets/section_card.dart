import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';

/// A Fluent card. The three workflow steps each live in one of these, so the
/// window reads as a numbered sequence.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.expandChild = false,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  /// True for the results panel, which takes the remaining window height.
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        border: Border.all(color: AppTheme.stroke),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const Divider(height: 1),
          if (expandChild)
            Expanded(child: _body(child))
          else
            _body(child),
        ],
      ),
    );
  }

  Widget _body(Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: child,
      );
}
