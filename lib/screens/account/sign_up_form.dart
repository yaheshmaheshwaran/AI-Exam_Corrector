import 'dart:async';

import 'package:flutter/material.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// Creating an account: a student or teacher joining their college by its
/// college ID, or an admin registering the college.
///
/// Students are linked to their college at once; a teacher waits for the
/// college admin. When the server asks for the email to be confirmed, the
/// code sent to it is typed in here.
class SignUpForm extends StatefulWidget {
  const SignUpForm({super.key, required this.session, required this.onSignIn});

  final AppSession session;

  /// Back to signing in.
  final VoidCallback onSignIn;

  @override
  State<SignUpForm> createState() => _SignUpFormState();
}

class _SignUpFormState extends State<SignUpForm> {
  AppRole _role = AppRole.student;
  final TextEditingController _code = TextEditingController();
  final TextEditingController _college = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _member = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _again = TextEditingController();
  final TextEditingController _emailCode = TextEditingController();

  /// The college the college ID belongs to, once looked up.
  String? _joining;
  bool _lookingUp = false;
  Timer? _lookup;

  bool _hidden = true;
  bool _busy = false;
  String? _error;

  /// Where the confirmation code went, once the server asked for one.
  String? _confirming;

  @override
  void dispose() {
    _lookup?.cancel();
    for (final TextEditingController c in <TextEditingController>[
      _code,
      _college,
      _name,
      _username,
      _member,
      _email,
      _password,
      _again,
      _emailCode,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static final RegExp _codeShape = RegExp(r'^[A-Z0-9-]{3,20}$');
  static final RegExp _usernameShape = RegExp(r'^[a-z0-9_.]{3,30}$');

  /// Looks the college up a moment after the college ID stops changing.
  void _codeChanged(String _) {
    _lookup?.cancel();
    setState(() => _joining = null);
    if (_role == AppRole.admin) return;
    final String code = College.normaliseCode(_code.text);
    if (!_codeShape.hasMatch(code)) return;
    _lookup = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _lookingUp = true);
      try {
        final String? name = await widget.session.collegeName(code);
        if (mounted && College.normaliseCode(_code.text) == code) setState(() => _joining = name ?? '');
      } on AppException {
        // Said again, properly, when the form is sent.
      } finally {
        if (mounted) setState(() => _lookingUp = false);
      }
    });
  }

  /// What is wrong with the form, in one sentence; null when it can go.
  String? _problem() {
    final String code = College.normaliseCode(_code.text);
    if (!_codeShape.hasMatch(code)) {
      return 'The college ID is 3 to 20 letters, digits or dashes${_role == AppRole.admin ? ' — choose one for your college' : ''}.';
    }
    if (_role == AppRole.admin && _college.text.trim().length < 2) return 'Enter the college’s name.';
    if (_name.text.trim().isEmpty) return 'Enter your full name.';
    if (!_usernameShape.hasMatch(_username.text.trim().toLowerCase())) {
      return 'The username is 3 to 30 lower-case letters, digits, dots or underscores.';
    }
    if (_member.text.trim().isEmpty) return 'Enter your ${_memberLabel.toLowerCase()}.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) return 'Enter a valid email address.';
    if (_password.text.length < 8) return 'Choose a password of at least 8 characters.';
    if (_password.text != _again.text) return 'The two passwords are different.';
    return null;
  }

  String get _memberLabel => _role == AppRole.student ? 'Roll number' : 'Staff ID';

  Future<void> _submit() async {
    final String? problem = _problem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final SignUpOutcome outcome = await widget.session.signUp(
        SignUpDetails(
          role: _role,
          collegeCode: _code.text,
          collegeName: _role == AppRole.admin ? _college.text : null,
          fullName: _name.text,
          username: _username.text,
          memberId: _member.text,
          email: _email.text,
          password: _password.text,
        ),
      );
      if (outcome case ConfirmEmail(:final String email)) {
        if (mounted) setState(() => _confirming = email);
      }
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final String? email = _confirming;
    if (email == null || _emailCode.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.confirmEmail(email: email, code: _emailCode.text);
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    String? hint,
    String? helper,
    IconData? icon,
    bool secret = false,
    List<String>? autofill,
    ValueChanged<String>? onChanged,
    TextCapitalization capitalization = TextCapitalization.none,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: Key(key),
      controller: controller,
      enabled: !_busy,
      obscureText: secret && _hidden,
      autofillHints: autofill,
      onChanged: onChanged,
      textCapitalization: capitalization,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        prefixIcon: icon == null ? null : Icon(icon, size: 18),
        suffixIcon: secret
            ? IconButton(
                tooltip: _hidden ? 'Show password' : 'Hide password',
                style: IconButton.styleFrom(
                  minimumSize: const Size(28, 28),
                  fixedSize: const Size(28, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
              )
            : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final String? error = _error;
    final String? confirming = _confirming;
    if (confirming != null) return _confirmStep(confirming, error);

    final String? joining = _joining;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('I am…', style: context.text.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<AppRole>(
            key: const Key('sign-up-role'),
            showSelectedIcon: false,
            // Three equal parts across the card.
            expandedInsets: EdgeInsets.zero,
            segments: const <ButtonSegment<AppRole>>[
              ButtonSegment<AppRole>(
                value: AppRole.student,
                label: Text('Student', key: Key('sign-up-student')),
              ),
              ButtonSegment<AppRole>(
                value: AppRole.teacher,
                label: Text('Teacher', key: Key('sign-up-teacher')),
              ),
              ButtonSegment<AppRole>(
                value: AppRole.admin,
                label: Text('New college', key: Key('sign-up-admin')),
              ),
            ],
            selected: <AppRole>{_role},
            onSelectionChanged: _busy
                ? null
                : (Set<AppRole> picked) {
                    setState(() {
                      _role = picked.single;
                      _error = null;
                    });
                    _codeChanged(_code.text);
                  },
          ),
          const SizedBox(height: 8),
          Text(switch (_role) {
            AppRole.student =>
              'You are linked to your college as soon as you sign up, and see the results '
                  'published to your roll number.',
            AppRole.teacher => 'Your college admin approves your account before you can publish results.',
            AppRole.admin =>
              'Register your college. You approve its teachers, and share the college ID '
                  'with them and your students.',
          }, style: context.text.caption),
          const SizedBox(height: 14),
          _field(
            'sign-up-college-code',
            _code,
            _role == AppRole.admin ? 'College ID (choose one)' : 'College ID',
            hint: 'e.g. PSGTECH',
            icon: Icons.apartment_outlined,
            capitalization: TextCapitalization.characters,
            onChanged: _codeChanged,
            helper: _role == AppRole.admin
                ? 'Short and memorable; everyone joins with it.'
                : _lookingUp
                ? 'Looking up the college…'
                : joining == null
                ? 'Ask your college admin or teacher for it.'
                : joining.isEmpty
                ? 'No college has this ID yet.'
                : 'Joining: $joining',
          ),
          if (_role == AppRole.admin)
            _field(
              'sign-up-college-name',
              _college,
              'College name',
              hint: 'e.g. PSG College of Technology',
              icon: Icons.account_balance_outlined,
              capitalization: TextCapitalization.words,
            ),
          _field(
            'sign-up-name',
            _name,
            'Full name',
            icon: Icons.badge_outlined,
            autofill: const <String>[AutofillHints.name],
            capitalization: TextCapitalization.words,
          ),
          _field(
            'sign-up-username',
            _username,
            'Username',
            hint: 'e.g. priya.s',
            icon: Icons.alternate_email,
            helper: 'You can sign in with it instead of your email.',
            autofill: const <String>[AutofillHints.newUsername],
          ),
          _field(
            'sign-up-member',
            _member,
            _memberLabel,
            hint: _role == AppRole.student ? 'e.g. 21CS045' : 'e.g. T1042',
            icon: Icons.numbers,
            capitalization: TextCapitalization.characters,
          ),
          _field(
            'sign-up-email',
            _email,
            'Email',
            icon: Icons.mail_outline,
            autofill: const <String>[AutofillHints.email],
          ),
          _field(
            'sign-up-password',
            _password,
            'Password',
            helper: 'At least 8 characters.',
            icon: Icons.lock_outline,
            secret: true,
            autofill: const <String>[AutofillHints.newPassword],
          ),
          _field('sign-up-password-again', _again, 'Password again', icon: Icons.lock_outline, secret: true),
          if (error != null)
            InfoBanner(key: const Key('sign-up-error'), title: error, tone: ToneKind.danger, margin: EdgeInsets.zero),
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('sign-up-submit'),
            onPressed: _busy ? null : _submit,
            child: Text(
              _busy ? 'Creating your account…' : (_role == AppRole.admin ? 'Register college' : 'Create account'),
            ),
          ),
          const SizedBox(height: 8),
          // Wraps rather than overflows at large text sizes.
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text('Already have an account?', style: context.text.caption),
              TextButton(
                key: const Key('open-sign-in'),
                onPressed: _busy ? null : widget.onSignIn,
                child: const Text('Sign in'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _confirmStep(String email, String? error) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Text('Check your email', style: context.text.title),
      const SizedBox(height: 6),
      Text('We sent a code to $email. Type it here to finish creating your account.', style: context.text.caption),
      const SizedBox(height: 14),
      TextField(
        key: const Key('email-code'),
        controller: _emailCode,
        enabled: !_busy,
        autofocus: true,
        keyboardType: TextInputType.number,
        onSubmitted: (_) => _confirm(),
        decoration: const InputDecoration(labelText: 'Code', prefixIcon: Icon(Icons.pin_outlined, size: 18)),
      ),
      if (error != null) ...<Widget>[
        const SizedBox(height: 10),
        InfoBanner(title: error, tone: ToneKind.danger, margin: EdgeInsets.zero),
      ],
      const SizedBox(height: 14),
      FilledButton(
        key: const Key('email-code-submit'),
        onPressed: _busy ? null : _confirm,
        child: Text(_busy ? 'Confirming…' : 'Confirm'),
      ),
      TextButton(onPressed: _busy ? null : widget.onSignIn, child: const Text('Back to sign in')),
    ],
  );
}
