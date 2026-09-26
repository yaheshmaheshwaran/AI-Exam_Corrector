import 'package:exam_corrector/core/async/cancellation.dart';
import 'package:exam_corrector/core/config/app_config.dart';
import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/json_read.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/question_label.dart';
import 'package:exam_corrector/domain/question_paper.dart';
import 'package:exam_corrector/pipeline/engines.dart';
import 'package:exam_corrector/services/ai/model_client.dart';

/// One point of a question's answer key.
class AnswerKeyPoint {
  const AnswerKeyPoint({required this.criterion, required this.marks, this.fullCredit = ''});

  /// A fact, concept, step or feature a teacher can tick.
  final String criterion;
  final double marks;

  /// What earns the point's full marks: the depth, the detail, the example.
  final String fullCredit;

  JsonMap toJson() => <String, Object?>{
        'criterion': criterion,
        'marks': marks,
        if (fullCredit.isNotEmpty) 'fullCredit': fullCredit,
      };

  static AnswerKeyPoint? fromJson(JsonMap json) {
    final String? criterion = readString(json['criterion']);
    final double? marks = readDouble(json['marks']);
    if (criterion == null || marks == null) return null;
    return AnswerKeyPoint(criterion: criterion, marks: marks, fullCredit: readRawString(json['fullCredit']) ?? '');
  }
}

/// A question's answer key, fixed before any script is read — the way a
/// chief examiner settles the scheme before marking starts, so that every
/// script is marked against the same points and none is shaped around the
/// answer in front of the marker.
class AnswerKeyEntry {
  const AnswerKeyEntry({
    required this.questionId,
    required this.maximum,
    this.points = const <AnswerKeyPoint>[],
    this.expectedWords,
    this.diagramExpected = false,
    this.exampleExpected = false,
    this.notes = '',
  });

  final String questionId;
  final double maximum;
  final List<AnswerKeyPoint> points;

  /// About how long a full-marks handwritten answer is.
  final int? expectedWords;
  final bool diagramExpected;
  final bool exampleExpected;
  final String notes;

  /// As the marker and the teacher read it.
  String get text {
    final StringBuffer out = StringBuffer();
    for (final AnswerKeyPoint point in points) {
      out.writeln('- ${point.criterion} [${formatMarks(point.marks)}]'
          '${point.fullCredit.isEmpty ? '' : ' — full credit: ${point.fullCredit}'}');
    }
    final List<String> expects = <String>[
      if (expectedWords != null) 'about $expectedWords words',
      if (diagramExpected) 'a labelled diagram',
      if (exampleExpected) 'an example',
    ];
    if (expects.isNotEmpty) out.writeln('A full answer: ${expects.join(', ')}.');
    if (notes.trim().isNotEmpty) out.writeln('Note: ${notes.trim()}');
    return out.toString().trim();
  }

  JsonMap toJson() => <String, Object?>{
        'questionId': questionId,
        'maximum': maximum,
        'points': <JsonMap>[for (final AnswerKeyPoint p in points) p.toJson()],
        'expectedWords': ?expectedWords,
        if (diagramExpected) 'diagramExpected': true,
        if (exampleExpected) 'exampleExpected': true,
        if (notes.isNotEmpty) 'notes': notes,
      };

  static AnswerKeyEntry? fromJson(JsonMap json) {
    final String? id = readString(json['questionId']);
    if (id == null) return null;
    return AnswerKeyEntry(
      questionId: id,
      maximum: readDouble(json['maximum']) ?? 0,
      points: readObjects(json['points'], AnswerKeyPoint.fromJson),
      expectedWords: readInt(json['expectedWords']),
      diagramExpected: readBool(json['diagramExpected']) ?? false,
      exampleExpected: readBool(json['exampleExpected']) ?? false,
      notes: readRawString(json['notes']) ?? '',
    );
  }
}

/// A paper's answer key: the AI's, with the teacher's corrections over it.
class AnswerKey {
  const AnswerKey({
    this.entries = const <String, AnswerKeyEntry>{},
    this.edits = const <String, String>{},
  });

  static const AnswerKey empty = AnswerKey();

  final Map<String, AnswerKeyEntry> entries;

  /// The teacher's own key for a question, in place of the AI's.
  final Map<String, String> edits;

  bool get isEmpty => entries.isEmpty && edits.isEmpty;

  String textFor(String questionId) {
    final String? edited = edits[questionId];
    if (edited != null && edited.trim().isNotEmpty) return edited.trim();
    return entries[questionId]?.text ?? '';
  }

  /// The teacher's key may state a length: "about 300 words".
  int? expectedWordsFor(String questionId) {
    final String? edited = edits[questionId];
    if (edited != null && edited.trim().isNotEmpty) {
      final RegExpMatch? stated = RegExp(r'(\d{2,4})\s*words', caseSensitive: false).firstMatch(edited);
      return stated == null ? null : int.parse(stated.group(1)!);
    }
    return entries[questionId]?.expectedWords;
  }

  JsonMap toJson() => <String, Object?>{
        'entries': <JsonMap>[for (final AnswerKeyEntry e in entries.values) e.toJson()],
      };

  static Map<String, AnswerKeyEntry> entriesFromJson(JsonMap? json) => <String, AnswerKeyEntry>{
        for (final AnswerKeyEntry e in readObjects(json?['entries'], AnswerKeyEntry.fromJson)) e.questionId: e,
      };
}

/// What the key is prepared from, for one question.
class AnswerKeyTask {
  const AnswerKeyTask({
    required this.question,
    this.section,
    this.syllabus = '',
    this.choice = '',
  });

  final Question question;
  final QuestionSection? section;
  final String syllabus;
  final String choice;
}

/// Prepares answer keys.
abstract class AnswerKeyEngine {
  /// Changes whenever the keys it would write change.
  String get fingerprint;

  Future<Map<String, AnswerKeyEntry>> prepare(
    List<AnswerKeyTask> tasks, {
    required String guidance,
    required String course,
    required MarkingStandard standard,
    StageProgress? onProgress,
    CancellationToken? cancel,
  });
}

/// [AnswerKeyEngine] that asks the model, from the questions alone.
class ModelAnswerKeyEngine implements AnswerKeyEngine {
  ModelAnswerKeyEngine(this._client, this._configProvider);

  final ModelClient _client;
  final AppConfig Function() _configProvider;

  static const String version = 'answer-key:v1';

  /// Questions per request: keys are short, but a whole paper in one
  /// response risks the output limit.
  static const int perRequest = 12;

  @override
  String get fingerprint => '$version:${_configProvider().modelChain.join(',')}';

  static const String systemPrompt = '''
You are the chief examiner preparing the answer key for a question paper, before any student's script is marked. You will not see any answers.

For each question, write the key a fair but demanding teacher marks against:
- points: the marking points a complete answer at this course's level must contain. Each is a specific fact, concept, step, feature or diagram element a teacher can tick — never "good explanation" or "clear presentation". Their marks must add up exactly to the question's maximum. Use about one point per 1–3 marks.
- For each point, full_credit: what earns the point's full marks — the depth, the explanation, the example or the working. A point that is only named earns a small part of its marks.
- expected_words: about how many words a full-marks handwritten answer needs. For descriptive answers roughly 20–30 words per mark; fewer for definitions, numericals, derivations and diagram-led answers.
- diagram_expected / example_expected: whether a full answer needs them.
- notes: anything the marker must know — alternatives to accept, common errors that earn nothing. Keep it short.

When the question lists what the answer must contain ("label the nucleus, the membrane…", "any three advantages"), each listed item is its own point. When a syllabus reference is given, pitch the depth to it: it shows what the course teaches, not the answers. When the teacher's guidance covers a question, follow it.''';

  static final Map<String, Object?> schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'keys': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'question_id': <String, Object?>{'type': 'string'},
            'points': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'description': <String, Object?>{'type': 'string'},
                  'marks': <String, Object?>{'type': 'number'},
                  'full_credit': <String, Object?>{'type': 'string'},
                },
                'required': <String>['description', 'marks', 'full_credit'],
                'additionalProperties': false,
              },
            },
            'expected_words': <String, Object?>{'type': 'integer'},
            'diagram_expected': <String, Object?>{'type': 'boolean'},
            'example_expected': <String, Object?>{'type': 'boolean'},
            'notes': <String, Object?>{'type': 'string'},
          },
          'required': <String>[
            'question_id',
            'points',
            'expected_words',
            'diagram_expected',
            'example_expected',
            'notes',
          ],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['keys'],
    'additionalProperties': false,
  };

  static String buildRequest(
    List<AnswerKeyTask> tasks, {
    required String guidance,
    required String course,
    required MarkingStandard standard,
  }) {
    final StringBuffer out = StringBuffer();
    if (course.trim().isNotEmpty) {
      out
        ..writeln('COURSE: ${course.trim()}')
        ..writeln();
    }
    out.writeln('MARKING STANDARD: ${standard.level.label} — ${standard.level.description}');
    if (standard.collegeRules.trim().isNotEmpty) {
      out.writeln('COLLEGE RULES: ${standard.collegeRules.trim()}');
    }
    if (guidance.trim().isNotEmpty) {
      out
        ..writeln("TEACHER'S MARKING GUIDANCE:")
        ..writeln(guidance.trim());
    }
    out.writeln();
    for (final AnswerKeyTask task in tasks) {
      final Question q = task.question;
      out.writeln('=== QUESTION ${q.questionId} (printed as ${q.displayNumber})'
          '${task.section == null ? '' : ' — Section ${task.section!.sectionId}'} ===');
      out.writeln('Question: ${q.questionText.trim().isEmpty ? '(wording not printed)' : q.questionText.trim()}');
      out.writeln('Maximum marks: ${formatMarks(q.maximumMarks ?? 0)}');
      if (task.choice.isNotEmpty) out.writeln('One alternative of a choice: ${task.choice}.');
      if (task.syllabus.trim().isNotEmpty) {
        out.writeln('Syllabus reference (not an answer key): ${task.syllabus.trim()}');
      }
      out.writeln();
    }
    out.writeln('TASK: Write the answer key for every question above. Set question_id '
        'exactly as it appears after "QUESTION".');
    return out.toString();
  }

  @override
  Future<Map<String, AnswerKeyEntry>> prepare(
    List<AnswerKeyTask> tasks, {
    required String guidance,
    required String course,
    required MarkingStandard standard,
    StageProgress? onProgress,
    CancellationToken? cancel,
  }) async {
    final AppConfig config = _configProvider();
    final Map<String, AnswerKeyEntry> keys = <String, AnswerKeyEntry>{};
    for (int start = 0; start < tasks.length; start += perRequest) {
      cancel?.throwIfCancelled();
      final List<AnswerKeyTask> chunk = tasks.sublist(start, (start + perRequest).clamp(0, tasks.length));
      onProgress?.call('Preparing the answer key…', start / tasks.length);
      final ModelResponse response = await _client.requestJson(
        ModelRequest(
          purpose: 'answer key',
          systemInstruction: systemPrompt,
          parts: <ContentPart>[
            TextPart(buildRequest(chunk, guidance: guidance, course: course, standard: standard)),
          ],
          schema: schema,
          maxTokens: config.maxTokens,
          effort: config.effort,
          truncationHint: 'The answer key was cut short because it exceeded the output limit. '
              'Raise EXAM_CORRECTOR_MAX_TOKENS.',
          refusalMessage: 'The AI declined to prepare an answer key for this paper.',
        ),
        models: config.modelChain,
        cancel: cancel,
      );
      keys.addAll(parse(readMap(response.payload), chunk));
    }
    return keys;
  }

  /// The keys in [payload], each checked against its question: marks that
  /// do not add up to the maximum are scaled so they do.
  static Map<String, AnswerKeyEntry> parse(JsonMap? payload, List<AnswerKeyTask> tasks) {
    final Map<String, AnswerKeyEntry> keys = <String, AnswerKeyEntry>{};
    for (final JsonMap item in readObjects(payload?['keys'], (JsonMap m) => m)) {
      final AnswerKeyTask? task = _match(readString(item['question_id']) ?? '', tasks);
      final double? maximum = task?.question.maximumMarks;
      if (task == null || maximum == null || maximum <= 0) continue;
      final List<AnswerKeyPoint> raw = <AnswerKeyPoint>[
        for (final JsonMap p in readObjects(item['points'], (JsonMap m) => m))
          if (readString(p['description']) case final String criterion)
            AnswerKeyPoint(
              criterion: criterion,
              marks: (readDouble(p['marks']) ?? 0).clamp(0, maximum).toDouble(),
              fullCredit: readRawString(p['full_credit'])?.trim() ?? '',
            ),
      ];
      final double sum = raw.fold<double>(0, (double s, AnswerKeyPoint p) => s + p.marks);
      if (raw.isEmpty || sum <= 0) continue;
      final List<AnswerKeyPoint> points = (sum - maximum).abs() < 1e-6
          ? raw
          : <AnswerKeyPoint>[
              for (final AnswerKeyPoint p in raw)
                AnswerKeyPoint(
                  criterion: p.criterion,
                  marks: ((p.marks / sum * maximum) * 4).roundToDouble() / 4,
                  fullCredit: p.fullCredit,
                ),
            ];
      final int? words = readInt(item['expected_words']);
      keys[task.question.questionId] = AnswerKeyEntry(
        questionId: task.question.questionId,
        maximum: maximum,
        points: points,
        expectedWords: words == null || words <= 0 ? null : words,
        diagramExpected: readBool(item['diagram_expected']) ?? false,
        exampleExpected: readBool(item['example_expected']) ?? false,
        notes: readRawString(item['notes'])?.trim() ?? '',
      );
    }
    return keys;
  }

  static AnswerKeyTask? _match(String written, List<AnswerKeyTask> tasks) {
    final String compact = written.toUpperCase().replaceAll(RegExp(r'\s'), '');
    for (final AnswerKeyTask t in tasks) {
      if (t.question.questionId.toUpperCase() == compact) return t;
    }
    final QuestionLabel? label = QuestionLabel.parse(written);
    if (label == null) return null;
    for (final AnswerKeyTask t in tasks) {
      if (t.question.label == label) return t;
    }
    return null;
  }
}
