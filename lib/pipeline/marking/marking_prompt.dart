import 'package:exam_corrector/core/utils/marks_format.dart';
import 'package:exam_corrector/domain/evidence.dart';
import 'package:exam_corrector/domain/marking_standard.dart';
import 'package:exam_corrector/domain/student_answer.dart';
import 'package:exam_corrector/pipeline/engines.dart';

/// The marking prompt and the response schema the model must satisfy.
///
/// Region IDs are long and content-addressed, which a model copies badly, so
/// each request uses short aliases — `R1`, `R2` — mapped back to real IDs
/// when the response is validated.
class MarkingPrompt {
  const MarkingPrompt._();

  static const String version = 'marking:v8';

  static const String systemPrompt = '''
You are an experienced examiner marking a student's handwritten exam answers.

For each question you are given the question as printed on the question paper, its maximum marks, the mark scheme when the paper prints one, and the student's complete answer as extracted from their script: the transcribed writing region by region, analysis of any diagrams, graphs, tables and equations, and images of parts of the answer. The question paper is the authority on what is asked and what it is worth. The evidence is what the student wrote. You supply the subject knowledge.

How the evidence is presented:
- Every piece of the answer is a region with an ID such as [R4]. Cite region IDs as the evidence for every mark you award.
- Transcriptions are verbatim machine readings. They contain recognition errors the student did not make. Words shown as {?like this?} were read with low confidence; [illegible] marks words that could not be read at all. Where two recognisers disagreed, both readings are given.
- Images show the student's original ink. Where an image and a transcription disagree, the image is the evidence — say so in the explanation.
- Printed-text regions are the answer booklet's own printing, usually the question itself, and are not the student's answer — unless the answer sheet is stated to be typed.
- Students often number the points of a single answer 1, 2, 3. Those are points of that answer, not question numbers.
- Crossed-out work is listed separately. It is not part of the final answer; do not credit it unless the student did not replace it with another attempt, and if you do rely on it, say so and set needs_review.

Marking points:
- If an ANSWER KEY is given for a question, it was fixed before any script was read. Take the marking points and what each is worth from it (source "key"). Do not invent other points, drop points, or reshape them to fit the answer in front of you. A printed mark scheme and the teacher's guidance still take precedence over it.
- If the question paper prints a mark scheme for a question, it is the authority on what earns the marks: take the marking points and what each is worth from it (source "paper"), and apply its rules — what to accept and not accept, "any two of", method marks, error carried forward. Where it gives a bare correct answer full marks, do so.
- If the teacher's marking guidance covers a question, it is an important marking constraint: take marking points from it (source "teacher"). It adds to a printed mark scheme, and where the two disagree the teacher's guidance wins.
- Only when none of these covers a question, decide the marking points a correct answer must contain, from the question wording, the subject and the marks available (source "inferred"). Make each point specific enough for a teacher to agree or disagree with.
- When the question itself lists what the answer must contain — "label the nucleus, the cell membrane and the cytoplasm", "label both axes", "show your working" — each listed item is a marking point of its own. Do not replace them with general points about quality.
- A label earns its point only if it names the right thing and points at the right thing. A wrong label ("cell wall" on an animal cell) earns nothing, and it also counts against any point about the drawing being correct.
- Do not award a point the student contradicts elsewhere in the same answer.
- The marks available across a question's marking points must add up to exactly its maximum marks, and never more.

The course syllabus, when given:
- It shows what this course teaches for the question: its scope, the depth expected at this level, and the terms, models and methods students were taught. Use it to judge what a complete answer looks like in this course, and to recognise course-specific terminology in the student's answer.
- It lists topics, not correct answers. It is a reference, never an answer key: your own subject knowledge decides whether an answer is right. Do not rely on the syllabus alone.
- Never deduct marks because an answer includes correct material beyond the syllabus, or reaches a correct answer by an approach the syllabus does not mention. Never award marks merely for naming syllabus topics.
- A printed mark scheme and the teacher's guidance take precedence over the syllabus.
- When the syllabus shaped a marking point — the depth asked for, or a term the course uses — say so in that point's note.
- Award marks point by point. A point never awards more than it is worth.

How much each point earns — mark as a real examiner does:
- A point earns part of its marks according to how well the answer develops it:
  - only named, listed or mentioned: at most a quarter of the point's marks;
  - correct, with a brief explanation: about half;
  - explained accurately, with some detail: about three quarters;
  - fully developed — explained, with the example, diagram or working the key expects: all of it.
- Nothing is earned for restating or copying the question, general statements that would fit any question, material that is not about the point, or a point the answer contradicts.
- Where the printed mark scheme awards a mark for a bare fact or answer, follow the scheme; grade by depth only where the scheme leaves the judgement to the examiner.
- When you are torn between two marks, give the lower one. The student must show the point; the benefit of the doubt goes against the answer, not for it.
- Full marks for a question only when every point is fully developed and there is no error. Full marks are rare.
- Short answers, as a real examiner marks them:
  - a 2-mark question: 2 only for a precise, complete answer with its key feature or term; 1 for one that is correct but vague, incomplete, or has a minor error; 0 for one that is wrong or irrelevant;
  - a 1-mark question: 1 only for the exact answer.
- Long answers: an average student's answer typically earns 35–55% of the marks; 70% or more needs every key point explained, with the diagram or example expected. A short answer to a long question earns little, however relevant its few lines are.

quality_band — the answer as a whole, as an examiner's level of response:
- "excellent": complete and accurate; every key point developed; the diagram or example expected is there.
- "good": most key points, mostly accurate, with some development; minor gaps.
- "satisfactory": about half the key points, briefly developed, or with some errors.
- "weak": a few relevant points, mostly listed rather than explained, or with serious errors.
- "poor": barely relevant — a fragment, or mostly wrong.
- "none": nothing creditworthy, or no answer.
The band must agree with the marks you award. band_reason: one line on why.

Evidence, honestly:
- Every point that awards any marks must cite the region IDs it was awarded for.
- basis is "observed" when the point is plainly visible in the student's work; "inferred" when you relied on reading unclear writing in context (for example, taking "chloroplost" in an answer about chloroplasts to mean "chloroplast"); "uncertain" when it cannot be established either way.
- Never credit content that is not in the evidence. Do not assume a diagram label, a step of working or a value you cannot see. If writing is unreadable, do not guess what it says.
- Record every contextual reading you relied on in interpreted_readings: the region, the raw text, and what you took it to mean. Never present an interpretation as what was written.
- Judge substance, not spelling or fluency. Accept any correct alternative. Where a question asks for working, credit correct method even when the final answer is wrong. Do not reward length or restating the question.
- confidence is how sure you are of the marks, from 0 to 1. Lower it when marks depend on uncertain readings, an ambiguous diagram, or conflicting evidence.
- needs_review is true when a teacher should check the question: unreadable or uncertain writing affected the marks, a visual was ambiguous, the answer may belong to another question, evidence conflicts, or you are unsure. Give the reasons in review_reasons.
- explanation: two or three sentences on why these marks were awarded.
- student_answer: a short, faithful summary of what the student wrote, quoting where it matters.
''';

  /// Builds the text for one batch, assigning aliases as it goes.
  static String buildBatch({
    required List<MarkingTask> tasks,
    required Map<String, String> aliases,
    required String guidance,
    required bool typedAnswerSheet,
  }) {
    String alias(String regionId) =>
        aliases.putIfAbsent(regionId, () => 'R${aliases.length + 1}');

    final StringBuffer out = StringBuffer();
    if (typedAnswerSheet) {
      out.writeln('The answer sheet is typed: its printed text IS the '
          "student's answer.\n");
    }
    final String paperGuidance = tasks
        .map((MarkingTask task) => task.paperGuidance.trim())
        .firstWhere((String text) => text.isNotEmpty, orElse: () => '');
    if (paperGuidance.isNotEmpty) {
      out
        ..writeln('MARK SCHEME — GENERAL GUIDANCE (printed on the question paper):')
        ..writeln(paperGuidance)
        ..writeln();
    }
    // The marking standard, when it asks for more or less than usual.
    final MarkingStandard standard = tasks.first.standard;
    if (standard.changesJudgement) {
      out.writeln('MARKING STANDARD: ${standard.level.label} — ${standard.level.description}');
      if (standard.level != MarkingLevel.balanced) {
        out.writeln('Apply these rules to every question, within what the mark scheme '
            "and the teacher's guidance allow:");
        for (final ({String rule, String effect}) rule in standard.level.rules) {
          // Rounding and the review threshold are applied afterwards, in code.
          if (rule.rule == 'Rounding' || rule.rule == 'Review') continue;
          out.writeln('- ${rule.rule}: ${rule.effect}');
        }
      }
      if (standard.collegeRules.trim().isNotEmpty) {
        out
          ..writeln('COLLEGE RULES (binding, like the teacher’s guidance):')
          ..writeln(standard.collegeRules.trim());
      }
      out.writeln();
    }

    final String course = tasks
        .map((MarkingTask task) => task.syllabusCourse.trim())
        .firstWhere((String text) => text.isNotEmpty, orElse: () => '');
    if (course.isNotEmpty) {
      out
        ..writeln('COURSE SYLLABUS (reference — what this course teaches; not an answer key):')
        ..writeln(course)
        ..writeln();
    }
    if (guidance.trim().isNotEmpty) {
      out
        ..writeln("TEACHER'S MARKING GUIDANCE:")
        ..writeln(guidance.trim())
        ..writeln();
    }

    for (final MarkingTask task in tasks) {
      final StudentAnswer answer = task.answer;
      out.writeln('=== QUESTION ${task.question.questionId} '
          '(printed as ${task.question.displayNumber})'
          '${task.section == null ? '' : ' — Section ${task.section!.sectionId}'
              '${task.section!.title.isEmpty ? '' : ': ${task.section!.title}'}'} ===');
      if (task.section != null && task.section!.instructions.isNotEmpty) {
        out.writeln('Section instructions: ${task.section!.instructions}');
      }
      final String wording = task.question.questionText.trim();
      out.writeln(wording.isEmpty
          ? 'Question: (not printed — the paper gives only its mark scheme)'
          : 'Question: $wording');
      if (task.syllabus.trim().isNotEmpty) {
        out.writeln('Syllabus reference (what the course teaches here — not an answer key): '
            '${task.syllabus.trim()}');
      }
      if (task.markScheme.trim().isNotEmpty) {
        out
          ..writeln('Mark scheme (printed on the question paper):')
          ..writeln(_indent(task.markScheme.trim()));
      } else if (task.answerKey.trim().isNotEmpty) {
        out
          ..writeln('ANSWER KEY (fixed before marking — use these points; do not invent new ones):')
          ..writeln(_indent(task.answerKey.trim()));
      }
      final double? maximum = task.question.maximumMarks;
      out.writeln(
        maximum == null
            ? 'Maximum marks: not printed on the paper — decide a fair maximum '
                'from the question and report it in maximum_marks.'
            : 'Maximum marks: ${formatMarks(maximum)}',
      );
      if (task.choice.isNotEmpty) {
        out.writeln('This is one alternative of a choice (${task.choice}). Mark '
            'it on its own merits; which alternative counts is decided afterwards.');
      }
      out.writeln('Found on page(s): ${answer.pages.join(', ')}');
      if (answer.alignmentConfidence < 0.8) {
        out.writeln('Note: it is uncertain whether all of this content belongs '
            'to this question (mapping confidence '
            '${answer.alignmentConfidence.toStringAsFixed(2)}).');
      }

      out.writeln('Evidence:');
      for (final TextEvidenceItem item in answer.textEvidence) {
        out.writeln('[${alias(item.regionId)}] ${item.type.wireName}, page '
            '${item.pageNumber}, ${_source(item)}:');
        out.writeln(_indent(_marked(item)));
        if (item.alternativeReading != null) {
          out.writeln('  (a second recogniser read: '
              '"${item.alternativeReading!.replaceAll('\n', ' / ')}")');
        }
      }
      for (final String regionId in answer.visualRegionIds) {
        final VisualEvidence? visual = answer.visualEvidence
            .where((VisualEvidence v) => v.regionId == regionId)
            .firstOrNull;
        out.writeln('[${alias(regionId)}] ${_describe(visual)}');
      }
      if (answer.crossedOut.isNotEmpty) {
        out.writeln('Crossed out (not part of the final answer):');
        for (final TextEvidenceItem item in answer.crossedOut) {
          out.writeln('[${alias(item.regionId)}] "${item.text.replaceAll('\n', ' / ')}"');
        }
      }
      if (task.images.isNotEmpty) {
        out.writeln('Images attached: ${task.images.map((MarkingImage i) => '[${alias(i.regionId)}] (${i.reason})').join(', ')}');
      }
      out.writeln();
    }

    out.writeln('TASK: Mark every question above. Return one entry per '
        'question. Set question_id to the ID exactly as it appears after '
        '"QUESTION" — for example ${tasks.first.question.questionId}.');
    return out.toString();
  }

  static String _source(TextEvidenceItem item) {
    final String who = item.source.label;
    if (item.source == ReadingSource.teacher) return 'corrected by the teacher';
    if (item.source == ReadingSource.textLayer) return 'typed';
    return 'read by $who, confidence ${item.confidence.toStringAsFixed(2)}';
  }

  /// The text with its uncertain words bracketed as `{?word?}`.
  static String _marked(TextEvidenceItem item) {
    final String text = item.text;
    if (item.illegible && text.trim().isEmpty) return '[illegible]';
    final List<({int start, int end})> spans = <({int start, int end})>[
      for (final UncertainSpan span in item.uncertainSpans)
        if (span.start != null &&
            span.end != null &&
            span.start! >= 0 &&
            span.end! <= text.length &&
            span.start! < span.end! &&
            span.text != '[illegible]')
          (start: span.start!, end: span.end!),
    ]..sort((a, b) => a.start.compareTo(b.start));

    final StringBuffer out = StringBuffer();
    int cursor = 0;
    for (final ({int start, int end}) span in spans) {
      if (span.start < cursor) continue;
      out
        ..write(text.substring(cursor, span.start))
        ..write('{?')
        ..write(text.substring(span.start, span.end))
        ..write('?}');
      cursor = span.end;
    }
    out.write(text.substring(cursor));
    return out.toString();
  }

  static String _describe(VisualEvidence? visual) {
    if (visual == null) return 'visual region — not analysed; see its image.';
    final String kind = visual.kind.wireName;
    if (!visual.analyzed) {
      return '$kind — analysis failed (${visual.error ?? 'unknown'}); judge it '
          'from its image.';
    }
    final String confidence = 'analysis confidence ${visual.confidence.toStringAsFixed(2)}';
    return switch (visual) {
      DiagramEvidence() => '$kind ($confidence): ${visual.description}'
          '${visual.labels.isEmpty ? '' : '\n  labels: ${visual.labels.join('; ')}'}'
          '${visual.components.isEmpty ? '' : '\n  components: ${visual.components.join('; ')}'}'
          '${visual.relationships.isEmpty ? '' : '\n  relationships: ${visual.relationships.join('; ')}'}',
      GraphEvidence() => '$kind ($confidence): ${visual.description}'
          '\n  x-axis: ${visual.xAxis}; y-axis: ${visual.yAxis}'
          '${visual.plottedElements.isEmpty ? '' : '\n  plotted: ${visual.plottedElements.join('; ')}'}'
          '${visual.approximateValues.isEmpty ? '' : '\n  values: ${visual.approximateValues.join('; ')}'}'
          '${visual.trend.isEmpty ? '' : '\n  trend: ${visual.trend}'}',
      TableEvidence() => '$kind ($confidence): ${visual.description}'
          '${visual.rows.isEmpty ? '' : '\n${visual.rows.map((List<String> row) => '  | ${row.join(' | ')} |').join('\n')}'}'
          '${visual.crossedOutCells.isEmpty ? '' : '\n  crossed-out cells: ${visual.crossedOutCells.join('; ')}'}',
      EquationEvidence() => '$kind ($confidence): LaTeX ${visual.latex}'
          '${visual.plainText.isEmpty ? '' : ' — plain: ${visual.plainText}'}'
          '${visual.description.isEmpty ? '' : '\n  ${visual.description}'}',
    };
  }

  static String _indent(String text) =>
      text.split('\n').map((String line) => '  $line').join('\n');

  static final Map<String, Object?> schema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'questions': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'question_id': <String, Object?>{'type': 'string'},
            'maximum_marks': <String, Object?>{'type': 'number'},
            'marking_points_source': <String, Object?>{
              'type': 'string',
              'enum': <String>['paper', 'teacher', 'key', 'inferred', 'mixed'],
            },
            'marking_points': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'id': <String, Object?>{'type': 'string'},
                  'description': <String, Object?>{'type': 'string'},
                  'source': <String, Object?>{
                    'type': 'string',
                    'enum': <String>['paper', 'teacher', 'key', 'inferred'],
                  },
                  'marks_available': <String, Object?>{'type': 'number'},
                  'marks_awarded': <String, Object?>{'type': 'number'},
                  'evidence': <String, Object?>{
                    'type': 'array',
                    'items': <String, Object?>{'type': 'string'},
                  },
                  'basis': <String, Object?>{
                    'type': 'string',
                    'enum': <String>['observed', 'inferred', 'uncertain'],
                  },
                  'note': <String, Object?>{'type': 'string'},
                },
                'required': <String>[
                  'id',
                  'description',
                  'source',
                  'marks_available',
                  'marks_awarded',
                  'evidence',
                  'basis',
                  'note',
                ],
                'additionalProperties': false,
              },
            },
            'awarded_marks': <String, Object?>{'type': 'number'},
            'quality_band': <String, Object?>{
              'type': 'string',
              'enum': <String>['excellent', 'good', 'satisfactory', 'weak', 'poor', 'none'],
            },
            'band_reason': <String, Object?>{'type': 'string'},
            'student_answer': <String, Object?>{'type': 'string'},
            'explanation': <String, Object?>{'type': 'string'},
            'confidence': <String, Object?>{'type': 'number'},
            'needs_review': <String, Object?>{'type': 'boolean'},
            'review_reasons': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{'type': 'string'},
            },
            'interpreted_readings': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'region': <String, Object?>{'type': 'string'},
                  'raw': <String, Object?>{'type': 'string'},
                  'interpreted': <String, Object?>{'type': 'string'},
                  'basis': <String, Object?>{
                    'type': 'string',
                    'enum': <String>['observed', 'inferred', 'uncertain'],
                  },
                },
                'required': <String>['region', 'raw', 'interpreted', 'basis'],
                'additionalProperties': false,
              },
            },
          },
          'required': <String>[
            'question_id',
            'maximum_marks',
            'marking_points_source',
            'marking_points',
            'awarded_marks',
            'quality_band',
            'band_reason',
            'student_answer',
            'explanation',
            'confidence',
            'needs_review',
            'review_reasons',
            'interpreted_readings',
          ],
          'additionalProperties': false,
        },
      },
    },
    'required': <String>['questions'],
    'additionalProperties': false,
  };
}
