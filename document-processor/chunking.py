"""Structure-aware chunking: one section per heading path, split into chunks of about max_tokens with some
overlap, each labeled with where it comes from ("Aftercare Guide > Tooth Extraction").
"""
import math
import re
from dataclasses import dataclass
from itertools import groupby

from extract import Block

SECTION_SEPARATOR = " > "
SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


@dataclass(frozen=True)
class Chunk:
    section: str
    content: str
    token_count: int
    page_start: int | None
    page_end: int | None

    @property
    def embedding_text(self) -> str:
        # The label travels with the text: "do not eat for two hours" alone does not say after what
        return f"{self.section}\n\n{self.content}"


@dataclass(frozen=True)
class _Unit:
    text: str
    page: int | None
    continues: bool  # joined to the previous unit with a space instead of a paragraph break


def estimate_tokens(text: str) -> int:
    """About 4 characters per token in English; close enough to size chunks without calling the model."""
    return max(1, math.ceil(len(text) / 4))


def chunk_document(title: str, blocks: list[Block], max_tokens: int = 500, overlap_ratio: float = 0.15) -> list[Chunk]:
    overlap_tokens = int(max_tokens * overlap_ratio)
    chunks = []
    for headings, section_blocks in groupby(blocks, key=lambda b: b.headings):
        section = SECTION_SEPARATOR.join((title, *headings))
        units = [unit for block in section_blocks for unit in _split_to_fit(block, max_tokens)]
        chunks.extend(_pack(section, units, max_tokens, overlap_tokens))
    return chunks


def _split_to_fit(block: Block, max_tokens: int) -> list[_Unit]:
    """A paragraph that fits is one unit; a longer one is split into sentences, and a huge sentence into words."""
    if estimate_tokens(block.text) <= max_tokens:
        return [_Unit(block.text, block.page, block.continues)]

    units = []
    for sentence in SENTENCE_END.split(block.text):
        pieces = [sentence] if estimate_tokens(sentence) <= max_tokens else _split_words(sentence, max_tokens)
        for piece in pieces:
            # Pieces of one paragraph rejoin with a space; the first one keeps the block's own link
            units.append(_Unit(piece, block.page, continues=block.continues if not units else True))
    return units


def _split_words(text: str, max_tokens: int) -> list[str]:
    pieces, current = [], []
    for word in text.split():
        if current and estimate_tokens(" ".join([*current, word])) > max_tokens:
            pieces.append(" ".join(current))
            current = []
        current.append(word)
    if current:
        pieces.append(" ".join(current))
    return pieces


def _pack(section: str, units: list[_Unit], max_tokens: int, overlap_tokens: int) -> list[Chunk]:
    chunks, current = [], []
    for unit in units:
        if current and estimate_tokens(_join([*current, unit])) > max_tokens:
            chunks.append(_make_chunk(section, current))
            # Repeat the end of the previous chunk so an idea cut at the border is complete in one of them
            overlap = _tail(current, overlap_tokens)
            current = overlap if estimate_tokens(_join([*overlap, unit])) <= max_tokens else []
        current.append(unit)
    if current:
        chunks.append(_make_chunk(section, current))
    return chunks


def _tail(units: list[_Unit], max_tokens: int) -> list[_Unit]:
    """The last units that fit in max_tokens (never the whole chunk)."""
    tail = []
    for unit in reversed(units[1:]):
        if estimate_tokens(_join([unit, *tail])) > max_tokens:
            break
        tail.insert(0, unit)
    return tail


def _join(units: list[_Unit]) -> str:
    text = ""
    for i, unit in enumerate(units):
        separator = "" if i == 0 else (" " if unit.continues else "\n\n")
        text += separator + unit.text
    return text


def _make_chunk(section: str, units: list[_Unit]) -> Chunk:
    content = _join(units)
    pages = [unit.page for unit in units if unit.page is not None]
    return Chunk(section, content, estimate_tokens(content),
                 min(pages) if pages else None, max(pages) if pages else None)
