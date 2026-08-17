import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/exam_paper.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ai/vision_transcription_service.dart';
import 'package:exam_corrector/services/ocr/answer_normalizer.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';
import 'package:exam_corrector/services/pdf_service.dart';

/// What ingestion produced: the paper, and anything worth telling the teacher.
class IngestResult {
  const IngestResult({
    required this.document,
    this.warnings = const <String>[],
  });

  /// The extracted document — an answer sheet or a question paper. Which one
  /// is the caller's business; ingestion treats them identically.
  final ExamPaper document;

  final List<String> warnings;

  /// A recognised document has to be checked by the teacher before it is used.
  bool get needsReview => document.isHandwritten;
}

/// Decides how a chosen file becomes markable text.
///
/// This is the branch the application was missing: a PDF with a text layer is
/// read directly, exactly as before, while a scan or a photograph — which used
/// to be rejected outright — goes to handwriting recognition instead.
///
/// The routing lives here rather than inside [PdfService] so that the PDF
/// service stays a pure "bytes to text" component with no opinion about, and no
/// dependency on, the OCR pipeline.
class DocumentIngestService {
  const DocumentIngestService({
    required AppConfig Function() configProvider,
    required OcrService ocrService,
    required VisionTranscriptionService visionService,
    PdfService pdfService = const PdfService(),
    AnswerNormalizer normalizer = const AnswerNormalizer(),
  })  : _configProvider = configProvider,
        _ocrService = ocrService,
        _visionService = visionService,
        _pdfService = pdfService,
        _normalizer = normalizer;

  final AppConfig Function() _configProvider;
  final OcrService _ocrService;
  final VisionTranscriptionService _visionService;
  final PdfService _pdfService;
  final AnswerNormalizer _normalizer;

  static const Set<String> imageExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.tif',
    '.tiff',
    '.bmp',
    '.webp',
  };

  AppConfig get _config => _configProvider();

  /// Turns a chosen file into markable text, whichever of the two documents it
  /// is. Ingestion draws no distinction between them.
  Future<IngestResult> loadDocument(
    String path, {
    OcrProgress? onProgress,
  }) async {
    if (_isImage(path)) {
      // A photograph has no text layer to try; it is handwriting by definition.
      if (!_config.ocrEnabled) {
        throw const OcrException(
          'Handwriting recognition is turned off, so an image cannot be read. '
          'Turn it on in Settings, or supply a PDF with a text layer.',
        );
      }
      return _recognise(path, onProgress: onProgress);
    }

    final String? text = await _pdfService.extractTextIfPresent(path);

    if (text != null) {
      return IngestResult(
        document: ExamPaper(
          filePath: path,
          fileName: _baseName(path),
          text: text,
        ),
      );
    }

    if (!_config.ocrEnabled) {
      throw const PdfExtractionException(
        'No readable text was found in this PDF. It is most likely a scan or '
        'photograph. Turn on handwriting recognition in Settings, or supply a '
        'PDF with a text layer.',
      );
    }

    return _recognise(path, onProgress: onProgress);
  }

  /// Recognise, cross-check, normalise.
  ///
  /// The order is deliberate. Cross-checking compares the vision model's
  /// reading against what TrOCR *originally* produced, so it has to happen
  /// before normalisation rewrites anything; normalising afterwards then tidies
  /// both readings on the same terms.
  Future<IngestResult> _recognise(
    String path, {
    OcrProgress? onProgress,
  }) async {
    final DocumentTranscript recognised = await _ocrService.transcribe(
      path: path,
      onProgress: onProgress,
    );

    final CrossCheckOutcome crossChecked = await _visionService.crossCheck(
      recognised,
      onProgress: onProgress,
    );

    final DocumentTranscript normalised = _normalise(crossChecked.transcript);
    final double threshold = _config.ocrConfidenceThreshold;

    final List<String> warnings = <String>[
      ...crossChecked.warnings,
      ..._describe(normalised, crossChecked, threshold),
    ];

    return IngestResult(
      document: ExamPaper(
        filePath: path,
        fileName: _baseName(path),
        text: normalised.toMarkedText(flagBelow: threshold),
        source: ExamSource.ocr,
        transcript: normalised,
      ),
      warnings: warnings,
    );
  }

  DocumentTranscript _normalise(DocumentTranscript transcript) {
    final Map<int, Map<int, TextLine>> replacements =
        <int, Map<int, TextLine>>{};

    for (int pageIndex = 0; pageIndex < transcript.pages.length; pageIndex++) {
      final PageTranscript page = transcript.pages[pageIndex];

      for (int lineIndex = 0; lineIndex < page.lines.length; lineIndex++) {
        final TextLine line = page.lines[lineIndex];
        final NormalizedLine normalized = _normalizer.normalizeLine(line.text);
        if (!normalized.isChanged || normalized.text == line.text) continue;

        replacements.putIfAbsent(
          pageIndex,
          () => <int, TextLine>{},
        )[lineIndex] = line.copyWith(text: normalized.text);
      }
    }

    return transcript.withLines(replacements);
  }

  List<String> _describe(
    DocumentTranscript transcript,
    CrossCheckOutcome crossChecked,
    double threshold,
  ) {
    final List<String> warnings = <String>[];
    final int uncertain = transcript.uncertainCount(threshold);

    if (crossChecked.rechecked > 0) {
      warnings.add(
        '${crossChecked.rechecked} low-confidence line(s) were double-checked '
        'against the page image; ${crossChecked.changed} were corrected.',
      );
    }

    if (uncertain > 0) {
      warnings.add(
        '$uncertain line(s) are still uncertain. Check them in the transcript '
        'review before trusting the marks that depend on them.',
      );
    }

    return warnings;
  }

  bool _isImage(String path) {
    final String lower = path.toLowerCase();
    return imageExtensions.any(lower.endsWith);
  }

  String _baseName(String path) {
    final int separator = path.lastIndexOf(RegExp(r'[/\\]'));
    return separator == -1 ? path : path.substring(separator + 1);
  }
}
