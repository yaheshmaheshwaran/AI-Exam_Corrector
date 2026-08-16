// One-off manual check of the whole pipeline against the sample in `sample/`:
// PDF text extraction, the real API, and local validation, compared with
// sample/expected_outcome.md.
//
// Run with:  dart run tool/sample_check.dart
// It is deliberately outside `test/`, so `flutter test` stays offline (the
// Flutter test binding blocks real HTTP anyway).
import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/ai/gemini_correction_service.dart';

/// From sample/expected_outcome.md.
const Map<String, double> expected = <String, double>{
  '1': 2,
  '2a': 1,
  '2b': 1,
  '3': 2,
  '4': 2,
  '5': 0,
  '6': 2,
  '7': 2,
  '8': 2,
};

// The PDF layer needs Flutter (syncfusion imports dart:ui) while real HTTP
// needs to be outside the Flutter test binding, so this script reads the
// sample's text twins. Extraction from the PDFs themselves is covered by
// test/services/pdf_service_test.dart.
String read(String path) => File(path).readAsStringSync();

Future<void> main() async {
  final AppConfig config = await AppConfig.load();
  stdout.writeln('model: ${config.model}   key resolved: ${config.hasApiKey}');

  final String paper = read('sample/student_paper.txt');
  final String markScheme = read('sample/mark_scheme.txt');
  stdout.writeln('paper: ${paper.length} chars   '
      'mark scheme: ${markScheme.length} chars');

  final CorrectionResult result = await GeminiCorrectionService(() => config)
      .correct(
    paperText: paper,
    markSchemeText: markScheme,
    onProgress: stdout.writeln,
  );

  stdout.writeln('');
  int matches = 0;
  for (final QuestionResult question in result.questions) {
    final double? want = expected[question.questionNumber];
    final bool ok = want != null && question.awardedMarks == want;
    if (ok) matches++;
    stdout.writeln(
      'Q${question.questionNumber}: '
      '${question.awardedMarks}/${question.maximumMarks}  '
      '${want == null ? "(unexpected question)" : ok ? "as expected" : "EXPECTED $want"}',
    );
    for (final MarkingPoint point in question.markingPoints) {
      stdout.writeln('    ${point.satisfied ? "✓" : "✗"} ${point.criterion}');
    }
  }

  for (final String warning in result.warnings) {
    stdout.writeln('! $warning');
  }
  stdout.writeln('');
  stdout.writeln('matched $matches of ${expected.length} questions');
  stdout.writeln('TOTAL ${result.totalMarks}/${result.maximumTotalMarks} '
      '(${result.percentage.round()}%)   expected 14/20 (70%)');
}
