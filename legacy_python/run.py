"""Entry point for the Exam Corrector desktop application."""

from __future__ import annotations

import sys
import tkinter as tk
from tkinter import messagebox, ttk

from app.config import AppConfig, ConfigError
from app.services.ai.anthropic_service import AnthropicCorrectionService
from app.ui.main_window import MainWindow


def main() -> int:
    try:
        config = AppConfig.from_env()
    except ConfigError as exc:
        _fatal("Configuration error", str(exc))
        return 1

    service = AnthropicCorrectionService(config)

    root = tk.Tk()
    root.title("Exam Corrector")
    root.minsize(880, 720)
    _apply_theme(root)

    MainWindow(root, config, service)
    root.mainloop()
    return 0


def _apply_theme(root: tk.Tk) -> None:
    style = ttk.Style(root)
    for preferred in ("vista", "aqua", "clam"):
        if preferred in style.theme_names():
            style.theme_use(preferred)
            break


def _fatal(title: str, message: str) -> None:
    root = tk.Tk()
    root.withdraw()
    messagebox.showerror(title, message)
    root.destroy()


if __name__ == "__main__":
    sys.exit(main())
