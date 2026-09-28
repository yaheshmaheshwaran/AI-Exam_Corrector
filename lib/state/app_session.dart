import 'package:flutter/foundation.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/account.dart';
import 'package:exam_corrector/services/accounts/account_repository.dart';
import 'package:exam_corrector/services/accounts/server_config.dart';
import 'package:exam_corrector/services/results/results_repository.dart';
import 'package:exam_corrector/services/results/session_results.dart';
import 'package:exam_corrector/services/settings_store.dart';

export 'package:exam_corrector/models/account.dart';

/// Where the person at the screen is.
enum SessionStage {
  /// Looking for an account kept from last time.
  starting,

  /// No one is signed in.
  signedOut,

  /// A teacher waiting for the college admin to approve them.
  awaitingApproval,

  /// Turned down, or removed from the college.
  closed,

  signedIn,

  /// A teacher marking on this computer without an account.
  offline,
}

/// Who is using the application, and the college they are signed in to.
///
/// Signing in, out and up happens here and only here: the screens show what
/// the stage says, and the results everyone reads follow the account — the
/// college's on its server once signed in, this computer's own for a teacher
/// working without an account.
class AppSession extends ChangeNotifier {
  AppSession({
    AccountRepository? accounts,
    ServerConfig? server,
    this.connectTo,
    this.settings = const SettingsStore(),
    SessionResults? results,
    this.localResults,
  }) : _accounts = accounts,
       _server = server,
       _results = results,
       _stage = accounts == null ? SessionStage.signedOut : SessionStage.starting {
    _route();
  }

  /// Already signed in as [account] — for tests and previews.
  AppSession.signedIn(Account account, {AccountRepository? accounts, SessionResults? results, this.localResults})
    : _accounts = accounts,
      _server = null,
      connectTo = null,
      settings = const SettingsStore(),
      _results = results,
      _account = account,
      _stage = SessionStage.signedIn {
    _route();
  }

  /// Makes the accounts of a newly entered server.
  final AccountRepository Function(ServerConfig server)? connectTo;
  final SettingsStore settings;

  /// What the app's results calls go to; switched as people sign in and out.
  final SessionResults? _results;

  /// This computer's own results, for a teacher without an account.
  final ResultsRepository? localResults;

  AccountRepository? _accounts;
  ServerConfig? _server;
  Account? _account;
  SessionStage _stage;
  String? _notice;

  SessionStage get stage => _stage;
  Account? get account => _account;
  AccountRepository? get accounts => _accounts;
  ServerConfig? get server => _server;

  /// Whether there is a college server to sign in to.
  bool get hasServer => _accounts != null;

  /// Something to tell the person on the sign-in screen: the server could
  /// not be reached when looking for their kept account.
  String? get notice => _notice;

  /// The role in use; null until someone is in.
  AppRole? get role => switch (_stage) {
    SessionStage.offline => AppRole.teacher,
    SessionStage.signedIn => _account?.role,
    _ => null,
  };

  AccountRepository get _need => _accounts ?? (throw const AccountException('Connect to your college server first.'));

  void _enter(Account account) {
    _account = account;
    _notice = null;
    _stage = switch (account.status) {
      AccountStatus.active => SessionStage.signedIn,
      AccountStatus.pending => SessionStage.awaitingApproval,
      AccountStatus.rejected || AccountStatus.removed => SessionStage.closed,
    };
    _route();
    notifyListeners();
  }

  /// Points the app's results at whoever is in now.
  void _route() {
    final SessionResults? results = _results;
    if (results == null) return;
    final Account? account = _account;
    results.use(switch (_stage) {
      SessionStage.offline => localResults,
      SessionStage.signedIn when account != null => _accounts?.results(account) ?? localResults,
      _ => null,
    });
  }

  /// Signs back in to the account kept from last time, if there is one.
  Future<void> restore() async {
    final AccountRepository? accounts = _accounts;
    if (accounts == null) {
      _stage = SessionStage.signedOut;
      notifyListeners();
      return;
    }
    try {
      final Account? account = await accounts.restore();
      if (account != null) return _enter(account);
    } on AccountException catch (error) {
      _notice = error.message;
    }
    _stage = SessionStage.signedOut;
    _route();
    notifyListeners();
  }

  /// Uses the college server at [server] from now on, remembered on this
  /// computer.
  Future<void> connect(ServerConfig server) async {
    final AccountRepository Function(ServerConfig)? connectTo = this.connectTo;
    if (connectTo == null) throw const AccountException('This build cannot connect to a college server.');
    await settings.save(supabaseUrl: server.url, supabaseAnonKey: server.anonKey);
    final AccountRepository? previous = _accounts;
    if (_account != null) await previous?.signOut();
    await previous?.dispose();
    _accounts = connectTo(server);
    _server = server;
    _account = null;
    _notice = null;
    if (_stage != SessionStage.offline) _stage = SessionStage.signedOut;
    _route();
    notifyListeners();
  }

  /// The name of the college with this college ID, or null.
  Future<String?> collegeName(String code) => _need.collegeName(code);

  Future<SignUpOutcome> signUp(SignUpDetails details) async {
    final SignUpOutcome outcome = await _need.signUp(details);
    if (outcome case SignedUp(:final Account account)) _enter(account);
    return outcome;
  }

  Future<void> confirmEmail({required String email, required String code}) async =>
      _enter(await _need.confirmEmail(email: email, code: code));

  Future<void> signIn({required String login, required String password, bool keep = false}) async =>
      _enter(await _need.signIn(login: login, password: password, keep: keep));

  /// Asks the server again — has the admin approved this teacher yet?
  Future<void> recheck() async => _enter(await _need.reload());

  /// A teacher marks on this computer, without an account; publishing waits
  /// until they sign in.
  void continueWithoutAccount() {
    _account = null;
    _stage = SessionStage.offline;
    _route();
    notifyListeners();
  }

  Future<void> signOut() async {
    if (_stage == SessionStage.signedOut) return;
    if (_account != null) await _accounts?.signOut();
    _account = null;
    _stage = SessionStage.signedOut;
    _route();
    notifyListeners();
  }

  /// Back to the sign-in screen. The teacher's marking work is kept.
  Future<void> leave() => signOut();
}
