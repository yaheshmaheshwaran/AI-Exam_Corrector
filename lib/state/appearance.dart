import 'package:flutter/material.dart';

import 'package:exam_corrector/services/settings_store.dart';

/// Whether the floating glass bars blur what passes beneath them, from 0
/// (off: the same bars, drawn solid) to 1 (full liquid glass) — the
/// teacher's choice, kept with their other settings.
class Transparency extends ValueNotifier<double> {
  Transparency({SettingsStore store = const SettingsStore()})
      : _store = store,
        super(standard);

  final SettingsStore _store;

  /// Where it starts until the teacher changes it: on.
  static const double standard = 1;

  Future<void> load() async {
    final String? saved = (await _store.read())[SettingsStore.transparencyField];
    value = switch (saved) {
      null || 'true' => standard,
      'false' => 0,
      _ => (double.tryParse(saved) ?? standard).clamp(0, 1).toDouble(),
    };
  }

  /// Shows [strength] at once without saving.
  void preview(double strength) => value = strength.clamp(0, 1).toDouble();

  /// Applies [strength] and saves it.
  Future<void> choose(double strength) async {
    value = strength.clamp(0, 1).toDouble();
    await _store.save(transparency: value);
  }
}

/// Makes the [Transparency] choice reachable from anywhere below the app.
class TransparencyScope extends InheritedNotifier<Transparency> {
  const TransparencyScope({super.key, required Transparency transparency, required super.child})
      : super(notifier: transparency);

  static Transparency? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TransparencyScope>()?.notifier;
}
