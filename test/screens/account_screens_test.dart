import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/app/app.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/screens/account/server_dialog.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/state/app_session.dart';

import '../state/account_fakes.dart';
import '../state/fakes.dart';

void main() {
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<AppSession> open(WidgetTester tester, MemoryAccountRepository accounts) async {
    final AppSession session = AppSession(accounts: accounts);
    await tester.runAsync(session.restore);
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(), session: session));
    await tester.pump();
    return session;
  }

  Future<void> tapAndWait(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('no server yet: connect, or mark without an account', (WidgetTester tester) async {
    tall(tester);
    final RecordingSettingsStore settings = RecordingSettingsStore();
    final AppSession session = AppSession(
      settings: settings,
      connectTo: (ServerConfig _) => MemoryAccountRepository.withCollege(),
    );
    await tester.pumpWidget(ExamCorrectorApp(controller: fakeController(), session: session));
    await tester.pump();
    expect(find.text('Connect to your college server'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-login')), findsNothing);

    // The server dialog checks the address, tests it, then saves it.
    await tester.tap(find.byKey(const Key('connect-server')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('server-url')), 'http://college.example');
    await tester.enterText(find.byKey(const Key('server-key')), 'anon-key-0123456789-abc');
    await tapAndWait(tester, find.byKey(const Key('server-save')));
    expect(find.textContaining('should start with https://'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('server-url')), 'https://college.supabase.co/');
    await tapAndWait(tester, find.byKey(const Key('server-save')));
    expect(settings.savedServerUrl, 'https://college.supabase.co');
    expect(find.byKey(const Key('sign-in-login')), findsOneWidget);
    expect(find.text('college.supabase.co'), findsOneWidget);

    // A teacher can still mark on this computer.
    await tester.tap(find.byKey(const Key('continue-offline')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('switch-role')), findsOneWidget);
    await tapAndWait(tester, find.byKey(const Key('switch-role')));
    expect(find.byKey(const Key('sign-in-screen')), findsOneWidget);
  });

  testWidgets('the server dialog reports what "Test connection" found', (WidgetTester tester) async {
    tall(tester);
    bool answers = false;
    final AppSession session = AppSession(connectTo: (ServerConfig _) => MemoryAccountRepository());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerDialog(
            session: session,
            probe: (ServerConfig server) async {
              if (!answers) throw const AccountException('The college server is not set up for Marklume yet.');
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('server-url')), 'https://college.supabase.co');
    await tester.enterText(find.byKey(const Key('server-key')), 'anon-key-0123456789-abc');
    await tapAndWait(tester, find.byKey(const Key('server-test')));
    expect(find.text('The college server is not set up for Marklume yet.'), findsOneWidget);
    answers = true;
    await tapAndWait(tester, find.byKey(const Key('server-test')));
    expect(find.text('Connected — college.supabase.co is ready for Marklume.'), findsOneWidget);
    expect(session.hasServer, isFalse, reason: 'testing does not save');
  });

  testWidgets('sign-up: each role asks for its own details; a student is in at once', (WidgetTester tester) async {
    tall(tester);
    final AppSession session = await open(tester, MemoryAccountRepository.withCollege());
    await tester.tap(find.byKey(const Key('open-sign-up')));
    await tester.pumpAndSettle();

    // Student: a roll number, no college name.
    expect(find.text('Roll number'), findsOneWidget);
    expect(find.byKey(const Key('sign-up-college-name')), findsNothing);
    // Teacher: a staff ID.
    await tester.tap(find.byKey(const Key('sign-up-teacher')));
    await tester.pumpAndSettle();
    expect(find.text('Staff ID'), findsOneWidget);
    // Admin: registers the college, so its name too.
    await tester.tap(find.byKey(const Key('sign-up-admin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign-up-college-name')), findsOneWidget);
    expect(find.text('Register college'), findsOneWidget);

    // Back to student; the college ID is looked up as it is typed.
    await tester.tap(find.byKey(const Key('sign-up-student')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sign-up-college-code')), 'psgtech');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Joining: PSG Tech'), findsOneWidget);

    // Nothing leaves until the form is right.
    await tapAndWait(tester, find.byKey(const Key('sign-up-submit')));
    expect(find.text('Enter your full name.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('sign-up-name')), 'Arun K');
    await tester.enterText(find.byKey(const Key('sign-up-username')), 'arun');
    await tester.enterText(find.byKey(const Key('sign-up-member')), '21cs046');
    await tester.enterText(find.byKey(const Key('sign-up-email')), 'arun@college.edu');
    await tester.enterText(find.byKey(const Key('sign-up-password')), 'password1');
    await tester.enterText(find.byKey(const Key('sign-up-password-again')), 'password2');
    await tapAndWait(tester, find.byKey(const Key('sign-up-submit')));
    expect(find.text('The two passwords are different.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('sign-up-password-again')), 'password1');
    await tapAndWait(tester, find.byKey(const Key('sign-up-submit')));
    expect(session.stage, SessionStage.signedIn);
    expect(find.textContaining('Arun K · 21CS046 · PSG Tech'), findsOneWidget);
  });

  testWidgets('a server that asks for the emailed code gets it here', (WidgetTester tester) async {
    tall(tester);
    final AppSession session = await open(tester, MemoryAccountRepository.withCollege(confirmByEmail: true));
    await tester.tap(find.byKey(const Key('open-sign-up')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sign-up-college-code')), 'PSGTECH');
    await tester.enterText(find.byKey(const Key('sign-up-name')), 'Meena R');
    await tester.enterText(find.byKey(const Key('sign-up-username')), 'meena');
    await tester.enterText(find.byKey(const Key('sign-up-member')), '21CS050');
    await tester.enterText(find.byKey(const Key('sign-up-email')), 'meena@college.edu');
    await tester.enterText(find.byKey(const Key('sign-up-password')), 'password1');
    await tester.enterText(find.byKey(const Key('sign-up-password-again')), 'password1');
    await tapAndWait(tester, find.byKey(const Key('sign-up-submit')));
    expect(find.textContaining('We sent a code to meena@college.edu'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('email-code')), MemoryAccountRepository.code);
    await tapAndWait(tester, find.byKey(const Key('email-code-submit')));
    expect(session.stage, SessionStage.signedIn);
  });

  testWidgets('a teacher waits for approval, then is in with the account menu', (WidgetTester tester) async {
    tall(tester);
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege();
    final AppSession session = await open(tester, accounts);
    await tester.tap(find.byKey(const Key('open-sign-up')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign-up-teacher')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sign-up-college-code')), 'PSGTECH');
    await tester.enterText(find.byKey(const Key('sign-up-name')), 'Mr Newton');
    await tester.enterText(find.byKey(const Key('sign-up-username')), 'newt');
    await tester.enterText(find.byKey(const Key('sign-up-member')), 'T77');
    await tester.enterText(find.byKey(const Key('sign-up-email')), 'newt@college.edu');
    await tester.enterText(find.byKey(const Key('sign-up-password')), 'password1');
    await tester.enterText(find.byKey(const Key('sign-up-password-again')), 'password1');
    await tapAndWait(tester, find.byKey(const Key('sign-up-submit')));
    expect(find.byKey(const Key('pending-screen')), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);

    await tapAndWait(tester, find.byKey(const Key('pending-recheck')));
    expect(find.text('Not approved yet. Try again a little later.'), findsOneWidget);

    // The admin approves (on their own computer).
    await tester.runAsync(() async {
      final Account me = session.account!;
      await accounts.signIn(login: 'admin', password: 'password1');
      await accounts.setTeacherStatus(me.id, AccountStatus.active);
      await accounts.signIn(login: 'newt', password: 'password1');
    });
    await tapAndWait(tester, find.byKey(const Key('pending-recheck')));
    expect(session.stage, SessionStage.signedIn);
    expect(find.byKey(const Key('account-menu')), findsOneWidget);

    await tester.tap(find.byKey(const Key('account-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Mr Newton'), findsOneWidget);
    await tapAndWait(tester, find.byKey(const Key('switch-role')));
    expect(find.byKey(const Key('sign-in-screen')), findsOneWidget);
  });

  testWidgets('the college: the admin approves teachers; a teacher removes a student', (WidgetTester tester) async {
    tall(tester);
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege();
    await accounts.signUp(
      const SignUpDetails(
        role: AppRole.teacher,
        collegeCode: 'PSGTECH',
        fullName: 'Mr Newton',
        username: 'newt',
        memberId: 'T77',
        email: 'newt@college.edu',
        password: 'password1',
      ),
    );
    final AppSession session = await open(tester, accounts);
    Future<void> signIn(String login) async {
      await tester.enterText(find.byKey(const Key('sign-in-login')), login);
      await tester.enterText(find.byKey(const Key('sign-in-password')), 'password1');
      await tapAndWait(tester, find.byKey(const Key('sign-in-submit')));
    }

    await signIn('admin');
    await tester.tap(find.byKey(const Key('account-menu')));
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.byKey(const Key('open-college')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('PSGTECH'), findsOneWidget);
    expect(find.textContaining('1 waiting'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tab-teachers')));
    await tester.pumpAndSettle();
    final String newt = accounts.account('newt').id;
    await tapAndWait(tester, find.byKey(Key('approve-$newt')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(accounts.account('newt').status, AccountStatus.active);
    expect(find.byKey(Key('remove-$newt')), findsOneWidget);

    // A teacher sees students only, and can take one out.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.runAsync(session.signOut);
    await tester.pumpAndSettle();
    await signIn('teach');
    await tester.tap(find.byKey(const Key('account-menu')));
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.byKey(const Key('open-college')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tab-teachers')), findsNothing);
    final String priya = accounts.account('priya').id;
    await tester.tap(find.byKey(Key('remove-$priya')));
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.text('Remove').last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(accounts.account('priya').status, AccountStatus.removed);
    expect(find.byKey(Key('restore-$priya')), findsOneWidget);
  });

  testWidgets('a removed student is told so on signing in', (WidgetTester tester) async {
    tall(tester);
    final MemoryAccountRepository accounts = MemoryAccountRepository.withCollege();
    await accounts.signIn(login: 'teach', password: 'password1');
    await accounts.setStudentStatus(accounts.account('priya').id, AccountStatus.removed);
    await accounts.signOut();
    await open(tester, accounts);
    await tester.enterText(find.byKey(const Key('sign-in-login')), 'priya');
    await tester.enterText(find.byKey(const Key('sign-in-password')), 'password1');
    await tapAndWait(tester, find.byKey(const Key('sign-in-submit')));
    expect(find.text('Your account is not active'), findsOneWidget);
    expect(find.byKey(const Key('pending-recheck')), findsNothing);
  });
}
