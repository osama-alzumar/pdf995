"""PDF → PDF tools on the server: repair, OCR, PDF/A and text-preserving compression."""
from __future__ import annotations

import json
import shutil
from pathlib import Path

import pikepdf

from .. import errors
from ..config import settings
from .common import decrypted_copy, is_pdf, run, validate_pdf

OCR_LANGUAGES = {"ar": "ara", "en": "eng"}


def repair(source: Path, work: Path, password: str | None = None) -> Path:
    """qpdf rebuilds the cross-reference table and object streams; Ghostscript re-interprets
    the whole file when qpdf cannot. The result must open and have pages."""
    if not is_pdf(source):
        # Junk before the header: keep everything from the first %PDF-.
        data = source.read_bytes()
        start = data.find(b"%PDF-")
        if start < 0:
            raise errors.cannot_open()
        trimmed = work / "trimmed.pdf"
        trimmed.write_bytes(data[start:])
        source = trimmed

    out = work / "repaired.pdf"
    args = ["qpdf"] + ([f"--password={password}"] if password else []) + ["--decrypt", str(source), str(out)]
    try:
        # qpdf exits 3 when it succeeded with warnings, which is exactly the "repaired" case.
        run(args, ok_codes=(0, 3))
        validate_pdf(out)
        return out
    except errors.ToolError:
        out.unlink(missing_ok=True)

    gs_out = work / "repaired-gs.pdf"
    try:
        run(["gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite",
             *([f"-sPDFPassword={password}"] if password else []),
             f"-sOutputFile={gs_out}", str(source)])
        validate_pdf(gs_out)
        return gs_out
    except errors.ToolError:
        raise errors.cannot_open()


def ocr(source: Path, work: Path, languages: list[str], password: str | None = None) -> tuple[Path, str]:
    """Searchable PDF with OCRmyPDF + Tesseract. Pages that already have text are kept as they are.
    Returns the PDF and the recognized text."""
    langs = "+".join(OCR_LANGUAGES[l] for l in languages if l in OCR_LANGUAGES) or "ara+eng"
    src = decrypted_copy(source, password, work)
    out = work / "ocr.pdf"
    sidecar = work / "ocr.txt"
    run(["ocrmypdf", "--skip-text", "--rotate-pages", "--deskew", "-l", langs,
         "--sidecar", str(sidecar), "--output-type", "pdf", "--optimize", "1",
         "--jobs", "2", str(src), str(out)], ok_codes=(0, 4, 10))
    pages_in = validate_pdf(src)
    validate_pdf(out, expected_pages=pages_in)
    text = sidecar.read_text(encoding="utf-8", errors="ignore") if sidecar.exists() else ""
    return out, text


def pdfa(source: Path, work: Path, password: str | None = None) -> tuple[Path, dict]:
    """PDF/A-2b via OCRmyPDF's Ghostscript pipeline (no OCR is added: --skip-text). If veraPDF is
    installed the result is validated against the standard and the verdict is returned."""
    src = decrypted_copy(source, password, work)
    out = work / "pdfa.pdf"
    run(["ocrmypdf", "--skip-text", "--output-type", "pdfa-2", "--pdfa-image-compression", "auto",
         "--optimize", "0", str(src), str(out)], ok_codes=(0, 4, 10))
    validate_pdf(out, expected_pages=validate_pdf(src))
    with pikepdf.open(out) as pdf:
        meta = pdf.open_metadata()
        part = meta.get("pdfaid:part")
        conformance = meta.get("pdfaid:conformance")
    if part != "2":
        raise errors.validation_failed()
    report = {"part": part, "conformance": conformance, "verapdf": None}
    if settings.verapdf and shutil.which(settings.verapdf):
        proc = run([settings.verapdf, "--flavour", "2b", "--format", "json", str(out)], ok_codes=(0, 1))
        try:
            jobs = json.loads(proc.stdout)["report"]["jobs"]
            compliant = jobs[0]["validationResult"][0]["compliant"] if isinstance(jobs[0]["validationResult"], list) \
                else jobs[0]["validationResult"]["compliant"]
            report["verapdf"] = bool(compliant)
        except Exception:
            report["verapdf"] = None
        if report["verapdf"] is False:
            raise errors.validation_failed()
    return out, report


GS_PRESETS = {"light": "/printer", "recommended": "/ebook", "strong": "/screen"}


def compress(source: Path, work: Path, level: str, password: str | None = None) -> Path:
    """Ghostscript re-writes the file with downsampled images; text stays text at every level."""
    src = decrypted_copy(source, password, work)
    out = work / "compressed.pdf"
    run(["gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6",
         f"-dPDFSETTINGS={GS_PRESETS.get(level, '/ebook')}", "-dDetectDuplicateImages=true",
         f"-sOutputFile={out}", str(src)])
    validate_pdf(out, expected_pages=validate_pdf(src))
    if out.stat().st_size >= source.stat().st_size:
        shutil.copyfile(source, out)  # never hand back a bigger "compressed" file
    return out
