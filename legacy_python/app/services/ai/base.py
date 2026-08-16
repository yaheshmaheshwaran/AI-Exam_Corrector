"""The correction service interface.

The UI and application logic depend only on this abstraction, so the underlying
model or provider can be swapped without touching anything else.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

from app.core.models import CorrectionResult


class CorrectionError(Exception):
    """Raised when correction fails for a reason the teacher should see."""


class CorrectionService(ABC):
    @abstractmethod
    def correct(self, paper_text: str, mark_scheme_text: str) -> CorrectionResult:
        """Evaluate a student's paper against a mark scheme.

        Implementations must return a validated CorrectionResult or raise
        CorrectionError with a human-readable message.
        """
