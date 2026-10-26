import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';

/// A labelled figure: "Average 14.2", "Pages 6".
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.tone});

  final String label;
  final String value;

  /// Colours the figure by meaning; null keeps it in the text colour.
  final ToneKind? tone;

  @override
  Widget build(BuildContext context) {
    final ToneKind? tone = this.tone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: context.text.caption),
        const SizedBox(height: 1),
        Text(
          value,
          style: context.text.title.copyWith(
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            color: tone == null ? null : context.colors.tone(tone).foreground,
          ),
        ),
      ],
    );
  }
}
