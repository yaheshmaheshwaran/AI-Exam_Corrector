"""Builds a handwritten script whose answers are drawings, tables and working.

The first sample is prose; this one exercises everything prose does not: a
labelled diagram, a results table, a plotted graph, lines of working, and a
line the student struck out. Every element is drawn at a known place, so what
the pipeline should find is known exactly (see sample/visual_expected.md).

    ocr_service/.venv/bin/python ocr_service/tools/make_visual_sample.py

Writes sample/visual_question_paper.pdf and sample/visual_student_paper.pdf.
"""

from __future__ import annotations

import math
import os
import random
import sys

import numpy as np
import pymupdf
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

WIDTH, HEIGHT = 1240, 1754  # A4 at 150 dpi
MARGIN = 90
INK = (26, 32, 86)

PRINT_FONT = "/System/Library/Fonts/Supplemental/Times New Roman.ttf"
HAND_FONT = "/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf"

QUESTIONS = [
    ("1", "Draw and label a diagram of an animal cell. Label the nucleus, the "
          "cell membrane and the cytoplasm.", 3),
    ("2", "A student timed how long a reaction took at 20, 30 and 40 °C. The "
          "times were 60 s, 40 s and 25 s. Record these results in a table "
          "with suitable headings.", 2),
    ("3", "Plot a graph of the results in question 2, with temperature on the "
          "x-axis. Label both axes.", 3),
    ("4", "A car travels 150 m in 12 s. Calculate its average speed. Show your "
          "working.", 3),
]


def font(path: str, size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def question_paper(path: str) -> None:
    document = pymupdf.open()
    page = document.new_page(width=595, height=842)
    y = 72
    page.insert_text((72, y), "Year 10 Science - Practical Skills", fontsize=14)
    y += 22
    page.insert_text((72, y), "Total marks available: 11", fontsize=11)
    y += 30
    for number, text, marks in QUESTIONS:
        words = text.split()
        lines, line = [], number + "  "
        for word in words:
            if len(line) + len(word) > 78:
                lines.append(line)
                line = "   "
            line += word + " "
        lines.append(line + f"[{marks} marks]")
        for text_line in lines:
            page.insert_text((72, y), text_line, fontsize=11)
            y += 15
        y += 12
    document.save(path)
    document.close()


def _hand(draw: ImageDraw.ImageDraw, xy, text: str, size: int = 30) -> None:
    draw.text((xy[0] + random.randint(-2, 3), xy[1] + random.randint(-2, 2)), text,
              font=font(HAND_FONT, size), fill=INK)


def _printed(draw: ImageDraw.ImageDraw, y: int, number: str) -> int:
    printed = font(PRINT_FONT, 21)
    text, marks = next((q[1], q[2]) for q in QUESTIONS if q[0] == number)
    words, line, lines = text.split(), f"{number}  ", []
    for word in words:
        if len(line) + len(word) > 62:
            lines.append(line)
            line = "    "
        line += word + " "
    lines.append(line + f"[{marks} marks]")
    for text_line in lines:
        draw.text((MARGIN, y), text_line, font=printed, fill=(20, 20, 20))
        y += 27
    return y + 18


def page_one() -> Image.Image:
    page = Image.new("RGB", (WIDTH, HEIGHT), "white")
    draw = ImageDraw.Draw(page)
    random.seed(3)

    y = _printed(draw, MARGIN, "1")
    # An animal cell: membrane, nucleus, and three labels with pointer lines.
    cx, cy = 430, y + 210
    draw.ellipse((cx - 260, cy - 170, cx + 260, cy + 170), outline=INK, width=4)
    draw.ellipse((cx - 50, cy - 40, cx + 60, cy + 55), outline=INK, width=4)
    for dx, dy in ((-150, -60), (120, 80), (-90, 100), (170, -70)):
        draw.ellipse((cx + dx - 12, cy + dy - 8, cx + dx + 12, cy + dy + 8), outline=INK, width=2)
    draw.line((cx + 10, cy + 5, cx + 360, cy - 60), fill=INK, width=3)
    _hand(draw, (cx + 370, cy - 85), "nucleus")
    draw.line((cx + 255, cy + 40, cx + 360, cy + 60), fill=INK, width=3)
    _hand(draw, (cx + 370, cy + 40), "cell wall")
    draw.line((cx - 120, cy + 20, cx + 360, cy + 150), fill=INK, width=3)
    _hand(draw, (cx + 370, cy + 130), "cytoplasm")

    y = cy + 230
    y = _printed(draw, y, "2")
    # A results table, ruled by hand.
    left, top = MARGIN + 40, y + 10
    widths, row_height = (300, 240), 58
    rows = [("Temperature (°C)", "Time (s)"), ("20", "60"), ("30", "40"), ("40", "25")]
    for r in range(len(rows) + 1):
        draw.line((left, top + r * row_height, left + sum(widths), top + r * row_height + random.randint(-2, 2)), fill=INK, width=3)
    for c in range(len(widths) + 1):
        x = left + sum(widths[:c])
        draw.line((x, top, x + random.randint(-2, 2), top + len(rows) * row_height), fill=INK, width=3)
    for r, (a, b) in enumerate(rows):
        _hand(draw, (left + 16, top + r * row_height + 12), a, size=28)
        _hand(draw, (left + widths[0] + 16, top + r * row_height + 12), b, size=28)
    return page


def page_two() -> Image.Image:
    page = Image.new("RGB", (WIDTH, HEIGHT), "white")
    draw = ImageDraw.Draw(page)
    random.seed(5)

    y = _printed(draw, MARGIN, "3")
    # A graph: axes, a labelled x-axis only, three points and a curve.
    origin_x, origin_y = MARGIN + 140, y + 460
    draw.line((origin_x, origin_y, origin_x + 700, origin_y), fill=INK, width=4)
    draw.line((origin_x, origin_y, origin_x, origin_y - 420), fill=INK, width=4)
    for i, label in enumerate(("20", "30", "40")):
        x = origin_x + 150 + i * 200
        draw.line((x, origin_y - 8, x, origin_y + 8), fill=INK, width=3)
        _hand(draw, (x - 18, origin_y + 14), label, size=24)
    for i, label in enumerate(("20", "40", "60")):
        yy = origin_y - 110 - i * 110
        draw.line((origin_x - 8, yy, origin_x + 8, yy), fill=INK, width=3)
        _hand(draw, (origin_x - 60, yy - 14), label, size=24)
    points = [(origin_x + 150, origin_y - 330), (origin_x + 350, origin_y - 220), (origin_x + 550, origin_y - 137)]
    for px, py in points:
        draw.line((px - 10, py - 10, px + 10, py + 10), fill=INK, width=3)
        draw.line((px - 10, py + 10, px + 10, py - 10), fill=INK, width=3)
    curve = [(origin_x + 120 + t, origin_y - 137 - 193 * math.exp(-(t - 30) / 260)) for t in range(0, 480, 8)]
    draw.line(curve, fill=INK, width=3)
    _hand(draw, (origin_x + 220, origin_y + 50), "Temperature (°C)", size=28)

    y = origin_y + 120
    y = _printed(draw, y, "4")
    hand_x = MARGIN + 40
    _hand(draw, (hand_x, y), "speed = distance / time")
    y += 50
    # A wrong start, struck through.
    _hand(draw, (hand_x, y), "= 150 x 12 = 1800")
    draw.line((hand_x - 6, y + 22, hand_x + 300, y + 20), fill=INK, width=4)
    y += 50
    _hand(draw, (hand_x, y), "= 150 / 12")
    y += 50
    _hand(draw, (hand_x, y), "= 12.5 m/s")
    return page


def scan(page: Image.Image, seed: int) -> Image.Image:
    array = np.asarray(page).astype(np.float32)
    array *= np.linspace(1.0, 0.92, array.shape[1], dtype=np.float32)[None, :, None]
    array += np.random.default_rng(seed).normal(0.0, 4.0, array.shape).astype(np.float32)
    scanned = Image.fromarray(np.clip(array, 0, 255).astype(np.uint8))
    return scanned.rotate(0.6, resample=Image.BICUBIC, fillcolor=(255, 255, 255))


def main() -> None:
    sample = os.path.join(REPO, "sample")
    question_paper(os.path.join(sample, "visual_question_paper.pdf"))
    pages = [scan(page_one(), 1), scan(page_two(), 2)]
    output = os.path.join(sample, "visual_student_paper.pdf")
    pages[0].save(output, "PDF", resolution=150.0, save_all=True, append_images=pages[1:])
    print(f"wrote {output}")


if __name__ == "__main__":
    sys.exit(main())
