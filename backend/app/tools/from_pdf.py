"""PDF → Word / PowerPoint / Excel.

Engines (see docs/ENGINES.md for the licensing and quality evaluation):
  - Word: pdf2docx (MIT, built on PyMuPDF) rebuilds paragraphs, tables and images; Arabic
    paragraphs are then marked right-to-left so Word lays them out correctly.
  - PowerPoint: one slide per page. The page is rendered *without its text* as the slide
    background (keeps drawings, photos and colors exactly), and the text is placed on top as
    real, editable text boxes at the original positions.
  - Excel: PyMuPDF's table finder; each table becomes a sheet, numbers become numbers.
"""
from __future__ import annotations

import re
from pathlib import Path

import pymupdf

from .. import errors
from .common import decrypted_copy, is_arabic, validate_docx, validate_pptx, validate_xlsx


def _open(path: Path) -> pymupdf.Document:
    try:
        doc = pymupdf.open(path)
    except Exception:
        raise errors.cannot_open()
    if doc.needs_pass:
        raise errors.password_required()
    if doc.page_count == 0:
        raise errors.cannot_open()
    return doc


def _has_text(doc: pymupdf.Document) -> bool:
    return any(page.get_text("text").strip() for page in doc)


# ---------------------------------------------------------------- Word

def to_word(source: Path, work: Path, password: str | None = None) -> Path:
    from pdf2docx import Converter

    src = decrypted_copy(source, password, work)
    with _open(src) as doc:
        if not _has_text(doc):
            raise errors.no_text()
    out = work / "result.docx"
    try:
        converter = Converter(str(src))
        converter.convert(str(out), multi_processing=False)
        converter.close()
    except Exception:
        raise errors.conversion_failed()
    _mark_rtl(out)
    validate_docx(out)
    return out


def _mark_rtl(path: Path) -> None:
    """Sets bidi on Arabic paragraphs and rtl on their runs, including inside tables."""
    import docx
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    from docx.enum.text import WD_ALIGN_PARAGRAPH

    document = docx.Document(str(path))

    def fix(paragraph) -> None:
        if not is_arabic(paragraph.text):
            return
        ppr = paragraph._p.get_or_add_pPr()
        if ppr.find(qn("w:bidi")) is None:
            ppr.insert(0, OxmlElement("w:bidi"))
        if paragraph.alignment in (None, WD_ALIGN_PARAGRAPH.LEFT):
            paragraph.alignment = WD_ALIGN_PARAGRAPH.RIGHT
        for run in paragraph.runs:
            rpr = run._r.get_or_add_rPr()
            if rpr.find(qn("w:rtl")) is None:
                rpr.append(OxmlElement("w:rtl"))

    def walk(container) -> None:
        for p in container.paragraphs:
            fix(p)
        for table in getattr(container, "tables", []):
            for row in table.rows:
                for cell in row.cells:
                    walk(cell)

    walk(document)
    document.save(str(path))


# ---------------------------------------------------------------- PowerPoint

def to_powerpoint(source: Path, work: Path, password: str | None = None) -> Path:
    from pptx import Presentation
    from pptx.util import Emu, Pt
    from pptx.dml.color import RGBColor
    from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
    from pptx.oxml.ns import qn

    src = decrypted_copy(source, password, work)
    doc = _open(src)
    first = doc[0].rect
    prs = Presentation()
    emu_per_pt = 12700
    prs.slide_width = Emu(int(first.width * emu_per_pt))
    prs.slide_height = Emu(int(first.height * emu_per_pt))
    blank = prs.slide_layouts[6]

    for index, page in enumerate(doc):
        slide = prs.slides.add_slide(blank)
        sx = prs.slide_width / (page.rect.width * emu_per_pt)
        sy = prs.slide_height / (page.rect.height * emu_per_pt)
        blocks = page.get_text("dict")["blocks"]

        # Background: the page with its text removed (drawings, images and colors stay).
        bg_doc = pymupdf.open()
        bg_doc.insert_pdf(doc, from_page=index, to_page=index)
        bg = bg_doc[0]
        for block in blocks:
            if block.get("type") == 0:
                for line in block["lines"]:
                    for span in line["spans"]:
                        if span["text"].strip():
                            bg.add_redact_annot(pymupdf.Rect(span["bbox"]))
        bg.apply_redactions(images=pymupdf.PDF_REDACT_IMAGE_NONE, graphics=pymupdf.PDF_REDACT_LINE_ART_NONE)
        png = work / f"slide-{index + 1}.png"
        bg.get_pixmap(dpi=150).save(str(png))
        bg_doc.close()
        slide.shapes.add_picture(str(png), 0, 0, prs.slide_width, prs.slide_height)

        for block in blocks:
            if block.get("type") != 0:
                continue
            text_lines = []
            sizes = []
            color = 0
            bold = False
            for line in block["lines"]:
                spans = [s for s in line["spans"] if s["text"].strip()]
                if not spans:
                    continue
                text_lines.append("".join(s["text"] for s in line["spans"]).strip())
                sizes.extend(s["size"] for s in spans)
                color = spans[0]["color"]
                bold = bold or bool(spans[0]["flags"] & 16)
            if not text_lines:
                continue
            x0, y0, x1, y1 = block["bbox"]
            box = slide.shapes.add_textbox(Emu(int(x0 * emu_per_pt * sx)), Emu(int(y0 * emu_per_pt * sy)),
                                           Emu(int(max(x1 - x0, 10) * emu_per_pt * sx * 1.05)),
                                           Emu(int(max(y1 - y0, 8) * emu_per_pt * sy)))
            frame = box.text_frame
            frame.word_wrap = True
            frame.vertical_anchor = MSO_ANCHOR.TOP
            for attr in ("margin_left", "margin_right", "margin_top", "margin_bottom"):
                setattr(frame, attr, 0)
            rtl = is_arabic(" ".join(text_lines))
            size = sorted(sizes)[len(sizes) // 2]
            for n, text in enumerate(text_lines):
                paragraph = frame.paragraphs[0] if n == 0 else frame.add_paragraph()
                paragraph.alignment = PP_ALIGN.RIGHT if rtl else PP_ALIGN.LEFT
                if rtl:
                    paragraph._p.get_or_add_pPr().set("rtl", "1")
                run = paragraph.add_run()
                run.text = text
                run.font.size = Pt(max(4, size * min(sx, sy)))
                run.font.bold = bold
                run.font.color.rgb = RGBColor((color >> 16) & 255, (color >> 8) & 255, color & 255)
                if rtl:
                    run._r.get_or_add_rPr().set("lang", "ar-SA")
                    rpr = run._r.get_or_add_rPr()
                    cs = rpr.find(qn("a:cs"))
                    if cs is None:
                        cs = rpr.makeelement(qn("a:cs"), {})
                        rpr.append(cs)
                    cs.set("typeface", "Arial")

    pages = doc.page_count
    doc.close()
    out = work / "result.pptx"
    prs.save(str(out))
    validate_pptx(out, expected_slides=pages)
    return out


# ---------------------------------------------------------------- Excel

_NUMBER = re.compile(r"^[-+]?\(?[\d٠-٩]{1,3}([,٬]?[\d٠-٩]{3})*([.٫][\d٠-٩]+)?\)?%?$")
_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩٫٬", "0123456789.,")


def _cell_value(text: str | None):
    if text is None:
        return None
    value = " ".join(str(text).split())
    if not value:
        return None
    if _NUMBER.match(value):
        plain = value.translate(_DIGITS)
        negative = plain.startswith("(") and plain.endswith(")")
        percent = plain.endswith("%")
        plain = plain.strip("()%").replace(",", "")
        try:
            number = float(plain)
            number = -number if negative else number
            number = number / 100 if percent else number
            return int(number) if number.is_integer() and not percent else number
        except ValueError:
            return value
    return value


def _page_tables(path: Path, page_index: int, page: pymupdf.Page) -> list[list[list[str | None]]]:
    """Tables on a page, rows of cells in visual left-to-right order.

    pdfplumber (MIT) finds the table grid reliably, including in Arabic documents where PyMuPDF's
    finder does not; but its text comes out in visual order (Arabic letters reversed). So the grid
    comes from pdfplumber and each cell's text is read by PyMuPDF, which returns logical order."""
    import pdfplumber

    tables: list[list[list[str | None]]] = []
    try:
        with pdfplumber.open(str(path)) as pdf:
            plumber_page = pdf.pages[page_index]
            for table in plumber_page.find_tables():
                rows = []
                for row in table.rows:
                    cells = []
                    for bbox in row.cells:
                        if bbox is None:
                            cells.append(None)
                            continue
                        text = page.get_textbox(pymupdf.Rect(bbox)).strip()
                        cells.append(" ".join(text.split()) or None)
                    rows.append(cells)
                tables.append(rows)
    except Exception:
        tables = []
    if tables:
        return tables
    try:
        return [t.extract() for t in page.find_tables().tables]
    except Exception:
        return []


def to_excel(source: Path, work: Path, password: str | None = None) -> tuple[Path, int]:
    import openpyxl
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter

    src = decrypted_copy(source, password, work)
    doc = _open(src)
    if not _has_text(doc):
        doc.close()
        raise errors.no_text()

    workbook = openpyxl.Workbook()
    workbook.remove(workbook.active)
    count = 0
    for page_index, page in enumerate(doc):
        for table_index, rows in enumerate(_page_tables(src, page_index, page)):
            rows = [r for r in rows if any(c not in (None, "") for c in r)]
            if len(rows) < 2 or max(len(r) for r in rows) < 2:
                continue
            count += 1
            sheet = workbook.create_sheet(title=f"P{page_index + 1}-T{table_index + 1}")
            rtl = is_arabic(" ".join(str(c) for r in rows for c in r if c))
            if rtl:
                # The first column of a right-to-left table is the rightmost one.
                rows = [list(reversed(r)) for r in rows]
            sheet.sheet_view.rightToLeft = rtl
            for r, row in enumerate(rows, start=1):
                for c, cell in enumerate(row, start=1):
                    value = _cell_value(cell)
                    target = sheet.cell(row=r, column=c, value=value)
                    target.alignment = Alignment(wrap_text=True, vertical="top")
                    if r == 1:
                        target.font = Font(bold=True)
                        target.fill = PatternFill("solid", fgColor="E8EEF7")
            for c in range(1, max(len(r) for r in rows) + 1):
                width = max(len(str(sheet.cell(row=r, column=c).value or "")) for r in range(1, len(rows) + 1))
                sheet.column_dimensions[get_column_letter(c)].width = min(max(10, width + 2), 60)
    doc.close()
    if count == 0:
        raise errors.no_tables()
    out = work / "result.xlsx"
    workbook.save(str(out))
    validate_xlsx(out)
    return out, count
