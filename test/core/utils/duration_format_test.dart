import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/utils/duration_format.dart';

void main() {
  test('seconds, then minutes and seconds, then hours and minutes', () {
    expect(formatElapsed(Duration.zero), '0s');
    expect(formatElapsed(const Duration(milliseconds: 59999)), '59s');
    expect(formatElapsed(const Duration(minutes: 1)), '1m 00s');
    expect(formatElapsed(const Duration(minutes: 14, seconds: 5)), '14m 05s');
    expect(formatElapsed(const Duration(hours: 1, minutes: 2, seconds: 40)), '1h 02m');
  });

  test('a clock that ran backwards reads as no time', () {
    expect(formatElapsed(const Duration(seconds: -3)), '0s');
  });
}
