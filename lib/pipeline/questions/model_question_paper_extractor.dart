import 'dart:io';
import 'dart:typed_data';

import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/domain/exam_document.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/pipeline/questions/question_paper_parser.dart';
import 'package:exam_corrector/pipeline/questions/question_tree.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// Extracts a question paper's structure with a model — from its text, or,
/// for a scanned paper, from its page images.
class ModelQuestionPaperExtractor implements QuestionPaperExtractor {
  ModelQuestionPaperExtractor(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  AppConfig get _config => _configProvider();

  bool get isAvailable => _client.isAvailable;

  @override
  String get fingerprint => 'model-paper:v3:${_config.effectiveVisionModel}';

  static const String systemPrompt = '''
You extract the structure of an exam question paper: its sections, every question and every part of every question, and the marks printed for each. You never answer the questions.

Rules:
- Include every question and every part exactly once, in paper order, parents before their parts. A question with parts ("2" with "2(a)", "2(b)") is listed as well as its parts.
- number: the label as printed, e.g. "1", "2(a)", "3(b)(ii)". Write parts with brackets.
- section_id: the section the question appears under, as printed ("A", "B"), or "" if the paper has no sections.
- text: the question's own wording, without its number or marks.
- max_marks: the marks printed for that question or part, or -1 when none are printed. Never invent a mark allocation.
- stated_total: the paper's printed total, or -1.
- Section stated_marks: the section's printed total, or -1.
- instructions: any instruction printed for the section, e.g. "Answer all questions".

Papers that include their own mark scheme:
- Some papers print their mark scheme with the questions: model answers, marking points, "Accept" / "Do not accept" / "Reject" notes, per-point marks such as "(1)" or M1 A1 B1. It may follow each question, or be gathered in a mark scheme, answers or answer key section.
- Copy each question's scheme verbatim into that question's mark_scheme — never into text. mark_scheme is "" when the paper prints none for it.
- Numbered marking points are not questions: never list "1. Names the mitochondrion (1 mark)" inside a scheme as a question of its own.
- max_marks is the question's allocation, never the mark for a single marking point.
- If the document prints only the scheme for a question and not its wording, text is "".
- marking_guidance: general marking instructions printed with the scheme that apply to every question, verbatim, or "".

Choices:
- A paper may let the student choose: an OR between two parts ("11 (a) … OR (b) …") or between two questions ("11 … OR 12 …"), or an instruction such as "Answer any five questions" or "Answer any two of the following".
- List each in choices. options lists the alternatives; each alternative is the list of question numbers that make it up, all parts of the same question or all top-level questions. choose is how many alternatives the student answers (1 for an OR). instruction is the wording printed, or "".
- An alternative can have parts of its own: in "11 (a)(i) [6] (ii) [6] OR (b)(i) [4] (ii) [8]" the options are [["11(a)"], ["11(b)"]], and question 11 is worth 12.
- An alternative can be several parts: in "11 (a) [6] (b) [6] OR (c) [4] (d) [8]" the options are [["11(a)", "11(b)"], ["11(c)", "11(d)"]].
- "Answer any two of questions 5 to 8" gives options [["5"], ["6"], ["7"], ["8"]] with choose 2.
- max_marks stays each question's or part's own printed allocation. Never add the alternatives together.
- An OR alternative printed without a number or letter of its own is given the next part letter of its question: "11 Explain X [12] OR Explain Y [12]" becomes "11(a)" and "11(b)".
- choices is [] when the paper offers none.
''';

  static final Map<String, Object?> schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'title': <String, Object?>{'type': 'string'},
      'stated_total': <String, Object?>{'type': 'number'},
      'marking_guidance': <String, Object?>{'type': 'string'},
      'choices': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'options': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'array',
                'items': <String, Object?>{'type': 'string'},
              },
            },
            'choose': <String, Object?>{'type': 'number'},
            'instruction': <String, Object?>{'type': 'string'},
          },
          'required': <String>['options', 'choose', 'instruction'],
          'additionalProperties': false,
        },
      },
      'sections': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'section_id': <String, Object?>{'type': 'string'},
            'title': <String, Object?>{'type': 'string'},
            'instructions': <String, Object?>{'type': 'string'},
            'stated_marks': <String, Object?>{'type': 'number'},
          },
          'required': <String>['section_id', 'title', 'instructions', 'stated_marks'],
          'additionalProperties': false,
        },
      },
      'questions': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'number': <String, Object?>{'type': 'string'},
            'section_id': <String, Object?>{'type': 'string'},
            'text': <String, Object?>{'type': 'string'},
            'max_marks': <String, Object?>{'type': 'number'},
            'mark_scheme': <String, Object?>{'type': 'string'},
          },
          'required': <String>[
            'number',
            'section_id',
            'text',
            'max_marks',
            'mark_scheme',
          ],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>[
      'title',
      'stated_total',
      'marking_guidance',
      'choices',
      'sections',
      'questions',
    ],
    'additionalProperties': false,
  };

  @override
  Future<QuestionPaper> extract(
    QuestionPaperSourceData source, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final List<ContentPart> parts = <ContentPart>[];
    QuestionPaperSource kind = QuestionPaperSource.modelText;

    final String? text = source.text;
    if (text != null && text.trim().isNotEmpty) {
      parts.add(TextPart('QUESTION PAPER:\n${text.trim()}'));
    } else {
      kind = QuestionPaperSource.modelVision;
      final List<ExamPage> pages = source.pages
          .where((ExamPage page) => page.hasImage && !page.isBlank)
          .take(_config.maxImagesPerRequest.clamp(1, 20))
          .toList();
      if (pages.isEmpty) {
        throw const PipelineException(
          'The question paper has no readable pages.',
          stage: 'reading the question paper',
        );
      }
      parts.add(TextPart('The question paper, page by page (${pages.length}):'));
      for (final ExamPage page in pages) {
        final String path = page.previewImagePath ?? page.imagePath!;
        final Uint8List bytes = await File(path).readAsBytes();
        parts.add(TextPart('Page ${page.pageNumber}:'));
        parts.add(
          ImagePart(
            bytes,
            mimeType: path.toLowerCase().endsWith('.jpg') ? 'image/jpeg' : 'image/png',
          ),
        );
      }
    }

    onProgress?.call('Reading the question paper\'s structure…', 0.2);
    final ModelResponse response = await _client.requestJson(
      ModelRequest(
        purpose: 'question paper extraction',
        systemInstruction: systemPrompt,
        parts: parts,
        schema: schema,
        maxTokens: 16000,
        effort: 'low',
        truncationHint: 'The question paper was too long to extract in one '
            'request.',
        refusalMessage: 'The AI declined to read this question paper.',
      ),
      models: kind == QuestionPaperSource.modelVision
          ? _config.chainFor(_config.effectiveVisionModel)
          : _config.modelChain,
      cancel: cancel,
    );

    final QuestionPaper paper = fromPayload(
      readMap(response.payload) ?? const <String, Object?>{},
      documentId: source.document.contentHash,
      source: kind,
    );
    if (paper.markable.isEmpty) {
      throw const PipelineException(
        'No questions could be found in the question paper. Check that the '
        'right file was chosen.',
        stage: 'reading the question paper',
      );
    }
    return paper;
  }

  /// Builds the structure from the model's flat list. Pure; tested directly.
  static QuestionPaper fromPayload(
    JsonMap payload, {
    required String documentId,
    QuestionPaperSource source = QuestionPaperSource.modelText,
  }) {
    double? positive(Object? value) {
      final double? number = readDouble(value);
      return number == null || number < 0 ? null : number;
    }

    final List<QuestionSection> sections = <QuestionSection>[
      for (final JsonMap s in readObjects(payload['sections'], (JsonMap m) => m))
        if (readString(s['section_id']) case final String id)
          QuestionSection(
            sectionId: id,
            title: readRawString(s['title']) ?? '',
            instructions: readRawString(s['instructions']) ?? '',
            statedMarks: positive(s['stated_marks']),
          ),
    ];

    final List<FlatQuestion> flat = <FlatQuestion>[];
    final Set<String> seen = <String>{};
    for (final JsonMap q in readObjects(payload['questions'], (JsonMap m) => m)) {
      final QuestionLabel? label =
          QuestionLabel.parse(readString(q['number']) ?? '');
      if (label == null || !seen.add(label.key)) continue;
      flat.add(
        FlatQuestion(
          label: label,
          sectionId: readString(q['section_id']),
          text: readRawString(q['text']) ?? '',
          marks: positive(q['max_marks']),
          markScheme: readRawString(q['mark_scheme']) ?? '',
        ),
      );
    }

    final List<FlatChoice> choices = <FlatChoice>[
      for (final JsonMap c in readObjects(payload['choices'], (JsonMap m) => m))
        FlatChoice(
          options: <List<QuestionLabel>>[
            for (final Object? option in readList(c['options']))
              <QuestionLabel>[
                // A lone label instead of a list is taken as a one-part option.
                for (final String number
                    in option is String ? <String>[option] : readStringList(option))
                  if (QuestionLabel.parse(number) case final QuestionLabel label) label,
              ],
          ],
          choose: readInt(c['choose']) ?? readDouble(c['choose'])?.round() ?? 1,
          instruction: readRawString(c['instruction']) ?? '',
        ),
    ];

    final double? total = positive(payload['stated_total']);
    final ({List<Question> questions, List<String> warnings, List<QuestionChoice> choices})
        tree = const QuestionTreeBuilder()
            .build(flat, sections: sections, statedTotal: total, choices: choices);

    return QuestionPaper(
      documentId: documentId,
      title: readRawString(payload['title']) ?? '',
      sections: sections,
      questions: tree.questions,
      statedTotal: total,
      source: source,
      warnings: tree.warnings,
      choices: tree.choices,
      markingGuidance: (readRawString(payload['marking_guidance']) ?? '').trim(),
    );
  }
}

/// The deterministic parser first; a model only when the parser's result
/// cannot be trusted or there is no text to parse.
class CompositeQuestionPaperExtractor implements QuestionPaperExtractor {
  const CompositeQuestionPaperExtractor({
    required this.parser,
    required this.model,
  });

  final HeuristicQuestionPaperParser parser;
  final ModelQuestionPaperExtractor? model;

  @override
  String get fingerprint =>
      'composite:${parser.fingerprint}:${model?.fingerprint ?? '-'}';

  @override
  Future<QuestionPaper> extract(
    QuestionPaperSourceData source, {
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final ModelQuestionPaperExtractor? model = this.model;
    final bool modelReady = model != null && model.isAvailable;
    final String? text = source.text;

    if (text != null && text.trim().isNotEmpty) {
      onProgress?.call('Reading the question paper…', 0);
      final QuestionPaper parsed = parser.parse(
        text,
        documentId: source.document.contentHash,
      );
      if (HeuristicQuestionPaperParser.isTrustworthy(parsed) || !modelReady) {
        if (parsed.markable.isEmpty) {
          throw const PipelineException(
            'No questions could be found in the question paper. Check that the '
            'right file was chosen, or add an API key so the paper can be read '
            'by the model.',
            stage: 'reading the question paper',
          );
        }
        return parsed;
      }
      try {
        return await model.extract(source, onProgress: onProgress, cancel: cancel);
      } on CorrectionException catch (error) {
        // The parser's result, with its gaps, beats no structure at all.
        if (parsed.markable.isEmpty) rethrow;
        return QuestionPaper(
          documentId: parsed.documentId,
          title: parsed.title,
          sections: parsed.sections,
          questions: parsed.questions,
          statedTotal: parsed.statedTotal,
          source: parsed.source,
          markingGuidance: parsed.markingGuidance,
          choices: parsed.choices,
          warnings: <String>[
            ...parsed.warnings,
            'The question paper could not be checked by the model '
                '(${error.message}).',
          ],
        );
      }
    }

    if (!modelReady) {
      throw const PipelineException(
        'The question paper is a scan with no text layer. Reading its '
        'questions and marks needs the vision model — add an API key in '
        'Settings — or supply the paper as a PDF with a text layer.',
        stage: 'reading the question paper',
      );
    }
    return model.extract(source, onProgress: onProgress, cancel: cancel);
  }
}
