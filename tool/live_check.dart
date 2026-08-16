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

const String paper = '''
--- Page 1 ---
Question 1. Name the organelle that carries out aerobic respiration and state
the molecule it produces.
Answer: The mitochondrion. It makes ATP.

Question 2. Give one reason why muscle cells contain many mitochondria.
Answer: (left blank)
''';

const String markScheme = '''
Question 1 (2 marks)
  - Names the mitochondrion (1 mark)
  - States that ATP is produced (1 mark)

Question 2 (1 mark)
  - Muscle cells have a high energy demand / need lots of ATP (1 mark)
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
      paperText: paper,
      markSchemeText: markScheme,
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
