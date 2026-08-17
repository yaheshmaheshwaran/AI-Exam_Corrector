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

/// Compares question numbers on identity, not punctuation.
///
/// The model is told to report the identifier "as written in the question
/// paper", and the paper prints `2 (a)` — so that is what comes back, and it is
/// correct. Matching it against `2a` is this script's problem, not a marking
/// discrepancy.
String key(String questionNumber) =>
    questionNumber.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

// The PDF layer needs Flutter (syncfusion imports dart:ui) while real HTTP
// needs to be outside the Flutter test binding, so this script reads the
// sample's text twins. Extraction from the PDFs themselves is covered by
// test/services/pdf_service_test.dart.
String read(String path) => File(path).readAsStringSync();

Future<void> main() async {
  final AppConfig config = await AppConfig.load();
  stdout.writeln('model: ${config.model}   key resolved: ${config.hasApiKey}');

  final String answerSheet = read('sample/student_paper.txt');
  final String questionPaper = read('sample/question_paper.txt');
  stdout.writeln('answer sheet: ${answerSheet.length} chars   '
      'question paper: ${questionPaper.length} chars');

  final CorrectionResult result = await GeminiCorrectionService(() => config)
      .correct(
    questionPaperText: questionPaper,
    answerSheetText: answerSheet,
    onProgress: stdout.writeln,
  );

  stdout.writeln('');
  int matches = 0;
  for (final QuestionResult question in result.questions) {
    final double? want = expected[key(question.questionNumber)];
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
