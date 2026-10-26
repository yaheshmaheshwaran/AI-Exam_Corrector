import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/async/observable.dart';

/// Lets a widget rebuild when an [Observable] — state kept in the plain-Dart
/// AI and marking layers — changes.
extension ObservableListenable on Observable {
  Listenable get listenable => _Adapter(this);
}

class _Adapter implements Listenable {
  const _Adapter(this._source);

  final Observable _source;

  @override
  void addListener(VoidCallback listener) => _source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _source.removeListener(listener);
}
