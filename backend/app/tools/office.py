"""Word / PowerPoint / Excel → PDF with LibreOffice (MPL-2.0).

Each conversion uses its own LibreOffice profile folder, so several can run at once without
fighting over the shared user profile lock.
"""
from __future__ import annotations

import os
from pathlib import Path

from .. import errors
from ..config import settings
from .common import run, validate_pdf

WORD = {".doc", ".docx", ".odt", ".rtf", ".txt"}
POWERPOINT = {".ppt", ".pptx", ".odp", ".pps", ".ppsx"}
EXCEL = {".xls", ".xlsx", ".ods", ".csv"}

ALLOWED = {"wordToPDF": WORD, "powerPointToPDF": POWERPOINT, "excelToPDF": EXCEL}


def to_pdf(tool: str, source: Path, work: Path) -> Path:
    if source.suffix.lower() not in ALLOWED[tool]:
        raise errors.unsupported(source.suffix)
    work = work.resolve()
    profile = work / "lo-profile"
    out_dir = work / "out"
    out_dir.mkdir()
    filter_ = "pdf"
    if tool == "excelToPDF":
        # One sheet per page width, keeps wide tables readable.
        filter_ = 'pdf:calc_pdf_Export:{"SinglePageSheets":{"type":"boolean","value":"false"}}'
    env = dict(os.environ, HOME=str(work), SAL_USE_VCLPLUGIN="svp")
    run([
        settings.soffice, "--headless", "--norestore", "--nolockcheck",
        f"-env:UserInstallation=file://{profile}",
        "--convert-to", filter_, "--outdir", str(out_dir), str(source),
    ], env=env)
    produced = list(out_dir.glob("*.pdf"))
    if not produced:
        raise errors.conversion_failed()
    validate_pdf(produced[0])
    return produced[0]
