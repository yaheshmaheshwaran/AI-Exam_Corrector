import 'package:exam_corrector/domain/json_read.dart';

/// Who is using the application.
enum AppRole {
  admin('College admin', 'Register your college and approve its teachers.'),
  teacher('Teacher', 'Mark papers, manage syllabi and publish results.'),
  student('Student', 'See your published marks.');

  const AppRole(this.label, this.description);

  final String label;
  final String description;

  /// Teachers and the college admin: those who mark and see every student.
  bool get isStaff => this != AppRole.student;

  static AppRole? parse(String? name) => switch (name) {
    'admin' => AppRole.admin,
    'teacher' => AppRole.teacher,
    'student' => AppRole.student,
    _ => null,
  };
}

/// Where an account stands in its college.
enum AccountStatus {
  /// A teacher waiting for the college admin.
  pending,
  active,

  /// A teacher the college admin turned down.
  rejected,

  /// Taken out of the college by a teacher or the admin; can be restored.
  removed;

  static AccountStatus parse(String? name) =>
      AccountStatus.values.where((AccountStatus s) => s.name == name).firstOrNull ?? AccountStatus.pending;
}

/// A college: what students and teachers join, by its college ID.
class College {
  const College({required this.id, required this.name, required this.code});

  final String id;
  final String name;

  /// The college ID people type to join — short, upper case, shared by the
  /// admin.
  final String code;

  static College? fromJson(Object? json) {
    if (json is! Map) return null;
    final String? id = readString(json['id']);
    final String? name = readString(json['name']);
    final String? code = readString(json['code']);
    if (id == null || name == null || code == null) return null;
    return College(id: id, name: name, code: code);
  }

  /// A college ID as it is stored: upper case, no spaces.
  static String normaliseCode(String code) => code.replaceAll(RegExp(r'\s+'), '').toUpperCase();
}

/// One person's account in their college.
class Account {
  const Account({
    required this.id,
    required this.email,
    required this.username,
    required this.fullName,
    required this.role,
    required this.status,
    required this.college,
    this.rollNo,
    this.staffId,
  });

  final String id;
  final String email;
  final String username;
  final String fullName;
  final AppRole role;
  final AccountStatus status;
  final College college;

  /// A student's roll number: what their results are published under.
  final String? rollNo;

  /// A teacher's or admin's staff ID.
  final String? staffId;

  bool get isActive => status == AccountStatus.active;

  /// The roll number or staff ID, whichever this account has.
  String get memberId => rollNo ?? staffId ?? '';

  Account withStatus(AccountStatus status) => Account(
    id: id,
    email: email,
    username: username,
    fullName: fullName,
    role: role,
    status: status,
    college: college,
    rollNo: rollNo,
    staffId: staffId,
  );

  /// A row of `profiles` with its college joined in as `college`.
  static Account? fromRow(Map<String, Object?> row) {
    final String? id = readString(row['id']);
    final AppRole? role = AppRole.parse(readString(row['role']));
    final College? college = College.fromJson(row['college']);
    if (id == null || role == null || college == null) return null;
    return Account(
      id: id,
      email: readString(row['email']) ?? '',
      username: readString(row['username']) ?? '',
      fullName: readString(row['full_name']) ?? '',
      role: role,
      status: AccountStatus.parse(readString(row['status'])),
      college: college,
      rollNo: readString(row['roll_no']),
      staffId: readString(row['staff_id']),
    );
  }
}

/// What someone fills in to sign up.
class SignUpDetails {
  const SignUpDetails({
    required this.role,
    required this.collegeCode,
    this.collegeName,
    required this.fullName,
    required this.username,
    required this.memberId,
    required this.email,
    required this.password,
  });

  final AppRole role;
  final String collegeCode;

  /// Only when registering a college (the admin).
  final String? collegeName;
  final String fullName;
  final String username;

  /// A student's roll number, or a teacher's or admin's staff ID.
  final String memberId;
  final String email;
  final String password;

  /// What the server's sign-up trigger reads.
  Map<String, Object?> get metadata => <String, Object?>{
    'role': role.name,
    'college_code': College.normaliseCode(collegeCode),
    if (collegeName != null) 'college_name': collegeName!.trim(),
    'full_name': fullName.trim(),
    'username': username.trim().toLowerCase(),
    'member_id': memberId.trim(),
  };
}

/// How signing up ended.
sealed class SignUpOutcome {
  const SignUpOutcome();
}

/// Signed up and signed in.
class SignedUp extends SignUpOutcome {
  const SignedUp(this.account);

  final Account account;
}

/// The server sent a code to [email]; it must be typed in before signing in.
class ConfirmEmail extends SignUpOutcome {
  const ConfirmEmail(this.email);

  final String email;
}
