"""Application configuration, loaded from the environment.

API credentials are never hard-coded. They are read from environment variables
(optionally seeded from a local .env file that is not committed).
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from dotenv import load_dotenv

# Load .env from the working directory / project root if present. Real
# environment variables always win over .env values.
load_dotenv(override=False)

DEFAULT_MODEL = "claude-opus-5"
DEFAULT_EFFORT = "high"
DEFAULT_MAX_TOKENS = 32000
MAX_PDF_BYTES = 25 * 1024 * 1024  # 25 MB


class ConfigError(Exception):
    """Raised when required configuration is missing or invalid."""


@dataclass(frozen=True)
class AppConfig:
    api_key: str | None
    model: str
    effort: str
    max_tokens: int

    @classmethod
    def from_env(cls) -> "AppConfig":
        raw_max_tokens = os.environ.get("EXAM_CORRECTOR_MAX_TOKENS", "")
        try:
            max_tokens = int(raw_max_tokens) if raw_max_tokens else DEFAULT_MAX_TOKENS
        except ValueError as exc:
            raise ConfigError(
                f"EXAM_CORRECTOR_MAX_TOKENS must be an integer, got {raw_max_tokens!r}."
            ) from exc

        return cls(
            api_key=os.environ.get("ANTHROPIC_API_KEY") or None,
            model=os.environ.get("EXAM_CORRECTOR_MODEL", DEFAULT_MODEL),
            effort=os.environ.get("EXAM_CORRECTOR_EFFORT", DEFAULT_EFFORT),
            max_tokens=max_tokens,
        )
