import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';

/// Turns the sidecar's JSON into a [DocumentTranscript].
///
/// Follows the same principle as [CorrectionValidationService]: this is the
/// only place a transcript is constructed, so nothing reaches the review screen
/// without having been checked. The sidecar is a separate process that can be
/// upgraded independently of the app, so its output is treated as untrusted
/// input rather than assumed well-formed.
class TranscriptParser {
  const TranscriptParser();

  DocumentTranscript parse(Object? payload) {
    if (payload is! Map<String, dynamic>) {
      throw const OcrException(
        'The handwriting recogniser returned an unexpected response.',
      );
    }

    final Object? rawPages = payload['pages'];
    if (rawPages is! List) {
      throw const OcrException(
        'The handwriting recogniser returned no pages.',
      );
    }

    final List<PageTranscript> pages = <PageTranscript>[
      for (int index = 0; index < rawPages.length; index++)
        _parsePage(rawPages[index], index),
    ];

    if (pages.every((PageTranscript page) => page.isEmpty)) {
      throw const OcrException(
        'No handwriting could be found in this document. Check that the scan '
        'is the right way up and that the writing is legible.',
      );
    }

    return DocumentTranscript(
      pages: pages,
      engine: _text(payload['engine']) ?? 'unknown',
      detector: _text(payload['detector']) ?? 'unknown',
      dpi: _integer(payload['dpi']) ?? 0,
      workdir: _text(payload['workdir']) ?? '',
    );
  }

  PageTranscript _parsePage(Object? raw, int fallbackIndex) {
    if (raw is! Map<String, dynamic>) {
      throw OcrException('Page ${fallbackIndex + 1} was not readable.');
    }

    final Object? rawLines = raw['lines'];
    final List<TextLine> lines = <TextLine>[];

    if (rawLines is List) {
      for (final Object? entry in rawLines) {
        final TextLine? line = _parseLine(entry);
        if (line != null) lines.add(line);
      }
    }

    return PageTranscript(
      index: _integer(raw['index']) ?? fallbackIndex,
      imagePath: _text(raw['image_path']) ?? '',
      width: _integer(raw['width']) ?? 0,
      height: _integer(raw['height']) ?? 0,
      lines: lines,
    );
  }

  /// Returns null for a line that carries no usable text, rather than throwing.
  ///
  /// One malformed line out of several hundred should cost that line, not the
  /// whole script the teacher just waited minutes for.
  TextLine? _parseLine(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;

    final String? text = _text(raw['text']);
    if (text == null) return null;

    final LineBox? box = _parseBox(raw['box']);
    if (box == null) return null;

    return TextLine(
      text: text,
      ocrText: text,
      confidence: _confidence(raw['confidence']),
      box: box,
      cropPath: _text(raw['crop_path']) ?? '',
    );
  }

  LineBox? _parseBox(Object? raw) {
    if (raw is! List || raw.length < 4) return null;

    final List<int> values = <int>[];
    for (int index = 0; index < 4; index++) {
      final int? value = _integer(raw[index]);
      if (value == null) return null;
      values.add(value);
    }

    if (values[2] <= 0 || values[3] <= 0) return null;

    return LineBox(
      x: values[0],
      y: values[1],
      width: values[2],
      height: values[3],
    );
  }

  /// Clamped rather than rejected: an out-of-range confidence is a bug in the
  /// recogniser, but the line's text may still be perfectly good.
  double _confidence(Object? value) {
    if (value is! num || value is bool) return 0;
    final double confidence = value.toDouble();
    if (!confidence.isFinite) return 0;
    return confidence.clamp(0.0, 1.0);
  }

  int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value is! bool && value.isFinite) return value.round();
    return null;
  }

  String? _text(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
