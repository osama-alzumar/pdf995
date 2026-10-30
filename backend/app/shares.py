"""Secure, expiring view links for protected documents.

- The app uploads an already-protected PDF (watermarked/redacted on the phone).
- The file is encrypted at rest with a random per-share key (AES-256-GCM); that key is itself
  encrypted with the server master key. Nothing is ever stored in a public bucket.
- A link works until it expires, its views are used up, or the owner revokes it. Then the
  encrypted file is deleted; only a small status row remains (so the owner sees "expired"),
  and that row is deleted after SHARE_KEEP_DAYS.
- The owner token is returned once and stored only as a SHA-256 hash.
- The recipient's page shows page images (no PDF) unless the owner allowed downloading.
  Nothing can stop a screenshot or a photo of the screen; the app says so to the owner.
- Opens are counted (time only). We do not identify who opened a link.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import html
import os
import secrets
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import pymupdf
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import errors
from .config import settings

_lock = threading.Lock()
VIEW_WINDOW_SECONDS = 15 * 60


def _db() -> sqlite3.Connection:
    settings.share_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    (settings.share_dir / "files").mkdir(exist_ok=True, mode=0o700)
    conn = sqlite3.connect(settings.share_dir / "shares.db", timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE IF NOT EXISTS shares (
        id TEXT PRIMARY KEY, owner_hash TEXT NOT NULL, recipient TEXT, purpose TEXT,
        created REAL NOT NULL, expires REAL NOT NULL, max_views INTEGER NOT NULL,
        opens INTEGER NOT NULL DEFAULT 0, last_opened REAL, allow_download INTEGER NOT NULL,
        revoked INTEGER NOT NULL DEFAULT 0, pages INTEGER NOT NULL, wrapped_key BLOB,
        purged INTEGER NOT NULL DEFAULT 0)""")
    return conn


def _master() -> AESGCM:
    if not settings.shares_enabled:
        raise errors.ToolError("shares_disabled", "المشاركة عبر الرابط غير مفعّلة على الخادم.",
                               "Link sharing is not enabled on the server.", 503)
    return AESGCM(hashlib.sha256(settings.share_master_key.encode()).digest())


def _file(share_id: str) -> Path:
    return settings.share_dir / "files" / f"{share_id}.bin"


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _iso(ts: float | None) -> str | None:
    if ts is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(ts))


@dataclass
class Share:
    id: str
    recipient: str
    purpose: str
    created: float
    expires: float
    max_views: int
    opens: int
    last_opened: float | None
    allow_download: bool
    revoked: bool
    pages: int
    purged: bool

    def state(self, now: float | None = None) -> str:
        now = now or time.time()
        if self.revoked:
            return "revoked"
        if now >= self.expires:
            return "expired"
        if self.opens >= self.max_views:
            return "exhausted"
        return "active"

    def status(self) -> dict:
        return {"id": self.id, "state": self.state(), "opens": self.opens, "max_views": self.max_views,
                "last_opened_at": _iso(self.last_opened), "expires_at": _iso(self.expires)}


def _row(row: sqlite3.Row | None) -> Share | None:
    if row is None:
        return None
    return Share(id=row["id"], recipient=row["recipient"] or "", purpose=row["purpose"] or "", created=row["created"],
                 expires=row["expires"], max_views=row["max_views"], opens=row["opens"], last_opened=row["last_opened"],
                 allow_download=bool(row["allow_download"]), revoked=bool(row["revoked"]), pages=row["pages"],
                 purged=bool(row["purged"]))


def create(pdf_path: Path, recipient: str, purpose: str, expires_in: int, max_views: int, allow_download: bool) -> dict:
    master = _master()
    _db().close()  # creates the private folders on first use
    size = pdf_path.stat().st_size
    if size > settings.share_max_mb * 1_000_000:
        raise errors.ToolError("too_large", "الملف أكبر من الحد المسموح للمشاركة.", "The file is too large to share.", 413)
    try:
        with pymupdf.open(pdf_path) as doc:
            if doc.needs_pass:
                raise errors.ToolError("encrypted", "لا يمكن مشاركة ملف محمي بكلمة مرور عبر الرابط.",
                                       "Password-protected files can't be shared by link.")
            pages = doc.page_count
    except errors.ToolError:
        raise
    except Exception:
        raise errors.cannot_open()
    if pages == 0:
        raise errors.cannot_open()
    if pages > settings.share_max_pages:
        raise errors.ToolError("too_many_pages", f"الحد الأقصى {settings.share_max_pages} صفحة للمشاركة.",
                               f"At most {settings.share_max_pages} pages can be shared.")
    expires_in = int(expires_in)
    if expires_in not in (600, 3600, 86_400, 604_800):
        raise errors.ToolError("bad_duration", "مدة غير مدعومة.", "Unsupported duration.")
    max_views = max(1, min(int(max_views), 50))

    share_id = secrets.token_urlsafe(16)
    owner_token = secrets.token_urlsafe(32)
    key = AESGCM.generate_key(bit_length=256)
    nonce = os.urandom(12)
    _file(share_id).write_bytes(nonce + AESGCM(key).encrypt(nonce, pdf_path.read_bytes(), share_id.encode()))
    os.chmod(_file(share_id), 0o600)
    knonce = os.urandom(12)
    wrapped = knonce + master.encrypt(knonce, key, share_id.encode())
    now = time.time()
    with _lock, _db() as conn:
        conn.execute("INSERT INTO shares (id, owner_hash, recipient, purpose, created, expires, max_views, allow_download, "
                     "pages, wrapped_key) VALUES (?,?,?,?,?,?,?,?,?,?)",
                     (share_id, _hash(owner_token), recipient[:80], purpose[:80], now, now + expires_in, max_views,
                      int(allow_download), pages, wrapped))
    return {"id": share_id, "url": f"{settings.public_base_url.rstrip('/')}/s/{share_id}", "owner_token": owner_token,
            "expires_at": _iso(now + expires_in)}


def _get(share_id: str) -> Share | None:
    with _db() as conn:
        return _row(conn.execute("SELECT * FROM shares WHERE id = ?", (share_id,)).fetchone())


def _owned(share_id: str, owner_token: str) -> Share:
    with _db() as conn:
        row = conn.execute("SELECT * FROM shares WHERE id = ?", (share_id,)).fetchone()
    if row is None or not hmac.compare_digest(row["owner_hash"], _hash(owner_token or "")):
        raise errors.ToolError("not_found", "المشاركة غير موجودة.", "Share not found.", 404)
    return _row(row)


def status(share_id: str, owner_token: str) -> dict:
    return _owned(share_id, owner_token).status()


def revoke(share_id: str, owner_token: str) -> dict:
    share = _owned(share_id, owner_token)
    with _lock, _db() as conn:
        conn.execute("UPDATE shares SET revoked = 1, purged = 1, wrapped_key = NULL WHERE id = ?", (share_id,))
    _file(share_id).unlink(missing_ok=True)
    share.revoked = True
    return share.status()


def _decrypt(share_id: str) -> bytes:
    with _db() as conn:
        row = conn.execute("SELECT wrapped_key FROM shares WHERE id = ?", (share_id,)).fetchone()
    if row is None or row["wrapped_key"] is None or not _file(share_id).exists():
        raise errors.ToolError("gone", "لم يعد هذا المستند متاحاً.", "This document is no longer available.", 410)
    wrapped = row["wrapped_key"]
    key = _master().decrypt(wrapped[:12], wrapped[12:], share_id.encode())
    blob = _file(share_id).read_bytes()
    return AESGCM(key).decrypt(blob[:12], blob[12:], share_id.encode())


# --- Viewing ---------------------------------------------------------------------------------

def _view_token(share_id: str, issued: int) -> str:
    mac = hmac.new(hashlib.sha256(("view:" + settings.share_master_key).encode()).digest(),
                   f"{share_id}:{issued}".encode(), hashlib.sha256).hexdigest()[:32]
    return f"{issued}.{mac}"


def _check_view_token(share_id: str, token: str) -> bool:
    try:
        issued_s, _ = token.split(".", 1)
        issued = int(issued_s)
    except (ValueError, AttributeError):
        return False
    if time.time() - issued > VIEW_WINDOW_SECONDS:
        return False
    return hmac.compare_digest(_view_token(share_id, issued), token)


def open_view(share_id: str) -> tuple[str, Share | None, str | None]:
    """Counts one open if the link is usable. Returns (state, share, view_token)."""
    with _lock:
        share = _get(share_id)
        if share is None:
            return "missing", None, None
        state = share.state()
        if state != "active":
            return state, share, None
        now = time.time()
        with _db() as conn:
            conn.execute("UPDATE shares SET opens = opens + 1, last_opened = ? WHERE id = ?", (now, share_id))
        share.opens += 1
        share.last_opened = now
    return "active", share, _view_token(share_id, int(now))


def page_png(share_id: str, page: int, token: str) -> bytes:
    share = _get(share_id)
    if share is None or share.revoked or time.time() >= share.expires or not _check_view_token(share_id, token):
        raise errors.ToolError("gone", "لم يعد هذا المستند متاحاً.", "This document is no longer available.", 410)
    if not 0 <= page < share.pages:
        raise errors.ToolError("not_found", "الصفحة غير موجودة.", "Page not found.", 404)
    with pymupdf.open(stream=_decrypt(share_id), filetype="pdf") as doc:
        return doc[page].get_pixmap(dpi=110).tobytes("png")


def download(share_id: str, token: str) -> bytes:
    share = _get(share_id)
    if share is None or not share.allow_download:
        raise errors.ToolError("not_allowed", "التنزيل غير مسموح لهذا المستند.", "Downloading is not allowed.", 403)
    if share.revoked or time.time() >= share.expires or not _check_view_token(share_id, token):
        raise errors.ToolError("gone", "لم يعد هذا المستند متاحاً.", "This document is no longer available.", 410)
    return _decrypt(share_id)


# --- Clean-up --------------------------------------------------------------------------------

def purge(now: float | None = None) -> int:
    """Deletes encrypted files of shares that can no longer be viewed (after the view window),
    and status rows older than SHARE_KEEP_DAYS. Returns how many files were deleted."""
    if not settings.share_dir.exists():
        return 0
    now = now or time.time()
    deleted = 0
    with _lock, _db() as conn:
        rows = conn.execute("SELECT * FROM shares WHERE purged = 0").fetchall()
        for row in rows:
            share = _row(row)
            state = share.state(now)
            finished_at = share.expires if state == "expired" else (share.last_opened or now)
            if state != "active" and now - finished_at > VIEW_WINDOW_SECONDS:
                _file(share.id).unlink(missing_ok=True)
                conn.execute("UPDATE shares SET purged = 1, wrapped_key = NULL WHERE id = ?", (share.id,))
                deleted += 1
        conn.execute("DELETE FROM shares WHERE expires < ?", (now - settings.share_keep_days * 86_400,))
    return deleted


# --- Pages for the recipient --------------------------------------------------------------------

_STYLE = """
:root{color-scheme:light dark;--bg:#F5F7FB;--card:#FFFFFF;--text:#141821;--sub:#4A5464;--accent:#1E3A6E;--line:#E3E7ED}
@media (prefers-color-scheme:dark){:root{--bg:#0B0E14;--card:#161B25;--text:#F2F4F7;--sub:#A3ACB9;--accent:#8FB0E8;--line:#2A303B}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);
font-family:"SF Arabic","Segoe UI","Noto Naskh Arabic",Tahoma,sans-serif;line-height:1.6}
main{max-width:860px;margin:0 auto;padding:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:16px;margin-bottom:14px}
.brand{font-weight:700;color:var(--accent);font-size:20px}
.muted{color:var(--sub);font-size:14px}
.page{width:100%;height:auto;display:block;border-radius:10px;border:1px solid var(--line);margin:0 0 14px;
-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;pointer-events:none}
.center{text-align:center;padding:48px 16px}
a.btn{display:inline-block;background:var(--accent);color:#fff;border-radius:12px;padding:12px 18px;text-decoration:none}
"""


def _page(title: str, body: str, status_code: int = 200) -> tuple[str, int]:
    return (f"<!doctype html><html lang='ar' dir='rtl'><head><meta charset='utf-8'>"
            f"<meta name='viewport' content='width=device-width,initial-scale=1'><meta name='robots' content='noindex,nofollow'>"
            f"<title>{html.escape(title)}</title><style>{_STYLE}</style></head><body><main>"
            f"<div class='brand'>ورقة</div>{body}</main></body></html>", status_code)


MESSAGES = {
    "expired": "انتهت صلاحية مشاركة هذا المستند",
    "revoked": "لم يعد هذا المستند متاحاً",
    "exhausted": "انتهى عدد مرات الفتح المسموحة لهذا المستند",
    "missing": "لم يعد هذا المستند متاحاً",
}


def render_view(share_id: str) -> tuple[str, int]:
    state, share, token = open_view(share_id)
    if state != "active":
        msg = MESSAGES.get(state, MESSAGES["missing"])
        return _page(msg, f"<div class='card center'><h1 style='font-size:22px'>{msg}</h1>"
                          f"<p class='muted'>يمكنك طلب نسخة جديدة من صاحب المستند.</p></div>", 410 if state != "missing" else 404)
    remaining = max(0, share.max_views - share.opens)
    hours = max(0, int((share.expires - time.time()) // 3600))
    minutes = max(0, int((share.expires - time.time()) % 3600 // 60))
    left = f"{hours} ساعة و{minutes} دقيقة" if hours else f"{minutes} دقيقة"
    imgs = "".join(f"<img class='page' alt='صفحة {i + 1}' src='/s/{share_id}/p/{i}?v={token}'>" for i in range(share.pages))
    download = (f"<p><a class='btn' href='/s/{share_id}/download?v={token}'>تنزيل نسخة PDF</a></p>"
                if share.allow_download else "<p class='muted'>العرض فقط — التنزيل غير متاح لهذا المستند.</p>")
    body = (f"<div class='card'><div>مخصص لـ: <b>{html.escape(share.recipient or 'الجهة المستلمة')}</b></div>"
            f"<div>الغرض: <b>{html.escape(share.purpose or '—')}</b></div>"
            f"<div class='muted'>متاح لمدة {left} أخرى · مرات الفتح المتبقية: {remaining}</div>{download}</div>"
            f"{imgs}<p class='muted'>هذا المستند مُشارك عبر تطبيق ورقة لغرض محدد. يُرجى عدم استخدامه لأي غرض آخر.</p>")
    return _page("مستند مُشارك", body)
