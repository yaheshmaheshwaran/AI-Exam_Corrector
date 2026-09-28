import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/press_feedback.dart';
import 'package:exam_corrector/services/ui_sound.dart';

/// Geometry shared by every screen, and the light and dark themes built from
/// [AppColors].
///
/// The design is deliberately quiet: flat surfaces separated by a hairline,
/// one accent, no shadows and no ripples. Motion is limited to a faint press
/// wash with a soft click ([PressFeedback]) and a quick fade between pages.
/// Colours live in [AppColors]; widgets read them with `context.colors`.
class AppTheme {
  const AppTheme._();

  // Geometry, on a 4px grid.
  static const double controlRadius = 6;
  static const double cardRadius = 10;
  static const double pillRadius = 999;
  static const double controlHeight = 32;
  static const double gapSmall = 8;
  static const double gap = 12;
  static const double pagePadding = 16;
  static const double gapLarge = 24;

  static const String fontFamily = 'PlusJakartaSans';

  /// Built once: rebuilding ThemeData on every frame is wasted work.
  static final ThemeData light = _build(AppColors.light, Brightness.light);
  static final ThemeData dark = _build(AppColors.dark, Brightness.dark);

  static ThemeData _build(AppColors c, Brightness brightness) {
    // Disabled controls are softer than faint text, which is now kept
    // readable for hints and details; disabled text is exempt from contrast
    // minimums and should look unavailable.
    final Color disabled = Color.lerp(c.textFaint, c.surface, 0.4)!;
    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
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

    final RoundedRectangleBorder controlShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius));
    const TextStyle buttonText = TextStyle(fontSize: 13, fontWeight: medium, fontFamily: fontFamily);

    OutlineInputBorder inputBorder(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: color, width: width),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[c],
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      fontFamily: fontFamily,
      textTheme: text,
      visualDensity: VisualDensity.compact,
      // Presses get a faint wash and a click instead of a ripple; pages fade
      // rather than slide.
      splashFactory: const PressFeedback(),
      splashColor: c.text.withValues(alpha: 0.10),
      highlightColor: Colors.transparent,
      hoverColor: c.surfaceMuted,
      focusColor: c.primarySoft,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.macOS: _QuickFade(),
          TargetPlatform.windows: _QuickFade(),
          TargetPlatform.linux: _QuickFade(),
        },
      ),
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
      iconTheme: IconThemeData(color: c.textMuted, size: 16),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        textStyle: TextStyle(fontSize: 12, color: c.surface, fontFamily: fontFamily),
        decoration: BoxDecoration(
          color: c.text,
          borderRadius: BorderRadius.circular(controlRadius),
        ),
      ),
      // Secondary button.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 12)),
          backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
            if (states.contains(WidgetState.disabled)) return Colors.transparent;
            if (states.contains(WidgetState.pressed)) return c.border;
            if (states.contains(WidgetState.hovered)) return c.surfaceMuted;
            return c.surface;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.text),
          iconColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.textMuted),
          side: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              BorderSide(color: states.contains(WidgetState.disabled) ? c.border : c.borderStrong)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: const WidgetStatePropertyAll<TextStyle>(buttonText),
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      // The one primary action on a view: it sounds fuller than the rest.
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          splashFactory: const PressFeedback(sound: UiSoundKind.press),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 16)),
          backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
            if (states.contains(WidgetState.disabled)) return c.surfaceMuted;
            if (states.contains(WidgetState.hovered) || states.contains(WidgetState.pressed)) {
              return c.primaryHover;
            }
            return c.primary;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.onPrimary),
          iconColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.onPrimary),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: const WidgetStatePropertyAll<TextStyle>(buttonText),
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 10)),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.primary),
          iconColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? disabled : c.primary),
          backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.hovered) ? c.primarySoft : Colors.transparent),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
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
              states.contains(WidgetState.hovered) ? c.surfaceMuted : Colors.transparent),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        hintStyle: TextStyle(color: c.textFaint, fontSize: 13),
        // Icons inside a field keep it at control height.
        prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: controlHeight),
        suffixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: controlHeight),
        labelStyle: TextStyle(color: c.textMuted, fontSize: 13),
        helperStyle: TextStyle(color: c.textMuted, fontSize: 12),
        border: inputBorder(c.borderStrong),
        enabledBorder: inputBorder(c.borderStrong),
        disabledBorder: inputBorder(c.border),
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
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: c.border),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.surfaceMuted,
        selectedColor: c.primarySoft,
        disabledColor: c.surfaceMuted,
        side: BorderSide(color: c.border),
        labelStyle: TextStyle(fontSize: 12, color: c.text, fontFamily: fontFamily),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius)),
        checkmarkColor: c.primary,
        showCheckmark: false,
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        iconColor: c.textMuted,
        textColor: c.text,
        selectedColor: c.primary,
        selectedTileColor: c.primarySoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(controlRadius)),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.primary : Colors.transparent),
        checkColor: WidgetStatePropertyAll<Color>(c.onPrimary),
        side: BorderSide(color: c.borderStrong, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.primary : c.borderStrong),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.onPrimary : c.textMuted),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.primary : c.surfaceMuted),
        trackOutlineColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.primary : c.borderStrong),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          splashFactory: const PressFeedback(sound: UiSoundKind.toggle),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, controlHeight)),
          visualDensity: VisualDensity.compact,
          backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? c.primarySoft : c.surface),
          foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? c.primary : c.text),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: c.borderStrong)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(controlShape),
          textStyle: const WidgetStatePropertyAll<TextStyle>(buttonText),
        ),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll<Color>(c.surfaceMuted),
        headingTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: semibold,
          color: c.textMuted,
          fontFamily: fontFamily,
        ),
        dataTextStyle: TextStyle(fontSize: 13, color: c.text, fontFamily: fontFamily),
        dividerThickness: 1,
        headingRowHeight: 36,
        dataRowMinHeight: 40,
        dataRowMaxHeight: 48,
        horizontalMargin: 12,
        columnSpacing: 24,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        elevation: 4,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(fontSize: 13, color: c.text, fontFamily: fontFamily),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: c.border),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(c.surface),
          surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: c.border)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.text,
        contentTextStyle: TextStyle(fontSize: 13, color: c.surface, fontFamily: fontFamily),
        actionTextColor: c.primarySoft,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
        width: 480,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        barrierColor: Colors.black.withValues(alpha: brightness == Brightness.dark ? 0.6 : 0.35),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius + 2),
          side: BorderSide(color: c.border),
        ),
        titleTextStyle: text.titleMedium,
        contentTextStyle: text.bodyMedium,
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.surface,
        foregroundColor: c.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 48,
        titleTextStyle: text.titleSmall,
        iconTheme: IconThemeData(color: c.textMuted, size: 18),
        shape: Border(bottom: BorderSide(color: c.border)),
      ),
      tabBarTheme: TabBarThemeData(
        splashFactory: const PressFeedback(sound: UiSoundKind.toggle),
        labelColor: c.primary,
        unselectedLabelColor: c.textMuted,
        indicatorColor: c.primary,
        dividerColor: c.border,
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
