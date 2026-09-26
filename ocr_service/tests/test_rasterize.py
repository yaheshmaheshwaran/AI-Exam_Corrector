"""Rasterisation."""

from __future__ import annotations

import os

import numpy as np
import pymupdf
import pytest
from PIL import Image

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



def test_pages_stream_one_at_a_time(tmp_path):
    from pipeline.rasterize import iter_pages

    source = _write_pdf(str(tmp_path / "paper.pdf"), pages=3)
    pages = iter_pages(source, str(tmp_path / "work"), dpi=100)

    first = next(pages)
    # Only the first page has been rendered so far.
    assert first.index == 0
    assert first.page_count == 3
    assert not os.path.exists(str(tmp_path / "work" / "pages" / "page_001.png"))
    assert [page.index for page in pages] == [1, 2]


def test_text_layer_characters_are_counted(tmp_path):
    source = _write_pdf(str(tmp_path / "paper.pdf"), pages=1)
    [page] = rasterize(source, str(tmp_path / "work"), dpi=100)
    assert page.text_chars > 0
    assert "Page 1" in page.text
