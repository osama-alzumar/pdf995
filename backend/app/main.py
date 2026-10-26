"""Waraqa processing server.

POST /v1/tools/{tool}  multipart (files[], options) → the resulting file
POST /v1/ai/{summarize|ask|translate}  JSON (extracted page text) → JSON
GET  /v1/health

Privacy: uploads go to a private per-request folder that is deleted as soon as the response has
been sent, and by the sweeper after RETENTION_MINUTES at the latest. File names and contents are
never logged — only the tool, sizes, duration and outcome.
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager
import threading
import time
from collections import defaultdict, deque
from pathlib import Path
from typing import Literal
from urllib.parse import quote

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

from . import ai, errors, storage
from .config import settings
from .tools import from_pdf, office, pdf_tools
from .tools.common import validate_pdf

log = logging.getLogger("waraqa")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

@asynccontextmanager
async def lifespan(_: FastAPI):
    storage.sweep_once(0)  # nothing from a previous run survives a restart
    storage.start_sweeper()
    yield


app = FastAPI(title="Waraqa", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)

TOOLS = ["wordToPDF", "powerPointToPDF", "excelToPDF", "pdfToWord", "pdfToPowerPoint", "pdfToExcel",
         "pdfToPDFA", "ocr", "repair", "compress"]

MEDIA = {
    ".pdf": "application/pdf",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
}

_jobs = threading.BoundedSemaphore(settings.max_parallel_jobs)
_hits: dict[str, deque] = defaultdict(deque)
_hits_lock = threading.Lock()


@app.exception_handler(errors.ToolError)
async def _tool_error(_: Request, exc: errors.ToolError):
    return JSONResponse(exc.body(), status_code=exc.status)


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "")
    return forwarded.split(",")[0].strip() or (request.client.host if request.client else "?")


def _rate_limit(request: Request) -> None:
    now = time.monotonic()
    key = _client_ip(request)
    with _hits_lock:
        window = _hits[key]
        while window and now - window[0] > 60:
            window.popleft()
        if len(window) >= settings.rate_limit_per_minute:
            raise errors.ToolError("rate_limited", "طلبات كثيرة. انتظر دقيقة ثم أعد المحاولة.",
                                   "Too many requests. Wait a minute and try again.", 429)
        window.append(now)


@app.get("/v1/health")
def health():
    return {"status": "ok", "tools": TOOLS, "ai": settings.ai_enabled,
            "retention_minutes": settings.retention_minutes, "max_upload_mb": settings.max_upload_mb}


async def _receive_files(request: Request, work: Path) -> tuple[list[Path], dict[str, str]]:
    length = int(request.headers.get("content-length") or 0)
    if length > settings.max_upload_bytes + 1_000_000:
        raise errors.ToolError("too_large", "الملف أكبر من الحد المسموح.", "The file is too large.", 413)
    form = await request.form(max_files=20, max_fields=20)
    files: list[Path] = []
    options: dict[str, str] = {}
    first_name = "file"
    total = 0
    for key, value in form.multi_items():
        if hasattr(value, "read"):
            name = storage.safe_name(value.filename or "file", "file")
            target = work / f"in-{len(files)}{Path(name).suffix.lower()}"
            with open(target, "wb") as fh:
                while chunk := await value.read(1 << 20):
                    total += len(chunk)
                    if total > settings.max_upload_bytes:
                        raise errors.ToolError("too_large", "الملف أكبر من الحد المسموح.", "The file is too large.", 413)
                    fh.write(chunk)
            files.append(target)
            if len(files) == 1:
                first_name = name
        elif not key.startswith("_"):
            options[key] = str(value)[:500]
    await form.close()
    if not files:
        raise errors.ToolError("no_file", "لم يُرسل أي ملف.", "No file was sent.", 400)
    options["_name0"] = first_name
    return files, options


def _run_tool(tool: str, files: list[Path], options: dict[str, str], work: Path) -> tuple[Path, str, dict]:
    source = files[0]
    stem = Path(options.get("_name0", "file")).stem or "file"
    password = options.get("password") or None
    headers: dict[str, str] = {}
    if tool in office.ALLOWED:
        return office.to_pdf(tool, source, work), f"{stem}.pdf", headers
    if tool == "pdfToWord":
        return from_pdf.to_word(source, work, password), f"{stem}.docx", headers
    if tool == "pdfToPowerPoint":
        return from_pdf.to_powerpoint(source, work, password), f"{stem}.pptx", headers
    if tool == "pdfToExcel":
        out, tables = from_pdf.to_excel(source, work, password)
        headers["X-Waraqa-Tables"] = str(tables)
        return out, f"{stem}.xlsx", headers
    if tool == "pdfToPDFA":
        out, report = pdf_tools.pdfa(source, work, password)
        headers["X-Waraqa-PDFA"] = f"{report['part']}{(report['conformance'] or '').lower()}"
        if report["verapdf"] is not None:
            headers["X-Waraqa-VeraPDF"] = "pass" if report["verapdf"] else "fail"
        return out, f"{stem} - PDFA.pdf", headers
    if tool == "ocr":
        langs = [l for l in options.get("languages", "ar,en").split(",") if l]
        out, text = pdf_tools.ocr(source, work, langs, password)
        headers["X-Waraqa-Characters"] = str(len(text.strip()))
        return out, f"{stem} - OCR.pdf", headers
    if tool == "repair":
        out = pdf_tools.repair(source, work, password)
        headers["X-Waraqa-Pages"] = str(validate_pdf(out))
        return out, f"{stem} - repaired.pdf", headers
    if tool == "compress":
        out = pdf_tools.compress(source, work, options.get("level", "recommended"), password)
        headers["X-Waraqa-Original-Bytes"] = str(source.stat().st_size)
        return out, f"{stem} - compressed.pdf", headers
    raise errors.ToolError("unknown_tool", "أداة غير معروفة.", "Unknown tool.", 404)


@app.post("/v1/tools/{tool}")
async def run_tool(tool: str, request: Request):
    if tool not in TOOLS:
        raise errors.ToolError("unknown_tool", "أداة غير معروفة.", "Unknown tool.", 404)
    _rate_limit(request)
    work = storage.new_job_dir()
    started = time.monotonic()
    try:
        files, options = await _receive_files(request, work)
        if not _jobs.acquire(timeout=120):
            raise errors.ToolError("busy", "الخادم مشغول. أعد المحاولة بعد قليل.", "The server is busy.", 503)
        try:
            # Blocking work runs in a worker thread so the server keeps answering.
            from starlette.concurrency import run_in_threadpool
            out, name, headers = await run_in_threadpool(_run_tool, tool, files, options, work)
        finally:
            _jobs.release()
    except errors.ToolError as exc:
        storage.remove(work)
        log.info("tool=%s status=%s code=%s ms=%d", tool, exc.status, exc.code, (time.monotonic() - started) * 1000)
        raise
    except Exception:
        storage.remove(work)
        log.exception("tool=%s status=500", tool)
        raise errors.conversion_failed()

    log.info("tool=%s status=200 out_bytes=%d ms=%d", tool, out.stat().st_size, (time.monotonic() - started) * 1000)
    ascii_name = name.encode("ascii", "ignore").decode() or f"result{out.suffix}"
    headers["Content-Disposition"] = f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}"
    headers["Cache-Control"] = "no-store"
    return FileResponse(out, media_type=MEDIA.get(out.suffix, "application/octet-stream"), headers=headers,
                        background=BackgroundTask(storage.remove, work))


# ------------------------------------------------------------------ AI

class Page(BaseModel):
    page: int = Field(ge=1, le=100_000)
    text: str = Field(max_length=200_000)


class SummarizeBody(BaseModel):
    pages: list[Page] = Field(max_length=5000)
    length: Literal["short", "detailed"] = "short"
    language: str = "ar"


class AskBody(BaseModel):
    pages: list[Page] = Field(max_length=5000)
    question: str = Field(max_length=2000)
    language: str = "ar"


class TranslateBody(BaseModel):
    pages: list[Page] = Field(max_length=5000)
    target: str


def _check_size(pages: list[Page]) -> list[dict]:
    if sum(len(p.text) for p in pages) > 400_000:
        raise errors.ToolError("too_large", "النص أطول من الحد المسموح.", "The text is too long.", 413)
    return [p.model_dump() for p in pages]


@app.post("/v1/ai/summarize")
def ai_summarize(body: SummarizeBody, request: Request):
    _rate_limit(request)
    return ai.summarize(_check_size(body.pages), body.length, body.language)


@app.post("/v1/ai/ask")
def ai_ask(body: AskBody, request: Request):
    _rate_limit(request)
    return ai.ask(_check_size(body.pages), body.question, body.language)


@app.post("/v1/ai/translate")
def ai_translate(body: TranslateBody, request: Request):
    _rate_limit(request)
    return ai.translate(_check_size(body.pages), body.target)
