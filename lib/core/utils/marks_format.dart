/// Formats a mark for display: `4`, `4.5`, `0.25`.
///
/// Marks are small numbers with at most a couple of decimal places, so trailing
/// zeros are noise.
String formatMarks(double value) {
  if (!value.isFinite) return '0';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);

  final String text = value.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// Formats a whole-number percentage for display.
String formatPercentage(double value) =>
    '${value.isFinite ? value.round() : 0}%';

/// Groups a count in thousands: `12,480`.
String formatCount(int value) {
  final String digits = value.abs().toString();
  final StringBuffer grouped = StringBuffer(value < 0 ? '-' : '');

  for (int index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
    grouped.write(digits[index]);
  }

  return grouped.toString();
}
