import pytest

from extract import DOCX, PDF, Block, ExtractionError, UnsupportedTypeError, extract_blocks
from tests.samples import make_blank_pdf, make_docx, make_markdown, make_pdf


def test_docx_keeps_heading_path_lists_and_tables():
    blocks = extract_blocks(make_docx(), DOCX)
    assert blocks == [
        Block(("Tooth Extraction",), "Bite gently on the gauze for 30 minutes."),
        Block(("Tooth Extraction", "Eating and drinking"), "- Do not eat for two hours."),
        Block(("Tooth Extraction", "Eating and drinking"), "- Avoid hot drinks for 24 hours."),
        Block(("Insurance",), "Plan | Covered\nDelta Dental PPO | Yes"),
    ]


def test_markdown_headings_paragraphs_and_lists():
    blocks = extract_blocks(make_markdown(), "text/markdown; charset=utf-8")
    assert blocks == [
        Block(("Cancellation Policy",), "Please cancel at least 24 hours in advance."),
        Block(("Cancellation Policy", "Late cancellations"), "- A $50 fee applies."),
        Block(("Cancellation Policy", "Late cancellations"), "- Two no-shows end online booking."),
    ]


def test_pdf_headings_come_from_font_sizes():
    blocks = extract_blocks(make_pdf(), PDF)
    assert [b.headings for b in blocks] == [
        ("Tooth Extraction",),
        ("Tooth Extraction", "Eating and drinking"),
        ("Tooth Extraction", "Eating and drinking"),
        ("Insurance",),
    ]


def test_pdf_paragraphs_lines_and_hyphenation():
    first = extract_blocks(make_pdf(), PDF)[0]
    assert first.text == ("Bite gently on the gauze for thirty minutes after the procedure. "
                          "Do not rinse your mouth during the first extraction day.")
    assert first.page == 1


def test_pdf_paragraph_running_onto_the_next_page_is_marked_as_continuation():
    blocks = extract_blocks(make_pdf(), PDF)
    assert (blocks[1].text, blocks[1].page, blocks[1].continues) == ("Take the pain medication with food and", 1, False)
    assert (blocks[2].text, blocks[2].page, blocks[2].continues) == ("plenty of water.", 2, True)


def test_pdf_page_numbers_are_dropped():
    assert not any("Page" in b.text for b in extract_blocks(make_pdf(), PDF))


def test_pdf_without_text_is_rejected():
    with pytest.raises(ExtractionError, match="OCR"):
        extract_blocks(make_blank_pdf(), PDF)


@pytest.mark.parametrize("mime_type", [PDF, DOCX])
def test_corrupt_files_are_rejected(mime_type):
    with pytest.raises(ExtractionError):
        extract_blocks(b"not really a document", mime_type)


def test_unsupported_types_are_rejected():
    with pytest.raises(UnsupportedTypeError):
        extract_blocks(b"\x89PNG", "image/png")
