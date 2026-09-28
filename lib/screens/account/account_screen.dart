import 'package:flutter/material.dart';

import 'package:exam_corrector/app/press_feedback.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/screens/account/server_dialog.dart';
import 'package:exam_corrector/screens/account/sign_up_form.dart';
import 'package:exam_corrector/services/ui_sound.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// The first screen: sign in to your college, or create an account — and,
/// for a teacher, marking on this computer without one.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.session, this.probe});

  final AppSession session;

  /// How the server dialog checks a server; the network when null.
  final ServerProbe? probe;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _signingUp = false;

  @override
  Widget build(BuildContext context) {
    final AppSession session = widget.session;
    if (session.stage == SessionStage.starting) {
      return const AccountFrame(
        key: Key('sign-in-screen'),
        subtitle: 'Signing you in…',
        child: SkeletonRows(count: 3, label: 'Signing you in'),
      );
    }
    return AccountFrame(
      key: const Key('sign-in-screen'),
      subtitle: _signingUp ? 'Create your account' : 'Sign in to your college',
      footer: _Footer(session: session, probe: widget.probe),
      child: !session.hasServer
          ? _ConnectPrompt(session: session, probe: widget.probe)
          : _signingUp
          ? SignUpForm(session: session, onSignIn: () => setState(() => _signingUp = false))
          : _SignInForm(session: session, onSignUp: () => setState(() => _signingUp = true)),
    );
  }
}

/// The frame every account screen shares: the logo and name, a line saying
/// what this screen is for, and its content on a card.
class AccountFrame extends StatelessWidget {
  const AccountFrame({super.key, required this.subtitle, required this.child, this.footer, this.width = 440});

  final String subtitle;
  final Widget child;
  final Widget? footer;
  final double width;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final Widget? footer = this.footer;
    return Scaffold(
      backgroundColor: c.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Center(child: AppLogo(size: 44)),
                const SizedBox(height: 12),
                Text('Marklume', textAlign: TextAlign.center, style: context.text.display),
                const SizedBox(height: 4),
                Text(subtitle, textAlign: TextAlign.center, style: context.text.muted),
                const SizedBox(height: 22),
                AppCard(
                  padding: const EdgeInsets.all(20),
                  child: _Comfortable(child: child),
                ),
                if (footer != null) ...<Widget>[const SizedBox(height: 14), footer],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Account forms are filled in once, not worked in all day: their main
/// button is a full, easy target, and a field's show-password button keeps
/// the field the height of the others.
class _Comfortable extends StatelessWidget {
  const _Comfortable({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: (theme.filledButtonTheme.style ?? const ButtonStyle()).copyWith(
            minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 40)),
            visualDensity: VisualDensity.standard,
          ),
        ),
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 32),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: (theme.iconButtonTheme.style ?? const ButtonStyle()).copyWith(
            visualDensity: VisualDensity.compact,
            padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.zero),
          ),
        ),
      ),
      child: child,
    );
  }
}

/// No server yet: what it is and where to get it.
class _ConnectPrompt extends StatelessWidget {
  const _ConnectPrompt({required this.session, this.probe});

  final AppSession session;
  final ServerProbe? probe;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Connect to your college server', style: context.text.title),
        const SizedBox(height: 6),
        Text(
          'Accounts and published results live on your college’s server. Your college admin gives you '
          'its address and public key — you enter them once on this computer.',
          style: context.text.caption,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('connect-server'),
          onPressed: () => ServerDialog.show(context, session, probe: probe),
          icon: const Icon(Icons.dns_outlined, size: 16),
          label: const Text('Connect…'),
        ),
      ],
    );
  }
}

class _SignInForm extends StatefulWidget {
  const _SignInForm({required this.session, required this.onSignUp});

  final AppSession session;
  final VoidCallback onSignUp;

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<_SignInForm> {
  final TextEditingController _login = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _keep = false;
  bool _hidden = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_login.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your email or username, and your password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.signIn(login: _login.text, password: _password.text, keep: _keep);
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? error = _error;
    final String? notice = widget.session.notice;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (notice != null) InfoBanner(title: notice, tone: ToneKind.warning),
          TextField(
            key: const Key('sign-in-login'),
            controller: _login,
            enabled: !_busy,
            autofocus: true,
            autofillHints: const <String>[AutofillHints.username, AutofillHints.email],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Email or username',
              prefixIcon: Icon(Icons.person_outline, size: 18),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('sign-in-password'),
            controller: _password,
            enabled: !_busy,
            obscureText: _hidden,
            autofillHints: const <String>[AutofillHints.password],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline, size: 18),
              suffixIcon: IconButton(
                tooltip: _hidden ? 'Show password' : 'Hide password',
                style: IconButton.styleFrom(
                  minimumSize: const Size(28, 28),
                  fixedSize: const Size(28, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
              ),
            ),
          ),
          const SizedBox(height: 4),
          ToggleRow(
            child: CheckboxListTile(
              key: const Key('sign-in-keep'),
              value: _keep,
              onChanged: toggled((bool? value) => setState(() => _keep = value ?? false)),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Keep me signed in on this computer'),
              subtitle: Text('Leave it off on a shared computer.', style: context.text.caption),
            ),
          ),
          if (error != null) ...<Widget>[
            const SizedBox(height: 6),
            InfoBanner(key: const Key('sign-in-error'), title: error, tone: ToneKind.danger, margin: EdgeInsets.zero),
          ],
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('sign-in-submit'),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Signing in…' : 'Sign in'),
          ),
          const SizedBox(height: 8),
          // Wraps rather than overflows at large text sizes.
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text('New here?', style: context.text.caption),
              TextButton(
                key: const Key('open-sign-up'),
                onPressed: _busy ? null : widget.onSignUp,
                child: const Text('Create an account'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Below the card: marking without an account, and which server this is.
class _Footer extends StatelessWidget {
  const _Footer({required this.session, this.probe});

  final AppSession session;
  final ServerProbe? probe;

  @override
  Widget build(BuildContext context) {
    final String? host = session.server?.host;
    return Column(
      children: <Widget>[
        TextButton.icon(
          key: const Key('continue-offline'),
          onPressed: session.continueWithoutAccount,
          icon: const Icon(Icons.edit_note_outlined, size: 18),
          label: const Text('Teacher? Mark without an account'),
        ),
        Text('Marking works on this computer; publishing to students needs an account.', style: context.text.faint),
        if (host != null) ...<Widget>[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.dns_outlined, size: 14, color: context.colors.textFaint),
              const SizedBox(width: 6),
              Flexible(
                child: Text(host, overflow: TextOverflow.ellipsis, style: context.text.faint),
              ),
              TextButton(
                key: const Key('server-change'),
                onPressed: () => ServerDialog.show(context, session, probe: probe),
                child: const Text('Change'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
