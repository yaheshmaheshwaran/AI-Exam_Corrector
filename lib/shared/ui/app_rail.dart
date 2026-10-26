import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_theme.dart';
import 'package:exam_corrector/services/window_chrome.dart';
import 'package:exam_corrector/shared/ui/app_logo.dart';
import 'package:exam_corrector/shared/ui/backdrop.dart';
import 'package:exam_corrector/shared/ui/frosted.dart';

/// The navigation rail: a narrow floating pane of glass down the left of the
/// window, with the app's logo at its head, an icon and a one-word label for
/// each place, and settings and the account at its foot.
///
/// Its top is level with the floating bars beside it, and its places start
/// level with the first section card. On macOS the window's own buttons sit
/// in its head, on the bars' centre line, with the logo beneath them; the
/// head moves the window when dragged, as a title bar would.
class AppRail extends StatelessWidget {
  const AppRail({super.key, required this.items, this.footer = const <Widget>[]});

  /// The places, top to bottom: [AppRailItem]s.
  final List<Widget> items;

  /// At the foot: settings, the account.
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppTheme.railWidth,
      child: Column(
        children: <Widget>[
          const SizedBox(height: AppTheme.floatInset, width: double.infinity, child: WindowDragArea()),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppTheme.floatInset, 0, 0, AppTheme.floatInset),
              child: RepaintBoundary(
                child: Frosted(
                  radius: AppTheme.railRadius,
                  child: Column(
                    children: <Widget>[
                      const _RailHead(),
                      for (final Widget item in items) Padding(padding: const EdgeInsets.only(bottom: 4), child: item),
                      const Expanded(child: WindowDragArea()),
                      for (final Widget item in footer) Padding(padding: const EdgeInsets.only(bottom: 6), child: item),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rail's head: the logo, and on macOS room above it for the window's
/// buttons.
///
/// While the window's buttons are over the app, the head is the bars' height
/// and the logo starts below it, level with the first section card. Elsewhere
/// — other systems, and macOS in full screen, where the buttons are hidden —
/// the logo sits on the bars' centre line, and the places start level with
/// the first section card.
class _RailHead extends StatelessWidget {
  const _RailHead();

  static const double logoSize = 32;

  /// From the rail's top to the first section card.
  static const double _toCards = AppTheme.underBar - AppTheme.floatInset;

  @override
  Widget build(BuildContext context) {
    final Widget logo = Tooltip(
      message: 'Marklume',
      waitDuration: const Duration(milliseconds: 700),
      child: Semantics(
        label: 'Marklume',
        image: true,
        child: const AppLogo(size: logoSize),
      ),
    );
    return ValueListenableBuilder<bool>(
      valueListenable: WindowChrome.buttonsShown,
      builder: (BuildContext context, bool buttonsShown, _) => buttonsShown ? _underButtons(logo) : _onBarLine(logo),
    );
  }

  Widget _underButtons(Widget logo) => WindowDragArea(
    child: SizedBox(
      width: double.infinity,
      child: Column(
        children: <Widget>[
          const SizedBox(height: _toCards),
          logo,
          const SizedBox(height: 10),
        ],
      ),
    ),
  );

  Widget _onBarLine(Widget logo) => SizedBox(
    width: double.infinity,
    height: _toCards,
    child: Column(
      children: <Widget>[
        // Centred on the bars' centre line, half a bar down.
        const SizedBox(height: AppTheme.barHeight / 2 - logoSize / 2),
        logo,
        const Spacer(),
        const SizedBox(width: 24, child: Divider(height: 1, thickness: 1)),
        const SizedBox(height: 8),
      ],
    ),
  );
}

/// One place in the rail: a 54 × 50 tile with an icon over its name. The
/// chosen place is a raised white pill in the accent colour; a count, when
/// there is one, sits on the icon's corner.
class AppRailItem extends StatelessWidget {
  const AppRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.count = 0,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  /// Waiting items, shown as a badge when above zero.
  final int count;

  /// A longer name, shown on hover.
  final String? tooltip;

  static const double width = 54;
  static const double height = 50;
  static final BorderRadius _corners = BorderRadius.circular(13);

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final Color colour = onPressed == null
        ? c.textFaint
        : selected
        ? c.primary
        : c.textMuted;
    final Widget content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Badge(
          isLabelVisible: count > 0,
          label: Text('$count'),
          offset: const Offset(8, -6),
          child: Icon(icon, size: 18, color: colour),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: colour, height: 1.2),
        ),
      ],
    );

    Widget tile = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: _corners,
        hoverColor: Colors.white.withValues(alpha: 0.55),
        child: SizedBox(width: width, height: height, child: content),
      ),
    );
    if (selected) {
      tile = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: _corners,
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xFAFFFFFF), Color(0xB3FFFFFF)],
          ),
          border: Border.all(color: c.primary.withValues(alpha: 0.12), width: 0.5),
          boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x1A3E2F23), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: tile,
      );
    }
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Tooltip(message: tooltip ?? label, waitDuration: const Duration(milliseconds: 700), child: tile),
    );
  }
}
