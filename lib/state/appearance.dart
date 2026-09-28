import 'package:flutter/material.dart';

import 'package:exam_corrector/services/settings_store.dart';

/// Light, dark, or whatever the system uses — the teacher's choice, kept
/// with their other settings.
class Appearance extends ValueNotifier<ThemeMode> {
  Appearance({SettingsStore store = const SettingsStore()})
      : _store = store,
        super(ThemeMode.system);

  final SettingsStore _store;

  /// Reads the saved choice. Called before the first frame, so the window
  /// never opens in the wrong theme.
  Future<void> load() async {
    final String? saved = (await _store.read())[SettingsStore.themeField];
    value = ThemeMode.values.firstWhere(
      (ThemeMode mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  /// Applies [mode] at once and saves it.
  Future<void> choose(ThemeMode mode) async {
    if (mode == value) return;
    value = mode;
    await _store.save(theme: mode.name);
  }
}

/// Makes the [Appearance] reachable from anywhere below the app, including
/// dialogs.
class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope({super.key, required Appearance appearance, required super.child})
      : super(notifier: appearance);

  static Appearance? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

/// How clearly content shows through the frosted surfaces, from 0 (off:
/// solid surfaces, no blur) to 1 (as clear as text allows) — the teacher's
/// choice, kept with their other settings.
class Transparency extends ValueNotifier<double> {
  Transparency({SettingsStore store = const SettingsStore()})
      : _store = store,
        super(standard);

  final SettingsStore _store;

  /// Where it starts until the teacher moves it.
  static const double standard = 0.8;

  Future<void> load() async {
    final String? saved = (await _store.read())[SettingsStore.transparencyField];
    value = switch (saved) {
      null || 'true' => standard,
      'false' => 0,
      _ => (double.tryParse(saved) ?? standard).clamp(0, 1).toDouble(),
    };
  }

  /// Shows [strength] at once without saving, while the slider moves.
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
