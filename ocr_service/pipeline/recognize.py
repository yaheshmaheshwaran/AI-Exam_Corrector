"""TrOCR recognition: a cropped text line becomes a string and a confidence.

TrOCR reports no confidence of its own. It is derived here from the decoder's
own token log-probabilities, and that one number carries a lot of weight
downstream: it decides which lines get a second opinion from the vision model,
which lines the review screen highlights, and which reach the teacher as a
warning. Everything the pipeline knows about its own reliability comes from
this module.
"""

from __future__ import annotations

import math
import os
import threading
from dataclasses import dataclass
from typing import Callable

import cv2
import numpy as np
import torch
from PIL import Image

DEFAULT_MODEL = "microsoft/trocr-large-handwritten"

# Crops per forward pass. Eight keeps a large model inside a laptop's memory
# while still amortising the per-batch overhead.
DEFAULT_BATCH_SIZE = 8

# TrOCR's decoder rarely needs more than this for one handwritten line; the cap
# stops a degenerate crop from generating until it times out.
MAX_NEW_TOKENS = 96

_MODEL_CACHE: dict[str, "_LoadedModel"] = {}
_MODEL_LOCK = threading.Lock()

ProgressFn = Callable[[int, int], None]


@dataclass
class LineTranscription:
    """What the recogniser made of one line crop."""

    text: str
    confidence: float
    crop_path: str


@dataclass
class CropReading:
    """What the recogniser made of one crop, word by word."""

    text: str
    confidence: float
    # (word, confidence) in reading order. A word's confidence is the geometric
    # mean probability of its own tokens, so one smudged word shows up as an
    # uncertain span instead of dragging down the whole line.
    words: list[tuple[str, float]]


@dataclass
class _LoadedModel:
    processor: object
    model: object
    device: torch.device


def resolve_device() -> torch.device:
    """Picks the best available device.

    `EXAM_CORRECTOR_OCR_DEVICE` overrides, which matters on Apple silicon: MPS
    is much faster than CPU but occasionally miscompiles an op, and forcing CPU
    is the fastest way to tell a model problem from a backend one.
    """
    override = os.environ.get("EXAM_CORRECTOR_OCR_DEVICE", "").strip().lower()
    if override:
        return torch.device(override)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def load_model(model_name: str = DEFAULT_MODEL) -> _LoadedModel:
    """Loads TrOCR once per model name and keeps it resident.

    Imports are deferred to call time: `transformers` costs seconds to import,
    and a text-layer PDF never reaches this module at all.
    """
    cached = _MODEL_CACHE.get(model_name)
    if cached is not None:
        return cached

    with _MODEL_LOCK:
        if model_name in _MODEL_CACHE:
            return _MODEL_CACHE[model_name]

        from transformers import TrOCRProcessor, VisionEncoderDecoderModel

        device = resolve_device()
        processor = TrOCRProcessor.from_pretrained(model_name)
        model = VisionEncoderDecoderModel.from_pretrained(model_name)
        model.to(device)
        model.eval()

        loaded = _LoadedModel(processor=processor, model=model, device=device)
        _MODEL_CACHE[model_name] = loaded
        return loaded


def recognize_lines(
    page_image: np.ndarray,
    boxes: list,
    crops_dir: str,
    page_index: int,
    model_name: str = DEFAULT_MODEL,
    batch_size: int = DEFAULT_BATCH_SIZE,
    on_progress: ProgressFn | None = None,
) -> list[LineTranscription]:
    """Transcribes every line box on one page, in order."""
    if not boxes:
        return []

    os.makedirs(crops_dir, exist_ok=True)
    loaded = load_model(model_name)

    crops: list[Image.Image] = []
    crop_paths: list[str] = []

    for index, box in enumerate(boxes):
        patch = page_image[box.y : box.y + box.height, box.x : box.x + box.width]
        if patch.size == 0:
            patch = np.full((8, 8, 3), 255, dtype=np.uint8)

        rgb = cv2.cvtColor(patch, cv2.COLOR_BGR2RGB)
        path = os.path.join(crops_dir, f"p{page_index:03d}_l{index:03d}.png")
        Image.fromarray(rgb).save(path)

        crops.append(Image.fromarray(rgb))
        crop_paths.append(path)

    readings = read_crops(
        crops,
        model_name=model_name,
        batch_size=batch_size,
        on_progress=on_progress,
    )
    return [
        LineTranscription(
            text=reading.text,
            confidence=reading.confidence,
            crop_path=crop_paths[index],
        )
        for index, reading in enumerate(readings)
    ]


def read_crops(
    crops: list[Image.Image],
    model_name: str = DEFAULT_MODEL,
    batch_size: int = DEFAULT_BATCH_SIZE,
    on_progress: ProgressFn | None = None,
) -> list[CropReading]:
    """Reads single-line crops, returning text, confidence and word scores."""
    if not crops:
        return []
    loaded = load_model(model_name)
    results: list[CropReading] = []
    total = len(crops)

    for start in range(0, total, batch_size):
        batch = crops[start : start + batch_size]
        results.extend(_transcribe_batch(loaded, batch))
        if on_progress is not None:
            on_progress(min(start + batch_size, total), total)

    return results


@torch.inference_mode()
def _transcribe_batch(
    loaded: _LoadedModel,
    crops: list[Image.Image],
) -> list[CropReading]:
    processor = loaded.processor
    model = loaded.model

    pixel_values = processor(images=crops, return_tensors="pt").pixel_values
    pixel_values = pixel_values.to(loaded.device)

    # Greedy decoding, deliberately. Beam search would raise accuracy slightly
    # but makes the per-token scores a beam-indexed tangle; a straight sequence
    # is what keeps the confidence figure honest and cheap.
    output = model.generate(
        pixel_values,
        max_new_tokens=MAX_NEW_TOKENS,
        num_beams=1,
        do_sample=False,
        output_scores=True,
        return_dict_in_generate=True,
    )

    texts = processor.batch_decode(output.sequences, skip_special_tokens=True)
    confidences = _sequence_confidences(model, processor, output)
    words = _sequence_words(model, processor, output)

    return [
        CropReading(text=text.strip(), confidence=confidence, words=word_scores)
        for text, confidence, word_scores in zip(texts, confidences, words)
    ]


def _sequence_words(model, processor, output) -> list[list[tuple[str, float]]]:
    """Per-word confidences for each sequence in the batch."""
    scores = model.compute_transition_scores(
        output.sequences, output.scores, normalize_logits=True
    )
    generated = output.sequences[:, 1:][:, : scores.shape[1]]
    tokenizer = processor.tokenizer
    special = set(getattr(tokenizer, "all_special_ids", []) or [])

    results: list[list[tuple[str, float]]] = []
    for row in range(generated.shape[0]):
        pieces: list[str] = []
        log_probs: list[float] = []
        for step in range(generated.shape[1]):
            token_id = int(generated[row, step])
            if token_id in special:
                continue
            value = float(scores[row, step])
            if not math.isfinite(value):
                value = 0.0
            pieces.append(tokenizer.convert_ids_to_tokens(token_id))
            log_probs.append(value)
        results.append(
            words_from_tokens(pieces, log_probs, tokenizer.convert_tokens_to_string)
        )
    return results


# The marker BPE tokenisers put on a token that starts a new word.
_WORD_START = ("\u0120", "\u2581", " ")


def words_from_tokens(
    pieces: list[str],
    log_probs: list[float],
    to_text: Callable[[list[str]], str] | None = None,
) -> list[tuple[str, float]]:
    """Groups BPE tokens into words, scoring each word by its own tokens.

    Pure: tested with hand-built tokens rather than a model.
    """
    if to_text is None:
        to_text = lambda tokens: "".join(tokens).replace("\u0120", " ")  # noqa: E731

    words: list[tuple[str, float]] = []
    current: list[str] = []
    current_scores: list[float] = []

    def flush() -> None:
        if not current:
            return
        text = to_text(current).strip()
        if text:
            mean = sum(current_scores) / len(current_scores)
            words.append((text, max(0.0, min(1.0, math.exp(mean)))))

    for piece, score in zip(pieces, log_probs):
        if current and piece.startswith(_WORD_START):
            flush()
            current, current_scores = [], []
        current.append(piece)
        current_scores.append(score)
    flush()
    return words


def _sequence_confidences(model, processor, output) -> list[float]:
    """Mean per-token probability for each sequence in the batch.

    `compute_transition_scores` gives normalised log-probabilities per generated
    token. Averaging in log space and exponentiating yields the geometric mean
    token probability — length-independent, unlike a summed log-likelihood,
    so a six-word line and a two-word line are directly comparable.
    """
    scores = model.compute_transition_scores(
        output.sequences, output.scores, normalize_logits=True
    )

    # `sequences` carries the decoder start token; `scores` does not.
    generated = output.sequences[:, 1:]
    generated = generated[:, : scores.shape[1]]

    pad_id = processor.tokenizer.pad_token_id
    mask = generated != pad_id if pad_id is not None else torch.ones_like(generated, dtype=torch.bool)

    # A masked position can hold -inf, which would poison the sum.
    scores = scores.masked_fill(~mask, 0.0)
    scores = torch.nan_to_num(scores, neginf=0.0, posinf=0.0)

    counts = mask.sum(dim=1).clamp(min=1)
    mean_log_prob = scores.sum(dim=1) / counts

    confidences = mean_log_prob.exp().clamp(0.0, 1.0)

    # An empty generation is not a confident one, whatever the arithmetic says.
    empty = mask.sum(dim=1) == 0
    confidences = confidences.masked_fill(empty, 0.0)

    return [float(value) for value in confidences.cpu()]
