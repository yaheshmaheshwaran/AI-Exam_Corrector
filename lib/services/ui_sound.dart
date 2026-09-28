import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:exam_corrector/services/settings_store.dart';

/// Which sound, by what the control does. Each is short and quiet; the
/// difference between them is what tells the teacher what happened.
enum UiSoundKind {
  /// Secondary buttons, rows, menus and chips: the lightest everyday tick.
  tap(Duration(milliseconds: 45)),

  /// The main action on a screen: a slightly fuller tone.
  press(Duration(milliseconds: 120)),

  /// Switches, checkboxes, segmented choices and tabs: a tiny high tick.
  toggle(Duration(milliseconds: 250)),

  /// Confirming something that cannot be undone: low and muted.
  remove(Duration(milliseconds: 150)),

  /// Marking finished: two soft notes rising.
  done(Duration(milliseconds: 600)),

  /// Something went wrong: two soft notes falling.
  problem(Duration(milliseconds: 600)),

  /// The app has opened: one warm chime as the opening screen's beam settles.
  welcome(Duration(milliseconds: 600));

  const UiSoundKind(this.gap);

  /// The shortest time between two plays, so a double press, a held key or a
  /// switch whose row also reacts never sounds twice.
  final Duration gap;
}

/// The app's sounds.
///
/// The sounds are small files handed to the platform once; each play is
/// then from memory, so there is no audio package and no delay. Teachers can
/// turn them off in Settings. Where the platform side is missing — tests, an
/// unsupported desktop — sounds are silently skipped.
class UiSound {
  UiSound._();

  static final UiSound instance = UiSound._();

  static const MethodChannel _channel = MethodChannel('exam_corrector/sound');

  /// Whether sounds play. Saved with the teacher's other settings.
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  SettingsStore _store = const SettingsStore();
  bool _ready = false;
  final Map<UiSoundKind, DateTime> _last = <UiSoundKind, DateTime>{};

  /// Reads the saved choice and hands the sounds to the platform.
  Future<void> load({SettingsStore store = const SettingsStore()}) async {
    _store = store;
    enabled.value = (await store.read())[SettingsStore.soundsField] != 'false';
    try {
      final Map<String, Uint8List> sounds = <String, Uint8List>{};
      for (final UiSoundKind kind in UiSoundKind.values) {
        final ByteData data = await rootBundle.load('assets/sounds/${kind.name}.wav');
        sounds[kind.name] = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }
      await _channel.invokeMethod<void>('load', sounds);
      _ready = true;
    } on MissingPluginException {
      _ready = false;
    } on PlatformException {
      _ready = false;
    }
  }

  /// Plays [kind], unless sounds are off or the same sound has just played.
  void play(UiSoundKind kind) {
    if (!_ready || !enabled.value) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _last[kind];
    if (last != null && now.difference(last) < kind.gap) return;
    _last[kind] = now;
    _channel.invokeMethod<void>('play', kind.name).catchError((Object _) {});
  }

  /// Turns sounds on or off and saves the choice.
  Future<void> setEnabled(bool on) async {
    if (enabled.value == on) return;
    enabled.value = on;
    await _store.save(sounds: on);
  }
}

/// Wraps a switch or checkbox's change handler so it plays the toggle sound.
ValueChanged<T>? toggled<T>(ValueChanged<T>? onChanged) {
  if (onChanged == null) return null;
  return (T value) {
    UiSound.instance.play(UiSoundKind.toggle);
    onChanged(value);
  };
}
