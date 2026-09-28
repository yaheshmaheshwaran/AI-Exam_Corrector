import 'package:flutter/material.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/screens/account/account_screen.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// Signed in, but not in yet: a teacher waiting for the college admin, or
/// an account turned down or taken out of the college.
class PendingScreen extends StatefulWidget {
  const PendingScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<PendingScreen> createState() => _PendingScreenState();
}

class _PendingScreenState extends State<PendingScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _recheck() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.recheck();
      if (mounted && widget.session.stage == SessionStage.awaitingApproval) {
        setState(() => _error = 'Not approved yet. Try again a little later.');
      }
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Account? account = widget.session.account;
    final String college = account?.college.name ?? 'your college';
    final (IconData icon, String title, String body) = switch (account?.status) {
      AccountStatus.rejected => (
        Icons.block_outlined,
        'Your teacher account was not approved',
        'The admin of $college turned down this account. If that is a mistake, ask them to restore it.',
      ),
      AccountStatus.removed => (
        Icons.person_off_outlined,
        'Your account is not active',
        'You were removed from $college. Ask a teacher or the college admin to restore your account.',
      ),
      _ => (
        Icons.hourglass_top_outlined,
        'Waiting for approval',
        'The admin of $college needs to approve your teacher account. You can check again once they have.',
      ),
    };
    final String? error = _error;
    return AccountFrame(
      key: const Key('pending-screen'),
      subtitle: account == null ? '' : '${account.fullName} · ${account.college.name}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(icon, size: 32, color: context.colors.textMuted),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: context.text.title),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: context.text.caption),
          if (error != null) ...<Widget>[
            const SizedBox(height: 12),
            InfoBanner(title: error, tone: ToneKind.warning, margin: EdgeInsets.zero),
          ],
          const SizedBox(height: 16),
          if (account?.status == AccountStatus.pending)
            FilledButton(
              key: const Key('pending-recheck'),
              onPressed: _busy ? null : _recheck,
              child: Text(_busy ? 'Checking…' : 'Check again'),
            ),
          const SizedBox(height: 6),
          TextButton(
            key: const Key('switch-role'),
            onPressed: _busy ? null : widget.session.signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
