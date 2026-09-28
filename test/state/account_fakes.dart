import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/account.dart';
import 'package:exam_corrector/services/accounts/account_repository.dart';
import 'package:exam_corrector/services/results/results_repository.dart';

/// Accounts held in memory, keeping the rules `supabase/setup.sql` keeps on
/// the server: colleges by their college ID, teachers waiting for the admin,
/// usernames and roll numbers taken once, removed accounts shut out.
class MemoryAccountRepository implements AccountRepository {
  MemoryAccountRepository({this.confirmByEmail = false, this.resultsFor});

  /// Whether signing up needs the code "sent" by email (always `123456`).
  final bool confirmByEmail;

  /// The college's results, as an account sees them.
  final ResultsRepository? Function(Account account)? resultsFor;

  final Map<String, College> colleges = <String, College>{};
  final Map<String, Account> _accounts = <String, Account>{};
  final Map<String, String> _passwords = <String, String>{};
  final Set<String> _unconfirmed = <String>{};
  Account? _current;
  Account? _kept;
  int _ids = 0;
  int signOuts = 0;
  bool disposed = false;

  static const String code = '123456';

  /// A college with an admin, an approved teacher and a student — every
  /// password `password1`.
  static MemoryAccountRepository withCollege({
    bool confirmByEmail = false,
    ResultsRepository? Function(Account account)? resultsFor,
  }) {
    final MemoryAccountRepository repo = MemoryAccountRepository(confirmByEmail: false, resultsFor: resultsFor);
    Future<void> add(AppRole role, String username, String name, String member, {String? college}) => repo.signUp(
      SignUpDetails(
        role: role,
        collegeCode: 'PSGTECH',
        collegeName: college,
        fullName: name,
        username: username,
        memberId: member,
        email: '$username@college.edu',
        password: 'password1',
      ),
    );
    add(AppRole.admin, 'admin', 'Dr Rao', 'A01', college: 'PSG Tech');
    add(AppRole.teacher, 'teach', 'Ms Iyer', 'T42');
    add(AppRole.student, 'priya', 'Priya S', '21CS045');
    repo._current = null;
    final Account teacher = repo.account('teach');
    repo._accounts[teacher.id] = teacher.withStatus(AccountStatus.active);
    return MemoryAccountRepository._copy(repo, confirmByEmail: confirmByEmail);
  }

  MemoryAccountRepository._copy(MemoryAccountRepository from, {required this.confirmByEmail})
    : resultsFor = from.resultsFor {
    colleges.addAll(from.colleges);
    _accounts.addAll(from._accounts);
    _passwords.addAll(from._passwords);
    _ids = from._ids;
  }

  /// The account with [username].
  Account account(String username) => _accounts.values.firstWhere((Account a) => a.username == username);

  Account? get current => _current;

  Account _need() => _current ?? (throw const AccountException('You were signed out. Sign in again.'));

  @override
  Future<Account?> restore() async {
    final Account? kept = _kept;
    if (kept == null) return null;
    return _current = _accounts[kept.id];
  }

  @override
  Future<String?> collegeName(String code) async => colleges[College.normaliseCode(code)]?.name;

  @override
  Future<SignUpOutcome> signUp(SignUpDetails details) async {
    final String code = College.normaliseCode(details.collegeCode);
    final String username = details.username.trim().toLowerCase();
    final String member = details.role == AppRole.student
        ? details.memberId.replaceAll(RegExp(r'\s+'), '').toUpperCase()
        : details.memberId.trim().toUpperCase();
    College? college = colleges[code];
    if (details.role == AppRole.admin && college != null) {
      throw const AccountException('That college ID is already registered.');
    }
    if (details.role != AppRole.admin && college == null) {
      throw const AccountException('No college has that college ID. Check it with your college admin.');
    }
    if (_accounts.values.any((Account a) => a.username == username)) {
      throw const AccountException('That username is taken. Try another.');
    }
    if (college != null &&
        _accounts.values.any(
          (Account a) => a.college.id == college!.id && a.role.isStaff == details.role.isStaff && a.memberId == member,
        )) {
      throw const AccountException('That roll number or staff ID is already registered in this college.');
    }
    if (_accounts.values.any((Account a) => a.email == details.email.trim())) {
      throw const AccountException('An account already uses that email. Sign in instead.');
    }
    college ??= colleges[code] = College(
      id: 'college-${colleges.length + 1}',
      name: details.collegeName!.trim(),
      code: code,
    );
    final Account account = Account(
      id: 'user-${++_ids}',
      email: details.email.trim(),
      username: username,
      fullName: details.fullName.trim(),
      role: details.role,
      status: details.role == AppRole.teacher ? AccountStatus.pending : AccountStatus.active,
      college: college,
      rollNo: details.role == AppRole.student ? member : null,
      staffId: details.role == AppRole.student ? null : member,
    );
    _accounts[account.id] = account;
    _passwords[account.id] = details.password;
    if (confirmByEmail) {
      _unconfirmed.add(account.email);
      return ConfirmEmail(account.email);
    }
    return SignedUp(_current = account);
  }

  @override
  Future<Account> confirmEmail({required String email, required String code}) async {
    if (!_unconfirmed.contains(email) || code.trim() != MemoryAccountRepository.code) {
      throw const AccountException('That code has expired or is wrong. Ask for a new one.');
    }
    _unconfirmed.remove(email);
    return _current = _accounts.values.firstWhere((Account a) => a.email == email);
  }

  @override
  Future<Account> signIn({required String login, required String password, bool keep = false}) async {
    final String wanted = login.trim().toLowerCase();
    final Account? found = _accounts.values
        .where((Account a) => a.email.toLowerCase() == wanted || a.username == wanted)
        .firstOrNull;
    if (found == null || _passwords[found.id] != password) {
      throw const AccountException('Wrong email, username or password.');
    }
    if (_unconfirmed.contains(found.email)) {
      throw const AccountException('Confirm your email first — type the code that was sent to it.');
    }
    _kept = keep ? found : null;
    return _current = found;
  }

  @override
  Future<Account> reload() async => _current = _accounts[_need().id]!;

  @override
  Future<void> signOut() async {
    signOuts++;
    _current = null;
    _kept = null;
  }

  @override
  Future<List<Account>> members({AppRole? role}) async {
    final Account me = _need();
    if (!me.role.isStaff || !me.isActive) return <Account>[_accounts[me.id]!];
    return <Account>[
      for (final Account a in _accounts.values)
        if (a.college.id == me.college.id && (role == null || a.role == role)) a,
    ]..sort((Account a, Account b) => a.fullName.compareTo(b.fullName));
  }

  @override
  Future<void> setTeacherStatus(String id, AccountStatus status) async {
    final Account me = _need();
    final Account? member = _accounts[id];
    if (me.role != AppRole.admin || !me.isActive) throw const AccountException('You don’t have permission to do that.');
    if (member == null || member.college.id != me.college.id) {
      throw const AccountException('That person is not in your college.');
    }
    if (member.role != AppRole.teacher || status == AccountStatus.pending) {
      throw const AccountException('You don’t have permission to do that.');
    }
    _accounts[id] = member.withStatus(status);
  }

  @override
  Future<void> setStudentStatus(String id, AccountStatus status) async {
    final Account me = _need();
    final Account? member = _accounts[id];
    if (!me.role.isStaff || !me.isActive) throw const AccountException('You don’t have permission to do that.');
    if (member == null || member.college.id != me.college.id) {
      throw const AccountException('That person is not in your college.');
    }
    if (member.role != AppRole.student ||
        !<AccountStatus>{AccountStatus.active, AccountStatus.removed}.contains(status)) {
      throw const AccountException('You don’t have permission to do that.');
    }
    _accounts[id] = member.withStatus(status);
  }

  @override
  Future<Set<String>> registeredRolls() async => <String>{
    for (final Account a in _accounts.values)
      if (a.role == AppRole.student && a.isActive && a.college.id == _need().college.id) a.rollNo!,
  };

  @override
  ResultsRepository? results(Account account) => resultsFor?.call(account);

  @override
  Future<void> dispose() async => disposed = true;
}
