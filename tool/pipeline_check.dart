// Runs the real understanding pipeline over real files and prints what every
// stage made of them: pages, regions, readings, answers, marks.
//
//   flutter test tool/pipeline_check.dart
//   EXAM_CORRECTOR_SCAN=/path/to/script.pdf \
//   EXAM_CORRECTOR_QUESTIONS=/path/to/paper.pdf flutter test tool/pipeline_check.dart
//   EXAM_CORRECTOR_CHECK_MARKING=0 flutter test tool/pipeline_check.dart
//   EXAM_CORRECTOR_OFFLINE=1 flutter test tool/pipeline_check.dart
//
// EXAM_CORRECTOR_OFFLINE=1 spends nothing: local layout, no API key, so no
// vision, no cross-check and no marking — what the local stages make of the
// papers on their own.
//
// It is a test file only because the PDF layer needs `dart:ui`. It starts the
// real sidecar and — unless marking is turned off and the layout engine is
// local — spends real API requests, so it is not part of the offline suite.
// Everything is cached as in the app, so a second run is fast and free.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_assessment.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/pipeline/document/document_inspector.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/pipeline_factory.dart';
import 'package:exam_corrector/services/ai/gemini_model_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_client.dart';
import 'package:exam_corrector/services/ocr/sidecar_process_service.dart';

/// Leaves every question unmarked, so the check costs no marking requests.
class _NoMarking implements MarkingEngine {
  @override
  String get fingerprint => 'no-marking';

  @override
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async =>
      <QuestionResult>[
        for (final MarkingTask task in tasks)
          QuestionResult(
            questionNumber: task.question.displayNumber,
            questionId: task.question.questionId,
            maximumMarks: task.question.maximumMarks ?? 0,
            awardedMarks: 0,
            studentAnswer: task.answer.text,
            evaluation: '(marking skipped)',
          ),
      ];
}

void main() {
  test('runs the whole pipeline over the sample', () async {
    final Map<String, String> env = Platform.environment;
    final String scan = File(env['EXAM_CORRECTOR_SCAN'] ?? 'sample/student_paper_handwritten.pdf').absolute.path;
    final String paper = File(env['EXAM_CORRECTOR_QUESTIONS'] ?? 'sample/question_paper.pdf').absolute.path;
    final bool offline = env['EXAM_CORRECTOR_OFFLINE'] == '1';
    final bool marking = !offline && env['EXAM_CORRECTOR_CHECK_MARKING'] != '0';

    final AppConfig saved = await AppConfig.load();
    final AppConfig config = offline
        ? saved.withApiKey(null).copyWith(
            layoutEngine: LayoutEngine.local,
            visionCrossCheck: false,
            visualAnalysis: false,
          )
        : saved;
    final SidecarProcessService process = SidecarProcessService();
    final SidecarClient sidecar = SidecarClient(process: process);
    addTearDown(sidecar.dispose);

    final PipelineFactory factory = PipelineFactory(
      config: () => config,
      sidecar: sidecar,
      models: GeminiModelClient(() => config),
    );

    stdout.writeln('answer sheet  $scan');
    stdout.writeln('question paper $paper');
    stdout.writeln('layout ${config.layoutEngine.name} · marking ${marking ? config.model : 'off'}\n');

    const LocalDocumentInspector inspector = LocalDocumentInspector();
    final SelectedDocument answers = await inspector.inspect(scan, DocumentRole.answerSheet);
    final SelectedDocument questions = await inspector.inspect(paper, DocumentRole.questionPaper);

    ProcessingStage? last;
    final Stopwatch clock = Stopwatch()..start();
    final ExamAssessment assessment = await factory
        .build(marker: marking ? null : _NoMarking())
        .run(
          answerSheet: answers,
          questionPaper: questions,
          onUpdate: (ProcessingJob job) {
            if (job.stage != last) {
              last = job.stage;
              stdout.writeln('[${clock.elapsed.inSeconds.toString().padLeft(4)}s] ${job.stage.label}');
            }
          },
        );

    stdout.writeln('\nreused from cache: ${assessment.job.reusedStages.map((ProcessingStage s) => s.name).join(', ')}');
    stdout.writeln('\n=== QUESTION PAPER (${assessment.questionPaper.source.name})');
    for (final Question q in assessment.questionPaper.markable) {
      stdout.writeln('  ${q.displayNumber.padRight(8)} ${q.maximumMarks} marks  ${q.questionText.split('\n').first}');
    }

    stdout.writeln('\n=== PAGES');
    for (final ExamPage page in assessment.answerSheet.pages) {
      stdout.writeln('--- page ${page.pageNumber} ${page.isBlank ? '(blank)' : ''} · ${page.detector}');
      for (final PageRegion r in page.regions) {
        final HandwritingEvidence? e = assessment.evidence.handwriting[r.regionId];
        final String text = (e?.effectiveText ?? r.detectedText ?? '').replaceAll('\n', ' / ');
        stdout.writeln('  #${r.readingOrder + 1} ${r.type.wireName.padRight(18)} '
            '${(e?.confidence ?? r.confidence).toStringAsFixed(2)} '
            '${e?.agreement == null ? '' : 'agree ${e!.agreement!.toStringAsFixed(2)} '}'
            '${text.length > 90 ? '${text.substring(0, 90)}…' : text}');
      }
    }

    stdout.writeln('\n=== ANSWERS');
    for (final Question q in assessment.questionPaper.markable) {
      final StudentAnswer a = assessment.answers[q.questionId]!;
      stdout.writeln('Q${q.displayNumber} · pages ${a.pages} · read ${a.answerConfidence.toStringAsFixed(2)} · '
          'mapped ${a.alignmentConfidence.toStringAsFixed(2)}');
      stdout.writeln('   ${a.isEmpty ? '(no answer)' : a.text.replaceAll('\n', ' / ')}');
      for (final String flag in a.flags) {
        stdout.writeln('   ! $flag');
      }
    }

    if (assessment.result != null && marking) {
      stdout.writeln('\n=== MARKS');
      for (final QuestionResult q in assessment.result!.questions) {
        stdout.writeln('Q${q.questionNumber}: ${q.awardedMarks}/${q.maximumMarks} '
            '· ${(q.confidence * 100).round()}%${q.needsReview ? ' · REVIEW' : ''}');
        for (final MarkingPoint p in q.markingPoints) {
          stdout.writeln('   ${p.satisfied ? '✓' : '✗'} ${p.criterion} '
              '(${p.marks}/${p.marksAvailable}, ${p.basis.name}, ${p.evidenceRegionIds.length} region(s))');
        }
      }
      stdout.writeln('TOTAL ${assessment.result!.totalMarks}/${assessment.result!.maximumTotalMarks}');
    }
    for (final String warning in assessment.warnings) {
      stdout.writeln('! $warning');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
