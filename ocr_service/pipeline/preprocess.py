"""Page clean-up before detection: deskew, denoise, even out contrast.

Runs *before* line detection so that every box and crop downstream is measured
against the same corrected image the teacher will see in the review screen.

Deliberately stops short of hard binarisation. TrOCR was trained on natural
grayscale line images, and thresholding a faint pencil script to pure black and
white throws away stroke detail the recogniser uses.
"""

from __future__ import annotations

import cv2
import numpy as np

# Scans are rarely off by more than a couple of degrees; searching wider mostly
# invites the page border to win over the text.
MAX_SKEW_DEGREES = 5.0
SKEW_STEP_DEGREES = 0.25

# The skew search runs on a downscaled copy — the angle is the same and the
# search is roughly twenty times cheaper.
SKEW_SEARCH_WIDTH = 1000

# Below this the rotation is not worth the resampling blur.
MIN_CORRECTABLE_SKEW = 0.15


def preprocess(image: np.ndarray) -> np.ndarray:
    """Returns a deskewed, denoised, contrast-normalised BGR copy of `image`."""
    deskewed = deskew(image)
    gray = cv2.cvtColor(deskewed, cv2.COLOR_BGR2GRAY)

    # Bilateral rather than non-local-means: it suppresses scanner speckle while
    # keeping pen strokes sharp, and it is fast enough to run on every page of a
    # long script.
    denoised = cv2.bilateralFilter(gray, d=5, sigmaColor=40, sigmaSpace=40)

    # CLAHE instead of global equalisation, so a shadow down one side of a phone
    # photograph does not wash out the opposite margin.
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    normalised = clahe.apply(denoised)

    return cv2.cvtColor(normalised, cv2.COLOR_GRAY2BGR)


def deskew(image: np.ndarray) -> np.ndarray:
    """Rotates `image` so its text lines run horizontal."""
    angle = estimate_skew(image)
    if abs(angle) < MIN_CORRECTABLE_SKEW:
        return image

    height, width = image.shape[:2]
    centre = (width / 2.0, height / 2.0)
    matrix = cv2.getRotationMatrix2D(centre, angle, 1.0)

    return cv2.warpAffine(
        image,
        matrix,
        (width, height),
        flags=cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_REPLICATE,
    )


def estimate_skew(image: np.ndarray) -> float:
    """Estimates the page's skew in degrees, positive meaning counter-clockwise.

    Uses a projection profile: when the page is straight, each text line falls
    entirely within a few pixel rows, so the row-sum profile is at its spikiest.
    Rotating away from straight smears ink across neighbouring rows and flattens
    it. The angle with the sharpest profile wins.
    """
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)

    scale = min(1.0, SKEW_SEARCH_WIDTH / max(gray.shape[1], 1))
    if scale < 1.0:
        gray = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)

    # Ink becomes white so the row sums measure content, not paper.
    binary = cv2.threshold(
        gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU
    )[1]
    if not binary.any():
        return 0.0

    best_angle = 0.0
    best_score = -1.0

    steps = int(MAX_SKEW_DEGREES / SKEW_STEP_DEGREES)
    for step in range(-steps, steps + 1):
        angle = step * SKEW_STEP_DEGREES
        score = _profile_sharpness(binary, angle)
        if score > best_score:
            best_score = score
            best_angle = angle

    return best_angle


def _profile_sharpness(binary: np.ndarray, angle: float) -> float:
    rotated = binary if angle == 0.0 else _rotate_flat(binary, angle)
    profile = rotated.sum(axis=1, dtype=np.float64)

    # Squared row-to-row change: high when lines are crisply separated from the
    # blank space between them, low when they bleed together.
    return float(np.square(np.diff(profile)).sum())


def _rotate_flat(binary: np.ndarray, angle: float) -> np.ndarray:
    height, width = binary.shape[:2]
    matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), angle, 1.0)
    return cv2.warpAffine(
        binary,
        matrix,
        (width, height),
        flags=cv2.INTER_NEAREST,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
