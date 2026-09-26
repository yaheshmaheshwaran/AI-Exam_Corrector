import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/processing_job.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/domain/teacher_review.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/export/report_exporter.dart';
import 'package:exam_corrector/state/correction_controller.dart';

import 'fakes.dart';

Future<void> chooseBoth(CorrectionController controller) async {
  await controller.chooseAnswerSheet();
  await controller.chooseQuestionPaper();
}

void main() {
  group('choosing documents', () {
    test('validates each file without processing it', () async {
      final CorrectionController controller = fakeController();

      await controller.chooseAnswerSheet();
      expect(controller.answerSheet!.fileName, 'answers.pdf');
      expect(controller.canCorrect, isFalse);
      expect(controller.statusMessage, contains('scanned'));

      await controller.chooseQuestionPaper();
      expect(controller.questionPaper!.role, DocumentRole.questionPaper);
      expect(controller.canCorrect, isTrue);
      expect(controller.assessment, isNull);
    });

    test('reports an unreadable file and leaves the slot empty', () async {
      final CorrectionController controller = fakeController(
        inspector: FakeInspector(error: 'This PDF is password protected.'),
      );

      await controller.chooseAnswerSheet();

      expect(controller.answerSheet, isNull);
      expect(controller.pendingError, 'This PDF is password protected.');
      expect(controller.statusIsError, isTrue);
    });

    test('cancelling the dialog changes nothing', () async {
      final CorrectionController controller =
          fakeController(picker: FakeFilePicker(null));
      await controller.chooseAnswerSheet();
      expect(controller.answerSheet, isNull);
      expect(controller.pendingError, isNull);
    });

    test('refuses the same file as both documents', () async {
      final CorrectionController controller =
          fakeController(picker: FakeFilePicker(answerPath, answerPath));
      await chooseBoth(controller);

      await controller.startCorrection();

      expect(controller.pendingError, contains('same document'));
      expect(controller.assessment, isNull);
    });
  });

  group('correcting', () {
    test('understands, aligns and marks the paper', () async {
      final CorrectionController controller = fakeController();
      final List<ProcessingStage> stages = <ProcessingStage>[];
      controller.addListener(() {
        final ProcessingStage? stage = controller.job?.stage;
        if (stage != null && (stages.isEmpty || stages.last != stage)) stages.add(stage);
      });
      await chooseBoth(controller);

      await controller.startCorrection();

      expect(stages, contains(ProcessingStage.recognizingHandwriting));
      expect(stages, contains(ProcessingStage.marking));
      expect(controller.result!.questions.map((QuestionResult q) => q.questionId),
          <String>['Q1', 'Q2']);
      expect(controller.assessment!.answers['Q1']!.text, contains('mitochondrion'));
      expect(controller.statusMessage, 'Marked 2 questions: 2 / 4 (50%). 1 need your review.');
      expect(controller.isProcessing, isFalse);
    });

    test('passes the guidance to marking', () async {
      final FakeMarker marker = FakeMarker();
      final CorrectionController controller = fakeController(marker: marker);
      await chooseBoth(controller);

      controller.setGuidance('  Award one mark per organelle.  ');
      await controller.startCorrection();

      expect(marker.lastGuidance, 'Award one mark per organelle.');
    });

    test('loads guidance from a file', () async {
      final Directory dir = await Directory.systemTemp.createTemp('guidance');
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/scheme.txt')
        ..writeAsStringSync('Q1: mitochondrion (1), ATP (1)');
      final FakeFilePicker picker = FakeFilePicker(answerPath, questionPath)
        ..guidancePath = file.path;
      final CorrectionController controller = fakeController(picker: picker);

      await controller.loadGuidanceFile();

      expect(controller.guidance.trimmed, 'Q1: mitochondrion (1), ATP (1)');
      expect(controller.guidanceFile, 'scheme.txt');
    });

    test('a marking failure keeps everything read from the paper', () async {
      final FakeMarker marker =
          FakeMarker(error: const CorrectionException('The free-tier quota has run out.'));
      final CorrectionController controller = fakeController(marker: marker);
      await chooseBoth(controller);

      await controller.startCorrection();

      expect(controller.result, isNull);
      expect(controller.assessment!.answers['Q1']!.text, contains('mitochondrion'));
      expect(controller.pendingError, 'The free-tier quota has run out.');
      expect(controller.job!.failedStage, ProcessingStage.marking);

      // Marking again resumes: nothing before marking runs twice.
      marker.error = null;
      await controller.startCorrection();
      expect(controller.result, isNotNull);
    });

    test('a pipeline failure is reported with its stage', () async {
      final CorrectionController controller = fakeController(
        paper: _FailingPaper(),
      );
      await chooseBoth(controller);

      await controller.startCorrection();

      expect(controller.pendingError, contains('no questions'));
      expect(controller.statusMessage, 'Correction failed.');
      expect(controller.isBusy, isFalse);
    });

    test('an unfinished run is offered for resuming when the files are chosen again', () async {
      final MemoryArtifactStore store = MemoryArtifactStore();
      final CorrectionController first = fakeController(
        store: store,
        marker: FakeMarker(error: const CorrectionException('quota')),
      );
      await chooseBoth(first);
      await first.startCorrection();

      final CorrectionController second = fakeController(store: store);
      await chooseBoth(second);

      expect(second.resumableJob, isNotNull);
      expect(second.statusMessage, contains('resume from marking'));
    });

    test('cancelling stops processing and says how to resume', () async {
      final FakeMarker marker = FakeMarker(gate: Completer<void>());
      final CorrectionController controller = fakeController(marker: marker);
      await chooseBoth(controller);

      final Future<void> running = controller.startCorrection();
      await Future<void>.delayed(Duration.zero);
      while (controller.job?.stage != ProcessingStage.marking) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(controller.isProcessing, isTrue);
      controller.cancelProcessing();
      marker.gate!.complete();
      await running;

      expect(controller.isProcessing, isFalse);
      expect(controller.statusMessage, contains('resumes where it stopped'));
      expect(controller.result, isNull);
    });
  });

  group('teacher review', () {
    late CorrectionController controller;
    late MemoryArtifactStore store;
    late FakeMarker marker;

    setUp(() async {
      store = MemoryArtifactStore();
      marker = FakeMarker();
      controller = fakeController(store: store, marker: marker);
      await chooseBoth(controller);
      await controller.startCorrection();
    });

    test('accepting records the AI mark without changing it', () async {
      await controller.acceptMark('Q1');

      final TeacherReview review = controller.reviews['Q1']!;
      expect(review.status, ReviewStatus.accepted);
      expect(review.aiMarks, 1);
      expect(controller.finalTotal, 2);
    });

    test('an override counts in the total and keeps the AI mark beside it', () async {
      await controller.overrideMark('Q1', 2, comment: 'Site is implied.');

      final TeacherReview review = controller.reviews['Q1']!;
      expect(review.teacherMarks, 2);
      expect(review.aiMarks, 1);
      expect(review.comment, 'Site is implied.');
      expect(controller.result!.question('Q1')!.awardedMarks, 1,
          reason: 'the AI result is never overwritten');
      expect(controller.finalTotal, 3);
      expect(controller.finalPercentage, 75);
      expect(controller.reviews.outstanding(controller.result!), 1);
    });

    test('an override outside the question\'s range is refused', () async {
      await controller.overrideMark('Q1', 5);
      expect(controller.reviews['Q1'], isNull);
      expect(controller.pendingError, contains('between 0 and 2'));
    });

    test('reviews survive a restart', () async {
      await controller.overrideMark('Q2', 0, comment: 'No mention of respiration.');

      final CorrectionController reopened = fakeController(store: store);
      await chooseBoth(reopened);

      expect(reopened.reviews['Q2']!.teacherMarks, 0);
      expect(reopened.reviews['Q2']!.comment, 'No mention of respiration.');
    });

    test('clearing a review restores the AI mark', () async {
      await controller.overrideMark('Q1', 2);
      await controller.clearReview('Q1');
      expect(controller.finalTotal, 2);
    });

    test('a corrected transcription re-marks only its own question', () async {
      final String region = controller.assessment!.answers['Q2']!.textEvidence.first.regionId;
      marker.marked.clear();

      await controller.correctTranscription(region, '2 Because muscles respire a lot.');
      expect(controller.hasPendingCorrections, isTrue);
      await controller.startCorrection();

      expect(marker.marked, <String>['Q2']);
      expect(controller.hasPendingCorrections, isFalse);
      final TextEvidenceItem item =
          controller.assessment!.answers['Q2']!.textEvidence.first;
      expect(item.text, '2 Because muscles respire a lot.');
      expect(item.rawText, '2 Because muscles need energy.');
    });

    test('writing the teacher chooses moves to that question at the re-mark', () async {
      final String region = controller.assessment!.answers['Q2']!.regionIds.first;

      await controller.assignRegions('Q1', <String>[region]);
      expect(controller.hasPendingCorrections, isTrue);
      expect(controller.assignments, <String, String>{region: 'Q1'});
      await controller.startCorrection();

      expect(controller.assessment!.answers['Q1']!.regionIds, contains(region));
      expect(controller.assessment!.answers['Q2']!.regionIds, isNot(contains(region)));
      expect(controller.assessment!.alignment.alignments['Q1']!.methods,
          contains(AlignmentMethod.teacher));

      // Kept for this script and paper across a restart; undone on request.
      final CorrectionController reopened = fakeController(store: store);
      await chooseBoth(reopened);
      expect(reopened.assignments, <String, String>{region: 'Q1'});
      await reopened.clearAssignments('Q1');
      expect(reopened.assignments, isEmpty);
    });

    test('reverting a correction goes back to the machine reading', () async {
      final String region = controller.assessment!.answers['Q2']!.textEvidence.first.regionId;
      await controller.correctTranscription(region, 'changed');
      await controller.revertTranscription(region);
      await controller.startCorrection();

      expect(controller.assessment!.answers['Q2']!.textEvidence.first.text,
          '2 Because muscles need energy.');
    });
  });

  group('export', () {
    test('writes a report with both marks for an overridden question', () async {
      final Directory dir = await Directory.systemTemp.createTemp('export');
      addTearDown(() => dir.delete(recursive: true));
      final FakeFilePicker picker = FakeFilePicker(answerPath, questionPath)
        ..savePath = '${dir.path}/report.csv';
      final CorrectionController controller = fakeController(picker: picker);
      await chooseBoth(controller);
      await controller.startCorrection();
      await controller.overrideMark('Q1', 2, comment: 'Fine');

      final String? path = await controller.exportReport(ReportFormat.csv);

      expect(path, '${dir.path}/report.csv');
      expect(picker.lastSuggestedName, 'answers - marks.csv');
      final List<String> lines = File(path!).readAsLinesSync();
      expect(lines.first, startsWith('Student,Question,Section,Maximum,AI mark,Teacher mark'));
      expect(lines[1], contains('answers.pdf,1,,2,1,2,2,90%,no,overridden,Fine'));
      expect(lines.last, contains('TOTAL'));
      expect(lines.last, contains('75%'));
    });

    test('does nothing before the paper is marked', () async {
      final CorrectionController controller = fakeController();
      expect(await controller.exportReport(ReportFormat.json), isNull);
    });
  });

  group('settings', () {
    test('saves the key and page understanding options, and applies them', () async {
      final RecordingSettingsStore settings = RecordingSettingsStore();
      final CorrectionController controller = fakeController(
        settings: settings,
        config: const AppConfig(apiKey: null, model: 'm', effort: 'high', maxTokens: 1),
      );
      expect(controller.statusIsError, isTrue);

      await controller.saveSettings(
        apiKey: ' new-key ',
        model: 'gemini-3.5-flash',
        fallbackModels: '',
        layoutEngine: LayoutEngine.vision,
        visionModel: 'gemini-3.7-flash',
        reviewThreshold: 0.8,
        developerMode: true,
      );

      expect(settings.saved, 'new-key');
      expect(settings.savedLayout, 'vision');
      expect(controller.config.apiKey, 'new-key');
      expect(controller.config.layoutEngine, LayoutEngine.vision);
      expect(controller.config.effectiveVisionModel, 'gemini-3.7-flash');
      expect(controller.config.reviewThreshold, 0.8);
      expect(controller.config.developerMode, isTrue);
      expect(controller.config.modelChain, <String>['gemini-3.5-flash']);
      expect(controller.statusIsError, isFalse);
    });

    test('a failure to save is reported, and the old settings stay', () async {
      final CorrectionController controller = fakeController(
        settings: RecordingSettingsStore(throwOnSave: true),
      );
      await controller.saveSettings(apiKey: 'x', model: 'y');
      expect(controller.pendingError, contains('disk full'));
      expect(controller.config.apiKey, 'test-key');
    });
  });
}

class _FailingPaper extends FakePaperExtractor {
  @override
  Future<Never> extract(
    source, {
    onProgress,
    cancel,
  }) async {
    throw const PipelineException('The question paper has no questions.');
  }
}
