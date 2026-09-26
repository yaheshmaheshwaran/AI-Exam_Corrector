// Marks the typed sample script through the whole pipeline and compares every
// question with sample/expected_outcome.md.
//
//   flutter test tool/sample_check.dart
//   EXAM_CORRECTOR_GUIDANCE=sample/mark_scheme.txt flutter test tool/sample_check.dart
//
// With EXAM_CORRECTOR_GUIDANCE the file is supplied as the teacher's marking
// guidance, exactly as if it had been loaded in the app.
//
// A test file only because the PDF layer needs `dart:ui`. It spends real API
// requests (one or two), so it is not part of the offline suite. The Flutter
// test binding is deliberately never initialised: it would block real HTTP.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/document/document_inspector.dart';
import 'package:exam_corrector/pipeline/pipeline_factory.dart';
import 'package:exam_corrector/services/ai/gemini_model_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_process_service.dart';

/// From sample/expected_outcome.md, keyed by question ID.
const Map<String, double> expected = <String, double>{
  'Q1': 2,
  'Q2a': 1,
  'Q2b': 1,
  'Q3': 2,
  'Q4': 2,
  'Q5': 0,
  'Q6': 2,
  'Q7': 2,
  'Q8': 2,
};

void main() {
  test('marks the sample as expected', () async {
    final AppConfig config = await AppConfig.load();
    final SidecarClient sidecar = SidecarClient(process: SidecarProcessService());
    addTearDown(sidecar.dispose);
    final PipelineFactory factory = PipelineFactory(
      config: () => config,
      sidecar: sidecar,
      models: GeminiModelClient(() => config),
    );

    final String? guidancePath = Platform.environment['EXAM_CORRECTOR_GUIDANCE'];
    final String guidance =
        guidancePath == null ? '' : File(guidancePath).readAsStringSync();
    stdout.writeln(guidance.isEmpty
        ? 'no marking guidance'
        : 'marking guidance: $guidancePath (${guidance.length} characters)');

    const LocalDocumentInspector inspector = LocalDocumentInspector();
    final ExamAssessment assessment = await factory.build().run(
          guidance: guidance,
          answerSheet: await inspector.inspect(
            File('sample/student_paper.pdf').absolute.path,
            DocumentRole.answerSheet,
          ),
          questionPaper: await inspector.inspect(
            File('sample/question_paper.pdf').absolute.path,
            DocumentRole.questionPaper,
          ),
        );

    final List<QuestionResult> questions =
        assessment.result?.questions ?? const <QuestionResult>[];
    int matches = 0;
    for (final QuestionResult q in questions) {
      final double? want = expected[q.questionId];
      final bool ok = want != null && q.awardedMarks == want;
      if (ok) matches++;
      stdout.writeln('Q${q.questionNumber}: ${q.awardedMarks}/${q.maximumMarks}  '
          '${want == null ? '(unexpected)' : ok ? 'as expected' : 'EXPECTED $want'}'
          '${q.needsReview ? '  [review]' : ''}');
      for (final MarkingPoint p in q.markingPoints) {
        stdout.writeln('    ${p.satisfied ? '✓' : '✗'} ${p.criterion}');
      }
    }
    for (final String warning in assessment.warnings) {
      stdout.writeln('! $warning');
    }
    stdout.writeln('\nmatched $matches of ${expected.length} questions');
    stdout.writeln('TOTAL ${assessment.result?.totalMarks}/${assessment.result?.maximumTotalMarks}'
        '   expected 14/20');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
