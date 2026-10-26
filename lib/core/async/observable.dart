/// A change signal for state kept outside Flutter.
///
/// The AI and marking layers are plain Dart (the PDF engine does not load
/// under Flutter's test runner, so tools run them with `dart run`). Screens
/// still need to know when usage or a server's state changes: they wrap an
/// [Observable] in a `Listenable` and rebuild on [notifyListeners].
mixin Observable {
  final List<void Function()> _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    for (final void Function() listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
