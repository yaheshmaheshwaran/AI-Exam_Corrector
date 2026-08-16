"""The correction prompt and the response schema the model must satisfy.

Kept in one place so marking behaviour can be tuned without touching transport
code. The mark scheme is the sole authority for awarding marks.
"""

from __future__ import annotations

SYSTEM_PROMPT = """\
You are an experienced examiner marking a student's exam paper.

The supplied mark scheme is the single authority for awarding marks. Apply it \
exactly as written.

Rules you must follow:
- Mark only against criteria stated in the mark scheme. Never invent marking \
criteria, and never award marks for qualities the mark scheme does not reward.
- Where the mark scheme lists alternative acceptable answers, accept any of them.
- Where the mark scheme allows partial credit, award it on the stated terms.
- Award marks per marking point. A question's awarded marks must equal the sum \
of the marks for its satisfied marking points, and must never exceed that \
question's maximum.
- Judge the answer on the marking criteria, not on whether it reads well.
- If the student did not answer a question, award zero and say so.
- If the paper's answer for a question cannot be located, award zero, record the \
student answer as "No answer found", and say so in the evaluation.
- Take the maximum marks for each question from the mark scheme. If the mark \
scheme does not state a maximum for a question, use the total of that question's \
marking points.
- Keep each evaluation to one or two sentences explaining why those marks were \
awarded.
- Cover every question in the mark scheme, in the mark scheme's order.
"""

USER_PROMPT_TEMPLATE = """\
MARK SCHEME:
{mark_scheme}

STUDENT EXAM PAPER:
{paper}

TASK:
Evaluate every question according to the supplied mark scheme.
For each question:
- Identify the question.
- Identify the student's answer.
- Determine the applicable marking criteria.
- Award marks based strictly on those criteria.
- Explain why the marks were awarded.
- Do not exceed the maximum marks.
"""

# JSON Schema constraining the model's response. Structured outputs require
# every object to declare its properties as required with additionalProperties
# disabled.
RESPONSE_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "question_number": {
                        "type": "string",
                        "description": "Question identifier as written in the mark scheme, e.g. '1' or '2b'.",
                    },
                    "maximum_marks": {
                        "type": "number",
                        "description": "Maximum marks available for this question per the mark scheme.",
                    },
                    "awarded_marks": {
                        "type": "number",
                        "description": "Marks awarded. Must not exceed maximum_marks.",
                    },
                    "student_answer": {
                        "type": "string",
                        "description": "The student's answer as it appears in the paper, or 'No answer found'.",
                    },
                    "evaluation": {
                        "type": "string",
                        "description": "One or two sentences explaining why these marks were awarded.",
                    },
                    "marking_points": {
                        "type": "array",
                        "description": "Each marking criterion from the mark scheme and whether the answer satisfied it.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "criterion": {"type": "string"},
                                "satisfied": {"type": "boolean"},
                                "marks": {
                                    "type": "number",
                                    "description": "Marks awarded for this point. Zero when not satisfied.",
                                },
                            },
                            "required": ["criterion", "satisfied", "marks"],
                            "additionalProperties": False,
                        },
                    },
                },
                "required": [
                    "question_number",
                    "maximum_marks",
                    "awarded_marks",
                    "student_answer",
                    "evaluation",
                    "marking_points",
                ],
                "additionalProperties": False,
            },
        },
        "total_marks": {"type": "number"},
        "maximum_total_marks": {"type": "number"},
        "percentage": {"type": "number"},
    },
    "required": ["questions", "total_marks", "maximum_total_marks", "percentage"],
    "additionalProperties": False,
}


def build_user_prompt(paper_text: str, mark_scheme_text: str) -> str:
    return USER_PROMPT_TEMPLATE.format(
        mark_scheme=mark_scheme_text.strip(),
        paper=paper_text.strip(),
    )
