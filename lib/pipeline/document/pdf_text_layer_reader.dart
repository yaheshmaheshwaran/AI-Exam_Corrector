import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/pdf_service.dart';

/// [TextLayerReader] over the PDF service's positioned text extraction.
class PdfTextLayerReader implements TextLayerReader {
  const PdfTextLayerReader({PdfService pdfService = const PdfService()})
      : _pdf = pdfService;

  final PdfService _pdf;

  @override
  Future<List<TextLayerPage>> read(String path) => _pdf.readTextLines(path);
}
