import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/services/accounts/account_repository.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// The college and its members: its college ID to share, the teachers the
/// admin approves, and the students a teacher can remove or restore.
class CollegeScreen extends StatefulWidget {
  const CollegeScreen({super.key, required this.session});

  final AppSession session;

  static Future<void> open(BuildContext context, AppSession session) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (BuildContext context) => CollegeScreen(session: session)));

  @override
  State<CollegeScreen> createState() => _CollegeScreenState();
}

class _CollegeScreenState extends State<CollegeScreen> {
  List<Account>? _members;
  String? _error;
  String _query = '';

  bool get _admin => widget.session.account?.role == AppRole.admin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AccountRepository? accounts = widget.session.accounts;
    if (accounts == null) return;
    try {
      final List<Account> members = await accounts.members();
      if (mounted) {
        setState(() {
          _members = members;
          _error = null;
        });
      }
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _set(Account member, AccountStatus status) async {
    final AccountRepository? accounts = widget.session.accounts;
    if (accounts == null) return;
    if (status == AccountStatus.removed || status == AccountStatus.rejected) {
      final bool sure = await confirmDialog(
        context,
        title: status == AccountStatus.rejected ? 'Turn down ${member.fullName}?' : 'Remove ${member.fullName}?',
        message: member.role == AppRole.student
            ? '${member.fullName} (${member.memberId}) will no longer be able to sign in or see their results. '
                  'You can restore them later.'
            : '${member.fullName} will no longer be able to sign in to ${member.college.name}. '
                  'You can restore them later.',
        confirm: status == AccountStatus.rejected ? 'Turn down' : 'Remove',
      );
      if (!sure) return;
    }
    try {
      if (member.role == AppRole.student) {
        await accounts.setStudentStatus(member.id, status);
      } else {
        await accounts.setTeacherStatus(member.id, status);
      }
    } on AppException catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final Account? me = widget.session.account;
    if (me == null) return const Scaffold();
    final List<Account> members = _members ?? const <Account>[];
    final List<Account> teachers = members.where((Account a) => a.role.isStaff).toList();
    final List<Account> students = members.where((Account a) => a.role == AppRole.student).toList();
    final int waiting = teachers.where((Account a) => a.status == AccountStatus.pending).length;

    return DefaultTabController(
      length: _admin ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: Text(me.college.name),
          actions: <Widget>[
            IconButton(
              key: const Key('college-refresh'),
              tooltip: 'Refresh',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(96),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, 0, AppTheme.pagePadding, 8),
                  child: _CollegeId(college: me.college),
                ),
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: <Widget>[
                    Tab(key: const Key('tab-students'), text: 'Students (${students.length})'),
                    if (_admin)
                      Tab(key: const Key('tab-teachers'), text: 'Teachers${waiting > 0 ? ' · $waiting waiting' : ''}'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: InfoBanner(title: _error!, tone: ToneKind.danger),
                ),
              )
            : _members == null
            ? const Padding(
                padding: EdgeInsets.all(AppTheme.pagePadding),
                child: SkeletonRows(count: 5, label: 'Loading members'),
              )
            : TabBarView(
                children: <Widget>[
                  _list(
                    students.where((Account a) => _matches(a)).toList(),
                    empty: 'No students have signed up yet. Share the college ID ${me.college.code} with them.',
                    search: true,
                  ),
                  if (_admin)
                    _list(<Account>[
                      ...teachers.where((Account a) => a.status == AccountStatus.pending),
                      ...teachers.where((Account a) => a.status != AccountStatus.pending),
                    ], empty: 'No teachers yet.'),
                ],
              ),
      ),
    );
  }

  bool _matches(Account a) {
    final String q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return a.fullName.toLowerCase().contains(q) ||
        a.memberId.toLowerCase().contains(q) ||
        a.username.toLowerCase().contains(q);
  }

  Widget _list(List<Account> members, {required String empty, bool search = false}) {
    return ListView(
      padding: const EdgeInsets.all(AppTheme.pagePadding),
      children: <Widget>[
        if (search) ...<Widget>[
          TextField(
            key: const Key('college-search'),
            onChanged: (String value) => setState(() => _query = value),
            decoration: const InputDecoration(
              hintText: 'Find by name, roll number or username',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (members.isEmpty) Text(empty, key: const Key('college-empty'), style: context.text.muted),
        for (final Account member in members)
          _MemberRow(
            member: member,
            me: widget.session.account!,
            admin: _admin,
            onSet: (AccountStatus status) => _set(member, status),
          ),
      ],
    );
  }
}

/// The college ID, to copy and share.
class _CollegeId extends StatelessWidget {
  const _CollegeId({required this.college});

  final College college;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text('College ID', style: context.text.caption),
        const SizedBox(width: 8),
        SelectableText(college.code, key: const Key('college-code'), style: context.text.mark),
        IconButton(
          key: const Key('copy-college-code'),
          tooltip: 'Copy the college ID',
          iconSize: 16,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: college.code));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('College ID copied.')));
            }
          },
          icon: const Icon(Icons.copy_outlined),
        ),
        Expanded(
          child: Text(
            'Students and teachers join with it.',
            overflow: TextOverflow.ellipsis,
            style: context.text.faint,
          ),
        ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.me, required this.admin, required this.onSet});

  final Account member;
  final Account me;
  final bool admin;
  final ValueChanged<AccountStatus> onSet;

  @override
  Widget build(BuildContext context) {
    final bool student = member.role == AppRole.student;
    final bool mayChange = member.id != me.id && member.role != AppRole.admin && (student || admin);
    final (String label, ToneKind tone) = switch (member.status) {
      AccountStatus.active => ('Active', ToneKind.success),
      AccountStatus.pending => ('Waiting for approval', ToneKind.warning),
      AccountStatus.rejected => ('Turned down', ToneKind.neutral),
      AccountStatus.removed => ('Removed', ToneKind.neutral),
    };
    Widget action(String key, String text, AccountStatus status, {bool primary = false}) => Padding(
      padding: const EdgeInsets.only(left: 6),
      child: primary
          ? FilledButton(key: Key('$key-${member.id}'), onPressed: () => onSet(status), child: Text(text))
          : OutlinedButton(key: Key('$key-${member.id}'), onPressed: () => onSet(status), child: Text(text)),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.border),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('${member.fullName}${member.id == me.id ? '  (you)' : ''}', style: context.text.titleSmall),
                Text(
                  '${member.role == AppRole.admin ? 'College admin · ' : ''}${member.memberId} · @${member.username} · ${member.email}',
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption,
                ),
              ],
            ),
          ),
          StatusPill(label: label, tone: tone, dense: true),
          if (mayChange)
            ...switch (member.status) {
              AccountStatus.pending => <Widget>[
                action('reject', 'Turn down', AccountStatus.rejected),
                action('approve', 'Approve', AccountStatus.active, primary: true),
              ],
              AccountStatus.active => <Widget>[action('remove', 'Remove', AccountStatus.removed)],
              AccountStatus.rejected ||
              AccountStatus.removed => <Widget>[action('restore', 'Restore', AccountStatus.active)],
            },
        ],
      ),
    );
  }
}
