import 'dart:convert';
import 'dart:io';

import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/constants/app_constants.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/models/ocr/document_transcript.dart';
import 'package:exam_corrector/models/ocr/page_transcript.dart';
import 'package:exam_corrector/models/ocr/text_line.dart';
import 'package:exam_corrector/services/ai/gemini_client.dart';
import 'package:exam_corrector/services/ocr/ocr_service.dart';

/// What a cross-check run amounted to.
class CrossCheckOutcome {
  const CrossCheckOutcome({
    required this.transcript,
    required this.rechecked,
    required this.changed,
    this.warnings = const <String>[],
  });

  final DocumentTranscript transcript;

  /// Lines that were sent for a second opinion.
  final int rechecked;

  /// Lines whose text the second opinion actually changed.
  final int changed;

  /// Anything the teacher should know — most often that the cross-check was
  /// skipped because the API quota had run out.
  final List<String> warnings;
}

/// A second opinion on the lines TrOCR was unsure of.
///
/// TrOCR is a single-line recogniser trained on IAM: English prose, one line at
/// a time. It is strong on running handwriting and reliably weak on everything
/// an exam script is also full of — equations, tables, units, crossed-out work.
/// Those are exactly the lines it scores badly, so a low confidence is a good
/// signal for "ask something with broader training".
///
/// Deliberately best-effort. A failure here leaves the TrOCR reading in place
/// and adds a warning; it never blocks marking, because a spent daily quota
/// must not stop a teacher from marking a paper.
class VisionTranscriptionService {
  VisionTranscriptionService(
    this._configProvider, {
    GeminiClient? client,
  }) : _client = client ?? GeminiClient();

  final AppConfig Function() _configProvider;
  final GeminiClient _client;

  AppConfig get _config => _configProvider();

  /// Two independent recognisers agreeing is the strongest evidence available
  /// short of the teacher reading it themselves.
  static const double agreementConfidence = 0.97;

  /// They disagreed. The vision reading is taken — it has the broader training
  /// — but the line stays flagged, because a genuine ambiguity is precisely
  /// what the review screen exists for.
  static const double disagreementConfidence = 0.5;

  static const String _systemPrompt = '''
You transcribe single lines of handwriting cropped from a student's exam paper.

Rules you must follow:
- Transcribe exactly what is written, verbatim. Never correct spelling, grammar, arithmetic or terminology.
- Never complete, summarise, answer or comment on the content. You are transcribing, not marking.
- Preserve mathematical notation, units, symbols and subscripts as written.
- Where the student crossed something out, transcribe only what remains legible and current.
- If a crop is blank or completely illegible, return an empty string for it.
- Return one entry for every crop you are given, using the index printed before each image.
''';

  static const Map<String, Object?> _responseSchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'lines': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'index': <String, Object?>{
              'type': 'integer',
              'description': 'The index printed before the image.',
            },
            'text': <String, Object?>{
              'type': 'string',
              'description': 'The line transcribed verbatim, or "" if illegible.',
            },
          },
          'required': <String>['index', 'text'],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['lines'],
    'additionalProperties': false,
  };

  /// Re-reads every line scoring below the configured threshold.
  Future<CrossCheckOutcome> crossCheck(
    DocumentTranscript transcript, {
    OcrProgress? onProgress,
  }) async {
    final AppConfig config = _config;
    final double threshold = config.ocrConfidenceThreshold;

    if (!config.visionCrossCheck) {
      return CrossCheckOutcome(
        transcript: transcript,
        rechecked: 0,
        changed: 0,
      );
    }
    if (!config.hasApiKey) {
      return CrossCheckOutcome(
        transcript: transcript,
        rechecked: 0,
        changed: 0,
        warnings: const <String>[
          'Low-confidence lines were not cross-checked: no API key is set.',
        ],
      );
    }

    final List<_Candidate> candidates = _collect(transcript, threshold);
    if (candidates.isEmpty) {
      return CrossCheckOutcome(
        transcript: transcript,
        rechecked: 0,
        changed: 0,
      );
    }

    final Map<int, Map<int, TextLine>> replacements =
        <int, Map<int, TextLine>>{};
    final List<String> warnings = <String>[];
    int changed = 0;

    final int batchCount =
        (candidates.length / AppConstants.visionBatchSize).ceil();

    for (int batch = 0; batch < batchCount; batch++) {
      final int start = batch * AppConstants.visionBatchSize;
      final List<_Candidate> slice = candidates.sublist(
        start,
        (start + AppConstants.visionBatchSize).clamp(0, candidates.length),
      );

      onProgress?.call(
        'Double-checking uncertain lines (${batch + 1} of $batchCount)…',
        batchCount == 0 ? 1 : (batch + 1) / batchCount,
      );

      final Map<int, String> readings;
      try {
        readings = await _transcribeBatch(slice, config);
      } on CorrectionException catch (error) {
        // Best-effort by design: keep what TrOCR read and tell the teacher why
        // it was not double-checked.
        warnings.add(
          'Some low-confidence lines could not be double-checked: '
          '${error.message}',
        );
        break;
      }

      for (int offset = 0; offset < slice.length; offset++) {
        final String? reading = readings[offset];
        if (reading == null) continue;

        final _Candidate candidate = slice[offset];
        final TextLine updated = _resolve(candidate.line, reading);
        if (updated.text != candidate.line.text) changed++;

        replacements.putIfAbsent(
          candidate.pageIndex,
          () => <int, TextLine>{},
        )[candidate.lineIndex] = updated;
      }
    }

    return CrossCheckOutcome(
      transcript: transcript.withLines(replacements),
      rechecked: candidates.length,
      changed: changed,
      warnings: warnings,
    );
  }

  /// Decides what a line says once two recognisers have read it.
  TextLine _resolve(TextLine line, String reading) {
    final String vision = reading.trim();

    // An empty reading means the vision model could make nothing of the crop
    // either. Two failures is not a reason to throw away the first attempt.
    if (vision.isEmpty) {
      return line.copyWith(confidence: disagreementConfidence);
    }

    final bool agrees = _normalise(vision) == _normalise(line.ocrText);

    return line.copyWith(
      text: vision,
      source: OcrSource.vision,
      confidence: agrees ? agreementConfidence : disagreementConfidence,
    );
  }

  /// Compares readings on their content, not their spacing or punctuation
  /// style, so a difference of one space is not treated as a disagreement.
  String _normalise(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[\s]+'), ' ')
      .replaceAll(RegExp(r'[^\w\s]'), '')
      .trim();

  List<_Candidate> _collect(DocumentTranscript transcript, double threshold) {
    final List<_Candidate> candidates = <_Candidate>[];

    for (int pageIndex = 0; pageIndex < transcript.pages.length; pageIndex++) {
      final PageTranscript page = transcript.pages[pageIndex];
      for (int lineIndex = 0; lineIndex < page.lines.length; lineIndex++) {
        final TextLine line = page.lines[lineIndex];
        if (!line.isUncertain(threshold)) continue;
        if (line.cropPath.isEmpty) continue;
        candidates.add(
          _Candidate(pageIndex: pageIndex, lineIndex: lineIndex, line: line),
        );
      }
    }

    return candidates;
  }

  /// Sends one batch of crops and returns the readings by position in [slice].
  ///
  /// Batched because the free tier counts requests rather than images: one
  /// request per line would exhaust a day's allowance on a single page.
  Future<Map<int, String>> _transcribeBatch(
    List<_Candidate> slice,
    AppConfig config,
  ) async {
    final List<Object> input = <Object>[
      <String, Object?>{
        'type': 'text',
        'text': 'Transcribe each of the following ${slice.length} cropped '
            'handwriting lines. Return one entry per crop, keyed by the index '
            'printed before it.',
      },
    ];

    for (int index = 0; index < slice.length; index++) {
      final List<int>? bytes = await _readCrop(slice[index].line.cropPath);
      if (bytes == null) continue;

      input.add(<String, Object?>{'type': 'text', 'text': 'Index $index:'});
      input.add(<String, Object?>{
        'type': 'image',
        'mime_type': 'image/png',
        'data': base64Encode(bytes),
      });
    }

    final InteractionOutcome outcome = await _client.sendWithRetries(
      apiKey: config.apiKey!,
      model: config.model,
      systemInstruction: _systemPrompt,
      input: input,
      responseSchema: _responseSchema,
      // Transcription is short; the ceiling only needs to cover one batch.
      maxTokens: 4000,
      // Reading handwriting is perception, not reasoning — thinking budget
      // here buys nothing and costs latency on every batch.
      effort: 'low',
      retryingMessage: 'Retrying the line check…',
    );

    final Object? payload = _client.decode(
      outcome,
      truncationHint: 'The line check exceeded its output limit.',
      refusalMessage: 'The AI declined to transcribe these lines.',
    );

    return _parseReadings(payload, slice.length);
  }

  Map<int, String> _parseReadings(Object? payload, int expected) {
    final Map<int, String> readings = <int, String>{};
    if (payload is! Map<String, dynamic>) return readings;

    final Object? lines = payload['lines'];
    if (lines is! List) return readings;

    for (final Object? entry in lines) {
      if (entry is! Map<String, dynamic>) continue;

      final Object? index = entry['index'];
      final Object? text = entry['text'];
      if (index is! int || text is! String) continue;
      if (index < 0 || index >= expected) continue;

      readings[index] = text;
    }

    return readings;
  }

  Future<List<int>?> _readCrop(String path) async {
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on IOException {
      return null;
    }
  }
}

class _Candidate {
  const _Candidate({
    required this.pageIndex,
    required this.lineIndex,
    required this.line,
  });

  final int pageIndex;
  final int lineIndex;
  final TextLine line;
}
