"""Certified translation orders (a human service by the Waraqa translation team).

- The customer sends the document from the app with a name and a WhatsApp number. The server
  counts the pages itself and quotes TRANSLATION_PRICE_SAR per page.
- Files are encrypted at rest (AES-256-GCM, a random key per order wrapped by the master key).
- The customer gets an owner token once (stored only as a SHA-256 hash) to follow the order and
  download the translation.
- The team works from the /admin panel: contact the customer, confirm payment, upload the
  translation. Payment is arranged directly with the team (not in the app), because the service
  is performed by people outside the app.
- Files are deleted ORDER_KEEP_DAYS after the order is delivered or cancelled.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
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

STATES = ["received", "awaiting_payment", "in_progress", "ready", "cancelled"]
STATE_AR = {"received": "تم الاستلام — بانتظار المراجعة", "awaiting_payment": "بانتظار الدفع",
            "in_progress": "قيد الترجمة", "ready": "الترجمة جاهزة", "cancelled": "ملغي"}
LANGUAGES = {"ar": "العربية", "en": "الإنجليزية", "fr": "الفرنسية", "tr": "التركية", "ur": "الأردية",
             "es": "الإسبانية", "de": "الألمانية", "zh": "الصينية", "id": "الإندونيسية", "other": "لغة أخرى"}
INPUT_TYPES = {".pdf", ".jpg", ".jpeg", ".png", ".heic", ".docx"}
RESULT_TYPES = {".pdf": "application/pdf",
                ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}
MAX_FILES = 10


def _db() -> sqlite3.Connection:
    settings.orders_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    (settings.orders_dir / "files").mkdir(exist_ok=True, mode=0o700)
    conn = sqlite3.connect(settings.orders_dir / "orders.db", timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY, number INTEGER NOT NULL, owner_hash TEXT NOT NULL,
        name TEXT NOT NULL, phone TEXT NOT NULL, email TEXT, source_lang TEXT NOT NULL, target_lang TEXT NOT NULL,
        notes TEXT, pages INTEGER NOT NULL, price INTEGER NOT NULL, state TEXT NOT NULL,
        message TEXT, files TEXT NOT NULL, result TEXT, created REAL NOT NULL, updated REAL NOT NULL,
        paid INTEGER NOT NULL DEFAULT 0, purged INTEGER NOT NULL DEFAULT 0)""")
    return conn


def _master() -> AESGCM:
    if not settings.orders_enabled:
        raise errors.ToolError("orders_disabled", "خدمة الترجمة غير مفعّلة حالياً.",
                               "The translation service is not enabled right now.", 503)
    return AESGCM(hashlib.sha256(("orders:" + settings.share_master_key).encode()).digest())


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _iso(ts: float | None) -> str | None:
    return None if ts is None else time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(ts))


def _path(name: str) -> Path:
    return settings.orders_dir / "files" / name


def _seal(order_id: str, name: str, data: bytes) -> None:
    key = AESGCM.generate_key(bit_length=256)
    nonce, knonce = os.urandom(12), os.urandom(12)
    aad = f"{order_id}/{name}".encode()
    blob = knonce + _master().encrypt(knonce, key, aad) + nonce + AESGCM(key).encrypt(nonce, data, aad)
    _path(name).write_bytes(blob)
    os.chmod(_path(name), 0o600)


def _open(order_id: str, name: str) -> bytes:
    if not _path(name).exists():
        raise errors.ToolError("gone", "الملف لم يعد متاحاً.", "The file is no longer available.", 410)
    blob = _path(name).read_bytes()
    aad = f"{order_id}/{name}".encode()
    key = _master().decrypt(blob[:12], blob[12:60], aad)
    return AESGCM(key).decrypt(blob[60:72], blob[72:], aad)


def count_pages(path: Path) -> int:
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".heic"}:
        return 1
    if suffix == ".docx":
        # Word pages depend on layout; estimate from the text (≈ 250 words per translated page).
        import zipfile
        try:
            with zipfile.ZipFile(path) as z:
                xml = z.read("word/document.xml").decode("utf-8", "ignore")
        except Exception:
            raise errors.cannot_open()
        words = len(re.sub(r"<[^>]+>", " ", xml).split())
        return max(1, -(-words // 250))
    try:
        with pymupdf.open(path) as doc:
            if doc.needs_pass:
                raise errors.ToolError("encrypted", "أزل كلمة المرور من الملف قبل إرساله للترجمة.",
                                       "Remove the file's password before sending it.")
            return doc.page_count
    except errors.ToolError:
        raise
    except Exception:
        raise errors.cannot_open()


def _clean_phone(phone: str) -> str:
    digits = re.sub(r"\D", "", phone.translate(str.maketrans("٠١٢٣٤٥٦٧٨٩", "0123456789")))
    if digits.startswith("00"):
        digits = digits[2:]
    if digits.startswith("05") and len(digits) == 10:
        digits = "966" + digits[1:]
    if not 9 <= len(digits) <= 15:
        raise errors.ToolError("bad_phone", "رقم الجوال غير صحيح.", "The mobile number is not valid.")
    return digits


@dataclass
class Order:
    id: str
    number: int
    name: str
    phone: str
    email: str
    source_lang: str
    target_lang: str
    notes: str
    pages: int
    price: int
    state: str
    message: str
    files: list[str]
    result: str | None
    created: float
    updated: float
    paid: bool
    purged: bool

    def public(self) -> dict:
        return {"id": self.id, "number": self.number, "state": self.state, "pages": self.pages, "price_sar": self.price,
                "source_language": self.source_lang, "target_language": self.target_lang, "message": self.message or "",
                "paid": self.paid, "has_result": bool(self.result) and not self.purged,
                "result_name": self.result_name, "created_at": _iso(self.created), "updated_at": _iso(self.updated)}

    @property
    def result_name(self) -> str | None:
        if not self.result:
            return None
        return f"ترجمة معتمدة - طلب {self.number}{Path(self.result).suffix}"


def _row(row: sqlite3.Row | None) -> Order | None:
    if row is None:
        return None
    return Order(id=row["id"], number=row["number"], name=row["name"], phone=row["phone"], email=row["email"] or "",
                 source_lang=row["source_lang"], target_lang=row["target_lang"], notes=row["notes"] or "",
                 pages=row["pages"], price=row["price"], state=row["state"], message=row["message"] or "",
                 files=[f for f in row["files"].split("|") if f], result=row["result"], created=row["created"],
                 updated=row["updated"], paid=bool(row["paid"]), purged=bool(row["purged"]))


def create(files: list[Path], names: list[str], name: str, phone: str, email: str, source_lang: str,
           target_lang: str, notes: str) -> dict:
    _master()
    _db().close()
    name = name.strip()[:80]
    if len(name) < 2:
        raise errors.ToolError("bad_name", "اكتب الاسم.", "Enter your name.")
    phone = _clean_phone(phone)
    email = email.strip()[:120]
    if email and not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        raise errors.ToolError("bad_email", "البريد الإلكتروني غير صحيح.", "The email address is not valid.")
    if source_lang not in LANGUAGES or target_lang not in LANGUAGES or (source_lang == target_lang != "other"):
        raise errors.ToolError("bad_language", "اختر لغة المصدر ولغة الترجمة.", "Choose the source and target languages.")
    if not files or len(files) > MAX_FILES:
        raise errors.ToolError("no_file", f"أرسل من ملف إلى {MAX_FILES} ملفات.", f"Send 1 to {MAX_FILES} files.")
    for f in files:
        if f.suffix.lower() not in INPUT_TYPES:
            raise errors.ToolError("unsupported", "نوع الملف غير مدعوم. أرسل PDF أو صورة أو Word.",
                                   "Unsupported file. Send a PDF, an image or a Word file.")
    pages = sum(count_pages(f) for f in files)
    if pages > settings.translation_max_pages:
        raise errors.ToolError("too_many_pages", f"الحد الأقصى {settings.translation_max_pages} صفحة للطلب الواحد.",
                               f"At most {settings.translation_max_pages} pages per order.")
    order_id = secrets.token_urlsafe(12)
    owner_token = secrets.token_urlsafe(32)
    stored = []
    for i, f in enumerate(files):
        stored_name = f"{order_id}-in{i}{f.suffix.lower()}"
        _seal(order_id, stored_name, f.read_bytes())
        stored.append(stored_name)
    now = time.time()
    with _lock, _db() as conn:
        number = (conn.execute("SELECT COALESCE(MAX(number), 1000) FROM orders").fetchone()[0]) + 1
        conn.execute("INSERT INTO orders (id, number, owner_hash, name, phone, email, source_lang, target_lang, notes, pages, "
                     "price, state, files, created, updated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                     (order_id, number, _hash(owner_token), name, phone, email, source_lang, target_lang, notes.strip()[:1000],
                      pages, pages * settings.translation_price_sar, "received", "|".join(stored), now, now))
        # Original file names are kept only for the team, encrypted with the files list.
        conn.execute("CREATE TABLE IF NOT EXISTS order_names (id TEXT PRIMARY KEY, names TEXT)")
        conn.execute("INSERT INTO order_names VALUES (?, ?)", (order_id, "|".join(n[:120].replace("|", " ") for n in names)))
    order = get(order_id)
    return dict(order.public(), owner_token=owner_token)


def get(order_id: str) -> Order | None:
    with _db() as conn:
        return _row(conn.execute("SELECT * FROM orders WHERE id = ?", (order_id,)).fetchone())


def names(order_id: str) -> list[str]:
    with _db() as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS order_names (id TEXT PRIMARY KEY, names TEXT)")
        row = conn.execute("SELECT names FROM order_names WHERE id = ?", (order_id,)).fetchone()
    return row["names"].split("|") if row else []


def owned(order_id: str, owner_token: str) -> Order:
    with _db() as conn:
        row = conn.execute("SELECT * FROM orders WHERE id = ?", (order_id,)).fetchone()
    if row is None or not hmac.compare_digest(row["owner_hash"], _hash(owner_token or "")):
        raise errors.ToolError("not_found", "الطلب غير موجود.", "Order not found.", 404)
    return _row(row)


def result_file(order_id: str, owner_token: str) -> tuple[bytes, str, str]:
    order = owned(order_id, owner_token)
    if order.state != "ready" or not order.result or order.purged:
        raise errors.ToolError("not_ready", "الترجمة ليست جاهزة بعد.", "The translation isn't ready yet.", 409)
    suffix = Path(order.result).suffix
    return _open(order_id, order.result), order.result_name, RESULT_TYPES.get(suffix, "application/octet-stream")


# --- Team (admin panel) ---------------------------------------------------------------------

def list_orders(state: str | None = None) -> list[Order]:
    with _db() as conn:
        if state:
            rows = conn.execute("SELECT * FROM orders WHERE state = ? ORDER BY created DESC LIMIT 500", (state,)).fetchall()
        else:
            rows = conn.execute("SELECT * FROM orders ORDER BY created DESC LIMIT 500").fetchall()
    return [_row(r) for r in rows]


def original(order_id: str, index: int) -> tuple[bytes, str]:
    order = get(order_id)
    if order is None or not 0 <= index < len(order.files):
        raise errors.ToolError("not_found", "غير موجود.", "Not found.", 404)
    labels = names(order_id)
    label = labels[index] if index < len(labels) else order.files[index]
    return _open(order_id, order.files[index]), label


def update(order_id: str, state: str | None = None, message: str | None = None, paid: bool | None = None,
           price: int | None = None) -> Order:
    order = get(order_id)
    if order is None:
        raise errors.ToolError("not_found", "غير موجود.", "Not found.", 404)
    if state is not None and state not in STATES:
        raise errors.ToolError("bad_state", "حالة غير معروفة.", "Unknown state.")
    if state == "ready" and not order.result:
        raise errors.ToolError("no_result", "ارفع ملف الترجمة أولاً.", "Upload the translation first.")
    with _lock, _db() as conn:
        conn.execute("UPDATE orders SET state = COALESCE(?, state), message = COALESCE(?, message), "
                     "paid = COALESCE(?, paid), price = COALESCE(?, price), updated = ? WHERE id = ?",
                     (state, None if message is None else message.strip()[:1000], None if paid is None else int(paid),
                      None if price is None else max(0, int(price)), time.time(), order_id))
    return get(order_id)


def attach_result(order_id: str, upload: Path) -> Order:
    order = get(order_id)
    if order is None:
        raise errors.ToolError("not_found", "غير موجود.", "Not found.", 404)
    suffix = upload.suffix.lower()
    if suffix not in RESULT_TYPES:
        raise errors.ToolError("unsupported", "ارفع الترجمة بصيغة PDF أو Word.", "Upload a PDF or Word file.")
    stored = f"{order_id}-result{suffix}"
    if order.result and order.result != stored:
        _path(order.result).unlink(missing_ok=True)
    _seal(order_id, stored, upload.read_bytes())
    with _lock, _db() as conn:
        conn.execute("UPDATE orders SET result = ?, state = 'ready', updated = ? WHERE id = ?", (stored, time.time(), order_id))
    return get(order_id)


def purge(now: float | None = None) -> int:
    """Deletes the files of orders delivered or cancelled more than ORDER_KEEP_DAYS ago."""
    if not settings.orders_dir.exists():
        return 0
    now = now or time.time()
    cutoff = now - settings.order_keep_days * 86_400
    deleted = 0
    with _lock, _db() as conn:
        rows = conn.execute("SELECT * FROM orders WHERE purged = 0 AND state IN ('ready', 'cancelled') AND updated < ?",
                            (cutoff,)).fetchall()
        for row in rows:
            order = _row(row)
            for name in order.files + ([order.result] if order.result else []):
                _path(name).unlink(missing_ok=True)
            conn.execute("UPDATE orders SET purged = 1 WHERE id = ?", (order.id,))
            deleted += 1
    return deleted
