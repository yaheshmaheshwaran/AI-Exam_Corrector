import 'package:flutter/material.dart';

import 'package:exam_corrector/app/app_colors.dart';
import 'package:exam_corrector/app/app_text.dart';
import 'package:exam_corrector/app/app_theme.dart';

/// A compact dropdown framed like a text field, in body type.
///
/// Material's bare dropdown sets its value in title type over an underline,
/// which reads as a heading rather than a control.
class SelectField<T> extends StatelessWidget {
  const SelectField({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.expand = false,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;

  /// Fills the width it is given rather than sizing to its longest item.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Container(
      height: AppTheme.controlHeight,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.borderStrong),
        borderRadius: BorderRadius.circular(AppTheme.controlRadius),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: hint,
          items: items,
          onChanged: onChanged,
          isDense: true,
          isExpanded: expand,
          style: context.text.small,
          icon: Icon(Icons.expand_more, size: 18, color: c.textMuted),
          borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          dropdownColor: c.surface,
          focusColor: Colors.transparent,
        ),
      ),
    );
  }
}
