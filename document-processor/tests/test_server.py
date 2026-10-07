import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from extract import DOCX, PDF
from server import Handler
from tests.samples import make_docx, make_markdown, make_pdf


@pytest.fixture(scope="module")
def base_url():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def post(base_url, body, content_type, query="?title=Aftercare%20Guide"):
    request = urllib.request.Request(f"{base_url}/extract-and-chunk{query}", data=body, method="POST",
                                     headers={"Content-Type": content_type})
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_health(base_url):
    with urllib.request.urlopen(f"{base_url}/health") as response:
        assert response.read() == b"ok"


@pytest.mark.parametrize("sample, content_type", [(make_docx, DOCX), (make_pdf, PDF), (make_markdown, "text/markdown")])
def test_returns_chunks_ready_to_embed(base_url, sample, content_type):
    status, body = post(base_url, sample(), content_type)
    assert status == 200
    assert body["title"] == "Aftercare Guide" and len(body["content_hash"]) == 64 and body["token_count"] > 0
    first = body["chunks"][0]
    assert first["index"] == 0
    assert first["section"].startswith("Aftercare Guide > ")
    assert first["embedding_text"] == f"{first['section']}\n\n{first['content']}"


def test_pdf_chunks_carry_their_pages(base_url):
    _, body = post(base_url, make_pdf(), PDF)
    assert [(c["page_start"], c["page_end"]) for c in body["chunks"]] == [(1, 1), (1, 2), (2, 2)]


def test_content_hash_follows_the_text_not_the_file(base_url):
    _, first = post(base_url, make_docx(), DOCX)
    _, again = post(base_url, make_docx(), DOCX)  # a new file with the same text
    _, other = post(base_url, make_markdown(), "text/markdown")
    assert first["content_hash"] == again["content_hash"] != other["content_hash"]


@pytest.mark.parametrize("query, status", [("", 400), ("?title=%20", 400), ("?title=x&max_tokens=5", 400),
                                           ("?title=x&max_tokens=abc", 400)])
def test_invalid_parameters(base_url, query, status):
    assert post(base_url, make_markdown(), "text/markdown", query)[0] == status


def test_unsupported_type(base_url):
    status, body = post(base_url, b"\x89PNG", "image/png")
    assert status == 415 and "Unsupported" in body["error"]


def test_unreadable_file(base_url):
    assert post(base_url, b"broken", PDF)[0] == 422


def test_empty_body(base_url):
    assert post(base_url, b"", PDF)[0] == 413
