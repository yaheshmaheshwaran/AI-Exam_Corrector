import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// What a background run tells the computer: stay awake, show progress on
/// the app's icon, and say when it is done.
abstract class BackgroundSignals {
  const BackgroundSignals();

  /// The system's own, where it has one; otherwise nothing happens.
  factory BackgroundSignals.platform() =>
      !kIsWeb && Platform.isMacOS ? const MacBackgroundSignals() : const NoBackgroundSignals();

  /// Keeps the computer from sleeping while [on].
  Future<void> keepAwake(bool on);

  /// Shows [label] on the app's icon; null clears it.
  Future<void> badge(String? label);

  /// Asks once whether notifications may be shown.
  Future<void> requestNotifications();

  /// Tells the teacher [title] and [body] — only when they are working in
  /// another app, since the window says it already otherwise.
  Future<void> notify(String title, String body);
}

/// macOS, through the window's `exam_corrector/background` channel.
class MacBackgroundSignals extends BackgroundSignals {
  const MacBackgroundSignals();

  static const MethodChannel _channel = MethodChannel('exam_corrector/background');

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null; // Tests, and builds without the channel.
    } on PlatformException {
      return null; // Best effort: marking carries on regardless.
    }
  }

  @override
  Future<void> keepAwake(bool on) => _call<void>('keepAwake', on);

  @override
  Future<void> badge(String? label) => _call<void>('badge', label);

  @override
  Future<void> requestNotifications() => _call<bool>('requestNotifications');

  @override
  Future<void> notify(String title, String body) async {
    if (await _call<bool>('isActive') ?? true) return;
    await _call<void>('notify', <String, String>{'title': title, 'body': body});
  }
}

/// Elsewhere: nothing.
class NoBackgroundSignals extends BackgroundSignals {
  const NoBackgroundSignals();

  @override
  Future<void> keepAwake(bool on) async {}

  @override
  Future<void> badge(String? label) async {}

  @override
  Future<void> requestNotifications() async {}

  @override
  Future<void> notify(String title, String body) async {}
}
