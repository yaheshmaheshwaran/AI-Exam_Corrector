import 'package:flutter/material.dart';

import 'package:exam_corrector/screens/college/college_screen.dart';
import 'package:exam_corrector/state/app_session.dart';
import 'package:exam_corrector/widgets/ui/ui.dart';

/// Who is signed in, in the top bar: their initials, and a menu with their
/// college and signing out.
class AccountMenu extends StatelessWidget {
  const AccountMenu({super.key, required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final Account? account = session.account;
    if (account == null) return const SizedBox.shrink();
    final AppColors c = context.colors;
    return PopupMenuButton<String>(
      key: const Key('account-menu'),
      tooltip: '${account.fullName} · ${account.college.name}',
      position: PopupMenuPosition.under,
      onSelected: (String choice) {
        switch (choice) {
          case 'college':
            CollegeScreen.open(context, session);
          case 'sign-out':
            session.signOut();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(account.fullName, style: context.text.titleSmall.copyWith(color: c.text)),
              Text('${account.role.label} · ${account.memberId}', style: context.text.caption),
              Text('@${account.username} · ${account.college.name}', style: context.text.caption),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (account.role.isStaff)
          const PopupMenuItem<String>(
            key: Key('open-college'),
            value: 'college',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.apartment_outlined, size: 18),
              title: Text('College and members'),
            ),
          ),
        const PopupMenuItem<String>(
          key: Key('switch-role'),
          value: 'sign-out',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout, size: 18),
            title: Text('Sign out'),
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: CircleAvatar(
          radius: 14,
          backgroundColor: c.primarySoft,
          child: Text(
            _initials(account.fullName),
            style: context.text.titleSmall.copyWith(fontSize: 11.5, color: c.primary, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  static String _initials(String name) {
    final List<String> words = name.trim().split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    return (words.first[0] + (words.length > 1 ? words.last[0] : '')).toUpperCase();
  }
}
