import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

/// The window's own frame, where the app draws it itself.
///
/// On macOS the content runs up under a transparent title bar, with the
/// window's close, minimise and zoom buttons over the rail; the app's
/// floating bars then move the window when dragged and zoom it when
/// double-clicked, as a title bar would. Elsewhere the system's title bar
/// stays, and all of this does nothing.
abstract final class WindowChrome {
  static const MethodChannel _channel = MethodChannel('exam_corrector/window');

  /// Whether the window's own buttons sit over the app, so the rail leaves
  /// room for them at its top.
  static bool get integratedTitleBar => !kIsWeb && Platform.isMacOS;

  static final ValueNotifier<bool> _buttonsShown = ValueNotifier<bool>(integratedTitleBar);

  /// Whether the window's own buttons are over the app now: they are not in
  /// full screen, where the system hides them.
  static ValueListenable<bool> get buttonsShown => _buttonsShown;

  @visibleForTesting
  static set buttonsShownForTesting(bool shown) => _buttonsShown.value = shown;

  /// Follows the window in and out of full screen. Called once at startup.
  static Future<void> watch() async {
    if (!integratedTitleBar) return;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'fullScreen') _buttonsShown.value = call.arguments != true;
    });
    try {
      _buttonsShown.value = await _channel.invokeMethod<bool>('isFullScreen') != true;
    } on MissingPluginException {
      // Tests, and builds without the window channel: the buttons are shown.
    } on PlatformException {
      // Unknown: the buttons are taken to be shown, as they usually are.
    }
  }

  /// Moves the window with the pointer, from a drag that has just begun.
  static Future<void> startDrag() => _call('startDrag');

  /// Zooms the window, or restores it, as double-clicking a title bar does.
  static Future<void> zoom() => _call('zoom');

  static Future<void> _call(String method) async {
    if (!integratedTitleBar) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Tests, and builds without the window channel: the frame stays put.
    } on PlatformException {
      // The window could not be moved this time; nothing to recover.
    }
  }
}
