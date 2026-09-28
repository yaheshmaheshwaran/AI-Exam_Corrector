import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/errors/app_exception.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/marking/answer_key.dart';
import 'package:exam_corrector/pipeline/marking/marking_rules.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key.dart';
import 'package:exam_corrector/pipeline/marking/teacher_key_parser.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// Matches a teacher's answer key to a paper's questions.
abstract class TeacherKeyReader {
  /// Changes whenever the matching it would do changes.
  String get fingerprint;

  Future<TeacherKey> read(
    TeacherKeySource source,
    QuestionPaper paper, {
    MarkingStandard standard = const MarkingStandard(),
    CancellationToken? cancel,
  });
}

/// Reads the key itself first — free and instant for the way most keys are
/// written — and asks the model only when too little of it matched and a
/// model is ready. With no model, what the reading matched is kept, and the
/// teacher told how much.
class CompositeTeacherKeyReader implements TeacherKeyReader {
  const CompositeTeacherKeyReader({this.model});

  final ModelTeacherKeyReader? model;

  @override
  String get fingerprint => 'teacher-key:v1:${model?.fingerprint ?? 'parser'}';

  @override
  Future<TeacherKey> read(
    TeacherKeySource source,
    QuestionPaper paper, {
    MarkingStandard standard = const MarkingStandard(),
    CancellationToken? cancel,
  }) async {
    final TeacherKeyParse parsed = TeacherKeyParser(standard: standard).parse(source.text, paper);
    TeacherKey fromParse({String? why}) => source.unmatched.copyWith(
          matched: true,
          entries: parsed.entries,
          unmatched: parsed.unmatched,
          warnings: <String>[
            ...parsed.warnings,
            if (!parsed.trustworthy && parsed.labelsSeen > 0)
              'Only ${parsed.entries.length} of the ${parsed.labelsSeen} answers in your key could be '
                  'matched to the paper\'s questions${why == null ? '' : ' ($why)'}. Check them in Review…',
            if (parsed.labelsSeen == 0)
              'No numbered answers were found in your key. Number each answer as the paper numbers '
                  'its questions — "1.", "2(a)", "Part B 11" — and choose it again.',
          ],
        );

    final ModelTeacherKeyReader? model = this.model;
    if (parsed.trustworthy || model == null || !model.isAvailable) return fromParse();
    try {
      return await model.align(source, paper, standard: standard, cancel: cancel);
    } on CorrectionException catch (error) {
      return fromParse(why: 'the AI could not help: ${error.message}');
    }
  }
}

/// Asks the model to match a key that does not follow a pattern — answers
/// written as paragraphs, a table with its own headings — to the questions.
/// It copies what the teacher wrote; it never writes an answer of its own.
class ModelTeacherKeyReader {
  ModelTeacherKeyReader(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  static const String version = 'teacher-key-align:v1';

  bool get isAvailable => _client.isAvailable;

  String get fingerprint => '$version:${_configProvider().modelChain.join(',')}';

  static const String systemPrompt = '''
You are matching a teacher's own answer key to the questions of an exam paper, so that each question can be marked against what the teacher wrote.

For each answer in the key, find the question it answers and copy the teacher's content:
- answer: the teacher's answer for that question, as written.
- points: when the key lists points with marks ("names the organelle (1)"), each point and its marks. Otherwise an empty list.
- alternatives: answers the key says to also accept.
- correct_option: for a multiple-choice question, the letter the key gives (a–e), lower case; otherwise "".
- key_marks: the marks the key gives the whole question, or -1 when it gives none.
- notes: anything else the teacher wrote about marking it.

Rules:
- Copy; never write, improve or complete an answer yourself. If the key does not answer a question, leave that question out.
- Match by the question labels the key uses ("1.", "Q2(a)", "Part B 11"), and by content when labels are missing. Use the question IDs given, exactly.
- An answer for a question with parts that the key splits by part goes to each part.
- List in unmatched every label the key answers that is not a question on this paper.''';

  static final Map<String, Object?> schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'entries': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'question_id': <String, Object?>{'type': 'string'},
            'answer': <String, Object?>{'type': 'string'},
            'points': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'criterion': <String, Object?>{'type': 'string'},
                  'marks': <String, Object?>{'type': 'number'},
                },
                'required': <String>['criterion', 'marks'],
                'additionalProperties': false,
              },
            },
            'alternatives': <String, Object?>{'type': 'array', 'items': <String, Object?>{'type': 'string'}},
            'correct_option': <String, Object?>{'type': 'string'},
            'key_marks': <String, Object?>{'type': 'number'},
            'notes': <String, Object?>{'type': 'string'},
          },
          'required': <String>['question_id', 'answer', 'points', 'alternatives', 'correct_option', 'key_marks', 'notes'],
          'additionalProperties': false,
        },
      },
      'unmatched': <String, Object?>{'type': 'array', 'items': <String, Object?>{'type': 'string'}},
    },
    'required': <String>['entries', 'unmatched'],
    'additionalProperties': false,
  };

  static String buildRequest(TeacherKeySource source, QuestionPaper paper, MarkingStandard standard) {
    final StringBuffer out = StringBuffer()..writeln('THE PAPER\'S QUESTIONS:');
    for (final Question q in paper.markable) {
      out.writeln('- ${q.questionId} (printed as ${q.displayNumber}'
          '${q.sectionId == null ? '' : ', Part ${q.sectionId}'}'
          '${q.maximumMarks == null ? '' : ', ${formatMarks(q.maximumMarks!)} marks'}'
          '${MarkingRules.isMcqQuestion(q, standard) ? ', multiple choice' : ''}): '
          '${_clip(q.questionText.replaceAll('\n', ' '), 220)}');
    }
    out
      ..writeln()
      ..writeln('THE TEACHER\'S ANSWER KEY (${source.fileName}):')
      ..writeln(source.text.trim());
    return out.toString();
  }

  Future<TeacherKey> align(
    TeacherKeySource source,
    QuestionPaper paper, {
    MarkingStandard standard = const MarkingStandard(),
    CancellationToken? cancel,
  }) async {
    final AppConfig config = _configProvider();
    final ModelResponse response = await _client.requestJson(
      ModelRequest(
        purpose: 'answer key matching',
        systemInstruction: systemPrompt,
        parts: <ContentPart>[TextPart(buildRequest(source, paper, standard))],
        schema: schema,
        maxTokens: config.maxTokens,
        effort: 'low',
        truncationHint: 'Your answer key was too long to match in one go. Split it, or raise '
            'EXAM_CORRECTOR_MAX_TOKENS.',
        refusalMessage: 'The AI declined to match your answer key.',
      ),
      models: config.modelChain,
      cancel: cancel,
    );
    return parse(readMap(response.payload), source, paper);
  }

  /// The model's matching, checked against the paper: unknown IDs go to
  /// unmatched, options must be a–e, and marks that disagree with the paper
  /// are reported.
  static TeacherKey parse(JsonMap? payload, TeacherKeySource source, QuestionPaper paper) {
    final Map<String, TeacherKeyEntry> entries = <String, TeacherKeyEntry>{};
    final List<String> unmatched = readStringList(payload?['unmatched']);
    final List<String> warnings = <String>[];
    for (final JsonMap raw in readObjects(payload?['entries'], (JsonMap m) => m)) {
      final String id = readString(raw['question_id']) ?? '';
      final Question? question = paper.byId(id);
      if (question == null || !question.isLeaf) {
        if (id.isNotEmpty) unmatched.add(id);
        continue;
      }
      final String option = (readString(raw['correct_option']) ?? '').toLowerCase();
      final double keyMarks = readDouble(raw['key_marks']) ?? -1;
      final TeacherKeyEntry entry = TeacherKeyEntry(
        questionId: question.questionId,
        answer: readRawString(raw['answer'])?.trim() ?? '',
        points: <AnswerKeyPoint>[
          for (final JsonMap p in readObjects(raw['points'], (JsonMap m) => m))
            if (readString(p['criterion']) case final String criterion)
              AnswerKeyPoint(criterion: criterion, marks: (readDouble(p['marks']) ?? 0).clamp(0, 1000).toDouble()),
        ],
        alternatives: readStringList(raw['alternatives']),
        option: RegExp(r'^[a-e]$').hasMatch(option) ? option : null,
        keyMarks: keyMarks >= 0 ? keyMarks : null,
        notes: readRawString(raw['notes'])?.trim() ?? '',
      );
      if (entry.isEmpty) continue;
      entries[question.questionId] = entry;
      final double? maximum = question.maximumMarks;
      if (maximum != null && entry.keyMarks != null && (entry.keyMarks! - maximum).abs() > 0.001) {
        warnings.add('Your key gives ${formatMarks(entry.keyMarks!)} marks for question ${question.displayNumber}; the '
            'paper says ${formatMarks(maximum)}, so the paper\'s marks are used.');
      }
    }
    return source.unmatched.copyWith(matched: true, entries: entries, unmatched: unmatched, warnings: warnings);
  }

  static String _clip(String text, int max) => text.length <= max ? text : '${text.substring(0, max)}…';
}
