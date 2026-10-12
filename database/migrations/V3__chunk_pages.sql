-- Page range of each chunk (PDFs only), so answers can cite "Aftercare Guide, p. 3".

SET search_path TO knowledge, public;

ALTER TABLE chunks
  ADD COLUMN page_start int,
  ADD COLUMN page_end   int,
  ADD CONSTRAINT chunks_page_range_check CHECK (
    (page_start IS NULL AND page_end IS NULL) OR (page_start >= 1 AND page_end >= page_start));
