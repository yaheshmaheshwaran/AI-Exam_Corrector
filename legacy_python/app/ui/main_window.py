"""Main application window: upload, mark scheme, correct, results.

The UI owns no marking logic. It collects input, calls the PDF and correction
services on a worker thread, and renders whatever the validation layer approves.
"""

from __future__ import annotations

import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from app.config import AppConfig
from app.core.models import CorrectionResult
from app.services.ai.base import CorrectionError, CorrectionService
from app.services.pdf_extractor import PdfExtractionError, extract_text
from app.ui.results_view import ResultsView

PAD = 10


class MainWindow(ttk.Frame):
    def __init__(self, root: tk.Tk, config: AppConfig, service: CorrectionService):
        super().__init__(root, padding=PAD)
        self._root = root
        self._config = config
        self._service = service

        self._paper_path: str | None = None
        self._paper_text: str = ""
        self._results: queue.Queue = queue.Queue()
        self._busy = False

        self.grid(row=0, column=0, sticky="nsew")
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(2, weight=1)

        self._build_paper_section()
        self._build_mark_scheme_section()
        self._build_results_section()
        self._build_action_bar()

        if not config.api_key:
            self._set_status(
                "ANTHROPIC_API_KEY is not set — correction will fail until it is.",
                error=True,
            )

    # -- layout -----------------------------------------------------------

    def _build_paper_section(self) -> None:
        frame = ttk.LabelFrame(self, text="1. Student exam paper (PDF)", padding=PAD)
        frame.grid(row=0, column=0, sticky="ew", pady=(0, PAD))
        frame.columnconfigure(0, weight=1)

        self._paper_label = ttk.Label(frame, text="No file selected.", foreground="#666666")
        self._paper_label.grid(row=0, column=0, sticky="w")

        self._choose_button = ttk.Button(frame, text="Choose PDF…", command=self._choose_paper)
        self._choose_button.grid(row=0, column=1, sticky="e", padx=(PAD, 0))

    def _build_mark_scheme_section(self) -> None:
        frame = ttk.LabelFrame(self, text="2. Mark scheme", padding=PAD)
        frame.grid(row=1, column=0, sticky="ew", pady=(0, PAD))
        frame.columnconfigure(0, weight=1)

        hint = ttk.Label(
            frame,
            text=(
                "Paste the mark scheme, or load it from a PDF. Include questions, "
                "expected answers, mark allocation, acceptable alternatives and "
                "partial-credit rules."
            ),
            foreground="#666666",
            wraplength=760,
            justify="left",
        )
        hint.grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 6))

        self._scheme_text = tk.Text(frame, height=9, wrap="word", borderwidth=1, relief="solid")
        self._scheme_text.grid(row=1, column=0, sticky="ew")

        scrollbar = ttk.Scrollbar(frame, orient="vertical", command=self._scheme_text.yview)
        scrollbar.grid(row=1, column=1, sticky="ns")
        self._scheme_text.configure(yscrollcommand=scrollbar.set)

        buttons = ttk.Frame(frame)
        buttons.grid(row=2, column=0, columnspan=2, sticky="e", pady=(6, 0))
        self._scheme_load_button = ttk.Button(
            buttons, text="Load from PDF…", command=self._load_mark_scheme
        )
        self._scheme_load_button.grid(row=0, column=0)
        self._scheme_clear_button = ttk.Button(
            buttons, text="Clear", command=lambda: self._scheme_text.delete("1.0", "end")
        )
        self._scheme_clear_button.grid(row=0, column=1, padx=(6, 0))

    def _build_results_section(self) -> None:
        frame = ttk.LabelFrame(self, text="3. Correction result", padding=PAD)
        frame.grid(row=2, column=0, sticky="nsew")
        frame.columnconfigure(0, weight=1)
        frame.rowconfigure(0, weight=1)

        self._results_view = ResultsView(frame)
        self._results_view.grid(row=0, column=0, sticky="nsew")

    def _build_action_bar(self) -> None:
        bar = ttk.Frame(self)
        bar.grid(row=3, column=0, sticky="ew", pady=(PAD, 0))
        bar.columnconfigure(0, weight=1)

        self._status = ttk.Label(bar, text="Ready.", foreground="#666666")
        self._status.grid(row=0, column=0, sticky="w")

        self._progress = ttk.Progressbar(bar, mode="indeterminate", length=140)
        self._progress.grid(row=0, column=1, padx=(PAD, PAD))
        self._progress.grid_remove()

        self._correct_button = ttk.Button(
            bar, text="Correct paper", command=self._start_correction
        )
        self._correct_button.grid(row=0, column=2, sticky="e")

    # -- actions ----------------------------------------------------------

    def _choose_paper(self) -> None:
        path = filedialog.askopenfilename(
            title="Select the student's exam paper",
            filetypes=[("PDF files", "*.pdf")],
        )
        if not path:
            return

        try:
            text = extract_text(path)
        except PdfExtractionError as exc:
            self._paper_path = None
            self._paper_text = ""
            self._paper_label.configure(text="No file selected.", foreground="#666666")
            messagebox.showerror("Could not read PDF", str(exc), parent=self._root)
            self._set_status("Exam paper could not be read.", error=True)
            return

        self._paper_path = path
        self._paper_text = text
        self._paper_label.configure(
            text=f"{_basename(path)}  ({len(text):,} characters extracted)",
            foreground="#1a7f37",
        )
        self._set_status("Exam paper loaded.")

    def _load_mark_scheme(self) -> None:
        path = filedialog.askopenfilename(
            title="Select the mark scheme",
            filetypes=[("PDF files", "*.pdf")],
        )
        if not path:
            return

        try:
            text = extract_text(path)
        except PdfExtractionError as exc:
            messagebox.showerror("Could not read PDF", str(exc), parent=self._root)
            return

        self._scheme_text.delete("1.0", "end")
        self._scheme_text.insert("1.0", text)
        self._set_status("Mark scheme loaded.")

    def _start_correction(self) -> None:
        if self._busy:
            return

        if not self._paper_text:
            messagebox.showwarning(
                "Exam paper required",
                "Choose the student's exam paper PDF first.",
                parent=self._root,
            )
            return

        mark_scheme = self._scheme_text.get("1.0", "end").strip()
        if not mark_scheme:
            messagebox.showwarning(
                "Mark scheme required",
                "Provide the mark scheme before correcting.",
                parent=self._root,
            )
            return

        self._set_busy(True)
        self._results_view.show_placeholder("Marking in progress…")
        self._set_status("Marking against the supplied mark scheme…")

        worker = threading.Thread(
            target=self._run_correction,
            args=(self._paper_text, mark_scheme),
            daemon=True,
        )
        worker.start()
        self.after(100, self._poll_result)

    def _run_correction(self, paper_text: str, mark_scheme: str) -> None:
        """Runs on a worker thread — must not touch Tk widgets."""
        try:
            result = self._service.correct(paper_text, mark_scheme)
            warnings = list(getattr(self._service, "last_warnings", []))
            self._results.put(("ok", (result, warnings)))
        except CorrectionError as exc:
            self._results.put(("error", str(exc)))
        except Exception as exc:  # never let a worker crash take down the app
            self._results.put(("error", f"Unexpected error during correction: {exc}"))

    def _poll_result(self) -> None:
        try:
            status, payload = self._results.get_nowait()
        except queue.Empty:
            self.after(100, self._poll_result)
            return

        self._set_busy(False)

        if status == "ok":
            result, warnings = payload
            self._show_result(result, warnings)
        else:
            self._results_view.show_placeholder("Correction failed.")
            self._set_status("Correction failed.", error=True)
            messagebox.showerror("Correction failed", payload, parent=self._root)

    def _show_result(self, result: CorrectionResult, warnings: list[str]) -> None:
        self._results_view.show(result, warnings)
        summary = (
            f"Marked {len(result.questions)} question"
            f"{'' if len(result.questions) == 1 else 's'}: "
            f"{result.total_marks:g} / {result.maximum_total_marks:g} "
            f"({result.percentage:.0f}%)."
        )
        if warnings:
            summary += f" {len(warnings)} adjustment(s) applied — see the result."
        self._set_status(summary)

    # -- helpers ----------------------------------------------------------

    def _set_busy(self, busy: bool) -> None:
        self._busy = busy
        state = "disabled" if busy else "normal"
        for widget in (
            self._correct_button,
            self._choose_button,
            self._scheme_load_button,
            self._scheme_clear_button,
        ):
            widget.configure(state=state)

        if busy:
            self._progress.grid()
            self._progress.start(12)
        else:
            self._progress.stop()
            self._progress.grid_remove()

    def _set_status(self, message: str, *, error: bool = False) -> None:
        self._status.configure(text=message, foreground="#b3261e" if error else "#666666")


def _basename(path: str) -> str:
    import os

    return os.path.basename(path)
