import 'dart:io';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/geometry.dart';
import 'package:exam_corrector/domain/page_region.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/models/question_result.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

const AppConfig pipelineConfig = AppConfig(
  apiKey: 'test-key',
  model: 'model-a',
  effort: 'high',
  maxTokens: 32000,
  fallbackModels: <String>['model-b'],
  ocrConfidenceThreshold: 0.8,
  reviewThreshold: 0.7,
);

const String docId = 'doc';

ExamPage page(
  int number, {
  List<PageRegion> regions = const <PageRegion>[],
  bool blank = false,
  String? image,
}) =>
    ExamPage(
      pageId: ExamPage.idFor(docId, number),
      pageNumber: number,
      width: 1000,
      height: 1400,
      imagePath: image ?? '/pages/page_$number.png',
      isBlank: blank,
      regions: regions,
    );

PageRegion region(
  String id, {
  int page = 1,
  RegionType type = RegionType.handwrittenAnswer,
  int order = 0,
  double y = 0.1,
  double confidence = 0.8,
  String? label,
  String? text,
  String? parent,
  List<NormalizedBox> lines = const <NormalizedBox>[],
}) =>
    PageRegion(
      regionId: id,
      pageId: ExamPage.idFor(docId, page),
      pageNumber: page,
      type: type,
      box: NormalizedBox(x: 0.1, y: y, width: 0.8, height: 0.05),
      confidence: confidence,
      readingOrder: order,
      detectedLabel: label,
      detectedText: text,
      parentRegionId: parent,
      cropPath: '/crops/$id.png',
      lineBoxes: lines,
    );

HandwritingEvidence reading(
  String regionId,
  String text, {
  double confidence = 0.95,
  ReadingSource source = ReadingSource.trocr,
  List<UncertainSpan> spans = const <UncertainSpan>[],
  List<RecognizedLine> lines = const <RecognizedLine>[],
}) =>
    HandwritingEvidence(
      regionId: regionId,
      readings: <HandwritingReading>[
        HandwritingReading(
          source: source,
          text: text,
          confidence: confidence,
          uncertainSpans: spans,
          lines: lines,
        ),
      ],
    );

ExamDocument document(List<ExamPage> pages,
        {DocumentSource source = DocumentSource.scanned}) =>
    ExamDocument(
      documentId: docId,
      role: DocumentRole.answerSheet,
      filePath: '/papers/answers.pdf',
      fileName: 'answers.pdf',
      source: source,
      pages: pages,
    );

Question question(
  String label, {
  double? marks = 2,
  String text = 'Explain something.',
  String? section,
  List<Question> parts = const <Question>[],
}) =>
    Question(
      label: QuestionLabel.parse(label)!,
      questionText: text,
      maximumMarks: marks,
      marksStated: marks != null,
      sectionId: section,
      subQuestions: parts,
    );

QuestionPaper paperOf(List<Question> questions) =>
    QuestionPaper(documentId: 'paper', questions: questions);

/// A model client that answers each request with a handler, and records it.
class FakeModelClient implements ModelClient {
  FakeModelClient(this.handler, {this.available = true});

  final Object? Function(ModelRequest request, List<String> models) handler;
  bool available;
  final List<ModelRequest> requests = <ModelRequest>[];

  @override
  bool get isAvailable => available;

  @override
  Future<ModelResponse> requestJson(
    ModelRequest request, {
    required List<String> models,
    void Function(String message)? onProgress,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    requests.add(request);
    final Object? payload = handler(request, models);
    if (payload is AppException) throw payload;
    return ModelResponse(payload: payload, model: models.first);
  }
}

/// A selected document pointing at a real temporary file.
Future<SelectedDocument> selected(
  Directory dir,
  String name,
  DocumentRole role, {
  DocumentSource source = DocumentSource.scanned,
  String? hash,
}) async {
  final File file = File('${dir.path}/$name');
  await file.writeAsString('%PDF-1.4 $name');
  return SelectedDocument(
    role: role,
    filePath: file.path,
    fileName: name,
    contentHash: hash ?? name.replaceAll('.', '_'),
    byteCount: 10,
    pageCount: 1,
    source: source,
  );
}

MarkingPoint point(String criterion, double marks, {double? available}) =>
    MarkingPoint(
      criterion: criterion,
      satisfied: marks > 0,
      marks: marks,
      marksAvailable: available ?? marks,
    );
