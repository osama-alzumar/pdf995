"""Translation team panel at /admin (Arabic, phone-friendly).

Login with ADMIN_PASSWORD_HASH (pbkdf2_sha256$iterations$salt_hex$hash_hex). The session is an
HMAC-signed, HttpOnly, Secure, SameSite=Strict cookie valid for 12 hours; POSTs must also come
from the same origin. Failed logins are rate limited per IP.
"""
from __future__ import annotations

import hashlib
import hmac
import html
import secrets
import threading
import time
from collections import defaultdict, deque
from urllib.parse import quote

from .config import settings
from . import translations as tr

COOKIE = "waraqa_admin"
SESSION_SECONDS = 12 * 3600
_fails: dict[str, deque] = defaultdict(deque)
_fails_lock = threading.Lock()


def hash_password(password: str, iterations: int = 310_000) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return f"pbkdf2_sha256${iterations}${salt.hex()}${digest.hex()}"


def check_password(password: str) -> bool:
    try:
        algo, iterations, salt, expected = settings.admin_password_hash.split("$")
        if algo != "pbkdf2_sha256":
            return False
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(iterations))
        return hmac.compare_digest(digest.hex(), expected)
    except ValueError:
        return False


def _key() -> bytes:
    return hashlib.sha256(("admin-session:" + settings.share_master_key + settings.admin_password_hash).encode()).digest()


def new_session() -> str:
    expires = int(time.time()) + SESSION_SECONDS
    mac = hmac.new(_key(), str(expires).encode(), hashlib.sha256).hexdigest()
    return f"{expires}.{mac}"


def valid_session(cookie: str | None) -> bool:
    if not cookie or not settings.admin_enabled:
        return False
    try:
        expires_s, mac = cookie.split(".", 1)
        expires = int(expires_s)
    except ValueError:
        return False
    if expires < time.time():
        return False
    return hmac.compare_digest(hmac.new(_key(), expires_s.encode(), hashlib.sha256).hexdigest(), mac)


def too_many_failures(ip: str) -> bool:
    now = time.monotonic()
    with _fails_lock:
        window = _fails[ip]
        while window and now - window[0] > 900:
            window.popleft()
        return len(window) >= 8


def record_failure(ip: str) -> None:
    with _fails_lock:
        _fails[ip].append(time.monotonic())


# --- Pages -------------------------------------------------------------------------------------

STYLE = """
:root{color-scheme:light dark;--bg:#F5F7FB;--card:#FFFFFF;--text:#141821;--sub:#4A5464;--accent:#1E3A6E;--line:#E3E7ED;
--ok:#067647;--warn:#B54708;--bad:#B42318}
@media (prefers-color-scheme:dark){:root{--bg:#0B0E14;--card:#161B25;--text:#F2F4F7;--sub:#A3ACB9;--accent:#8FB0E8;--line:#2A303B;
--ok:#47CD89;--warn:#FDB022;--bad:#F97066}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);
font-family:"SF Arabic","Segoe UI","Noto Naskh Arabic",Tahoma,sans-serif;line-height:1.6}
main{max-width:900px;margin:0 auto;padding:16px}
header{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:14px}
.brand{font-weight:800;color:var(--accent);font-size:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px;margin-bottom:12px}
a{color:var(--accent)}.muted{color:var(--sub);font-size:14px}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;justify-content:space-between}
.pill{display:inline-block;border-radius:999px;padding:2px 10px;font-size:13px;border:1px solid var(--line)}
.s-received{color:var(--warn)}.s-awaiting_payment{color:var(--warn)}.s-in_progress{color:var(--accent)}
.s-ready{color:var(--ok)}.s-cancelled{color:var(--bad)}
input,select,textarea{width:100%;font:inherit;padding:10px;border-radius:10px;border:1px solid var(--line);
background:var(--bg);color:var(--text)}
textarea{min-height:80px}label{display:block;font-weight:700;margin:10px 0 4px}
button,.btn{display:inline-block;font:inherit;font-weight:700;background:var(--accent);color:#fff;border:0;border-radius:10px;
padding:10px 16px;text-decoration:none;cursor:pointer}
.btn.light{background:transparent;color:var(--accent);border:1px solid var(--line)}
.filters a{margin-inline-end:10px}
table{width:100%;border-collapse:collapse}td{padding:4px 0;vertical-align:top}td:first-child{color:var(--sub);width:35%}
"""


def page(title: str, body: str, logged_in: bool = True) -> str:
    nav = ("<form method='post' action='/admin/logout' style='margin:0'><button class='btn light'>خروج</button></form>"
           if logged_in else "")
    return (f"<!doctype html><html lang='ar' dir='rtl'><head><meta charset='utf-8'>"
            f"<meta name='viewport' content='width=device-width,initial-scale=1'><meta name='robots' content='noindex,nofollow'>"
            f"<title>{html.escape(title)}</title><style>{STYLE}</style></head><body><main>"
            f"<header><a class='brand' href='/admin' style='text-decoration:none'>ورقة · طلبات الترجمة</a>{nav}</header>"
            f"{body}</main></body></html>")


def login_page(error: str = "") -> str:
    note = f"<p style='color:var(--bad)'>{html.escape(error)}</p>" if error else ""
    if not settings.admin_enabled:
        return page("غير مفعّل", "<div class='card'>لوحة الإدارة غير مفعّلة على الخادم.</div>", False)
    return page("دخول", f"""<div class='card' style='max-width:420px;margin:40px auto'>
<h1 style='font-size:20px;margin-top:0'>دخول فريق الترجمة</h1>{note}
<form method='post' action='/admin/login'><label for='p'>كلمة المرور</label>
<input id='p' type='password' name='password' autocomplete='current-password' required autofocus>
<p><button>دخول</button></p></form></div>""", False)


def _date(ts: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(ts + 3 * 3600))  # Riyadh time


def _lang(code: str) -> str:
    return tr.LANGUAGES.get(code, code)


def list_page(state: str | None) -> str:
    orders = tr.list_orders(state)
    counts = {s: 0 for s in tr.STATES}
    for o in tr.list_orders(None):
        counts[o.state] += 1
    filters = "<a href='/admin'>الكل</a>" + "".join(
        f"<a href='/admin?state={s}'>{tr.STATE_AR[s]} ({counts[s]})</a>" for s in tr.STATES)
    if not orders:
        items = "<div class='card muted'>لا توجد طلبات.</div>"
    else:
        items = "".join(f"""<a href='/admin/orders/{o.id}' style='text-decoration:none;color:inherit'><div class='card'>
<div class='row'><b>طلب {o.number} — {html.escape(o.name)}</b><span class='pill s-{o.state}'>{tr.STATE_AR[o.state]}</span></div>
<div class='muted'>{_lang(o.source_lang)} ← {_lang(o.target_lang)} · {o.pages} صفحة · {o.price} ريال
{' · مدفوع' if o.paid else ''} · {_date(o.created)}</div></div></a>""" for o in orders)
    return page("الطلبات", f"<div class='card filters'>{filters}</div>{items}")


def order_page(order_id: str, notice: str = "") -> str | None:
    o = tr.get(order_id)
    if o is None:
        return None
    labels = tr.names(order_id)
    files = "".join(f"<li><a href='/admin/orders/{o.id}/files/{i}'>{html.escape(labels[i] if i < len(labels) else f'ملف {i + 1}')}</a></li>"
                    for i in range(len(o.files))) if not o.purged else "<li class='muted'>حُذفت الملفات بعد انتهاء مدة الحفظ.</li>"
    wa_text = quote(f"مرحباً {o.name}، معك فريق الترجمة في تطبيق ورقة بخصوص طلبك رقم {o.number} "
                    f"({o.pages} صفحة، {o.price} ريال).")
    options = "".join(f"<option value='{s}' {'selected' if s == o.state else ''}>{tr.STATE_AR[s]}</option>" for s in tr.STATES)
    result = (f"<p>ملف الترجمة: <b>{html.escape(o.result_name or '')}</b> — العميل يستطيع تنزيله من التطبيق.</p>"
              if o.result else "<p class='muted'>لم تُرفع الترجمة بعد.</p>")
    note = f"<div class='card' style='color:var(--ok)'>{html.escape(notice)}</div>" if notice else ""
    return page(f"طلب {o.number}", f"""{note}
<div class='card'><div class='row'><h1 style='font-size:20px;margin:0'>طلب {o.number}</h1>
<span class='pill s-{o.state}'>{tr.STATE_AR[o.state]}</span></div>
<table><tr><td>الاسم</td><td>{html.escape(o.name)}</td></tr>
<tr><td>الجوال</td><td dir='ltr' style='text-align:right'>+{html.escape(o.phone)}</td></tr>
<tr><td>البريد</td><td>{html.escape(o.email) or '—'}</td></tr>
<tr><td>من ← إلى</td><td>{_lang(o.source_lang)} ← {_lang(o.target_lang)}</td></tr>
<tr><td>الصفحات</td><td>{o.pages}</td></tr><tr><td>السعر</td><td>{o.price} ريال {'(مدفوع)' if o.paid else '(غير مدفوع)'}</td></tr>
<tr><td>التاريخ</td><td>{_date(o.created)}</td></tr><tr><td>ملاحظات العميل</td><td>{html.escape(o.notes) or '—'}</td></tr></table>
<p><a class='btn' href='https://wa.me/{o.phone}?text={wa_text}' target='_blank' rel='noopener'>تواصل عبر واتساب</a></p></div>
<div class='card'><b>ملفات العميل</b><ul>{files}</ul></div>
<div class='card'><b>رفع الترجمة</b>{result}
<form method='post' action='/admin/orders/{o.id}/result' enctype='multipart/form-data'>
<input type='file' name='file' accept='.pdf,.docx' required><p><button>رفع وتسليم للعميل</button></p></form></div>
<div class='card'><b>تحديث الطلب</b><form method='post' action='/admin/orders/{o.id}'>
<label>الحالة</label><select name='state'>{options}</select>
<label>السعر (ريال)</label><input name='price' type='number' min='0' value='{o.price}'>
<label><input type='checkbox' name='paid' value='1' style='width:auto' {'checked' if o.paid else ''}> تم الدفع</label>
<label>رسالة تظهر للعميل في التطبيق</label><textarea name='message'>{html.escape(o.message)}</textarea>
<p><button>حفظ</button></p></form></div>""")
