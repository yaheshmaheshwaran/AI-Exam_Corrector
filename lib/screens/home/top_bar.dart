part of 'home_screen.dart';

/// The bar across the top: what the application is, what the model is doing,
/// and the places the teacher can go from here.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.model,
    required this.hasApiKey,
    required this.onSettings,
    this.onSyllabi,
    this.usage,
    this.onSwitchRole,
    this.openRequests,
    this.onRequests,
    this.onStudents,
    this.account,
  });

  /// The signed-in account's menu, in place of the sign-out button.
  final Widget? account;

  /// Opens the table of where every student stands.
  final VoidCallback? onStudents;

  final VoidCallback? onSwitchRole;

  /// Students' correction requests waiting; null where there are none to
  /// show.
  final int? openRequests;
  final VoidCallback? onRequests;

  /// What the AI is doing and how much it has been used; replaces the model
  /// name where available.
  final Widget? usage;

  final String model;
  final bool hasApiKey;
  final VoidCallback onSettings;

  /// Opens the syllabus library; null where there is none.
  final VoidCallback? onSyllabi;

  static const double height = 52;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    // Its surface, edge and separation come from the frosted layer it sits
    // in; the bar itself is only its contents.
    return Container(
      height: height,
      padding: const EdgeInsets.only(left: AppTheme.pagePadding, right: 10),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // The model is context, not a control: it is the first thing to go
          // when the window is narrow, and the tools shrink to icons before
          // anything overflows.
          final bool showModel = constraints.maxWidth >= 620;
          final bool compact = constraints.maxWidth < 1000;
          Widget tool(Key key, VoidCallback onPressed, IconData icon, String label) =>
              _BarButton(key: key, onPressed: onPressed, icon: icon, label: label, compact: compact);

          return Row(
            children: <Widget>[
              Expanded(
                child: Row(
                  children: <Widget>[
                    const AppLogo(size: 26),
                    const SizedBox(width: 10),
                    Text(
                      'Marklume',
                      style: context.text.titleSmall.copyWith(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2),
                    ),
                    if (showModel) ...<Widget>[
                      Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 14), color: c.border),
                      Flexible(
                        child: usage ??
                            StatusPill(
                              label: hasApiKey ? model : 'No API key',
                              icon: hasApiKey ? Icons.auto_awesome_outlined : Icons.key_off_outlined,
                              tone: hasApiKey ? ToneKind.neutral : ToneKind.warning,
                              tooltip: hasApiKey
                                  ? 'Marking runs on $model'
                                  : 'No API key set — open Settings to add one.',
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (onStudents != null) tool(const Key('open-students'), onStudents!, Icons.groups_outlined, 'Students'),
              if (onRequests != null)
                Badge(
                  isLabelVisible: (openRequests ?? 0) > 0,
                  label: Text('${openRequests ?? 0}'),
                  offset: const Offset(-2, 2),
                  child: tool(const Key('open-requests'), onRequests!, Icons.rate_review_outlined, 'Requests'),
                ),
              if (onSyllabi != null) tool(const Key('open-syllabi'), onSyllabi!, Icons.menu_book_outlined, 'Syllabi'),
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: c.border,
              ),
              tool(const Key('open-settings'), onSettings, Icons.settings_outlined, 'Settings'),
              if (account != null) ...<Widget>[const SizedBox(width: 4), account!]
              else if (onSwitchRole != null)
                IconButton(
                  key: const Key('switch-role'),
                  tooltip: 'Back to sign in',
                  onPressed: onSwitchRole,
                  icon: const Icon(Icons.logout),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A quiet button in the top bar: an icon and label in the text colour,
/// shrinking to the icon alone when the window is narrow.
class _BarButton extends StatelessWidget {
  const _BarButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.compact,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon));
    }
    final AppColors c = context.colors;
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: c.text,
        iconColor: c.textMuted,
        backgroundColor: Colors.transparent,
      ).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.hovered) ? c.surfaceMuted : Colors.transparent),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}
