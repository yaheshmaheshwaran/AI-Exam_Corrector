"""Builds a scanned-looking handwritten exam paper for testing the pipeline.

There is no handwriting in the repository to test against, and a clean render of
a text PDF is not a fair test — it exercises none of what makes real scripts
hard. So this renders the sample paper's answers in a handwriting face, then
degrades the page the way a school scanner does: a slight rotation, sensor
noise, and uneven lighting.

    ocr_service/.venv/bin/python tools/make_handwritten_sample.py

Writes sample/student_paper_handwritten.pdf.
"""

from __future__ import annotations

import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# 150 dpi A4 — a realistic scanner default, and deliberately not the 300 dpi the
# pipeline prefers, so the resampling path gets exercised too.
WIDTH, HEIGHT = 1240, 1754
MARGIN = 90

PRINT_FONT = "/System/Library/Fonts/Supplemental/Times New Roman.ttf"
HAND_FONTS = [
    "/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf",
    "/System/Library/Fonts/Noteworthy.ttc",
]

# (printed question, handwritten answer) — taken from sample/student_paper.txt.
PAPER = [
    (
        "1  Name the organelle that carries out aerobic respiration, and",
        "state the molecule it produces.  [2 marks]",
        ["The mitochondrion. It makes ATP."],
    ),
    (
        "2 (a)  Write the word equation for aerobic respiration.",
        "[1 mark]",
        ["glucose + oxygen -> carbon dioxide + water"],
    ),
    (
        "2 (b)  Explain why muscle cells contain a large number of",
        "mitochondria.  [2 marks]",
        [
            "Because muscle cells need a lot of energy,",
            "especially when you are exercising.",
        ],
    ),
    (
        "3  A cell is 50 micrometres long. In a drawing the same cell",
        "measures 100 mm. Calculate the magnification.  [3 marks]",
        [
            "50 micrometres = 0.05 mm",
            "magnification = size of image / size of real object",
            "= 100 / 0.05",
            "= 2000",
            "Magnification = x2000",
        ],
    ),
    (
        "4  Describe two ways a root hair cell is adapted for taking up",
        "mineral ions from the soil.  [2 marks]",
        [
            "It has a long thin extension that sticks out into",
            "the soil, which increases the surface area. It also",
            "has lots of mitochondria to provide the energy.",
        ],
    ),
    (
        "5  State one function of the cell membrane.",
        "[1 mark]",
        [],
    ),
    (
        "7  Define osmosis.",
        "[3 marks]",
        [
            "Osmosis is when water moves from a dilute",
            "solution to a more concentrated solution.",
        ],
    ),
]


def load_font(path: str, size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def render_page() -> Image.Image:
    page = Image.new("RGB", (WIDTH, HEIGHT), "white")
    draw = ImageDraw.Draw(page)

    printed = load_font(PRINT_FONT, 21)
    header = load_font(PRINT_FONT, 26)
    hands = [load_font(path, 30) for path in HAND_FONTS]

    y = MARGIN
    draw.text((MARGIN, y), "NORTHGATE ACADEMY", font=header, fill=(20, 20, 20))
    y += 38
    draw.text(
        (MARGIN, y),
        "Year 10 Combined Science - Biology Paper 1",
        font=printed,
        fill=(20, 20, 20),
    )
    y += 46

    random.seed(7)

    for question, marks, answer_lines in PAPER:
        draw.text((MARGIN, y), question, font=printed, fill=(20, 20, 20))
        y += 28
        draw.text((MARGIN, y), marks, font=printed, fill=(20, 20, 20))
        y += 36

        draw.text((MARGIN + 20, y), "Answer:", font=printed, fill=(20, 20, 20))
        y += 34

        for line in answer_lines:
            hand = random.choice(hands)
            # Real handwriting does not sit on a perfect baseline.
            jitter_x = random.randint(-3, 4)
            jitter_y = random.randint(-2, 3)
            ink = random.choice([(28, 34, 90), (22, 28, 76)])  # blue-black pen
            draw.text(
                (MARGIN + 40 + jitter_x, y + jitter_y),
                line,
                font=hand,
                fill=ink,
            )
            y += 42

        y += 26
        if y > HEIGHT - 200:
            break

    return page


def scan_artefacts(page: Image.Image) -> Image.Image:
    """Degrades a clean render into something that looks scanned."""
    array = np.asarray(page).astype(np.float32)

    # Uneven lighting: a soft gradient across the page, as from a lid not quite
    # closed on a flatbed.
    gradient = np.linspace(1.0, 0.90, array.shape[1], dtype=np.float32)
    array *= gradient[None, :, None]

    # Sensor noise.
    rng = np.random.default_rng(11)
    array += rng.normal(0.0, 4.0, array.shape).astype(np.float32)

    scanned = Image.fromarray(np.clip(array, 0, 255).astype(np.uint8))

    # Paper never goes in perfectly straight.
    return scanned.rotate(-0.8, resample=Image.BICUBIC, fillcolor=(255, 255, 255))


def main() -> None:
    page = scan_artefacts(render_page())

    output = os.path.join(REPO, "sample", "student_paper_handwritten.pdf")
    page.save(output, "PDF", resolution=150.0)

    preview = os.path.join(REPO, "sample", "student_paper_handwritten.png")
    page.save(preview)

    print(f"wrote {output}")
    print(f"wrote {preview}")


if __name__ == "__main__":
    sys.exit(main())
