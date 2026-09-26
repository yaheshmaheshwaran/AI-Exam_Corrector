import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/state/app_session.dart';

/// The first screen: choose Teacher or Student and go in.
///
/// Simple on purpose — no accounts or passwords yet. Signing in properly will
/// replace the choice here, not the screens behind it.
class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key, required this.onChoose});

  final ValueChanged<AppRole> onChoose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.rule_folder_outlined, size: 40, color: AppTheme.accent),
                const SizedBox(height: 10),
                Text('Exam Corrector', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  'Who is using the app?',
                  style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 28),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final List<Widget> cards = <Widget>[
                      for (final AppRole role in AppRole.values)
                        _RoleCard(role: role, onTap: () => onChoose(role)),
                    ];
                    if (constraints.maxWidth < 520) {
                      return Column(
                        children: <Widget>[
                          cards.first,
                          const SizedBox(height: AppTheme.gap),
                          cards.last,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(child: cards.first),
                        const SizedBox(width: AppTheme.gap),
                        Expanded(child: cards.last),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.role, required this.onTap});

  final AppRole role;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: AppTheme.cardBackground,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppTheme.stroke),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: InkWell(
        key: ValueKey<String>('role-${role.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                role == AppRole.teacher ? Icons.co_present_outlined : Icons.school_outlined,
                size: 32,
                color: AppTheme.accent,
              ),
              const SizedBox(height: 12),
              Text(role.label, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                role.description,
                style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Text('Continue', style: theme.textTheme.titleSmall?.copyWith(color: AppTheme.accent)),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_forward, size: 16, color: AppTheme.accent),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
