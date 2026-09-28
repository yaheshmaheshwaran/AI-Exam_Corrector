import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/account.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/accounts/session_file.dart';
import 'package:exam_corrector/services/accounts/supabase_account_repository.dart';

/// A token the client can read the expiry of; nothing checks its signature.
String _token(String user) {
  String part(Map<String, Object?> json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final int exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  return '${part(<String, Object?>{'alg': 'HS256', 'typ': 'JWT'})}.'
      '${part(<String, Object?>{'sub': user, 'exp': exp, 'role': 'authenticated'})}.signature';
}

Map<String, Object?> _user(String id, String email) => <String, Object?>{
  'id': id,
  'aud': 'authenticated',
  'role': 'authenticated',
  'email': email,
  'app_metadata': <String, Object?>{},
  'user_metadata': <String, Object?>{},
  'created_at': '2026-09-01T00:00:00Z',
};

void main() {
  const ServerConfig server = ServerConfig(url: 'https://college.supabase.co', anonKey: 'anon-key-0123456789');
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('accounts'));
  tearDown(() => dir.deleteSync(recursive: true));

  final Map<String, Object?> profile = <String, Object?>{
    'id': 'u1',
    'email': 'priya@college.edu',
    'username': 'priya',
    'full_name': 'Priya S',
    'role': 'student',
    'status': 'active',
    'roll_no': '21CS045',
    'staff_id': null,
    'college': <String, Object?>{'id': 'c1', 'name': 'PSG Tech', 'code': 'PSGTECH'},
  };

  test('a username becomes its email, then a password sign-in; kept, the session is saved', () async {
    final List<String> asked = <String>[];
    final MockClient server0 = MockClient((http.Request request) async {
      asked.add('${request.method} ${request.url.path}');
      final String path = request.url.path;
      if (path.endsWith('/rpc/email_for_login')) {
        expect(jsonDecode(request.body), <String, Object?>{'p_login': 'priya'});
        return http.Response(
          jsonEncode('priya@college.edu'),
          200,
          headers: <String, String>{'content-type': 'application/json'},
          request: request,
        );
      }
      if (path.endsWith('/auth/v1/token')) {
        final Map<String, Object?> body = jsonDecode(request.body) as Map<String, Object?>;
        if (body['password'] != 'password1') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'code': 400,
              'error_code': 'invalid_credentials',
              'msg': 'Invalid login credentials',
            }),
            400,
            headers: <String, String>{'content-type': 'application/json'},
            request: request,
          );
        }
        expect(body['email'], 'priya@college.edu');
        return http.Response(
          jsonEncode(<String, Object?>{
            'access_token': _token('u1'),
            'token_type': 'bearer',
            'expires_in': 3600,
            'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
            'refresh_token': 'refresh-1',
            'user': _user('u1', 'priya@college.edu'),
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
          request: request,
        );
      }
      if (path.endsWith('/rest/v1/profiles')) {
        expect(request.url.queryParameters['id'], 'eq.u1');
        final bool one = (request.headers['Accept'] ?? request.headers['accept'] ?? '').contains('object');
        return http.Response(
          jsonEncode(one ? profile : <Object?>[profile]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
          request: request,
        );
      }
      return http.Response('{}', 404, request: request);
    });

    final File kept = File('${dir.path}/account-session.json');
    final SupabaseAccountRepository accounts = SupabaseAccountRepository(
      server,
      sessionFile: SessionFile(kept),
      httpClient: server0,
    );
    addTearDown(accounts.dispose);

    await expectLater(
      accounts.signIn(login: 'priya', password: 'wrong-pass'),
      throwsA(
        isA<AccountException>().having(
          (AccountException e) => e.message,
          'message',
          'Wrong email, username or password.',
        ),
      ),
    );

    final Account account = await accounts.signIn(login: 'priya', password: 'password1', keep: true);
    expect(account.rollNo, '21CS045');
    expect(account.college.name, 'PSG Tech');
    expect(account.role, AppRole.student);
    expect(asked, contains('POST /rest/v1/rpc/email_for_login'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await SessionFile(kept).read(server.url), contains('refresh-1'));

    await accounts.signOut();
    expect(kept.existsSync(), isFalse);
  });

  test('signing up checks first, then waits for the emailed code when there is no session', () async {
    Map<String, Object?>? sentMetadata;
    final MockClient server0 = MockClient((http.Request request) async {
      final String path = request.url.path;
      if (path.endsWith('/rpc/check_signup')) {
        final Map<String, Object?> body = jsonDecode(request.body) as Map<String, Object?>;
        final String status = body['p_username'] == 'taken' ? 'username_taken' : 'ok';
        return http.Response(
          jsonEncode(<String, Object?>{'status': status, 'college_name': 'PSG Tech'}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
          request: request,
        );
      }
      if (path.endsWith('/auth/v1/signup')) {
        final Map<String, Object?> body = jsonDecode(request.body) as Map<String, Object?>;
        sentMetadata = (body['data'] as Map<String, Object?>?) ?? <String, Object?>{};
        expect(body.containsKey('code_challenge'), isTrue);
        expect(body['code_challenge'], isNull, reason: 'the plain flow: nothing stored between steps');
        return http.Response(
          jsonEncode(_user('u2', 'arun@college.edu')),
          200,
          headers: <String, String>{'content-type': 'application/json'},
          request: request,
        );
      }
      return http.Response('{}', 404, request: request);
    });
    final SupabaseAccountRepository accounts = SupabaseAccountRepository(server, httpClient: server0);
    addTearDown(accounts.dispose);

    SignUpDetails details(String username) => SignUpDetails(
      role: AppRole.student,
      collegeCode: 'psg tech',
      fullName: 'Arun K',
      username: username,
      memberId: '21 CS 046',
      email: 'arun@college.edu',
      password: 'password1',
    );

    await expectLater(
      accounts.signUp(details('taken')),
      throwsA(
        isA<AccountException>().having((AccountException e) => e.message, 'message', contains('username is taken')),
      ),
    );
    final SignUpOutcome outcome = await accounts.signUp(details('Arun.K'));
    expect(outcome, isA<ConfirmEmail>().having((ConfirmEmail c) => c.email, 'email', 'arun@college.edu'));
    expect(sentMetadata, <String, Object?>{
      'role': 'student',
      'college_code': 'PSGTECH',
      'full_name': 'Arun K',
      'username': 'arun.k',
      'member_id': '21 CS 046',
    });
  });

  test('a server out of reach says so', () async {
    final MockClient down = MockClient((http.Request request) async => throw const SocketException('no route'));
    final SupabaseAccountRepository accounts = SupabaseAccountRepository(server, httpClient: down);
    addTearDown(accounts.dispose);
    await expectLater(
      accounts.collegeName('PSGTECH'),
      throwsA(isA<AccountException>().having((AccountException e) => e.offline, 'offline', isTrue)),
    );
    await expectLater(SupabaseAccountRepository.check(server, httpClient: down), throwsA(isA<AccountException>()));
  });
}
