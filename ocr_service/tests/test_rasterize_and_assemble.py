"""Rasterisation and the response contract."""

from __future__ import annotations

import os
import types

import numpy as np
import pymupdf
import pytest
from PIL import Image

from pipeline.assemble import build_document, build_page, to_marked_text
from pipeline.detect import LineBox
from pipeline.rasterize import rasterize


def _write_pdf(path: str, pages: int = 2) -> str:
    document = pymupdf.open()
    for index in range(pages):
        page = document.new_page(width=595, height=842)  # A4 at 72 dpi
        page.insert_text((72, 144), f"Page {index + 1}", fontsize=24)
    document.save(path)
    document.close()
    return path


def test_renders_one_image_per_pdf_page(tmp_path):
    source = _write_pdf(str(tmp_path / "paper.pdf"), pages=3)

    pages = rasterize(source, str(tmp_path / "work"), dpi=150)

    assert len(pages) == 3
    assert [page.index for page in pages] == [0, 1, 2]
    for page in pages:
        assert os.path.isfile(page.path)
        assert page.image.shape[:2] == (page.height, page.width)


def test_dpi_controls_the_rendered_size(tmp_path):
    source = _write_pdf(str(tmp_path / "paper.pdf"), pages=1)

    low = rasterize(source, str(tmp_path / "low"), dpi=100)[0]
    high = rasterize(source, str(tmp_path / "high"), dpi=300)[0]

    assert high.width > low.width * 2.5


def test_dpi_is_clamped_to_the_supported_range(tmp_path):
    source = _write_pdf(str(tmp_path / "paper.pdf"), pages=1)

    absurd = rasterize(source, str(tmp_path / "capped"), dpi=5000)[0]
    at_max = rasterize(source, str(tmp_path / "max"), dpi=400)[0]

    assert absurd.width == at_max.width


def test_accepts_a_photograph_as_a_single_page(tmp_path):
    path = str(tmp_path / "scan.png")
    Image.fromarray(np.full((400, 300, 3), 255, dtype=np.uint8)).save(path)

    pages = rasterize(path, str(tmp_path / "work"))

    assert len(pages) == 1
    assert pages[0].width == 300
    assert pages[0].height == 400


def test_rejects_an_unsupported_file_type(tmp_path):
    path = tmp_path / "notes.txt"
    path.write_text("not a paper")

    with pytest.raises(ValueError, match="Unsupported file type"):
        rasterize(str(path), str(tmp_path / "work"))


def test_reports_a_missing_file_clearly(tmp_path):
    with pytest.raises(ValueError, match="File not found"):
        rasterize(str(tmp_path / "absent.pdf"), str(tmp_path / "work"))


def _transcription(text: str, confidence: float):
    return types.SimpleNamespace(
        text=text, confidence=confidence, crop_path=f"/crops/{text or 'blank'}.png"
    )


def test_a_page_keeps_its_lines_in_detection_order():
    boxes = [LineBox(0, 0, 10, 10), LineBox(0, 20, 10, 10)]
    transcriptions = [_transcription("first", 0.9), _transcription("second", 0.8)]

    page = build_page(0, "/pages/page_000.png", 800, 1000, boxes, transcriptions)

    assert [line["text"] for line in page["lines"]] == ["first", "second"]
    assert page["lines"][0]["box"] == [0, 0, 10, 10]


def test_lines_that_recognised_to_nothing_are_dropped():
    boxes = [LineBox(0, 0, 10, 10), LineBox(0, 20, 10, 10)]
    transcriptions = [_transcription("kept", 0.9), _transcription("   ", 0.1)]

    page = build_page(0, "/pages/page_000.png", 800, 1000, boxes, transcriptions)

    assert len(page["lines"]) == 1
    assert page["lines"][0]["text"] == "kept"


def test_document_summarises_line_count_and_mean_confidence():
    boxes = [LineBox(0, 0, 10, 10)]
    first = build_page(0, "a.png", 8, 10, boxes, [_transcription("one", 1.0)])
    second = build_page(1, "b.png", 8, 10, boxes, [_transcription("two", 0.5)])

    document = build_document([first, second], "trocr", 300, "db_resnet50")

    assert document["line_count"] == 2
    assert document["mean_confidence"] == pytest.approx(0.75)
    assert document["engine"] == "trocr"


def test_a_document_with_no_lines_has_zero_mean_confidence():
    empty = build_page(0, "a.png", 8, 10, [], [])

    document = build_document([empty], "trocr", 300, "db_resnet50")

    assert document["line_count"] == 0
    assert document["mean_confidence"] == 0.0


def test_debug_text_uses_the_same_page_marker_as_the_app():
    boxes = [LineBox(0, 0, 10, 10)]
    page = build_page(0, "a.png", 8, 10, boxes, [_transcription("answer", 0.9)])

    text = to_marked_text(build_document([page], "trocr", 300, "db_resnet50"))

    assert text == "--- Page 1 ---\nanswer"
