/// The engines the understanding pipeline is built from.
///
/// Each stage depends on one of these interfaces and nothing more specific.
/// The implementations — local computer vision, the sidecar's TrOCR, a vision
/// model, the PDF text layer — are chosen by configuration in
/// `pipeline_factory.dart`, so nothing here, and nothing that uses it, knows
/// which provider or model is doing the work.
library;

import 'dart:io';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/models/question_result.dart';

/// Progress within a stage: a message for the teacher, and a fraction 0..1.
typedef StageProgress = void Function(String message, double fraction);

/// Validates a chosen file and fingerprints it — cheap, done on selection.
abstract class DocumentInspector {
  Future<SelectedDocument> inspect(String path, DocumentRole role);
}

/// Turns a document into page images, one page at a time.
abstract class DocumentRenderer {
  /// Identifies the renderer and its settings, for the cache key.
  String get fingerprint;

  Future<ExamDocument> render(
    SelectedDocument document, {
    required Directory outputDirectory,
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

/// Reads a PDF's own text layer as positioned lines — exact, and free.
abstract class TextLayerReader {
  Future<List<TextLayerPage>> read(String path);
}

class TextLayerPage {
  const TextLayerPage({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.lines,
  });

  final int pageNumber;
  final double width;
  final double height;
  final List<TextLayerLine> lines;

  String get text => lines.map((TextLayerLine line) => line.text).join('\n');
}

class TextLayerLine {
  const TextLayerLine({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;
}

/// What stage one decided to do with a page.
enum PageRoute {
  /// Nothing written. Skipped by every later stage.
  skip,

  /// Read from the PDF's text layer.
  textLayer,

  /// Needs layout analysis.
  detect,
}

/// Stage one: a cheap look at each page before anything expensive runs.
abstract class PageAnalyzer {
  PageRoute route(ExamPage page);
}

/// Stage two: segments pages into typed regions.
abstract class RegionDetector {
  String get fingerprint;

  /// Returns [pages] with their regions filled in. Pages this detector cannot
  /// handle are returned unchanged with an empty region list and a warning.
  Future<RegionDetection> detect(
    ExamDocument document,
    List<ExamPage> pages, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

class RegionDetection {
  const RegionDetection({
    required this.pages,
    this.readings = const <String, HandwritingReading>{},
    this.warnings = const <String>[],
  });

  final List<ExamPage> pages;

  /// Transcriptions a detector made while it looked — the vision model reads
  /// the writing as it segments the page. Kept as one reading among others,
  /// keyed by region ID.
  final Map<String, HandwritingReading> readings;
  final List<String> warnings;
}

/// Cuts regions out of their page image, for display and for models.
abstract class RegionCropper {
  Future<Map<String, String>> crop(
    ExamPage page,
    List<PageRegion> regions, {
    required Directory outputDirectory,
  });
}

/// Reads handwriting region by region.
abstract class HandwritingRecognizer {
  String get fingerprint;

  /// Returns evidence keyed by region ID. A region that could not be read
  /// gets failed evidence rather than disappearing: its image still exists.
  ///
  /// [priorReadings] are transcriptions made earlier — by the vision model
  /// while it segmented the page, or from a text layer — which a recogniser
  /// can keep, cross-check, or skip re-reading.
  Future<Map<String, HandwritingEvidence>> recognize(
    ExamDocument document,
    List<PageRegion> regions, {
    Map<String, HandwritingReading> priorReadings =
        const <String, HandwritingReading>{},
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

/// A visual region to analyse, with what is known about its context.
class VisualTask {
  const VisualTask({
    required this.region,
    required this.imagePath,
    this.questionContext,
  });

  final PageRegion region;

  /// The crop, or the whole page when no crop could be made.
  final String imagePath;

  /// The question the region was found under, when alignment knows it.
  final String? questionContext;
}

abstract class DiagramAnalyzer {
  Future<Map<String, VisualEvidence>> analyzeDiagrams(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

abstract class GraphAnalyzer {
  Future<Map<String, VisualEvidence>> analyzeGraphs(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

abstract class TableAnalyzer {
  Future<Map<String, VisualEvidence>> analyzeTables(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

abstract class EquationRecognizer {
  Future<Map<String, VisualEvidence>> recognizeEquations(
    List<VisualTask> tasks, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

/// What a question paper can be read from.
class QuestionPaperSourceData {
  const QuestionPaperSourceData({
    required this.document,
    this.text,
    this.pages = const <ExamPage>[],
  });

  final SelectedDocument document;

  /// The text layer, when the paper has one.
  final String? text;

  /// Rendered pages, when it does not.
  final List<ExamPage> pages;
}

/// Normalises a question paper into sections, questions, parts and marks.
abstract class QuestionPaperExtractor {
  String get fingerprint;

  Future<QuestionPaper> extract(
    QuestionPaperSourceData source, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

/// The answer sheet split into logical answer blocks.
class BoundaryResult {
  const BoundaryResult({
    required this.document,
    required this.evidence,
    required this.segments,
    this.warnings = const <String>[],
  });

  /// The document, with any block that held two answers split at the label.
  final ExamDocument document;
  final EvidenceSet evidence;
  final List<AnswerSegment> segments;

  /// Numbers that looked like labels but were read as part of an answer.
  final List<String> warnings;
}

/// Finds where each answer starts and ends, across regions and pages.
abstract class AnswerBoundaryDetector {
  BoundaryResult detect(
    ExamDocument document,
    EvidenceSet evidence,
    QuestionPaper paper,
  );
}

/// Maps answer blocks onto the question paper's questions.
abstract class QuestionAligner {
  AlignmentResult align(List<AnswerSegment> segments, QuestionPaper paper);
}

/// Assembles each question's complete answer from its regions and evidence.
abstract class AnswerReconstructor {
  Map<String, StudentAnswer> reconstruct({
    required ExamDocument document,
    required EvidenceSet evidence,
    required AlignmentResult alignment,
    required QuestionPaper paper,
  });
}

/// One question to mark, with everything the marker should see.
class MarkingTask {
  const MarkingTask({
    required this.question,
    required this.answer,
    this.section,
    this.images = const <MarkingImage>[],
    this.markScheme = '',
    this.paperGuidance = '',
    this.choice = '',
  });

  final Question question;
  final QuestionSection? section;
  final StudentAnswer answer;
  final List<MarkingImage> images;

  /// The mark scheme the question paper printed for this question, its
  /// parent's included. Empty when the paper prints none.
  final String markScheme;

  /// General marking instructions printed with the paper's scheme.
  final String paperGuidance;

  /// The choice this question is an option of, as it reads: "11(a) or
  /// 11(b)". Empty when it is not one.
  final String choice;
}

/// An image of part of the student's answer, tied to its region.
class MarkingImage {
  const MarkingImage({
    required this.regionId,
    required this.path,
    required this.reason,
  });

  final String regionId;
  final String path;

  /// Why it is attached: a diagram, an uncertain reading…
  final String reason;
}

/// Marks answers against their questions, with evidence for every mark.
abstract class MarkingEngine {
  String get fingerprint;

  /// Marks [tasks], returning one validated result per task, in order.
  Future<List<QuestionResult>> mark(
    List<MarkingTask> tasks, {
    required String guidance,
    required bool typedAnswerSheet,
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}
