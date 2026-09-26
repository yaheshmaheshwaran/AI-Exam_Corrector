import 'package:flutter/foundation.dart';

/// Who is using the application.
enum AppRole {
  teacher('Teacher', 'Mark papers, manage syllabi and publish results.'),
  student('Student', 'See your published marks.');

  const AppRole(this.label, this.description);

  final String label;
  final String description;
}

/// The signed-in role.
///
/// Deliberately simple for now: choosing a role is enough to go in. Real
/// sign-in — accounts, passwords, a college login — belongs here and only
/// here, so the screens need not change when it comes.
class AppSession extends ChangeNotifier {
  AppSession({AppRole? role}) : _role = role;

  AppRole? _role;

  /// Null until a role is chosen.
  AppRole? get role => _role;

  void enter(AppRole role) {
    if (_role == role) return;
    _role = role;
    notifyListeners();
  }

  /// Back to choosing a role. The teacher's work is kept.
  void leave() {
    if (_role == null) return;
    _role = null;
    notifyListeners();
  }
}
