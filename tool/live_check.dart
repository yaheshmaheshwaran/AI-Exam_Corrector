// One-off manual check: marks a tiny paper against a tiny mark scheme using
// the real API and the real key, then prints the validated result.
//
// Run with:  dart run tool/live_check.dart
// This is not part of `flutter test` — the test suite stays offline.
import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/models/correction_result.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/ai/gemini_correction_service.dart';

const String questionPaper = '''
--- Page 1 ---
SECTION A

1. Name the organelle that carries out aerobic respiration and state the
   molecule it produces.                                        [2 marks]

2. Give one reason why muscle cells contain many mitochondria.   [1 mark]
''';

const String answerSheet = '''
--- Page 1 ---
1. The mitochondrion. It makes ATP.

2. (left blank)
''';

Future<void> main() async {
  final AppConfig config = await AppConfig.load();
  stdout.writeln('model: ${config.model}  effort: ${config.effort}');
  stdout.writeln('api key resolved: ${config.hasApiKey}');
  if (!config.hasApiKey) {
    stderr.writeln('No key resolved — nothing to check.');
    exit(1);
  }

  final GeminiCorrectionService service = GeminiCorrectionService(() => config);

  try {
    final CorrectionResult result = await service.correct(
      questionPaperText: questionPaper,
      answerSheetText: answerSheet,
    );

    for (final QuestionResult question in result.questions) {
      stdout.writeln(
        'Q${question.questionNumber}: '
        '${question.awardedMarks}/${question.maximumMarks} — '
        '${question.evaluation}',
      );
      for (final MarkingPoint point in question.markingPoints) {
        stdout.writeln(
          '   ${point.satisfied ? "✓" : "✗"} ${point.criterion}',
        );
      }
    }
    stdout.writeln(
      'TOTAL ${result.totalMarks}/${result.maximumTotalMarks} '
      '(${result.percentage.round()}%)  warnings: ${result.warnings.length}',
    );
  } catch (error) {
    stderr.writeln('FAILED: $error');
    exit(1);
  }
}
