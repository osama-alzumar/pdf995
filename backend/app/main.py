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
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

from . import admin, ai, errors, shares, storage, translations
from .config import settings
from .tools import from_pdf, office, pdf_tools
from .tools.common import validate_pdf

log = logging.getLogger("waraqa")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

@asynccontextmanager
async def lifespan(_: FastAPI):
    storage.sweep_once(0)  # nothing from a previous run survives a restart
    storage.start_sweeper()
    if settings.shares_enabled:
        def purge_loop() -> None:
            while True:
                try:
                    shares.purge()
                    translations.purge()
                except Exception:
                    log.exception("purge failed")
                time.sleep(60)
        threading.Thread(target=purge_loop, name="waraqa-share-purge", daemon=True).start()
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
    return {"status": "ok", "tools": TOOLS, "ai": settings.ai_enabled, "shares": settings.shares_enabled,
            "translation": settings.orders_enabled, "translation_price_sar": settings.translation_price_sar,
            "retention_minutes": settings.retention_minutes, "max_upload_mb": settings.max_upload_mb}


async def _receive_files(request: Request, work: Path, limit: int | None = None) -> tuple[list[Path], dict[str, str]]:
    limit = limit or settings.max_upload_bytes
    length = int(request.headers.get("content-length") or 0)
    if length > limit + 1_000_000:
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
                    if total > limit:
                        raise errors.ToolError("too_large", "الملف أكبر من الحد المسموح.", "The file is too large.", 413)
                    fh.write(chunk)
            files.append(target)
            options[f"_name{len(files) - 1}"] = name
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


# ------------------------------------------------------------------ secure share links

PRIVATE_HEADERS = {
    "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
}


@app.post("/v1/shares")
async def create_share(request: Request):
    _rate_limit(request)
    if not settings.shares_enabled:
        raise errors.ToolError("shares_disabled", "المشاركة عبر الرابط غير مفعّلة على الخادم.",
                               "Link sharing is not enabled on the server.", 503)
    work = storage.new_job_dir()
    try:
        files, options = await _receive_files(request, work)
        result = shares.create(files[0], options.get("recipient", ""), options.get("purpose", ""),
                               int(options.get("expires_in", "86400") or 0), int(options.get("max_views", "3") or 1),
                               options.get("allow_download") == "1")
    except ValueError:
        raise errors.ToolError("bad_request", "بيانات غير صحيحة.", "Invalid request.", 400)
    finally:
        storage.remove(work)
    log.info("share created pages_ok")
    return JSONResponse(result, headers={"Cache-Control": "no-store"})


@app.get("/v1/shares/{share_id}")
def share_status(share_id: str, request: Request):
    return JSONResponse(shares.status(share_id, request.headers.get("x-owner-token", "")), headers={"Cache-Control": "no-store"})


@app.delete("/v1/shares/{share_id}")
def share_revoke(share_id: str, request: Request):
    return JSONResponse(shares.revoke(share_id, request.headers.get("x-owner-token", "")), headers={"Cache-Control": "no-store"})


@app.get("/s/{share_id}")
def share_view(share_id: str):
    if not settings.shares_enabled:
        return HTMLResponse("<h1>غير متاح</h1>", status_code=503, headers=PRIVATE_HEADERS)
    body, code = shares.render_view(share_id)
    return HTMLResponse(body, status_code=code, headers=PRIVATE_HEADERS)


@app.get("/s/{share_id}/p/{page}")
def share_page(share_id: str, page: int, v: str = ""):
    return Response(shares.page_png(share_id, page, v), media_type="image/png", headers=PRIVATE_HEADERS)


@app.get("/s/{share_id}/download")
def share_download(share_id: str, v: str = ""):
    headers = dict(PRIVATE_HEADERS, **{"Content-Disposition": "attachment; filename=\"waraqa-shared.pdf\""})
    return Response(shares.download(share_id, v), media_type="application/pdf", headers=headers)


# ------------------------------------------------------------------ certified translation orders

@app.post("/v1/translations")
async def create_translation(request: Request):
    _rate_limit(request)
    if not settings.orders_enabled:
        raise errors.ToolError("orders_disabled", "خدمة الترجمة غير مفعّلة حالياً.",
                               "The translation service is not enabled right now.", 503)
    work = storage.new_job_dir()
    try:
        files, options = await _receive_files(request, work, settings.orders_max_mb * 1_000_000)
        names = [options.get(f"_name{i}", f.name) for i, f in enumerate(files)]
        from starlette.concurrency import run_in_threadpool
        result = await run_in_threadpool(translations.create, files, names, options.get("name", ""),
                                         options.get("phone", ""), options.get("email", ""),
                                         options.get("source_language", ""), options.get("target_language", ""),
                                         options.get("notes", ""))
    finally:
        storage.remove(work)
    log.info("translation order created pages=%d", result["pages"])
    return JSONResponse(result, headers={"Cache-Control": "no-store"})


@app.get("/v1/translations/{order_id}")
def translation_status(order_id: str, request: Request):
    order = translations.owned(order_id, request.headers.get("x-owner-token", ""))
    return JSONResponse(order.public(), headers={"Cache-Control": "no-store"})


@app.get("/v1/translations/{order_id}/result")
def translation_result(order_id: str, request: Request):
    data, name, media = translations.result_file(order_id, request.headers.get("x-owner-token", ""))
    ascii_name = name.encode("ascii", "ignore").decode().strip() or "translation"
    return Response(data, media_type=media, headers={
        "Cache-Control": "no-store",
        "Content-Disposition": f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}"})


# ------------------------------------------------------------------ team panel

ADMIN_HEADERS = dict(PRIVATE_HEADERS, **{
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"})


def _admin_ok(request: Request) -> bool:
    return admin.valid_session(request.cookies.get(admin.COOKIE))


def _same_origin(request: Request) -> bool:
    origin = request.headers.get("origin") or request.headers.get("referer") or ""
    host = request.headers.get("host", "")
    return bool(host) and (origin.startswith(f"https://{host}") or origin.startswith(f"http://{host}"))


def _html(body: str, status: int = 200) -> HTMLResponse:
    return HTMLResponse(body, status_code=status, headers=ADMIN_HEADERS)


def _to_login() -> RedirectResponse:
    return RedirectResponse("/admin/login", status_code=303)


@app.get("/admin/login")
def admin_login_page():
    return _html(admin.login_page())


@app.post("/admin/login")
async def admin_login(request: Request):
    ip = _client_ip(request)
    if not settings.admin_enabled:
        return _html(admin.login_page(), 503)
    if admin.too_many_failures(ip):
        return _html(admin.login_page("محاولات كثيرة. انتظر ربع ساعة."), 429)
    form = await request.form(max_files=0, max_fields=3)
    if not _same_origin(request) or not admin.check_password(str(form.get("password", ""))):
        admin.record_failure(ip)
        log.info("admin login failed")
        return _html(admin.login_page("كلمة المرور غير صحيحة."), 401)
    response = RedirectResponse("/admin", status_code=303)
    response.set_cookie(admin.COOKIE, admin.new_session(), max_age=admin.SESSION_SECONDS, httponly=True,
                        secure=request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https",
                        samesite="strict", path="/admin")
    return response


@app.post("/admin/logout")
def admin_logout():
    response = _to_login()
    response.delete_cookie(admin.COOKIE, path="/admin")
    return response


@app.get("/admin")
def admin_orders(request: Request, state: str | None = None):
    if not _admin_ok(request):
        return _to_login()
    return _html(admin.list_page(state if state in translations.STATES else None))


@app.get("/admin/orders/{order_id}")
def admin_order(order_id: str, request: Request, notice: str = ""):
    if not _admin_ok(request):
        return _to_login()
    body = admin.order_page(order_id, {"saved": "تم الحفظ.", "uploaded": "رُفعت الترجمة وأصبحت متاحة للعميل في التطبيق."}.get(notice, ""))
    return _html(body) if body else _html(admin.page("غير موجود", "<div class='card'>الطلب غير موجود.</div>"), 404)


@app.post("/admin/orders/{order_id}")
async def admin_update(order_id: str, request: Request):
    if not _admin_ok(request) or not _same_origin(request):
        return _to_login()
    form = await request.form(max_files=0, max_fields=8)
    try:
        translations.update(order_id, state=str(form.get("state") or "") or None, message=str(form.get("message", "")),
                            paid=form.get("paid") == "1", price=int(form.get("price") or 0))
    except errors.ToolError as exc:
        return _html(admin.page("خطأ", f"<div class='card'>{exc.message_ar}</div><a href='/admin/orders/{order_id}'>رجوع</a>"), 400)
    return RedirectResponse(f"/admin/orders/{order_id}?notice=saved", status_code=303)


@app.post("/admin/orders/{order_id}/result")
async def admin_result(order_id: str, request: Request):
    if not _admin_ok(request) or not _same_origin(request):
        return _to_login()
    work = storage.new_job_dir()
    try:
        files, _ = await _receive_files(request, work, settings.orders_max_mb * 1_000_000)
        translations.attach_result(order_id, files[0])
    except errors.ToolError as exc:
        return _html(admin.page("خطأ", f"<div class='card'>{exc.message_ar}</div><a href='/admin/orders/{order_id}'>رجوع</a>"), 400)
    finally:
        storage.remove(work)
    log.info("translation delivered")
    return RedirectResponse(f"/admin/orders/{order_id}?notice=uploaded", status_code=303)


@app.get("/admin/orders/{order_id}/files/{index}")
def admin_file(order_id: str, index: int, request: Request):
    if not _admin_ok(request):
        return _to_login()
    data, name = translations.original(order_id, index)
    ascii_name = name.encode("ascii", "ignore").decode().strip() or "file"
    return Response(data, media_type="application/octet-stream", headers=dict(ADMIN_HEADERS, **{
        "Content-Disposition": f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}"}))


# ------------------------------------------------------------------ public pages (privacy / support)

@app.get("/")
def home():
    return RedirectResponse("/support", status_code=302)


@app.get("/privacy")
def privacy():
    return FileResponse(settings.docs_dir / "privacy.html", media_type="text/html; charset=utf-8")


@app.get("/support")
def support():
    return FileResponse(settings.docs_dir / "support.html", media_type="text/html; charset=utf-8")
