// Runs the real handwriting pipeline through the application's own services.
//
// Unlike ocr_service/tools/run_pipeline.py, this exercises everything the app
// actually uses: spawning the sidecar, the SSE client, the transcript parser,
// the vision cross-check, normalisation and question anchoring. If this passes,
// only the widget layer stands between it and the real flow.
//
//   flutter test tool/ocr_check.dart
//   EXAM_CORRECTOR_SCAN=/path/to/scan.pdf flutter test tool/ocr_check.dart
//   EXAM_CORRECTOR_OCR_VISION_CHECK=0 flutter test tool/ocr_check.dart
//
// It is a test file only because the ingest path reaches `syncfusion_flutter_pdf`,
// which needs `dart:ui` and so cannot run under plain `dart run`. It asserts
// nothing about marking; it prints what the pipeline produced.
//
// This one really does hit the sidecar, and — unless the cross-check is turned
// off — the real API, so it is not part of the offline suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';
import 'package:exam_corrector/services/ocr/document_ingest_service.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/services/ocr/question_anchor_service.dart';
import 'package:exam_corrector/services/ocr/sidecar_ocr_service.dart';

void main() {
  test('transcribes a scanned script end to end', () async {
    final String path = File(
      Platform.environment['EXAM_CORRECTOR_SCAN'] ??
          'sample/student_paper_handwritten.pdf',
    ).absolute.path;

    if (!File(path).existsSync()) {
      fail(
        'Not found: $path\n'
        'Generate one with: ocr_service/.venv/bin/python '
        'tools/make_handwritten_sample.py',
      );
    }

    final AppConfig config = await AppConfig.load();

    stdout.writeln('paper      $path');
    stdout.writeln('model      ${config.trocrModel}');
    stdout.writeln('threshold  ${config.ocrConfidenceThreshold}');
    stdout.writeln('vision     ${config.visionCrossCheck ? 'on' : 'off'}');
    stdout.writeln('');

    final OcrService ocr = SidecarOcrService(() => config);
    final DocumentIngestService ingest = DocumentIngestService(
      configProvider: () => config,
      ocrService: ocr,
      visionService: VisionTranscriptionService(() => config),
    );

    final Stopwatch clock = Stopwatch()..start();

    try {
      final IngestResult result = await ingest.loadDocument(
        path,
        onProgress: (String message, double fraction) {
          final String percent =
              (fraction * 100).round().toString().padLeft(3);
          stdout.writeln('  [$percent%] $message');
        },
      );

      clock.stop();
      _report(result, clock.elapsed, config);

      expect(result.document.source, ExamSource.ocr);
      expect(result.document.transcript, isNotNull);
      expect(result.document.text, isNotEmpty);
    } finally {
      await ocr.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}

void _report(IngestResult result, Duration elapsed, AppConfig config) {
  final ExamPaper paper = result.document;
  final DocumentTranscript? transcript = paper.transcript;

  stdout.writeln('\nsource     ${paper.source.name}');
  stdout.writeln('elapsed    ${elapsed.inSeconds}s');

  if (transcript == null) {
    stdout.writeln('\n(text layer — no transcript)');
    return;
  }

  final double threshold = config.ocrConfidenceThreshold;

  stdout.writeln('engine     ${transcript.engine}');
  stdout.writeln('detector   ${transcript.detector}');
  stdout.writeln('lines      ${transcript.lineCount}');
  stdout.writeln('mean conf  ${transcript.meanConfidence.toStringAsFixed(3)}');
  stdout.writeln('uncertain  ${transcript.uncertainCount(threshold)}');

  if (result.warnings.isNotEmpty) {
    stdout.writeln('\nwarnings:');
    for (final String warning in result.warnings) {
      stdout.writeln('  - $warning');
    }
  }

  stdout.writeln('\n=== lines ===');
  for (final PageTranscript page in transcript.pages) {
    stdout.writeln('--- Page ${page.pageNumber} ---');
    for (final TextLine line in page.lines) {
      final String flag = line.isUncertain(threshold) ? '  <-- CHECK' : '';
      final String origin =
          line.source == OcrSource.trocr ? '' : '  [${line.source.name}]';
      stdout.writeln(
        '  ${line.confidence.toStringAsFixed(3)}  ${line.text}$origin$flag',
      );
    }
  }

  final AnchoredTranscript anchored =
      const QuestionAnchorService().anchor(transcript, flagBelow: threshold);

  stdout.writeln('\n=== question anchors ===');
  if (anchored.anchors.isEmpty) stdout.writeln('  (none detected)');
  for (final QuestionAnchor anchor in anchored.anchors) {
    stdout.writeln(
      '  Q${anchor.questionNumber}  page ${anchor.pageIndex + 1} '
      'line ${anchor.lineIndex}',
    );
  }

  stdout.writeln('\n=== text sent for marking ===');
  stdout.writeln(anchored.text);
}
