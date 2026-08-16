"""Domain model for a correction result.

These types are the contract between the AI layer, the validation layer and the
UI. Nothing in here knows about Anthropic, PDFs or Tkinter.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class MarkingPoint:
    criterion: str
    satisfied: bool
    marks: float


@dataclass(frozen=True)
class QuestionResult:
    question_number: str
    maximum_marks: float
    awarded_marks: float
    student_answer: str
    evaluation: str
    marking_points: list[MarkingPoint] = field(default_factory=list)


@dataclass(frozen=True)
class CorrectionResult:
    questions: list[QuestionResult]
    total_marks: float
    maximum_total_marks: float
    percentage: float

    @property
    def has_questions(self) -> bool:
        return bool(self.questions)
