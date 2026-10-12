-- Ingestion: decide what to sync, store documents with their chunks atomically, delete removed ones.
-- Called by the n8n ingestion workflows. Every function pins search_path (n8n connects with public).
-- Business cases return {ok: false, message} instead of raising errors.

SET search_path TO knowledge, public;

-- Resolves the base and declares it for row level security (this transaction only)
CREATE OR REPLACE FUNCTION use_knowledge_base(p_knowledge_base text) RETURNS int
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_id int;
BEGIN
  SELECT id INTO v_id FROM knowledge_bases WHERE slug = p_knowledge_base;
  PERFORM set_config('app.knowledge_base_id', coalesce(v_id::text, ''), true);
  -- An agent declared earlier in the same transaction must not widen what ingestion sees
  PERFORM set_config('app.agent_id', '', true);
  RETURN v_id;
END $$;


-- Compares the files currently in the source with what is stored.
-- p_files: [{source_id, title, modified_at}] -> files to (re)process and documents to delete.
-- A file is (re)processed when it is new, was deleted, has a new date or a new title.
CREATE OR REPLACE FUNCTION plan_sync(p_knowledge_base text, p_source text, p_files jsonb) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_kb_id     int := use_knowledge_base(p_knowledge_base);
  v_files     jsonb := coalesce(p_files, '[]');
  v_process   jsonb;
  v_delete    jsonb;
  v_unchanged int;
BEGIN
  IF v_kb_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Unknown knowledge base.');
  END IF;

  -- An empty listing is far more likely a failed or misconfigured listing than an emptied folder
  IF jsonb_array_length(v_files) = 0 AND EXISTS (
       SELECT FROM documents WHERE knowledge_base_id = v_kb_id AND source = p_source AND status = 'active') THEN
    RETURN jsonb_build_object('ok', false, 'message',
      'The source listing is empty: refusing to delete every document. Use delete_document if that is intended.');
  END IF;

  WITH files AS (
    SELECT * FROM jsonb_to_recordset(v_files) AS f(source_id text, title text, modified_at timestamptz)
  )
  SELECT
    coalesce(jsonb_agg(to_jsonb(f)) FILTER (
      WHERE d.id IS NULL OR d.status = 'deleted' OR d.source_modified_at IS DISTINCT FROM f.modified_at
         OR d.title IS DISTINCT FROM f.title), '[]'),
    count(*) FILTER (
      WHERE d.status = 'active' AND d.source_modified_at IS NOT DISTINCT FROM f.modified_at
        AND d.title IS NOT DISTINCT FROM f.title)
  INTO v_process, v_unchanged
  FROM files f
  LEFT JOIN documents d
    ON d.knowledge_base_id = v_kb_id AND d.source = p_source AND d.source_id = f.source_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('source_id', d.source_id, 'title', d.title)), '[]')
  INTO v_delete
  FROM documents d
  WHERE d.knowledge_base_id = v_kb_id AND d.source = p_source AND d.status = 'active'
    AND NOT EXISTS (SELECT FROM jsonb_array_elements(v_files) f WHERE f->>'source_id' = d.source_id);

  RETURN jsonb_build_object('ok', true, 'to_process', v_process, 'to_delete', v_delete,
                            'unchanged', v_unchanged);
END $$;


-- A file whose date changed may still have the same text (permissions changed, edited and reverted...).
-- Same text and same title: remember the new date and skip the embeddings.
-- A new title is a change: it is part of every chunk's label, which is embedded with the text.
DROP FUNCTION IF EXISTS skip_if_unchanged(text, text, text, text, timestamptz);
CREATE OR REPLACE FUNCTION skip_if_unchanged(p_knowledge_base text, p_source text, p_source_id text,
                                             p_title text, p_content_hash text, p_source_modified_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_kb_id int := use_knowledge_base(p_knowledge_base);
BEGIN
  IF v_kb_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Unknown knowledge base.');
  END IF;

  UPDATE documents
  SET source_modified_at = p_source_modified_at, updated_at = now()
  WHERE knowledge_base_id = v_kb_id AND source = p_source AND source_id = p_source_id
    AND status = 'active' AND content_hash = p_content_hash AND title = p_title;

  RETURN jsonb_build_object('ok', true, 'unchanged', FOUND);
END $$;


-- Stores a document and replaces all its chunks in one transaction:
-- searches see either the previous version or the new one, never a mix or nothing.
-- p_document: {source, source_id, title, mime_type, source_url, content_hash, source_modified_at}
-- p_chunks:   [{section, content, token_count, page_start, page_end, embedding: [768 numbers]}] in document order
CREATE OR REPLACE FUNCTION upsert_document(p_knowledge_base text, p_document jsonb, p_chunks jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_kb_id           int := use_knowledge_base(p_knowledge_base);
  v_previous_status text;
  v_document_id     bigint;
  v_version         int;
  v_chunk_count     int;
BEGIN
  IF v_kb_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Unknown knowledge base.');
  END IF;
  IF coalesce(p_document->>'source', '') NOT IN ('google_drive', 'upload') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Source must be google_drive or upload.');
  END IF;
  IF coalesce(p_document->>'source_id', '') = '' OR coalesce(p_document->>'title', '') = ''
     OR coalesce(p_document->>'content_hash', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'source_id, title and content_hash are required.');
  END IF;
  IF jsonb_typeof(p_chunks) IS DISTINCT FROM 'array' OR jsonb_array_length(p_chunks) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'The document has no chunks (no text was extracted?).');
  END IF;
  IF EXISTS (SELECT FROM jsonb_array_elements(p_chunks) c
             WHERE coalesce(trim(c->>'content'), '') = ''
                OR jsonb_typeof(c->'embedding') IS DISTINCT FROM 'array'
                OR jsonb_array_length(c->'embedding') <> 768) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Every chunk needs content and a 768-dimension embedding.');
  END IF;
  -- Pages: both missing, or both numbers with 1 <= start <= end
  IF EXISTS (SELECT FROM jsonb_array_elements(p_chunks) c,
                    LATERAL (SELECT jsonb_typeof(coalesce(c->'page_start', 'null')) AS start_type,
                                    jsonb_typeof(coalesce(c->'page_end', 'null')) AS end_type) t
             WHERE NOT CASE
                     WHEN t.start_type = 'null' AND t.end_type = 'null' THEN true
                     WHEN t.start_type = 'number' AND t.end_type = 'number'
                       THEN (c->>'page_start')::numeric >= 1 AND (c->>'page_end')::numeric >= (c->>'page_start')::numeric
                     ELSE false
                   END) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Page ranges need page_start >= 1 and page_end >= page_start.');
  END IF;

  SELECT status INTO v_previous_status
  FROM documents
  WHERE knowledge_base_id = v_kb_id AND source = p_document->>'source' AND source_id = p_document->>'source_id'
  FOR UPDATE;

  INSERT INTO documents (knowledge_base_id, source, source_id, title, mime_type, source_url,
                         content_hash, source_modified_at)
  VALUES (v_kb_id, p_document->>'source', p_document->>'source_id', p_document->>'title',
          p_document->>'mime_type', p_document->>'source_url', p_document->>'content_hash',
          (p_document->>'source_modified_at')::timestamptz)
  ON CONFLICT (knowledge_base_id, source, source_id) DO UPDATE
  SET title = EXCLUDED.title,
      mime_type = EXCLUDED.mime_type,
      source_url = EXCLUDED.source_url,
      content_hash = EXCLUDED.content_hash,
      source_modified_at = EXCLUDED.source_modified_at,
      version = documents.version + 1,
      status = 'active',
      deleted_at = NULL,
      updated_at = now()
  RETURNING id, version INTO v_document_id, v_version;

  DELETE FROM chunks WHERE document_id = v_document_id;

  INSERT INTO chunks (document_id, knowledge_base_id, chunk_index, section, content, token_count, embedding,
                      page_start, page_end)
  SELECT v_document_id, v_kb_id, (c.ordinality - 1)::int, nullif(c.value->>'section', ''), c.value->>'content',
         (c.value->>'token_count')::int, (c.value->>'embedding')::vector,
         (c.value->>'page_start')::int, (c.value->>'page_end')::int
  FROM jsonb_array_elements(p_chunks) WITH ORDINALITY AS c;
  GET DIAGNOSTICS v_chunk_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'action', CASE WHEN v_previous_status = 'active' THEN 'updated' ELSE 'added' END,
    'document_id', v_document_id,
    'version', v_version,
    'chunk_count', v_chunk_count);
END $$;


-- The file is gone from the source: keep the document row (audit) and remove its chunks
-- so it can never be retrieved again. Deleting twice is harmless.
CREATE OR REPLACE FUNCTION delete_document(p_knowledge_base text, p_source text, p_source_id text)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_kb_id       int := use_knowledge_base(p_knowledge_base);
  v_document_id bigint;
BEGIN
  IF v_kb_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Unknown knowledge base.');
  END IF;

  UPDATE documents
  SET status = 'deleted', deleted_at = now(), updated_at = now()
  WHERE knowledge_base_id = v_kb_id AND source = p_source AND source_id = p_source_id AND status = 'active'
  RETURNING id INTO v_document_id;

  IF v_document_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'deleted', false);
  END IF;

  DELETE FROM chunks WHERE document_id = v_document_id;
  RETURN jsonb_build_object('ok', true, 'deleted', true, 'document_id', v_document_id);
END $$;


CREATE OR REPLACE FUNCTION start_ingestion_run(p_knowledge_base text, p_trigger text) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_kb_id  int := use_knowledge_base(p_knowledge_base);
  v_run_id bigint;
BEGIN
  IF v_kb_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Unknown knowledge base.');
  END IF;
  IF p_trigger NOT IN ('schedule', 'manual', 'upload') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Trigger must be schedule, manual or upload.');
  END IF;

  INSERT INTO ingestion_runs (knowledge_base_id, trigger) VALUES (v_kb_id, p_trigger)
  RETURNING id INTO v_run_id;
  RETURN jsonb_build_object('ok', true, 'run_id', v_run_id);
END $$;


-- p_stats: {files_seen, added, updated, unchanged, deleted, failed, errors: [...], fatal_error}
CREATE OR REPLACE FUNCTION finish_ingestion_run(p_run_id bigint, p_stats jsonb) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_failed int := coalesce((p_stats->>'failed')::int, 0);
BEGIN
  UPDATE ingestion_runs
  SET files_seen          = coalesce((p_stats->>'files_seen')::int, 0),
      documents_added     = coalesce((p_stats->>'added')::int, 0),
      documents_updated   = coalesce((p_stats->>'updated')::int, 0),
      documents_unchanged = coalesce((p_stats->>'unchanged')::int, 0),
      documents_deleted   = coalesce((p_stats->>'deleted')::int, 0),
      documents_failed    = v_failed,
      errors              = coalesce(p_stats->'errors', '[]')
                            || CASE WHEN p_stats ? 'fatal_error'
                                    THEN jsonb_build_array(jsonb_build_object('error', p_stats->>'fatal_error'))
                                    ELSE '[]' END,
      status              = CASE WHEN p_stats ? 'fatal_error' THEN 'failed'
                                 WHEN v_failed > 0 THEN 'partial'
                                 ELSE 'succeeded' END,
      finished_at         = now()
  WHERE id = p_run_id AND status = 'running';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'No running ingestion run with that id.');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;
