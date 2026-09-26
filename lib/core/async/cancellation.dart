import 'package:exam_corrector/core/errors/app_exception.dart';

/// Lets a teacher stop a long correction.
///
/// Checked between pages and between requests, and wired to in-flight HTTP
/// requests so a cancelled correction does not wait out a streaming response
/// it no longer wants. Work already cached stays cached: cancelling and
/// starting again resumes rather than restarts.
class CancellationToken {
  CancellationToken();

  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  /// Throws [CancelledException] once [cancel] has been called.
  void throwIfCancelled() {
    if (_cancelled) throw const CancelledException();
  }

  /// Runs [listener] on cancellation; returns a function that unregisters it.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}
