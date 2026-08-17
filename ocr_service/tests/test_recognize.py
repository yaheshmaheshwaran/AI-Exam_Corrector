"""The confidence figure decides what gets a second opinion and what the
teacher is warned about, so its arithmetic is tested directly rather than
inferred from model output."""

from __future__ import annotations

import math
import types

import pytest
import torch

from pipeline.recognize import _sequence_confidences


class _FakeTokenizer:
    pad_token_id = 0


class _FakeProcessor:
    tokenizer = _FakeTokenizer()


def _model_returning(scores: torch.Tensor):
    """A stand-in exposing only the one method under test."""
    return types.SimpleNamespace(
        compute_transition_scores=lambda sequences, raw, normalize_logits: scores
    )


def _output(sequences: torch.Tensor):
    return types.SimpleNamespace(sequences=sequences, scores=())


def test_confidence_is_the_geometric_mean_token_probability():
    log_probs = torch.log(torch.tensor([[0.9, 0.9, 0.9, 0.9]]))
    sequences = torch.tensor([[2, 5, 6, 7, 8]])  # leading decoder-start token

    confidences = _sequence_confidences(
        _model_returning(log_probs), _FakeProcessor(), _output(sequences)
    )

    assert confidences[0] == pytest.approx(0.9, abs=1e-4)


def test_confidence_is_independent_of_line_length():
    # A short line and a long line of equally certain tokens must score the
    # same, otherwise the threshold would just be flagging long lines.
    short = _sequence_confidences(
        _model_returning(torch.log(torch.tensor([[0.8, 0.8]]))),
        _FakeProcessor(),
        _output(torch.tensor([[2, 5, 6]])),
    )
    long = _sequence_confidences(
        _model_returning(torch.log(torch.tensor([[0.8] * 10]))),
        _FakeProcessor(),
        _output(torch.tensor([[2] + [5] * 10])),
    )

    assert short[0] == pytest.approx(long[0], abs=1e-4)


def test_padding_positions_are_excluded():
    # Two real tokens then padding; the padding must not drag the score down.
    log_probs = torch.log(torch.tensor([[0.9, 0.9, 0.01, 0.01]]))
    sequences = torch.tensor([[2, 5, 6, 0, 0]])

    confidences = _sequence_confidences(
        _model_returning(log_probs), _FakeProcessor(), _output(sequences)
    )

    assert confidences[0] == pytest.approx(0.9, abs=1e-4)


def test_negative_infinity_at_a_masked_position_does_not_poison_the_mean():
    log_probs = torch.tensor([[math.log(0.9), math.log(0.9), -math.inf]])
    sequences = torch.tensor([[2, 5, 6, 0]])

    confidences = _sequence_confidences(
        _model_returning(log_probs), _FakeProcessor(), _output(sequences)
    )

    assert math.isfinite(confidences[0])
    assert confidences[0] == pytest.approx(0.9, abs=1e-4)


def test_an_empty_generation_scores_zero():
    log_probs = torch.tensor([[0.0, 0.0]])
    sequences = torch.tensor([[2, 0, 0]])

    confidences = _sequence_confidences(
        _model_returning(log_probs), _FakeProcessor(), _output(sequences)
    )

    assert confidences[0] == 0.0


def test_confidences_are_returned_per_sequence_in_batch_order():
    log_probs = torch.log(torch.tensor([[0.9, 0.9], [0.2, 0.2]]))
    sequences = torch.tensor([[2, 5, 6], [2, 7, 8]])

    confidences = _sequence_confidences(
        _model_returning(log_probs), _FakeProcessor(), _output(sequences)
    )

    assert len(confidences) == 2
    assert confidences[0] > confidences[1]
    assert all(0.0 <= value <= 1.0 for value in confidences)
