import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_glass.dart';
import 'package:exam_corrector/app/press_feedback.dart';
import 'package:exam_corrector/services/ui_sound.dart';

/// Geometry shared by every screen, and the theme built from [AppColors].
///
/// The app is light only, in liquid glass over the Warm mist backdrop:
/// floating rounded bars that blur what passes under them, content on
/// quieter glass cards, and raised pill buttons that press down when
/// clicked. One accent, espresso, marks the main action and what is
/// selected. Presses play a soft click ([PressFeedback]); pages fade.
/// Colours live in [AppColors]; widgets read them with `context.colors`.
class AppTheme {
  const AppTheme._();

  // Geometry, on a 4px grid.
  static const double controlRadius = 8;
  static const double fieldRadius = 12;
  static const double cardRadius = 16;
  static const double barRadius = 16;
  static const double footRadius = 20;
  static const double railRadius = 20;
  static const double dialogRadius = 22;
  static const double pillRadius = 999;
  static const double controlHeight = 32;
  static const double compactHeight = 28;
  static const double primaryHeight = 40;
  static const double gapSmall = 8;
  static const double gap = 12;
  static const double pagePadding = 16;
  static const double gapLarge = 24;

  /// Floating glass sits this far in from the window's edges.
  static const double floatInset = 10;

  /// A floating toolbar's height, and how far content below it starts.
  static const double barHeight = 46;
  static const double underBar = floatInset + barHeight + floatInset;

  /// The navigation rail's slot, the setup column beside it, and the
  /// status bar floating at the foot of the window.
  static const double railWidth = 80;
  static const double setupWidth = 320;
  static const double statusHeight = 32;

  static const String fontFamily = 'PlusJakartaSans';

  /// Built once: rebuilding ThemeData on every frame is wasted work.
  static final ThemeData light = _build(AppColors.light);

  static ThemeData _build(AppColors c) {
    // Disabled controls are softer than faint text, which is kept readable
    // for hints and details; disabled text is exempt from contrast minimums
    // and should look unavailable.
    final Color disabled = Color.lerp(c.textFaint, c.surface, 0.4)!;
    final ColorScheme scheme = ColorScheme(
      brightness: Brightness.light,
      primary: c.primary,
      onPrimary: c.onPrimary,
      primaryContainer: c.primarySoft,
      onPrimaryContainer: c.primary,
      secondary: c.primary,
      onSecondary: c.onPrimary,
      secondaryContainer: c.primarySoft,
      onSecondaryContainer: c.primary,
      tertiary: c.bonus,
      onTertiary: c.surface,
      surface: c.surface,
      onSurface: c.text,
      onSurfaceVariant: c.textMuted,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surface,
      surfaceContainerHigh: c.surface,
      surfaceContainerHighest: c.surfaceMuted,
      outline: c.borderStrong,
      outlineVariant: c.border,
      error: c.danger,
      onError: c.surface,
      errorContainer: c.dangerFill,
      onErrorContainer: c.danger,
      shadow: Colors.black,
      scrim: Colors.black54,
      surfaceTint: Colors.transparent,
    );

    const FontWeight regular = FontWeight.w400;
    const FontWeight medium = FontWeight.w500;
    const FontWeight semibold = FontWeight.w600;
    final TextTheme text = TextTheme(
      headlineSmall: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.25, letterSpacing: -0.3),
      titleLarge: const TextStyle(fontSize: 20, fontWeight: semibold, height: 1.3, letterSpacing: -0.2),
      titleMedium: const TextStyle(fontSize: 15, fontWeight: semibold, height: 1.35),
      titleSmall: const TextStyle(fontSize: 13, fontWeight: semibold, height: 1.4),
      bodyLarge: const TextStyle(fontSize: 14, fontWeight: regular, height: 1.5),
      bodyMedium: const TextStyle(fontSize: 14, fontWeight: regular, height: 1.5),
      bodySmall: const TextStyle(fontSize: 12, fontWeight: regular, height: 1.5, letterSpacing: 0.1),
      labelLarge: const TextStyle(fontSize: 13, fontWeight: medium),
      labelMedium: const TextStyle(fontSize: 12, fontWeight: medium, letterSpacing: 0.1),
      labelSmall: const TextStyle(fontSize: 12, fontWeight: semibold, letterSpacing: 0.1),
    ).apply(
      bodyColor: c.text,
      displayColor: c.text,
      fontFamily: fontFamily,
    );

    const OutlinedBorder pill = StadiumBorder();
    const TextStyle buttonText = TextStyle(fontSize: 13, fontWeight: medium, fontFamily: fontFamily);
    // A wash of white on hover: glass catching more light.
    const Color glassHover = Color(0x99FFFFFF);

    OutlineInputBorder inputBorder(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(fieldRadius),
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[c],
      // Screens are see-through: the Warm mist backdrop lies under them all.
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: c.surface,
      fontFamily: fontFamily,
      textTheme: text,
      visualDensity: VisualDensity.compact,
      // Presses get a faint wash and a click instead of a ripple; pages fade
      // rather than slide.
      splashFactory: const PressFeedback(),
      splashColor: c.text.withValues(alpha: 0.08),
      highlightColor: Colors.transparent,
      hoverColor: glassHover,
      focusColor: c.primarySoft,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.macOS: _QuickFade(),
          TargetPlatform.windows: _QuickFade(),
          TargetPlatform.linux: _QuickFade(),
        },
      ),
      dividerTheme: DividerThemeData(color: c.text.withValues(alpha: 0.07), thickness: 1, space: 1),
      iconTheme: IconThemeData(color: c.textMuted, size: 16),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        textStyle: TextStyle(fontSize: 12, color: c.surface, fontFamily: fontFamily),
        decoration: BoxDecoration(
          color: c.text.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(controlRadius),
        ),
      ),
      // Secondary button: a raised white pill.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 14)),
          backgroundColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.text),
          iconColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.textMuted),
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(pill),
          textStyle: const WidgetStatePropertyAll<TextStyle>(buttonText),
          elevation: const WidgetStatePropertyAll<double>(0),
          backgroundBuilder: RaisedPill.secondary,
        ),
      ),
      // The one primary action on a view: a raised espresso pill that sounds
      // fuller than the rest.
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          splashFactory: const PressFeedback(sound: UiSoundKind.press),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 18)),
          backgroundColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.onPrimary),
          iconColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.onPrimary),
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(pill),
          textStyle: const WidgetStatePropertyAll<TextStyle>(buttonText),
          elevation: const WidgetStatePropertyAll<double>(0),
          backgroundBuilder: RaisedPill.primary,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 12)),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.primary),
          iconColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.primary),
          backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.hovered) ? glassHover : Colors.transparent),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(pill),
          textStyle: const WidgetStatePropertyAll<TextStyle>(buttonText),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(controlHeight, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.all(6)),
          iconSize: const WidgetStatePropertyAll<double>(18),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.textMuted),
          backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.hovered) ? glassHover : Colors.transparent),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(pill),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.72),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        hintStyle: TextStyle(color: c.textFaint, fontSize: 13),
        // Icons inside a field keep it at control height.
        prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: controlHeight),
        suffixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: controlHeight),
        labelStyle: TextStyle(color: c.textMuted, fontSize: 13),
        helperStyle: TextStyle(color: c.textMuted, fontSize: 12),
        border: inputBorder(c.text.withValues(alpha: 0.12)),
        enabledBorder: inputBorder(c.text.withValues(alpha: 0.12)),
        disabledBorder: inputBorder(c.text.withValues(alpha: 0.07)),
        focusedBorder: inputBorder(c.primary, 1.5),
        errorBorder: inputBorder(c.danger),
        focusedErrorBorder: inputBorder(c.danger, 1.5),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.primary,
        selectionColor: c.primary.withValues(alpha: 0.25),
        selectionHandleColor: c.primary,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.primary,
        linearMinHeight: 3,
        linearTrackColor: c.track,
        circularTrackColor: Colors.transparent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.hovered) ? c.textFaint : c.borderStrong),
        crossAxisMargin: 2,
      ),
      cardTheme: CardThemeData(
        color: AppGlass.cardFill,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: const BorderSide(color: AppGlass.rim),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withValues(alpha: 0.6),
        selectedColor: c.primarySoft,
        disabledColor: c.surfaceMuted,
        side: BorderSide(color: c.text.withValues(alpha: 0.1)),
        labelStyle: TextStyle(fontSize: 12, color: c.text, fontFamily: fontFamily),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        shape: const StadiumBorder(),
        checkmarkColor: c.primary,
        showCheckmark: false,
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        iconColor: c.textMuted,
        textColor: c.text,
        selectedColor: c.primary,
        selectedTileColor: c.primarySoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius + 2)),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.primary : Colors.white.withValues(alpha: 0.7)),
        checkColor: WidgetStatePropertyAll<Color>(c.onPrimary),
        side: BorderSide(color: c.borderStrong, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.primary : c.borderStrong),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.primary : c.text.withValues(alpha: 0.14)),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        thumbIcon: const WidgetStatePropertyAll<Icon?>(null),
      ),
      // A capsule track with the chosen segment lit white on it.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          splashFactory: const PressFeedback(sound: UiSoundKind.toggle),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          visualDensity: VisualDensity.compact,
          backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? Colors.white : c.text.withValues(alpha: 0.06)),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled)
                  ? disabled
                  : states.contains(WidgetState.selected)
                      ? c.text
                      : c.textMuted),
          overlayColor: WidgetStatePropertyAll<Color>(c.text.withValues(alpha: 0.04)),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: c.text.withValues(alpha: 0.1), width: 0.5)),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(pill),
          textStyle: const WidgetStatePropertyAll<TextStyle>(buttonText),
        ),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        dataRowColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected)
                ? c.primarySoft
                : states.contains(WidgetState.hovered)
                    ? Colors.white.withValues(alpha: 0.55)
                    : Colors.transparent),
        headingTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: semibold,
          color: c.textFaint,
          fontFamily: fontFamily,
        ),
        dataTextStyle: TextStyle(fontSize: 13, color: c.text, fontFamily: fontFamily),
        dividerThickness: 1,
        headingRowHeight: 36,
        dataRowMinHeight: 40,
        dataRowMaxHeight: 48,
        horizontalMargin: 14,
        columnSpacing: 24,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white.withValues(alpha: 0.96),
        elevation: 8,
        shadowColor: const Color(0x403E2F23),
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(fontSize: 13, color: c.text, fontFamily: fontFamily),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(controlRadius + 2),
          side: const BorderSide(color: AppGlass.hairline),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(Colors.white.withValues(alpha: 0.96)),
          surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          side: const WidgetStatePropertyAll<BorderSide>(BorderSide(color: AppGlass.hairline)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius + 2)),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.text.withValues(alpha: 0.92),
        contentTextStyle: TextStyle(fontSize: 13, color: c.surface, fontFamily: fontFamily),
        actionTextColor: c.primarySoft,
        elevation: 2,
        shape: const StadiumBorder(),
        width: 480,
      ),
      // A white sheet over the blurred, faintly dimmed window: the blur
      // lifts it, so it needs no heavy shadow, only a crisp edge.
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        barrierColor: Colors.black.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dialogRadius),
          side: BorderSide(color: c.text.withValues(alpha: 0.1)),
        ),
        titleTextStyle: text.titleMedium,
        contentTextStyle: text.bodyMedium,
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: c.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 48,
        titleTextStyle: text.titleSmall,
        iconTheme: IconThemeData(color: c.textMuted, size: 18),
      ),
      tabBarTheme: TabBarThemeData(
        splashFactory: const PressFeedback(sound: UiSoundKind.toggle),
        labelColor: c.primary,
        unselectedLabelColor: c.textMuted,
        indicatorColor: c.primary,
        dividerColor: Colors.transparent,
        labelStyle: buttonText,
        unselectedLabelStyle: buttonText,
      ),
      badgeTheme: BadgeThemeData(backgroundColor: c.danger, textColor: c.surface),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: c.textMuted,
        collapsedIconColor: c.textMuted,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
    );
  }
}

/// Raised pills: soft buttons with a small ledge under them that press down
/// when clicked. Drawn behind a button's label as its background, so every
/// FilledButton and OutlinedButton gets them from the theme.
/// Under reduced motion the press changes colour only.
abstract final class RaisedPill {
  static const StadiumBorder _pill = StadiumBorder();

  /// The top of a pill catches the light.
  static const LinearGradient _sheen = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.center,
    colors: <Color>[Color(0x2EFFFFFF), Color(0x00FFFFFF)],
  );

  static bool _pressed(BuildContext context, Set<WidgetState> states) =>
      states.contains(WidgetState.pressed) && !AppMotion.still(context);

  /// The main action: an espresso gradient on a dark ledge.
  static Widget primary(BuildContext context, Set<WidgetState> states, Widget? child) {
    final AppColors c = context.colors;
    if (states.contains(WidgetState.disabled)) {
      return DecoratedBox(
        decoration: ShapeDecoration(color: c.surfaceMuted, shape: StadiumBorder(side: BorderSide(color: c.border))),
        child: child,
      );
    }
    final bool pressed = _pressed(context, states);
    final bool lit = states.contains(WidgetState.hovered) || states.contains(WidgetState.focused);
    return Transform.translate(
      offset: Offset(0, pressed ? 2 : 0),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: _pill,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: lit
                ? const <Color>[Color(0xFF76604E), Color(0xFF47372B)]
                : const <Color>[Color(0xFF6A5443), Color(0xFF3E2F23)],
          ),
          shadows: pressed
              ? const <BoxShadow>[BoxShadow(color: Color(0x333E2F23), blurRadius: 6, offset: Offset(0, 1))]
              : const <BoxShadow>[
                  BoxShadow(color: Color(0xFF2A1F16), offset: Offset(0, 2)),
                  BoxShadow(color: Color(0x473E2F23), blurRadius: 14, offset: Offset(0, 5)),
                ],
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: const ShapeDecoration(shape: _pill, gradient: _sheen),
          child: child,
        ),
      ),
    );
  }

  /// Every other button: a white pill on a faint warm ledge.
  static Widget secondary(BuildContext context, Set<WidgetState> states, Widget? child) {
    final AppColors c = context.colors;
    if (states.contains(WidgetState.disabled)) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: Colors.white.withValues(alpha: 0.4),
          shape: StadiumBorder(side: BorderSide(color: c.text.withValues(alpha: 0.08), width: 0.5)),
        ),
        child: child,
      );
    }
    final bool pressed = _pressed(context, states);
    final bool lit = states.contains(WidgetState.hovered) || states.contains(WidgetState.focused);
    return Transform.translate(
      offset: Offset(0, pressed ? 1 : 0),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: StadiumBorder(
            side: BorderSide(
              color: states.contains(WidgetState.focused) ? c.primary : c.text.withValues(alpha: 0.15),
              width: states.contains(WidgetState.focused) ? 1.5 : 0.5,
            ),
          ),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: lit
                ? const <Color>[Color(0xFFFFFFFF), Color(0xFFF8F7F5)]
                : const <Color>[Color(0xFFFFFFFF), Color(0xFFF3F1EE)],
          ),
          shadows: pressed
              ? const <BoxShadow>[BoxShadow(color: Color(0x0F171717), blurRadius: 2, offset: Offset(0, 1))]
              : const <BoxShadow>[
                  BoxShadow(color: Color(0x1A3E2F23), offset: Offset(0, 1.5)),
                  BoxShadow(color: Color(0x14171717), blurRadius: 8, offset: Offset(0, 3)),
                ],
        ),
        child: child,
      ),
    );
  }
}

/// A new page fades in over about 130 ms, and fades out as quickly when
/// closed: enough to show that something changed, never enough to wait for.
/// With reduce-motion on, pages change at once.
class _QuickFade extends PageTransitionsBuilder {
  const _QuickFade();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: const Interval(0, 0.45, curve: Curves.easeOut),
        reverseCurve: const Interval(0.55, 1, curve: Curves.easeIn),
      ),
      child: child,
    );
  }
}
