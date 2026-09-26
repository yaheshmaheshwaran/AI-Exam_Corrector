// Marks two tiny answers with the real API and prints the validated result.
//
//   dart run tool/live_check.dart
//
// Checks the key, the model chain and the marking engine end to end in one
// request. Not part of `flutter test` — the suite stays offline.
import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/marking/model_marking_engine.dart';
import 'package:exam_corrector/services/ai/gemini_model_client.dart';

StudentAnswer typed(String id, String text) => StudentAnswer(
      questionId: id,
      pages: const <int>[1],
      regionIds: <String>['$id-r1'],
      textEvidence: <TextEvidenceItem>[
        TextEvidenceItem(
          regionId: '$id-r1',
          pageNumber: 1,
          type: RegionType.handwrittenAnswer,
          text: text,
          rawText: text,
          confidence: 0.95,
          source: ReadingSource.trocr,
        ),
      ],
      answerConfidence: 0.95,
      alignmentConfidence: 1,
    );

Future<void> main() async {
  final AppConfig config = await AppConfig.load();
  stdout.writeln('model: ${config.model}  effort: ${config.effort}  key: ${config.hasApiKey}');
  if (!config.hasApiKey) {
    stderr.writeln('No key resolved — nothing to check.');
    exit(1);
  }

  final List<MarkingTask> tasks = <MarkingTask>[
    MarkingTask(
      question: Question(
        label: QuestionLabel.parse('1')!,
        questionText: 'Name the organelle that carries out aerobic respiration and '
            'state the molecule it produces.',
        maximumMarks: 2,
        marksStated: true,
      ),
      answer: typed('Q1', 'The mitochondrion. It makes ATP.'),
    ),
    MarkingTask(
      question: Question(
        label: QuestionLabel.parse('2')!,
        questionText: 'Give one reason why muscle cells contain many mitochondria.',
        maximumMarks: 1,
        marksStated: true,
      ),
      answer: typed('Q2', 'Because the chloroplost makes energy.'),
    ),
  ];

  try {
    final List<QuestionResult> results = await ModelMarkingEngine(
      GeminiModelClient(() => config),
      () => config,
    ).mark(tasks, guidance: '', typedAnswerSheet: false, onProgress: (String m, double f) => stdout.writeln(m));
    for (final QuestionResult q in results) {
      stdout.writeln('Q${q.questionNumber}: ${q.awardedMarks}/${q.maximumMarks} '
          '(${(q.confidence * 100).round()}%) — ${q.evaluation}');
      for (final MarkingPoint p in q.markingPoints) {
        stdout.writeln('   ${p.satisfied ? '✓' : '✗'} ${p.criterion} [${p.basis.name}; ${p.evidenceRegionIds.join(', ')}]');
      }
      for (final InterpretedReading r in q.interpretedReadings) {
        stdout.writeln('   read "${r.raw}" as "${r.interpreted}" (${r.basis.name})');
      }
    }
  } catch (error) {
    stderr.writeln('FAILED: $error');
    exit(1);
  }
}
