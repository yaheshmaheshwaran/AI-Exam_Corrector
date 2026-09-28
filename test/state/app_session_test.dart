import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/accounts/account_repository.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/session_results.dart';
import 'package:exam_corrector/state/app_session.dart';

import 'account_fakes.dart';
import 'fakes.dart';

void main() {
  late SqliteResultsRepository local;
  late SqliteResultsRepository cloud;
  setUp(() {
    local = SqliteResultsRepository.inMemory();
    cloud = SqliteResultsRepository.inMemory();
  });
  tearDown(() {
    local.close();
    cloud.close();
  });

  SignUpDetails details(AppRole role, String username, String member, {String code = 'PSGTECH', String? college}) =>
      SignUpDetails(
        role: role,
        collegeCode: code,
        collegeName: college,
        fullName: 'Someone $username',
        username: username,
        memberId: member,
        email: '$username@college.edu',
        password: 'password1',
      );

  test('without a server: signed out, and a teacher can mark on this computer', () async {
    final SessionResults results = SessionResults();
    final AppSession session = AppSession(results: results, localResults: local);
    expect(session.stage, SessionStage.signedOut);
    expect(session.hasServer, isFalse);
    expect(results.active, isNull, reason: 'nothing to publish to while signed out');
    await expectLater(session.signIn(login: 'x', password: 'y'), throwsA(isA<AccountException>()));

    session.continueWithoutAccount();
    expect(session.stage, SessionStage.offline);
    expect(session.role, AppRole.teacher);
    expect(results.active, same(local));

    await session.signOut();
    expect(session.stage, SessionStage.signedOut);
    expect(results.active, isNull);
  });

  test('signs in by username or email; the college’s results follow the account', () async {
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege(resultsFor: (_) => cloud);
    final SessionResults results = SessionResults();
    final AppSession session = AppSession(accounts: accounts, results: results, localResults: local);
    expect(session.stage, SessionStage.starting);
    await session.restore();
    expect(session.stage, SessionStage.signedOut);

    await expectLater(
      session.signIn(login: 'priya', password: 'wrong-one'),
      throwsA(isA<AccountException>().having((AccountException e) => e.message, 'message', contains('Wrong'))),
    );
    int changes = 0;
    session.addListener(() => changes++);
    await session.signIn(login: 'PRIYA', password: 'password1');
    expect(session.stage, SessionStage.signedIn);
    expect(session.role, AppRole.student);
    expect(session.account!.rollNo, '21CS045');
    expect(results.active, same(cloud));
    expect(changes, 1);

    await session.signOut();
    expect(accounts.signOuts, 1);
    await session.signIn(login: 'teach@college.edu', password: 'password1');
    expect(session.role, AppRole.teacher);
  });

  test('a kept account comes back next time; one not kept does not', () async {
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege();
    await AppSession(accounts: accounts).signIn(login: 'priya', password: 'password1', keep: true);
    final AppSession next = AppSession(accounts: accounts);
    await next.restore();
    expect(next.stage, SessionStage.signedIn);
    expect(next.account!.username, 'priya');

    await next.signOut();
    final AppSession after = AppSession(accounts: accounts);
    await after.restore();
    expect(after.stage, SessionStage.signedOut);
  });

  test('a teacher waits for the admin; approved, they are in', () async {
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege();
    final AppSession teacher = AppSession(accounts: accounts);
    final SignUpOutcome outcome = await teacher.signUp(details(AppRole.teacher, 'newt', 'T77'));
    expect(outcome, isA<SignedUp>());
    expect(teacher.stage, SessionStage.awaitingApproval);
    expect(teacher.role, isNull, reason: 'no marking or publishing until approved');

    // The admin approves, from their own session.
    final MemoryAccountRepository adminSide = accounts;
    await adminSide.signIn(login: 'admin', password: 'password1');
    await adminSide.setTeacherStatus(adminSide.account('newt').id, AccountStatus.active);
    await adminSide.signIn(login: 'newt', password: 'password1');

    await teacher.recheck();
    expect(teacher.stage, SessionStage.signedIn);
    expect(teacher.role, AppRole.teacher);
  });

  test('a student is linked at once; removed, they are shut out', () async {
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege();
    final AppSession student = AppSession(accounts: accounts);
    await student.signUp(details(AppRole.student, 'arun', '21 cs 046'));
    expect(student.stage, SessionStage.signedIn);
    expect(student.account!.rollNo, '21CS046');
    expect(student.account!.college.name, 'PSG Tech');

    await accounts.signIn(login: 'teach', password: 'password1');
    await accounts.setStudentStatus(accounts.account('arun').id, AccountStatus.removed);
    await accounts.signIn(login: 'arun', password: 'password1');
    await student.recheck();
    expect(student.stage, SessionStage.closed);
  });

  test('an admin registers a college; its college ID is then taken', () async {
    final AppSession admin = AppSession(accounts: MemoryAccountRepository());
    await admin.signUp(details(AppRole.admin, 'founder', 'A1', code: 'new-col', college: 'New College'));
    expect(admin.stage, SessionStage.signedIn);
    expect(admin.role, AppRole.admin);
    expect(admin.account!.college.code, 'NEW-COL');
    expect(await admin.collegeName('new-col'), 'New College');
    await expectLater(
      admin.signUp(details(AppRole.admin, 'second', 'A2', code: 'NEW-COL', college: 'Again')),
      throwsA(isA<AccountException>()),
    );
    await expectLater(
      admin.signUp(details(AppRole.student, 'lost', '1', code: 'NOPE')),
      throwsA(isA<AccountException>().having((AccountException e) => e.message, 'message', contains('No college'))),
    );
  });

  test('when the server asks, the emailed code finishes signing up', () async {
    final AppSession session = AppSession(accounts: MemoryAccountRepository.withCollege(confirmByEmail: true));
    final SignUpOutcome outcome = await session.signUp(details(AppRole.student, 'meena', '21CS050'));
    expect(outcome, isA<ConfirmEmail>());
    expect(session.stage, isNot(SessionStage.signedIn));
    await expectLater(
      session.confirmEmail(email: 'meena@college.edu', code: '000000'),
      throwsA(isA<AccountException>()),
    );
    await session.confirmEmail(email: 'meena@college.edu', code: MemoryAccountRepository.code);
    expect(session.stage, SessionStage.signedIn);
  });

  test('connecting to a server saves it and starts signed out', () async {
    final RecordingSettingsStore settings = RecordingSettingsStore();
    final List<AccountRepository> made = <AccountRepository>[];
    final AppSession session = AppSession(
      settings: settings,
      connectTo: (ServerConfig server) {
        final MemoryAccountRepository repo = MemoryAccountRepository.withCollege();
        made.add(repo);
        return repo;
      },
    );
    expect(session.hasServer, isFalse);
    await session.connect(const ServerConfig(url: 'https://abc.supabase.co', anonKey: 'public-key-0123456789'));
    expect(session.hasServer, isTrue);
    expect(session.stage, SessionStage.signedOut);
    expect(settings.savedServerUrl, 'https://abc.supabase.co');
    expect(settings.savedServerKey, 'public-key-0123456789');

    await session.signIn(login: 'teach', password: 'password1');
    await session.connect(const ServerConfig(url: 'https://xyz.supabase.co', anonKey: 'public-key-9876543210'));
    expect(session.account, isNull, reason: 'another server: signed out of the old one');
    expect((made.first as MemoryAccountRepository).disposed, isTrue);
  });
}
