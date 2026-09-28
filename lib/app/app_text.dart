import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';

/// The type ramp by purpose, so a widget asks for "muted" or "caption"
/// rather than restyling a theme slot by hand.
///
/// caption 12 · small 13 · body 14 · titleSmall 13/600 · title 15/600 ·
/// heading 20/600 · display 24/700.
@immutable
class AppText {
  const AppText._(this._theme, this._colors);

  final TextTheme _theme;
  final AppColors _colors;

  TextStyle get body => _theme.bodyMedium!;
  TextStyle get small => _theme.bodySmall!.copyWith(fontSize: 13);
  TextStyle get muted => body.copyWith(color: _colors.textMuted);
  TextStyle get smallMuted => small.copyWith(color: _colors.textMuted);
  TextStyle get caption => _theme.bodySmall!.copyWith(color: _colors.textMuted);
  TextStyle get faint => _theme.bodySmall!.copyWith(color: _colors.textFaint);
  TextStyle get label => _theme.labelLarge!;
  TextStyle get titleSmall => _theme.titleSmall!;
  TextStyle get title => _theme.titleMedium!;
  TextStyle get heading => _theme.titleLarge!;
  TextStyle get display => _theme.headlineSmall!;

  /// Marks and counts: figures of one width, so columns line up.
  TextStyle get mark => _theme.titleSmall!.copyWith(
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );

  /// Section labels in the setup rail: small, strong, quiet.
  TextStyle get overline => _theme.labelMedium!.copyWith(
        color: _colors.textMuted,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      );
}

extension AppTextContext on BuildContext {
  AppText get text {
    final ThemeData theme = Theme.of(this);
    return AppText._(theme.textTheme, theme.extension<AppColors>() ?? AppColors.light);
  }
}
