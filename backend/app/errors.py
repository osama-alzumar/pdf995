"""Errors returned to the app. Each has a stable code the iOS client maps to its own message,
plus Arabic/English text for anything the client does not know yet."""
from __future__ import annotations


class ToolError(Exception):
    status = 422

    def __init__(self, code: str, message_ar: str, message_en: str, status: int | None = None):
        super().__init__(code)
        self.code = code
        self.message_ar = message_ar
        self.message_en = message_en
        if status:
            self.status = status

    def body(self) -> dict:
        return {"error": self.code, "message_ar": self.message_ar, "message_en": self.message_en}


def cannot_open() -> ToolError:
    return ToolError("cannot_open", "تعذّر فتح الملف. قد يكون تالفاً.", "The file couldn't be opened. It may be damaged.")


def unsupported(kind: str = "") -> ToolError:
    return ToolError("unsupported_file", f"نوع الملف غير مدعوم {kind}".strip(), f"Unsupported file type {kind}".strip())


def password_required() -> ToolError:
    return ToolError("password_required", "الملف محمي بكلمة مرور.", "The file is password-protected.")


def wrong_password() -> ToolError:
    return ToolError("wrong_password", "كلمة المرور غير صحيحة.", "Wrong password.")


def conversion_failed() -> ToolError:
    return ToolError("conversion_failed", "تعذّر تحويل الملف.", "The conversion failed.", status=422)


def validation_failed() -> ToolError:
    return ToolError("output_validation_failed", "الملف الناتج لم يجتز الفحص.", "The result failed validation.", status=500)


def no_text() -> ToolError:
    return ToolError("no_text", "لم يُعثر على نص في الملف.", "No text was found in the file.")


def no_tables() -> ToolError:
    return ToolError("no_tables", "لم يُعثر على جداول في هذا الملف.", "No tables were found in this file.")


def timeout() -> ToolError:
    return ToolError("timeout", "استغرقت العملية وقتاً طويلاً.", "The job took too long.", status=504)


def ai_not_configured() -> ToolError:
    return ToolError("ai_not_configured", "أدوات الذكاء الاصطناعي غير مفعّلة.", "AI tools are not enabled.", status=503)


def ai_failed() -> ToolError:
    return ToolError("ai_failed", "تعذّر إكمال طلب الذكاء الاصطناعي.", "The AI request failed.", status=502)
