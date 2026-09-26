# PyInstaller spec for the sidecar: a self-contained `exam-corrector-ocr`
# folder the application finds beside its executable, so a teacher needs no
# Python installation.
#
#   ocr_service/.venv/bin/python ocr_service/packaging/build_sidecar.py
#
# Model weights are not bundled: TrOCR (~1.4 GB) and DBNet (~100 MB) download
# to the user's cache on first use, exactly as in development.

import os

from PyInstaller.utils.hooks import collect_data_files, collect_submodules, copy_metadata

SERVICE = os.path.abspath(os.path.join(SPECPATH, os.pardir))

hidden = []
hidden += collect_submodules("uvicorn")
hidden += collect_submodules("doctr")
for package in (
    "transformers.models.trocr",
    "transformers.models.vision_encoder_decoder",
    "transformers.models.vit",
    "transformers.models.deit",
    "transformers.models.roberta",
    "transformers.models.xlm_roberta",
    "transformers.models.auto",
):
    hidden += collect_submodules(package)
hidden += collect_submodules("pipeline")

datas = []
datas += collect_data_files("doctr")
# transformers checks its dependencies' versions at import time.
for distribution in (
    "transformers",
    "tokenizers",
    "huggingface-hub",
    "safetensors",
    "torch",
    "numpy",
    "tqdm",
    "regex",
    "requests",
    "packaging",
    "filelock",
    "pyyaml",
    "python-doctr",
):
    try:
        datas += copy_metadata(distribution)
    except Exception:  # noqa: BLE001 - a missing optional distribution is fine
        pass

analysis = Analysis(
    [os.path.join(SERVICE, "app.py")],
    pathex=[SERVICE],
    hiddenimports=hidden,
    datas=datas,
    excludes=["tkinter", "matplotlib", "IPython", "notebook", "pytest"],
    noarchive=False,
)

pyz = PYZ(analysis.pure)

executable = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="exam-corrector-ocr",
    # No console window when the app starts it on Windows. The app talks to
    # it over loopback HTTP and drains its pipes; app.py copes with missing
    # standard streams.
    console=False,
    upx=False,
)

COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    name="exam-corrector-ocr",
    upx=False,
)
