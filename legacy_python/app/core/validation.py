"""Validation of the AI's structured response before it is shown as marks.

Nothing reaches the UI without passing through here. Structural problems raise
ValidationError; recoverable inconsistencies are corrected and reported as
warnings so the teacher knows the marks were adjusted.

The invariant this module enforces: awarded marks can never exceed the maximum
marks, and displayed totals are always recomputed from the per-question marks.
"""

from __future__ import annotations

from typing import Any

from app.core.models import CorrectionResult, MarkingPoint, QuestionResult


class ValidationError(Exception):
    """Raised when the AI response cannot be trusted to display as marks."""


def validate_correction(payload: Any) -> tuple[CorrectionResult, list[str]]:
    """Turn a raw decoded AI response into a CorrectionResult.

    Returns the result and a list of warnings describing any adjustment made.
    """
    warnings: list[str] = []

    if not isinstance(payload, dict):
        raise ValidationError("The AI response was not a JSON object.")

    raw_questions = payload.get("questions")
    if not isinstance(raw_questions, list):
        raise ValidationError("The AI response contained no 'questions' list.")
    if not raw_questions:
        raise ValidationError(
            "The AI returned no questions. Check that the mark scheme and the "
            "exam paper describe the same exam."
        )

    questions = [
        _validate_question(raw, index, warnings)
        for index, raw in enumerate(raw_questions, start=1)
    ]

    # Totals are always recomputed locally — the model's arithmetic is never
    # the source of truth for what the teacher sees.
    total = sum(q.awarded_marks for q in questions)
    maximum_total = sum(q.maximum_marks for q in questions)

    _note_if_different(
        warnings,
        payload.get("total_marks"),
        total,
        "Reported total marks did not match the per-question marks; the total was recalculated.",
    )
    _note_if_different(
        warnings,
        payload.get("maximum_total_marks"),
        maximum_total,
        "Reported maximum total did not match the per-question maxima; the maximum was recalculated.",
    )

    percentage = (total / maximum_total * 100.0) if maximum_total > 0 else 0.0

    return (
        CorrectionResult(
            questions=questions,
            total_marks=total,
            maximum_total_marks=maximum_total,
            percentage=percentage,
        ),
        warnings,
    )


def _validate_question(raw: Any, index: int, warnings: list[str]) -> QuestionResult:
    where = f"Question #{index}"
    if not isinstance(raw, dict):
        raise ValidationError(f"{where} was not a JSON object.")

    number = _require_text(raw.get("question_number"), f"{where} question_number") or str(index)
    label = f"Question {number}"

    maximum = _require_number(raw.get("maximum_marks"), f"{label} maximum_marks")
    if maximum < 0:
        raise ValidationError(f"{label} has a negative maximum ({maximum}).")

    awarded = _require_number(raw.get("awarded_marks"), f"{label} awarded_marks")

    if awarded < 0:
        warnings.append(f"{label}: awarded marks were negative and were raised to 0.")
        awarded = 0.0
    if awarded > maximum:
        warnings.append(
            f"{label}: awarded marks ({_fmt(awarded)}) exceeded the maximum "
            f"({_fmt(maximum)}) and were capped."
        )
        awarded = maximum

    points = _validate_marking_points(raw.get("marking_points"), label)

    return QuestionResult(
        question_number=number,
        maximum_marks=maximum,
        awarded_marks=awarded,
        student_answer=_optional_text(raw.get("student_answer")) or "No answer found",
        evaluation=_optional_text(raw.get("evaluation")) or "No evaluation provided.",
        marking_points=points,
    )


def _validate_marking_points(raw_points: Any, label: str) -> list[MarkingPoint]:
    if raw_points is None:
        return []
    if not isinstance(raw_points, list):
        raise ValidationError(f"{label}: marking_points was not a list.")

    points: list[MarkingPoint] = []
    for position, raw in enumerate(raw_points, start=1):
        where = f"{label} marking point {position}"
        if not isinstance(raw, dict):
            raise ValidationError(f"{where} was not a JSON object.")

        criterion = _require_text(raw.get("criterion"), f"{where} criterion")
        satisfied = raw.get("satisfied")
        if not isinstance(satisfied, bool):
            raise ValidationError(f"{where}: 'satisfied' must be true or false.")

        marks = _require_number(raw.get("marks"), f"{where} marks")
        marks = max(marks, 0.0)
        if not satisfied:
            marks = 0.0

        points.append(MarkingPoint(criterion=criterion, satisfied=satisfied, marks=marks))

    return points


def _require_number(value: Any, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationError(f"{where} must be a number, got {value!r}.")
    number = float(value)
    if number != number or number in (float("inf"), float("-inf")):
        raise ValidationError(f"{where} was not a finite number.")
    return number


def _require_text(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{where} must be a non-empty string.")
    return value.strip()


def _optional_text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _note_if_different(
    warnings: list[str], reported: Any, computed: float, message: str
) -> None:
    if isinstance(reported, (int, float)) and not isinstance(reported, bool):
        if abs(float(reported) - computed) > 0.01:
            warnings.append(message)


def _fmt(value: float) -> str:
    return f"{value:g}"
