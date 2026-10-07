"""Document processor for n8n: PDF / DOCX / Markdown -> clean text split into chunks ready to embed.

POST /extract-and-chunk?title=Aftercare%20Guide[&max_tokens=500]
     body: the file itself; Content-Type: its type (application/pdf, DOCX, text/markdown, text/plain)
  -> {"title", "content_hash", "token_count",
      "chunks": [{"index", "section", "content", "embedding_text", "token_count", "page_start", "page_end"}]}
GET  /health -> ok

No model calls and no secrets here: the same file always gives the same chunks, and the tests need no network.
"""
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from chunking import SECTION_SEPARATOR, chunk_document, estimate_tokens
from extract import ExtractionError, UnsupportedTypeError, extract_blocks

MAX_BYTES = 20 * 1024 * 1024
DEFAULT_MAX_TOKENS = 500
MAX_TOKENS_RANGE = range(100, 2001)


def process(data: bytes, mime_type: str, title: str, max_tokens: int = DEFAULT_MAX_TOKENS) -> dict:
    blocks = extract_blocks(data, mime_type)
    chunks = chunk_document(title, blocks, max_tokens)
    # Hash of the extracted text, not of the file: re-saving a file without changing it is not a change
    text = "\n".join(SECTION_SEPARATOR.join(b.headings) + "\n" + b.text for b in blocks)
    return {
        "title": title,
        "content_hash": hashlib.sha256(text.encode()).hexdigest(),
        "token_count": sum(estimate_tokens(b.text) for b in blocks),
        "chunks": [
            {"index": i, "section": c.section, "content": c.content, "embedding_text": c.embedding_text,
             "token_count": c.token_count, "page_start": c.page_start, "page_end": c.page_end}
            for i, c in enumerate(chunks)
        ],
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._respond(200, b"ok", "text/plain")
        else:
            self._respond(404, b"not found", "text/plain")

    def do_POST(self):
        url = urlparse(self.path)
        if url.path != "/extract-and-chunk":
            return self._respond(404, b"not found", "text/plain")

        params = parse_qs(url.query)
        title = params.get("title", [""])[0].strip()
        if not title:
            return self._error(400, "The title query parameter is required")
        try:
            max_tokens = int(params.get("max_tokens", [DEFAULT_MAX_TOKENS])[0])
        except ValueError:
            max_tokens = 0
        if max_tokens not in MAX_TOKENS_RANGE:
            return self._error(400, "max_tokens must be between 100 and 2000")

        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > MAX_BYTES:
            return self._error(413, "Empty or too large body")
        data = self.rfile.read(length)

        try:
            result = process(data, self.headers.get("Content-Type", ""), title, max_tokens)
        except UnsupportedTypeError as e:
            return self._error(415, str(e))
        except ExtractionError as e:
            return self._error(422, str(e))

        self._respond(200, json.dumps(result).encode(), "application/json")

    def _error(self, status, message):
        self._respond(status, json.dumps({"error": message}).encode(), "application/json")

    def _respond(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
