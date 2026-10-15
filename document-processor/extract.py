"""Text extraction: PDF, DOCX and Markdown / plain text -> ordered blocks of text with their heading path.

Headings matter for retrieval: "do not eat for two hours" is only useful if we know it belongs to
"Tooth Extraction". DOCX and Markdown declare them; in PDFs they are inferred from the font size and weight.
"""
import io
import math
import re
from collections import Counter
from dataclasses import dataclass

import docx
from docx.table import Table
from docx.text.paragraph import Paragraph
from pypdf import PdfReader

PDF = "application/pdf"
DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
TEXT_TYPES = {"text/plain", "text/markdown"}
SUPPORTED_TYPES = {PDF, DOCX, *TEXT_TYPES}

# A PDF line at least this much larger than the body text is a heading; so is a short line entirely in bold
HEADING_SIZE_RATIO = 1.15
MAX_HEADING_WORDS = 15
PAGE_NUMBER = re.compile(r"^(page\s+)?\d+(\s*(of|/)\s*\d+)?$", re.IGNORECASE)
LIST_ITEM = re.compile(r"^\s*([-*+•]|\d+[.)])\s+")


class UnsupportedTypeError(Exception):
    """The file type is not one of SUPPORTED_TYPES."""


class ExtractionError(Exception):
    """The file cannot be turned into text (corrupt, password-protected, scanned...)."""


@dataclass(frozen=True)
class Block:
    headings: tuple[str, ...]  # e.g. ("Tooth Extraction", "Eating and drinking")
    text: str
    page: int | None = None
    # True when the block continues the previous block's paragraph (a PDF paragraph split by a page break)
    continues: bool = False


def extract_blocks(data: bytes, mime_type: str) -> list[Block]:
    mime_type = (mime_type or "").split(";")[0].strip().lower()
    if mime_type == PDF:
        blocks = _from_pdf(data)
    elif mime_type == DOCX:
        blocks = _from_docx(data)
    elif mime_type in TEXT_TYPES:
        blocks = _from_markdown(data)
    else:
        raise UnsupportedTypeError(f"Unsupported type {mime_type!r}. Supported: {', '.join(sorted(SUPPORTED_TYPES))}.")

    blocks = [b for b in blocks if b.text]
    if not blocks:
        raise ExtractionError("No text could be extracted (a scanned PDF needs OCR, which is not supported).")
    return blocks


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text.replace(" ", " ")).strip()


def _with_heading(headings: tuple[str, ...], level: int, text: str) -> tuple[str, ...]:
    """A level-2 heading replaces the previous level 2 and everything below it."""
    return (*headings[:level - 1], text)


# ---------------------------------------------------------------- DOCX (also Google Docs exported as DOCX)

def _from_docx(data: bytes) -> list[Block]:
    try:
        document = docx.Document(io.BytesIO(data))
    except Exception as e:  # zipfile, lxml and python-docx all raise their own errors
        raise ExtractionError(f"Not a readable DOCX file: {e}") from e

    blocks, headings = [], ()
    # Paragraphs and tables in document order
    for element in document.element.body.iterchildren():
        tag = element.tag.rsplit("}", 1)[-1]
        if tag == "p":
            paragraph = Paragraph(element, document)
            text = _clean(paragraph.text)
            style = paragraph.style.name if paragraph.style is not None else ""
            if not text or style == "Title":  # the title comes from the file name
                continue
            level = _docx_heading_level(style)
            if level:
                headings = _with_heading(headings, level, text)
            else:
                blocks.append(Block(headings, f"- {text}" if style.lower().startswith("list") else text))
        elif tag == "tbl":
            rows = (" | ".join(_clean(cell.text) for cell in row.cells) for row in Table(element, document).rows)
            text = "\n".join(row for row in rows if row.strip(" |"))
            if text:
                blocks.append(Block(headings, text))
    return blocks


def _docx_heading_level(style: str) -> int:
    match = re.match(r"^heading\s*(\d)$", style, re.IGNORECASE)
    return int(match[1]) if match else 0


# ---------------------------------------------------------------- Markdown / plain text

def _from_markdown(data: bytes) -> list[Block]:
    blocks, headings, paragraph = [], (), []

    def flush():
        if paragraph:
            blocks.append(Block(headings, _clean(" ".join(paragraph))))
            paragraph.clear()

    for line in data.decode("utf-8-sig", errors="replace").splitlines():
        heading = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if heading:
            flush()
            headings = _with_heading(headings, len(heading[1]), _clean(heading[2]))
        elif not line.strip():
            flush()
        elif LIST_ITEM.match(line):
            flush()
            blocks.append(Block(headings, "- " + _clean(LIST_ITEM.sub("", line, count=1))))
        else:
            paragraph.append(line)
    flush()
    return blocks


# ---------------------------------------------------------------- PDF

@dataclass
class _Line:
    text: str
    size: float
    y: float
    page: int
    bold: bool = False


def _from_pdf(data: bytes) -> list[Block]:
    try:
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted and not reader.decrypt(""):
            raise ExtractionError("The PDF is password-protected.")
        lines = [line for number, page in enumerate(reader.pages, start=1) for line in _pdf_lines(page, number)]
    except ExtractionError:
        raise
    except Exception as e:  # pypdf raises several error types for damaged files
        raise ExtractionError(f"Not a readable PDF file: {e}") from e

    lines = [line for line in lines if line.text and not PAGE_NUMBER.match(line.text)]
    if not lines:
        return []

    body_size = _body_size(lines)
    # Each distinct heading style is a level: larger first, and bold before regular at the same size
    styles = sorted({style for line in lines if (style := _heading_style(line, body_size))},
                    key=lambda style: (-style[0], not style[1]))

    blocks, headings, paragraph = [], (), []
    previous, previous_level, continues = None, 0, False

    def flush():
        if paragraph:
            blocks.append(Block(headings, _join_lines([p.text for p in paragraph]), paragraph[0].page, continues))
            paragraph.clear()

    for line in lines:
        style = _heading_style(line, body_size)
        level = styles.index(style) + 1 if style else 0
        if level:
            flush()
            continues = False
            if level == previous_level and _same_paragraph(previous, line):
                headings = (*headings[:-1], f"{headings[-1]} {line.text}")  # heading wrapped over two lines
            else:
                headings = _with_heading(headings, level, line.text)
        else:
            if paragraph and not _same_paragraph(previous, line):
                # A page break after a line without final punctuation: the same paragraph goes on
                runs_on = line.page != previous.page and not re.search(r"[.!?:]$", previous.text)
                flush()
                continues = runs_on
            paragraph.append(line)
        previous, previous_level = line, level
    flush()
    return blocks


def _pdf_lines(page, page_number: int) -> list[_Line]:
    """Rebuilds the page's lines with their font size and vertical position."""
    lines: list[_Line] = []
    current: list[str] = []
    state = {"size": 0.0, "y": None, "bold": None}

    def end_line():
        text = _clean("".join(current))
        if text:
            lines.append(_Line(text, state["size"], state["y"], page_number, bool(state["bold"])))
        current.clear()
        state["size"], state["y"], state["bold"] = 0.0, None, None

    def visit(text, cm, tm, font_dict, font_size):
        if not text:
            return
        matrix = _multiply(tm, cm)
        y = matrix[5]
        size = font_size * math.hypot(matrix[2], matrix[3])
        if state["y"] is not None and abs(y - state["y"]) > 1 and current:
            end_line()
        for i, part in enumerate(text.split("\n")):
            if i > 0:
                end_line()
            if part:
                if state["y"] is None:
                    state["y"] = y
                if part.strip():
                    state["size"] = max(state["size"], size)
                    # The line is bold only if all of its text is
                    state["bold"] = _is_bold(font_dict) and state["bold"] is not False
                current.append(part)

    page.extract_text(visitor_text=visit)
    end_line()
    return lines


def _multiply(m, n):
    """Product of two PDF transformation matrices [a b c d e f]."""
    return [m[0] * n[0] + m[1] * n[2], m[0] * n[1] + m[1] * n[3],
            m[2] * n[0] + m[3] * n[2], m[2] * n[1] + m[3] * n[3],
            m[4] * n[0] + m[5] * n[2] + n[4], m[4] * n[1] + m[5] * n[3] + n[5]]


def _body_size(lines: list[_Line]) -> float:
    """The font size used for most of the text."""
    weights = Counter()
    for line in lines:
        weights[round(line.size, 1)] += len(line.text)
    return weights.most_common(1)[0][0]


def _is_bold(font_dict) -> bool:
    name = str((font_dict or {}).get("/BaseFont", ""))
    return any(weight in name.lower() for weight in ("bold", "black", "heavy"))


def _heading_style(line: _Line, body_size: float) -> tuple[float, bool] | None:
    """(size, bold) when the line looks like a heading, None otherwise."""
    if body_size <= 0 or len(line.text.split()) > MAX_HEADING_WORDS:
        return None
    larger = line.size >= body_size * HEADING_SIZE_RATIO
    # Bold at body size is a heading only on its own: "Note: rinse well." is a bold lead-in, not a title
    bold_title = line.bold and line.size >= body_size * 0.95 and not re.search(r"[.,;:]$", line.text)
    return (round(line.size, 1), line.bold) if larger or bold_title else None


def _same_paragraph(previous: _Line | None, line: _Line) -> bool:
    """Consecutive lines with normal line spacing; a bigger gap (or a new page) starts a new paragraph."""
    if previous is None or previous.page != line.page or previous.y is None or line.y is None:
        return False
    gap = previous.y - line.y
    return 0 < gap <= max(previous.size, line.size) * 1.6


def _join_lines(lines: list[str]) -> str:
    text = lines[0]
    for line in lines[1:]:
        # "extrac-" + "tion" -> "extraction"
        if text.endswith("-") and line[:1].islower():
            text = text[:-1] + line
        else:
            text = f"{text} {line}"
    return _clean(text)
