import 'package:exam_corrector/models/account.dart';
import 'package:exam_corrector/services/results/results_repository.dart';

/// Accounts and colleges: signing up, signing in, and who belongs to a
/// college.
///
/// The session and screens use only this, so the college server behind it —
/// Supabase today — could be replaced without changing them. Every failure is
/// an `AccountException` with a message written for the person at the screen.
abstract class AccountRepository {
  /// The account signed in on this computer last time, when it was kept.
  Future<Account?> restore();

  /// Checks a college ID before signing up: its college's name, or null
  /// when no college has it.
  Future<String?> collegeName(String code);

  Future<SignUpOutcome> signUp(SignUpDetails details);

  /// Finishes signing up with the code sent to [email].
  Future<Account> confirmEmail({required String email, required String code});

  /// Signs in with an email address or a username. [keep] remembers the
  /// account on this computer until it signs out.
  Future<Account> signIn({required String login, required String password, bool keep = false});

  /// The signed-in account as the server has it now — a pending teacher
  /// approved since, a student removed.
  Future<Account> reload();

  Future<void> signOut();

  /// The college's members, as a teacher or the admin sees them.
  Future<List<Account>> members({AppRole? role});

  /// The admin approves, turns down, removes or restores a teacher.
  Future<void> setTeacherStatus(String id, AccountStatus status);

  /// A teacher or the admin removes or restores a student.
  Future<void> setStudentStatus(String id, AccountStatus status);

  /// The roll numbers of the college's students who have signed up.
  Future<Set<String>> registeredRolls();

  /// The college's published results, as [account] may see them; null while
  /// results stay on this computer.
  ResultsRepository? results(Account account);

  /// Stops talking to the server — when another server replaces it.
  Future<void> dispose();
}
