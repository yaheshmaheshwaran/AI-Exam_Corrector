"""Anthropic-backed implementation of CorrectionService.

This is the only module that knows the model exists. It sends the correction
prompt, constrains the response to RESPONSE_SCHEMA, and hands the decoded
payload to the validation layer.
"""

from __future__ import annotations

import json

import anthropic

from app.config import AppConfig
from app.core.models import CorrectionResult
from app.core.validation import ValidationError, validate_correction
from app.services.ai.base import CorrectionError, CorrectionService
from app.services.ai.prompt import (
    RESPONSE_SCHEMA,
    SYSTEM_PROMPT,
    build_user_prompt,
)


class AnthropicCorrectionService(CorrectionService):
    def __init__(self, config: AppConfig, client: anthropic.Anthropic | None = None):
        self._config = config
        self._client = client
        self.last_warnings: list[str] = []

    def _get_client(self) -> anthropic.Anthropic:
        """Build the client on first use so a missing key surfaces as a clear
        message at correction time rather than crashing at startup."""
        if self._client is None:
            try:
                # An explicit key wins; otherwise let the SDK resolve
                # credentials from the environment. Nothing is hard-coded.
                self._client = (
                    anthropic.Anthropic(api_key=self._config.api_key)
                    if self._config.api_key
                    else anthropic.Anthropic()
                )
            except Exception as exc:
                raise CorrectionError(
                    "No API credentials were found. Set ANTHROPIC_API_KEY in your "
                    "environment (or in a .env file next to the application) and "
                    "restart."
                ) from exc
        return self._client

    def correct(self, paper_text: str, mark_scheme_text: str) -> CorrectionResult:
        if not paper_text.strip():
            raise CorrectionError("The exam paper contained no text to mark.")
        if not mark_scheme_text.strip():
            raise CorrectionError("A mark scheme is required before correcting.")

        message = self._request(paper_text, mark_scheme_text)
        payload = self._decode(message)

        try:
            result, warnings = validate_correction(payload)
        except ValidationError as exc:
            raise CorrectionError(
                f"The AI returned a result that failed validation: {exc}"
            ) from exc

        self.last_warnings = warnings
        return result

    def _request(self, paper_text: str, mark_scheme_text: str):
        client = self._get_client()
        try:
            # Streamed because a full paper's correction is a long response;
            # streaming avoids HTTP timeouts on large max_tokens.
            with client.messages.stream(
                model=self._config.model,
                max_tokens=self._config.max_tokens,
                system=SYSTEM_PROMPT,
                output_config={
                    "effort": self._config.effort,
                    "format": {"type": "json_schema", "schema": RESPONSE_SCHEMA},
                },
                messages=[
                    {
                        "role": "user",
                        "content": build_user_prompt(paper_text, mark_scheme_text),
                    }
                ],
            ) as stream:
                return stream.get_final_message()
        except anthropic.AuthenticationError as exc:
            raise CorrectionError(
                "The API key was rejected. Check ANTHROPIC_API_KEY and try again."
            ) from exc
        except anthropic.PermissionDeniedError as exc:
            raise CorrectionError(
                "This API key does not have access to the configured model "
                f"({self._config.model})."
            ) from exc
        except anthropic.NotFoundError as exc:
            raise CorrectionError(
                f"The configured model ({self._config.model}) was not found."
            ) from exc
        except anthropic.RateLimitError as exc:
            raise CorrectionError(
                "The API rate limit was reached. Please wait a moment and try again."
            ) from exc
        except anthropic.APIConnectionError as exc:
            raise CorrectionError(
                "Could not reach the API. Check your internet connection and try again."
            ) from exc
        except anthropic.APIStatusError as exc:
            raise CorrectionError(f"The API returned an error: {exc.message}") from exc
        except TypeError as exc:
            # The SDK resolves credentials when the request is built, not when
            # the client is constructed.
            if "authentication" in str(exc).lower():
                raise CorrectionError(
                    "No API credentials were found. Set ANTHROPIC_API_KEY in your "
                    "environment (or in a .env file next to the application) and "
                    "restart."
                ) from exc
            raise CorrectionError(f"Unexpected error contacting the API: {exc}") from exc
        except Exception as exc:
            raise CorrectionError(f"Unexpected error contacting the API: {exc}") from exc

    def _decode(self, message) -> object:
        if message.stop_reason == "refusal":
            raise CorrectionError(
                "The AI declined to mark this paper. Please review the uploaded "
                "content."
            )
        if message.stop_reason == "max_tokens":
            raise CorrectionError(
                "The correction was cut short because it exceeded the output limit. "
                "Try marking fewer questions at once, or raise "
                "EXAM_CORRECTOR_MAX_TOKENS."
            )

        text = "".join(
            block.text for block in message.content if block.type == "text"
        ).strip()
        if not text:
            raise CorrectionError("The AI returned an empty response.")

        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise CorrectionError(
                f"The AI response was not valid JSON: {exc}"
            ) from exc
