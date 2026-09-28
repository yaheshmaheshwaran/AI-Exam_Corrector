import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/account.dart';
import 'package:exam_corrector/services/accounts/account_repository.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/accounts/server_errors.dart';
import 'package:exam_corrector/services/accounts/session_file.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/supabase_results_repository.dart';

/// Accounts on the college's Supabase project.
///
/// Who may see or change what is decided by the rules in
/// `supabase/setup.sql`, on the server; this only asks. A profile — role,
/// college, status — is written by the server when an account is created,
/// from what was filled in, and is never trusted from the app afterwards.
class SupabaseAccountRepository implements AccountRepository {
  SupabaseAccountRepository(
    this.server, {
    SessionFile sessionFile = const SessionFile(null),
    http.Client? httpClient,
    this.pageCache,
  }) : _sessions = sessionFile,
       client = SupabaseClient(
         server.url,
         server.anonKey,
         // Email and password only: no redirect back into the app, so the
         // plain flow, which needs nothing stored between steps.
         authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
         httpClient: httpClient,
       ) {
    _changes = client.auth.onAuthStateChange.listen(_remember, onError: (Object _) {});
  }

  /// Checks that [server] answers and is set up for Marklume — for "Test
  /// connection" before it is saved.
  static Future<void> check(ServerConfig server, {http.Client? httpClient}) async {
    final SupabaseClient client = SupabaseClient(
      server.url,
      server.anonKey,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit, autoRefreshToken: false),
      httpClient: httpClient,
    );
    try {
      await client.rpc('marklume_schema');
    } catch (error) {
      throw describeServerError(error);
    } finally {
      await client.dispose();
    }
  }

  final ServerConfig server;
  final SupabaseClient client;
  final SessionFile _sessions;

  /// Where answer sheet pages are kept once fetched, so they can be shown.
  final Directory? pageCache;

  late final StreamSubscription<AuthState> _changes;

  /// Whether the session is kept on this computer.
  bool _keep = false;

  static const String _profileColumns = '*, college:colleges(id, name, code)';

  /// Keeps the kept session up to date: the server issues new tokens as
  /// the old ones expire.
  void _remember(AuthState state) {
    final Session? session = state.session;
    if (!_keep || session == null) return;
    if (state.event == AuthChangeEvent.signedIn || state.event == AuthChangeEvent.tokenRefreshed) {
      unawaited(_sessions.write(server.url, jsonEncode(session.toJson())));
    }
  }

  Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on AppException {
      rethrow;
    } catch (error) {
      throw describeServerError(error);
    }
  }

  Future<Account> _profile() async {
    final User? user = client.auth.currentUser;
    if (user == null) throw const AccountException('You were signed out. Sign in again.');
    final Map<String, dynamic>? row = await client
        .from('profiles')
        .select(_profileColumns)
        .eq('id', user.id)
        .maybeSingle();
    final Account? account = row == null ? null : Account.fromRow(row);
    if (account == null) {
      throw const AccountException(
        'This account has no college profile. It may have been made outside Marklume — sign up here instead.',
      );
    }
    return account;
  }

  @override
  Future<Account?> restore() async {
    final String? saved = await _sessions.read(server.url);
    if (saved == null) return null;
    try {
      await client.auth.recoverSession(saved);
      _keep = true;
      final Session? session = client.auth.currentSession;
      if (session != null) await _sessions.write(server.url, jsonEncode(session.toJson()));
      return await _profile();
    } catch (error) {
      final AppException described = describeServerError(error);
      // Out of reach: keep the session for next time, and say so.
      if (described is AccountException && described.offline) throw described;
      await _sessions.delete();
      return null;
    }
  }

  @override
  Future<String?> collegeName(String code) => _call(() async {
    final Object? name = await client.rpc(
      'college_name',
      params: <String, Object?>{'p_code': College.normaliseCode(code)},
    );
    return name is String && name.isNotEmpty ? name : null;
  });

  @override
  Future<SignUpOutcome> signUp(SignUpDetails details) => _call(() async {
    // The server hides why an account could not be made, so what can be
    // checked is checked first, and said plainly.
    final Object? check = await client.rpc(
      'check_signup',
      params: <String, Object?>{
        'p_role': details.role.name,
        'p_college_code': College.normaliseCode(details.collegeCode),
        'p_username': details.username.trim().toLowerCase(),
        'p_member_id': details.memberId.trim(),
      },
    );
    final String status = check is Map ? '${check['status']}' : 'ok';
    if (status != 'ok') throw describeServerError(PostgrestException(message: status));

    _keep = false;
    final AuthResponse response = await client.auth.signUp(
      email: details.email.trim(),
      password: details.password,
      data: details.metadata,
    );
    if (response.session == null) return ConfirmEmail(details.email.trim());
    return SignedUp(await _profile());
  });

  @override
  Future<Account> confirmEmail({required String email, required String code}) => _call(() async {
    await client.auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.signup);
    return _profile();
  });

  @override
  Future<Account> signIn({required String login, required String password, bool keep = false}) => _call(() async {
    String email = login.trim();
    if (!email.contains('@')) {
      final Object? found = await client.rpc('email_for_login', params: <String, Object?>{'p_login': email});
      // An unknown username gets the same answer as a wrong password.
      if (found is! String || found.isEmpty) throw const AccountException('Wrong email, username or password.');
      email = found;
    }
    _keep = keep;
    if (!keep) await _sessions.delete();
    await client.auth.signInWithPassword(email: email, password: password);
    return _profile();
  });

  @override
  Future<Account> reload() => _call(_profile);

  @override
  Future<void> signOut() async {
    _keep = false;
    await _sessions.delete();
    try {
      await client.auth.signOut();
    } catch (_) {
      // Offline: the session is gone from this computer, which is what
      // signing out here means.
    }
    // Answer sheets fetched for this account go too: the next person at a
    // shared computer should not find them.
    final Directory? cache = pageCache;
    try {
      if (cache != null && await cache.exists()) await cache.delete(recursive: true);
    } on IOException {
      // Left for the next sign-out.
    }
  }

  @override
  Future<List<Account>> members({AppRole? role}) => _call(() async {
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query = client.from('profiles').select(_profileColumns);
    if (role != null) query = query.eq('role', role.name);
    final List<Map<String, dynamic>> rows = await query.order('full_name');
    return <Account>[
      for (final Map<String, dynamic> row in rows)
        if (Account.fromRow(row) case final Account account) account,
    ];
  });

  @override
  Future<void> setTeacherStatus(String id, AccountStatus status) => _call(() async {
    await client.rpc('set_teacher_status', params: <String, Object?>{'p_member': id, 'p_status': status.name});
  });

  @override
  Future<void> setStudentStatus(String id, AccountStatus status) => _call(() async {
    await client.rpc('set_student_status', params: <String, Object?>{'p_member': id, 'p_status': status.name});
  });

  @override
  Future<Set<String>> registeredRolls() => _call(() async {
    final List<Map<String, dynamic>> rows = await client
        .from('profiles')
        .select('roll_no')
        .eq('role', 'student')
        .eq('status', 'active');
    return <String>{
      for (final Map<String, dynamic> row in rows)
        if (row['roll_no'] case final String roll) roll,
    };
  });

  @override
  ResultsRepository? results(Account account) => SupabaseResultsRepository(client, account, pageCache: pageCache);

  @override
  Future<void> dispose() async {
    await _changes.cancel();
    await client.dispose();
  }
}
