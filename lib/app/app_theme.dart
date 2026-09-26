import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Windows 11 (Fluent) design tokens.
///
/// The application should look like it belongs on Windows, not like a Material
/// app that happens to run there: layered neutral surfaces, 4px controls inside
/// 8px cards, the system accent blue, Segoe UI type, and no ink ripples.
class AppTheme {
  const AppTheme._();

  // Layering — Fluent "solid backdrop" and "card" fills.
  static const Color pageBackground = Color(0xFFF3F3F3);
  static const Color cardBackground = Color(0xFFFFFFFF);
  static const Color subtleBackground = Color(0xFFFAFAFA);
  static const Color controlBackground = Color(0xFFFDFDFD);
  static const Color stroke = Color(0xFFE5E5E5);
  static const Color controlStroke = Color(0xFFD1D1D1);

  // Accent — the Windows 11 default blue.
  static const Color accent = Color(0xFF0067C0);
  static const Color accentHover = Color(0xFF005FB8);
  static const Color accentPressed = Color(0xFF00519E);

  // Text.
  static const Color textPrimary = Color(0xFF1B1B1B);
  static const Color textSecondary = Color(0xFF5D5D5D);
  static const Color textDisabled = Color(0xFF9D9D9D);

  // Status colours, matching Fluent's InfoBar severities.
  static const Color success = Color(0xFF0F7B0F);
  static const Color successFill = Color(0xFFDFF6DD);
  static const Color danger = Color(0xFFC42B1C);
  static const Color dangerFill = Color(0xFFFDE7E9);
  static const Color caution = Color(0xFF9D5D00);
  static const Color cautionFill = Color(0xFFFFF4CE);

  // The syllabus bonus: badges, and the marks and lines they touch.
  static const Color gold = Color(0xFFB07D00);
  static const Color goldFill = Color(0xFFFFF3CC);

  // Geometry.
  static const double cardRadius = 8;
  static const double controlRadius = 4;
  static const double controlHeight = 32;
  static const double gap = 12;
  static const double pagePadding = 16;

  static const List<String> _fontFallback = <String>[
    'Segoe UI Variable Text',
    'Segoe UI',
    '.SF Pro Text',
    'Helvetica Neue',
  ];

  static ThemeData build() {
    const ColorScheme scheme = ColorScheme.light(
      primary: accent,
      onPrimary: Colors.white,
      secondary: accent,
      onSecondary: Colors.white,
      surface: cardBackground,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: controlStroke,
      outlineVariant: stroke,
      error: danger,
      onError: Colors.white,
    );

    final TextTheme text = const TextTheme(
      // Fluent type ramp: Caption 12, Body 14, Body Strong 14/600,
      // Subtitle 20/600, Title 28/600.
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3),
      titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4),
      titleSmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.4),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45),
      bodySmall: TextStyle(fontSize: 12, height: 1.4),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ).apply(
      bodyColor: textPrimary,
      displayColor: textPrimary,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: _fontFallback,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: pageBackground,
      canvasColor: pageBackground,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: _fontFallback,
      textTheme: text,
      // Windows controls do not ripple.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      dividerTheme: const DividerThemeData(
        color: stroke,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: textSecondary, size: 16),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: const TextStyle(fontSize: 12, color: textPrimary),
        decoration: BoxDecoration(
          color: controlBackground,
          border: Border.all(color: stroke),
          borderRadius: BorderRadius.circular(controlRadius),
        ),
      ),
      // Standard (secondary) button.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStateProperty.all(const Size(0, controlHeight)),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 12),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return subtleBackground;
            if (states.contains(WidgetState.pressed)) return pageBackground;
            if (states.contains(WidgetState.hovered)) return const Color(0xFFF5F5F5);
            return controlBackground;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled) ? textDisabled : textPrimary),
          side: WidgetStateProperty.all(const BorderSide(color: controlStroke)),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(controlRadius),
            ),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          elevation: WidgetStateProperty.all(0),
        ),
      ),
      // Accent (primary) button.
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStateProperty.all(const Size(0, controlHeight)),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return const Color(0xFFE0E0E0);
            if (states.contains(WidgetState.pressed)) return accentPressed;
            if (states.contains(WidgetState.hovered)) return accentHover;
            return accent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled) ? textDisabled : Colors.white),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(controlRadius),
            ),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          elevation: WidgetStateProperty.all(0),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStateProperty.all(const Size(0, controlHeight)),
          foregroundColor: WidgetStateProperty.all(accent),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(controlRadius),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: controlBackground,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        hintStyle: const TextStyle(color: textDisabled, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: controlStroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: controlStroke),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: stroke),
        ),
        // Fluent focus: the accent underline thickens rather than a full ring.
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: accent, width: 1.6),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearMinHeight: 3,
        linearTrackColor: Color(0xFFE0E0E0),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered)
                ? const Color(0xFF8A8A8A)
                : const Color(0xFFC4C4C4)),
        crossAxisMargin: 2,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: subtleBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: const BorderSide(color: stroke),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textPrimary,
          fontFamily: 'Segoe UI',
          fontFamilyFallback: _fontFallback,
        ),
      ),
    );
  }

  /// The system chrome hint used while the window is showing results.
  static const SystemUiOverlayStyle overlay = SystemUiOverlayStyle.dark;
}
