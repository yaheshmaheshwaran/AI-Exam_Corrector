import 'package:flutter/material.dart';

/// A capsule segmented control: one choice raised white on a soft track.
/// Used where a screen switches between a few views of the same thing.
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  /// Each choice's value and label, left to right.
  final List<({T value, String label, Key? key})> segments;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<T>? onChanged = this.onChanged;
    return SegmentedButton<T>(
      showSelectedIcon: false,
      segments: <ButtonSegment<T>>[
        for (final ({T value, String label, Key? key}) s in segments)
          ButtonSegment<T>(value: s.value, label: Text(s.label, key: s.key)),
      ],
      selected: <T>{selected},
      onSelectionChanged: onChanged == null ? null : (Set<T> picked) => onChanged(picked.single),
    );
  }
}
