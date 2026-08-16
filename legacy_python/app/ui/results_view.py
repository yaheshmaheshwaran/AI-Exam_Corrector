"""Read-only, question-by-question rendering of a CorrectionResult."""

from __future__ import annotations

import tkinter as tk
from tkinter import ttk

from app.core.models import CorrectionResult

TICK = "✓"
CROSS = "✗"


class ResultsView(ttk.Frame):
    def __init__(self, parent: tk.Misc):
        super().__init__(parent)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        self._text = tk.Text(
            self,
            wrap="word",
            state="disabled",
            padx=12,
            pady=10,
            borderwidth=1,
            relief="solid",
            height=18,
        )
        self._text.grid(row=0, column=0, sticky="nsew")

        scrollbar = ttk.Scrollbar(self, orient="vertical", command=self._text.yview)
        scrollbar.grid(row=0, column=1, sticky="ns")
        self._text.configure(yscrollcommand=scrollbar.set)

        self._configure_tags()
        self.show_placeholder("Correction results will appear here.")

    def _configure_tags(self) -> None:
        base = ("TkDefaultFont", 11)
        self._text.tag_configure("question", font=(base[0], 13, "bold"), spacing1=12, spacing3=4)
        self._text.tag_configure("label", font=(base[0], base[1], "bold"))
        self._text.tag_configure("body", font=base, lmargin1=16, lmargin2=16, spacing3=2)
        self._text.tag_configure("satisfied", font=base, foreground="#1a7f37", lmargin1=16, lmargin2=32)
        self._text.tag_configure("unsatisfied", font=base, foreground="#b3261e", lmargin1=16, lmargin2=32)
        self._text.tag_configure("total", font=(base[0], 15, "bold"), spacing1=16, spacing3=4)
        self._text.tag_configure("warning", font=base, foreground="#8a6100", lmargin1=8, lmargin2=8)
        self._text.tag_configure("muted", font=base, foreground="#666666")
        self._text.tag_configure("rule", spacing1=6, spacing3=6)

    # -- public API -------------------------------------------------------

    def show_placeholder(self, message: str) -> None:
        with self._editable():
            self._text.delete("1.0", "end")
            self._text.insert("end", message, "muted")

    def show(self, result: CorrectionResult, warnings: list[str] | None = None) -> None:
        with self._editable():
            self._text.delete("1.0", "end")

            for warning in warnings or []:
                self._write(f"! {warning}\n", "warning")
            if warnings:
                self._write("\n", "rule")

            for question in result.questions:
                self._write(f"Question {question.question_number}\n", "question")
                self._write("Maximum Marks: ", "label")
                self._write(f"{_fmt(question.maximum_marks)}\n", "body")
                self._write("Awarded Marks: ", "label")
                self._write(f"{_fmt(question.awarded_marks)}\n", "body")

                self._write("Student Answer:\n", "label")
                self._write(f"{question.student_answer}\n", "body")

                self._write("Evaluation:\n", "label")
                self._write(f"{question.evaluation}\n", "body")

                if question.marking_points:
                    self._write("Marking Points:\n", "label")
                    for point in question.marking_points:
                        symbol = TICK if point.satisfied else CROSS
                        tag = "satisfied" if point.satisfied else "unsatisfied"
                        marks = f" ({_fmt(point.marks)})" if point.satisfied else ""
                        self._write(f"{symbol} {point.criterion}{marks}\n", tag)

            self._write(
                f"Total Marks: {_fmt(result.total_marks)} / "
                f"{_fmt(result.maximum_total_marks)}\n",
                "total",
            )
            self._write(f"Percentage: {result.percentage:.0f}%\n", "total")

        self._text.see("1.0")

    # -- internals --------------------------------------------------------

    def _write(self, text: str, tag: str) -> None:
        self._text.insert("end", text, tag)

    def _editable(self):
        view = self._text

        class _Editable:
            def __enter__(self):
                view.configure(state="normal")

            def __exit__(self, *_exc):
                view.configure(state="disabled")
                return False

        return _Editable()


def _fmt(value: float) -> str:
    return f"{value:g}"
