/// The correction prompt and the response schema the model must satisfy.
///
/// Kept in one place so marking behaviour can be tuned without touching
/// transport code, and well away from the UI.
///
/// The question paper is the structural authority: it establishes which
/// questions exist, what section each belongs to, and how many marks each
/// carries. It does not say what a correct answer looks like — that judgement
/// is the model's, which is why every question must come back with the marking
/// points it decided to reward. Those are what the teacher checks.
class CorrectionPrompt {
  const CorrectionPrompt._();

  static const String systemPrompt = '''
You are an experienced examiner marking a student's exam paper.

You are given the question paper and the student's answer sheet as two separate documents. The question paper is the authority for what is marked and for how many marks. You supply the subject knowledge for judging whether an answer is correct.

Structure — taken from the question paper, never from the answer sheet:
- Mark every question that appears in the question paper, in the question paper's order. Do not add questions it does not contain.
- The question paper may be divided into sections. Keep each question with the section it appears under, and apply any section-wide instruction to every question in that section.
- Take each question's maximum marks from the marks printed in the question paper. Marks printed on the answer sheet are the student's own copy and carry no authority.
- Where the question paper states no marks for a question, decide a maximum from what the question demands, and set marks_stated_in_paper to false for that question. Set it to true whenever the paper did state the marks.

Matching — the question number is the only link between the two documents:
- Match each answer to its question by the question number written beside it. Do not match on position, order, or wording.
- An answer may continue elsewhere on the sheet, such as in an extra answer space. Where a continuation names its question number, mark it as part of that question.
- If the answer sheet contains an answer whose question number is not in the question paper, do not mark it. Record it in unmatched_answers instead.
- If a question in the question paper has no answer, award zero, record the student answer as "No answer found", and say so in the evaluation.

Marking — your own subject knowledge, declared openly:
- For each question, decide the marking points a correct answer must contain, and divide the question's maximum marks between them. Report them in marking_points. This is what the teacher checks, so make each point specific enough to agree or disagree with.
- Award marks per marking point. A question's awarded marks must equal the sum of the marks for its satisfied marking points, and must never exceed that question's maximum.
- Accept any answer that is correct on the subject, including wordings and valid alternatives you did not list. Judge the answer on its substance, not on whether it reads well or matches your phrasing.
- Where a question asks for working, credit correct method even when the final answer is wrong.
- Do not reward length, confidence or restating the question.
- Keep each evaluation to one or two sentences explaining why those marks were awarded.
''';

  /// Added when the teacher supplied marking notes.
  ///
  /// Stated as a gap-filler rather than an instruction of equal weight: the
  /// teacher writes guidance quickly and in general terms ("Section A: one mark
  /// each"), and it must not silently override a mark printed on the paper for
  /// a question they were not thinking about.
  static const String guidanceClause = '''

The teacher has supplied additional marking guidance. Treat it as extra information about how to mark, not as a replacement for the question paper.
- Apply it wherever the question paper is silent: a question with no printed marks, or how marks should be divided within a question.
- Where it disagrees with marks printed in the question paper, follow the question paper, and note the disagreement in that question's evaluation.
- Guidance addressed to a section applies to every question in that section.
''';

  /// Added when either document was transcribed from handwriting.
  ///
  /// Without this the model penalises the recogniser's mistakes as if they were
  /// the student's — a misread word becomes a spelling error, a dropped minus
  /// sign becomes a wrong answer.
  static const String handwritingClause = '''

At least one of these documents was transcribed from handwriting by automatic recognition, so it contains transcription errors that no one actually made.
- Judge each answer on its evident intent. Do not deduct marks for misspellings, malformed characters, or garbled words that are plainly artefacts of the transcription rather than the student's own error.
- Where the marking of a point turns on exact spelling, terminology or notation, apply it only when the transcription is clear enough to be sure.
- Lines beginning with ⚠ were transcribed with low confidence. Read them especially charitably, and say so in the evaluation when a mark turned on one.
- Markers added by the transcription — ⚠ and [[Q…]] — are not part of the documents. Never include them when quoting a student's answer.
''';

  /// The system prompt, adapted to what this particular correction was given.
  static String systemPromptFor({
    required bool hasGuidance,
    required bool fromHandwriting,
  }) {
    final StringBuffer prompt = StringBuffer(systemPrompt);
    if (hasGuidance) prompt.write(guidanceClause);
    if (fromHandwriting) prompt.write(handwritingClause);
    return prompt.toString();
  }

  /// Builds the user turn: question paper, answer sheet, guidance, then task.
  ///
  /// The question paper comes first because it is what the rest is read
  /// against.
  static String buildUserPrompt({
    required String questionPaperText,
    required String answerSheetText,
    String guidanceText = '',
  }) {
    final StringBuffer prompt = StringBuffer()
      ..writeln('QUESTION PAPER:')
      ..writeln(questionPaperText.trim())
      ..writeln()
      ..writeln("STUDENT'S ANSWER SHEET:")
      ..writeln(answerSheetText.trim())
      ..writeln();

    if (guidanceText.trim().isNotEmpty) {
      prompt
        ..writeln('ADDITIONAL MARKING GUIDANCE FROM THE TEACHER:')
        ..writeln(guidanceText.trim())
        ..writeln();
    }

    prompt.write('''
TASK:
Mark the student's answer sheet against the question paper.
For each question in the question paper:
- Identify the question, its section, and its maximum marks.
- Find the student's answer to it by question number.
- Decide the marking points a correct answer must contain, and how the marks divide between them.
- Award marks against those points.
- Explain why the marks were awarded.
- Do not exceed the maximum marks.
''');

    return prompt.toString();
  }

  /// JSON Schema constraining the model's response. Every object declares its
  /// properties as required with additionalProperties disabled, so a structured
  /// response can only be the shape the validator expects.
  static const Map<String, Object?> responseSchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'questions': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'question_number': <String, Object?>{
              'type': 'string',
              'description':
                  "Question identifier as written in the question paper, e.g. '1' or '2b'.",
            },
            'maximum_marks': <String, Object?>{
              'type': 'number',
              'description':
                  'Maximum marks for this question, from the question paper.',
            },
            'marks_stated_in_paper': <String, Object?>{
              'type': 'boolean',
              'description':
                  'True when the question paper printed this question\'s marks. '
                      'False when the maximum had to be inferred.',
            },
            'awarded_marks': <String, Object?>{
              'type': 'number',
              'description': 'Marks awarded. Must not exceed maximum_marks.',
            },
            'student_answer': <String, Object?>{
              'type': 'string',
              'description':
                  "The student's answer as it appears on the answer sheet, or 'No answer found'.",
            },
            'evaluation': <String, Object?>{
              'type': 'string',
              'description':
                  'One or two sentences explaining why these marks were awarded.',
            },
            'marking_points': <String, Object?>{
              'type': 'array',
              'description':
                  'The marking points you decided a correct answer must contain, '
                      'and whether the student satisfied each.',
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'criterion': <String, Object?>{'type': 'string'},
                  'satisfied': <String, Object?>{'type': 'boolean'},
                  'marks': <String, Object?>{
                    'type': 'number',
                    'description':
                        'Marks awarded for this point. Zero when not satisfied.',
                  },
                },
                'required': <String>['criterion', 'satisfied', 'marks'],
                'additionalProperties': false,
              },
            },
          },
          'required': <String>[
            'question_number',
            'maximum_marks',
            'marks_stated_in_paper',
            'awarded_marks',
            'student_answer',
            'evaluation',
            'marking_points',
          ],
          'additionalProperties': false,
        },
      },
      'unmatched_answers': <String, Object?>{
        'type': 'array',
        'description':
            'Answers on the sheet whose question number is not in the question '
                'paper. These are not marked, but the teacher is told about them.',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'question_number': <String, Object?>{'type': 'string'},
            'student_answer': <String, Object?>{'type': 'string'},
          },
          'required': <String>['question_number', 'student_answer'],
          'additionalProperties': false,
        },
      },
      'total_marks': <String, Object?>{'type': 'number'},
      'maximum_total_marks': <String, Object?>{'type': 'number'},
      'percentage': <String, Object?>{'type': 'number'},
    },
    'required': <String>[
      'questions',
      'unmatched_answers',
      'total_marks',
      'maximum_total_marks',
      'percentage',
    ],
    'additionalProperties': false,
  };
}
