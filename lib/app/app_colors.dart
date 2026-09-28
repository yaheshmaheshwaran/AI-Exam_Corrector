import 'package:flutter/material.dart';

/// The application's colours, by role: the Americano palette.
///
/// Every colour has one job. Neutral greys carry the layout; one espresso
/// accent marks the main action and what is selected (a steamed-milk cream in
/// dark mode); the four grading colours — sage for full marks, ochre for
/// partial, brick for zero, steel blue for the syllabus bonus — carry marking
/// meaning and are never used as decoration. The grading colours were chosen
/// to stay distinct from each other and from the accent under colour-blindness
/// simulation, and are kept muted so they inform without shouting. Their
/// fills are tinted just enough to read at a glance against a white or dark
/// card — soft pastels in light mode, deep tints in dark — so a score chip's
/// colour is seen, not guessed. Each role has a light and a dark value;
/// widgets read them through `context.colors` so both themes come for free.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceMuted,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.primary,
    required this.primaryHover,
    required this.onPrimary,
    required this.primarySoft,
    required this.primaryBorder,
    required this.success,
    required this.successFill,
    required this.successBorder,
    required this.warning,
    required this.warningFill,
    required this.warningBorder,
    required this.danger,
    required this.dangerFill,
    required this.dangerBorder,
    required this.bonus,
    required this.bonusFill,
    required this.bonusBorder,
    required this.highlight,
    required this.track,
  });

  // Neutrals: the page, what sits on it, and the lines between.
  final Color bg;
  final Color surface;
  final Color surfaceMuted;
  final Color border;
  final Color borderStrong;

  // Text, from most to least important.
  final Color text;
  final Color textMuted;
  final Color textFaint;

  // The accent: the main action, selection, focus, links, and the model at work.
  final Color primary;
  final Color primaryHover;
  final Color onPrimary;
  final Color primarySoft;
  final Color primaryBorder;

  // Full marks, published, verified.
  final Color success;
  final Color successFill;
  final Color successBorder;

  // Partial marks, needs review, a model near its limit.
  final Color warning;
  final Color warningFill;
  final Color warningBorder;

  // Zero marks, errors, destructive actions.
  final Color danger;
  final Color dangerFill;
  final Color dangerBorder;

  // The syllabus bonus: steel blue, the one hue red-green colour-blind
  // readers can always tell from full, partial and zero.
  final Color bonus;
  final Color bonusFill;
  final Color bonusBorder;

  /// Behind text picked out in a transcription.
  final Color highlight;

  /// The unfilled part of a progress bar.
  final Color track;

  static const AppColors light = AppColors(
    bg: Color(0xFFF7F7F6),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF2F2F1),
    border: Color(0xFFE4E4E2),
    borderStrong: Color(0xFFCBCBCA),
    text: Color(0xFF171717),
    textMuted: Color(0xFF50504D),
    textFaint: Color(0xFF6B6B69),
    primary: Color(0xFF3E2F23),
    primaryHover: Color(0xFF55483D),
    onPrimary: Color(0xFFFFFFFF),
    primarySoft: Color(0xFFF3EEEA),
    primaryBorder: Color(0xFFDDD3CA),
    success: Color(0xFF446E48),
    successFill: Color(0xFFE0F3E1),
    successBorder: Color(0xFFACCFAE),
    warning: Color(0xFF8A5901),
    warningFill: Color(0xFFFAEAD8),
    warningBorder: Color(0xFFDCBF9B),
    danger: Color(0xFF8C3224),
    dangerFill: Color(0xFFFFE6E1),
    dangerBorder: Color(0xFFE7B7AD),
    bonus: Color(0xFF2F4F6D),
    bonusFill: Color(0xFFDEEFFF),
    bonusBorder: Color(0xFFA7C8E9),
    highlight: Color(0xFFFAE2B0),
    track: Color(0xFFE4E4E2),
  );

  static const AppColors dark = AppColors(
    bg: Color(0xFF121212),
    surface: Color(0xFF1B1B1B),
    surfaceMuted: Color(0xFF242424),
    border: Color(0xFF2C2C2C),
    borderStrong: Color(0xFF3F3F3F),
    text: Color(0xFFEDEDED),
    textMuted: Color(0xFFB9B9B9),
    textFaint: Color(0xFF9A9A9A),
    primary: Color(0xFFE8DBD1),
    primaryHover: Color(0xFFEFE6DF),
    onPrimary: Color(0xFF121212),
    primarySoft: Color(0xFF33312F),
    primaryBorder: Color(0xFF696460),
    success: Color(0xFF97D4A5),
    successFill: Color(0xFF1E3122),
    successBorder: Color(0xFF365D40),
    warning: Color(0xFFE7AF61),
    warningFill: Color(0xFF362916),
    warningBorder: Color(0xFF684D27),
    danger: Color(0xFFE8847C),
    dangerFill: Color(0xFF3B2422),
    dangerBorder: Color(0xFF724440),
    bonus: Color(0xFF70A9E0),
    bonusFill: Color(0xFF1D2D3D),
    bonusBorder: Color(0xFF355575),
    highlight: Color(0xFF533F19),
    track: Color(0xFF2C2C2C),
  );

  /// Colours drawn over a scanned page. The scan is white paper in either
  /// theme, so these do not change with it.
  static const Color regionPrinted = Color(0xFF7A7A7A);
  static const Color regionQuestionNumber = Color(0xFF7C5E3C);
  static const Color regionHandwriting = Color(0xFF0F766E);
  static const Color regionDiagram = Color(0xFF15803D);
  static const Color regionGraph = Color(0xFF0F766E);
  static const Color regionTable = Color(0xFFC05A00);
  static const Color regionEquation = Color(0xFFC2185B);
  static const Color regionLabel = Color(0xFF8A5A2B);
  static const Color regionCrossedOut = Color(0xFFB91C1C);
  static const Color regionMarginNote = Color(0xFFB08600);
  static const Color regionHeader = Color(0xFF5C6B7A);
  static const Color regionUnknown = Color(0xFF333333);
  static const Color regionMark = Color(0x55FFC700);

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceMuted,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? textMuted,
    Color? textFaint,
    Color? primary,
    Color? primaryHover,
    Color? onPrimary,
    Color? primarySoft,
    Color? primaryBorder,
    Color? success,
    Color? successFill,
    Color? successBorder,
    Color? warning,
    Color? warningFill,
    Color? warningBorder,
    Color? danger,
    Color? dangerFill,
    Color? dangerBorder,
    Color? bonus,
    Color? bonusFill,
    Color? bonusBorder,
    Color? highlight,
    Color? track,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      textFaint: textFaint ?? this.textFaint,
      primary: primary ?? this.primary,
      primaryHover: primaryHover ?? this.primaryHover,
      onPrimary: onPrimary ?? this.onPrimary,
      primarySoft: primarySoft ?? this.primarySoft,
      primaryBorder: primaryBorder ?? this.primaryBorder,
      success: success ?? this.success,
      successFill: successFill ?? this.successFill,
      successBorder: successBorder ?? this.successBorder,
      warning: warning ?? this.warning,
      warningFill: warningFill ?? this.warningFill,
      warningBorder: warningBorder ?? this.warningBorder,
      danger: danger ?? this.danger,
      dangerFill: dangerFill ?? this.dangerFill,
      dangerBorder: dangerBorder ?? this.dangerBorder,
      bonus: bonus ?? this.bonus,
      bonusFill: bonusFill ?? this.bonusFill,
      bonusBorder: bonusBorder ?? this.bonusBorder,
      highlight: highlight ?? this.highlight,
      track: track ?? this.track,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceMuted: l(surfaceMuted, other.surfaceMuted),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      text: l(text, other.text),
      textMuted: l(textMuted, other.textMuted),
      textFaint: l(textFaint, other.textFaint),
      primary: l(primary, other.primary),
      primaryHover: l(primaryHover, other.primaryHover),
      onPrimary: l(onPrimary, other.onPrimary),
      primarySoft: l(primarySoft, other.primarySoft),
      primaryBorder: l(primaryBorder, other.primaryBorder),
      success: l(success, other.success),
      successFill: l(successFill, other.successFill),
      successBorder: l(successBorder, other.successBorder),
      warning: l(warning, other.warning),
      warningFill: l(warningFill, other.warningFill),
      warningBorder: l(warningBorder, other.warningBorder),
      danger: l(danger, other.danger),
      dangerFill: l(dangerFill, other.dangerFill),
      dangerBorder: l(dangerBorder, other.dangerBorder),
      bonus: l(bonus, other.bonus),
      bonusFill: l(bonusFill, other.bonusFill),
      bonusBorder: l(bonusBorder, other.bonusBorder),
      highlight: l(highlight, other.highlight),
      track: l(track, other.track),
    );
  }
}

/// A status colour with its fill and border, for pills, banners and badges.
@immutable
class Tone {
  const Tone(this.foreground, this.fill, this.border);

  final Color foreground;
  final Color fill;
  final Color border;
}

/// What a status colour means. Widgets choose a meaning; the theme chooses
/// the colour.
enum ToneKind { neutral, primary, success, warning, danger, bonus }

extension AppColorsTones on AppColors {
  Tone tone(ToneKind kind) => switch (kind) {
        ToneKind.neutral => Tone(textMuted, surfaceMuted, border),
        ToneKind.primary => Tone(primary, primarySoft, primaryBorder),
        ToneKind.success => Tone(success, successFill, successBorder),
        ToneKind.warning => Tone(warning, warningFill, warningBorder),
        ToneKind.danger => Tone(danger, dangerFill, dangerBorder),
        ToneKind.bonus => Tone(bonus, bonusFill, bonusBorder),
      };
}

extension AppColorsContext on BuildContext {
  /// The colours of the current theme, light or dark.
  AppColors get colors => Theme.of(this).extension<AppColors>() ?? AppColors.light;
}
