from chunking import chunk_document, estimate_tokens
from extract import Block


def paragraph(n: int, words: int = 30) -> str:
    return " ".join(f"p{n}w{i}" for i in range(words)) + "."


def test_estimate_tokens():
    assert estimate_tokens("") == 1
    assert estimate_tokens("a" * 400) == 100


def test_each_heading_path_is_its_own_labeled_section():
    chunks = chunk_document("Aftercare Guide", [
        Block(("Tooth Extraction",), "Bite on the gauze."),
        Block(("Tooth Extraction",), "Do not eat for two hours."),
        Block(("Whitening",), "Avoid coffee for 48 hours."),
    ])
    assert [(c.section, c.content) for c in chunks] == [
        ("Aftercare Guide > Tooth Extraction", "Bite on the gauze.\n\nDo not eat for two hours."),
        ("Aftercare Guide > Whitening", "Avoid coffee for 48 hours."),
    ]
    assert chunks[0].embedding_text == "Aftercare Guide > Tooth Extraction\n\nBite on the gauze.\n\nDo not eat for two hours."


def test_a_main_heading_equal_to_the_title_is_not_repeated():
    chunks = chunk_document("Aftercare Guide", [
        Block(("Aftercare Guide",), "Intro."),
        Block(("aftercare guide", "Tooth Extraction"), "Bite on the gauze."),
    ])
    assert [c.section for c in chunks] == ["Aftercare Guide", "Aftercare Guide > Tooth Extraction"]


def test_text_before_any_heading_is_labeled_with_the_title():
    assert chunk_document("FAQ", [Block((), "Welcome.")])[0].section == "FAQ"


def test_long_sections_are_split_under_the_limit_with_overlap():
    blocks = [Block(("Policies",), paragraph(n)) for n in range(20)]
    chunks = chunk_document("Handbook", blocks, max_tokens=200, overlap_ratio=0.25)
    assert len(chunks) > 1
    assert all(c.token_count <= 200 for c in chunks)
    for previous, current in zip(chunks, chunks[1:]):
        # The next chunk starts with the last paragraph of the previous one
        assert current.content.startswith(previous.content.split("\n\n")[-1])
    # Nothing is lost
    text = "\n\n".join(c.content for c in chunks)
    assert all(paragraph(n) in text for n in range(20))


def test_no_overlap_when_it_would_not_fit():
    chunks = chunk_document("Handbook", [Block((), paragraph(n, words=70)) for n in range(4)],
                            max_tokens=150, overlap_ratio=0.1)
    assert [c.content for c in chunks] == [paragraph(n, words=70) for n in range(4)]


def test_huge_paragraphs_are_split_by_sentences_then_words():
    sentences = " ".join(paragraph(n) for n in range(10))
    endless = " ".join(f"word{i}" for i in range(1000))
    chunks = chunk_document("Doc", [Block((), sentences), Block((), endless)], max_tokens=120, overlap_ratio=0)
    assert all(c.token_count <= 120 for c in chunks)
    assert " ".join(c.content.replace("\n\n", " ") for c in chunks) == f"{sentences} {endless}"


def test_a_paragraph_continued_on_the_next_page_is_rejoined_with_a_space():
    chunk = chunk_document("Doc", [Block((), "Take it with food and", page=1),
                                   Block((), "plenty of water.", page=2, continues=True)])[0]
    assert chunk.content == "Take it with food and plenty of water."
    assert (chunk.page_start, chunk.page_end) == (1, 2)


def test_documents_without_pages_have_no_page_range():
    chunk = chunk_document("Doc", [Block((), "Text.")])[0]
    assert (chunk.page_start, chunk.page_end) == (None, None)
