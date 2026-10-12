-- Database tests for ingestion, hybrid search and isolation between knowledge bases.
-- Runs inside a transaction that is rolled back: nothing is left behind.
-- The assertions run as rag_app (the role n8n uses), because superusers bypass row level security.
-- Expected output: NOTICE: ALL TESTS PASSED

\set ON_ERROR_STOP on
BEGIN;

-- Fixtures (as the owner: rag_app cannot create bases or agents)
INSERT INTO knowledge.knowledge_bases (slug, name) VALUES ('test-kb-a', 'Test A'), ('test-kb-b', 'Test B');
INSERT INTO knowledge.agents (slug, name) VALUES
  ('test-agent-a', 'Reads A'), ('test-agent-b', 'Reads B'), ('test-agent-ab', 'Reads A and B');
INSERT INTO knowledge.agent_knowledge_bases (agent_id, knowledge_base_id)
SELECT a.id, kb.id
FROM knowledge.agents a
JOIN knowledge.knowledge_bases kb ON (a.slug, kb.slug) IN (
  ('test-agent-a', 'test-kb-a'), ('test-agent-b', 'test-kb-b'),
  ('test-agent-ab', 'test-kb-a'), ('test-agent-ab', 'test-kb-b'));

-- Fake 768-dimension unit embeddings: ARRAY[1] is axis 1, ARRAY[0.8, 0.6] is 80% similar to it, ...
CREATE FUNCTION pg_temp.test_embedding(p_weights float8[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT to_jsonb(array(
    SELECT coalesce(p_weights[i], 0) / (SELECT sqrt(sum(w * w)) FROM unnest(p_weights) w)
    FROM generate_series(1, 768) i))
$$;

SET LOCAL ROLE rag_app;

DO $$
DECLARE
  r        jsonb;
  doc_a    jsonb := jsonb_build_object('source', 'google_drive', 'source_id', 'file-1', 'title', 'Aftercare Guide',
                                       'content_hash', 'hash-1', 'source_modified_at', '2026-01-01T00:00:00Z');
  doc_b    jsonb := jsonb_build_object('source', 'google_drive', 'source_id', 'file-9', 'title', 'Staff Policies',
                                       'content_hash', 'hash-9', 'source_modified_at', '2026-01-01T00:00:00Z');
  e1       jsonb := pg_temp.test_embedding(ARRAY[1]);
  e3       jsonb := pg_temp.test_embedding(ARRAY[0, 0, 1]);
  e5       jsonb := pg_temp.test_embedding(ARRAY[0, 0, 0, 0, 1]);
  chunks_a jsonb;
  doc_a_id bigint;
  doc_b_id bigint;
  kb_a_id  int := (SELECT id FROM knowledge.knowledge_bases WHERE slug = 'test-kb-a');
  kb_b_id  int := (SELECT id FROM knowledge.knowledge_bases WHERE slug = 'test-kb-b');
  agent_a  int := (SELECT id FROM knowledge.agents WHERE slug = 'test-agent-a');
  n        int;
BEGIN
  chunks_a := jsonb_build_array(
    jsonb_build_object('section', 'Aftercare Guide > Tooth Extraction',
                       'content', 'After a tooth extraction, do not eat for two hours.', 'embedding', e1, 'page_start', 1, 'page_end', 2),
    jsonb_build_object('section', 'Aftercare Guide > Insurance',
                       'content', 'We accept Delta Dental PPO plans.',
                       'embedding', pg_temp.test_embedding(ARRAY[0.8, 0.6])));

  ---------------------------------------------------------------- ingestion
  r := knowledge.upsert_document('test-kb-a', doc_a, chunks_a);
  ASSERT (r->>'ok')::boolean AND r->>'action' = 'added' AND (r->>'version')::int = 1
         AND (r->>'chunk_count')::int = 2, 'A new document should be added as version 1: ' || r::text;
  doc_a_id := (r->>'document_id')::bigint;

  r := knowledge.upsert_document('test-kb-b', doc_b, jsonb_build_array(jsonb_build_object(
         'content', 'Full-time staff get fifteen vacation days per year.', 'embedding', e3)));
  ASSERT (r->>'ok')::boolean, 'Document B should be added: ' || r::text;
  doc_b_id := (r->>'document_id')::bigint;

  r := knowledge.upsert_document('nope', doc_a, chunks_a);
  ASSERT (r->>'ok')::boolean = false, 'Unknown knowledge base should be rejected';
  r := knowledge.upsert_document('test-kb-a', doc_a, '[]');
  ASSERT (r->>'ok')::boolean = false, 'A document without chunks should be rejected';
  r := knowledge.upsert_document('test-kb-a', doc_a,
         jsonb_build_array(jsonb_build_object('content', 'x', 'embedding', '[1, 2, 3]'::jsonb)));
  ASSERT (r->>'ok')::boolean = false, 'Embeddings with the wrong dimensions should be rejected';
  r := knowledge.upsert_document('test-kb-a', doc_a || '{"source": "dropbox"}', chunks_a);
  ASSERT (r->>'ok')::boolean = false, 'Unknown sources should be rejected';
  r := knowledge.upsert_document('test-kb-a', doc_a,
         jsonb_build_array(jsonb_build_object('content', 'x', 'embedding', e1, 'page_start', 3, 'page_end', 2)));
  ASSERT (r->>'ok')::boolean = false, 'A page range ending before it starts should be rejected';
  r := knowledge.upsert_document('test-kb-a', doc_a,
         jsonb_build_array(jsonb_build_object('content', 'x', 'embedding', e1, 'page_start', 3)));
  ASSERT (r->>'ok')::boolean = false, 'A page range needs both ends';

  ---------------------------------------------------------------- search
  r := knowledge.search_knowledge('test-agent-a', 'What should I do after an extraction?', e1::text);
  ASSERT (r->>'ok')::boolean AND (r->>'answerable')::boolean, 'A matching question should be answerable: ' || r::text;
  ASSERT r->'results'->0->>'content' LIKE 'After a tooth extraction%'
         AND r->'results'->0->>'document_title' = 'Aftercare Guide', 'Best match should come first, with its title';
  ASSERT (r->'results'->0->>'page_start')::int = 1 AND (r->'results'->0->>'page_end')::int = 2,
         'Results should carry their page range for citations: ' || r::text;

  -- Hybrid: the vector search prefers the extraction chunk, but "PPO" only appears in the insurance chunk.
  -- Found by both searches, the insurance chunk must win the fusion.
  r := knowledge.search_knowledge('test-agent-a', 'Do you take PPO insurance?', e1::text);
  ASSERT r->'results'->0->>'content' LIKE '%Delta Dental PPO%', 'RRF should rank the keyword match first: ' || r::text;

  -- Threshold: nothing similar enough -> say "I don't know", return no passages
  r := knowledge.search_knowledge('test-agent-a', 'Do you sell toothbrushes?', e5::text);
  ASSERT (r->>'ok')::boolean AND (r->>'answerable')::boolean = false
         AND jsonb_array_length(r->'results') = 0, 'Unrelated questions should not be answerable: ' || r::text;

  r := knowledge.search_knowledge('nobody', 'Hi', e1::text);
  ASSERT (r->>'ok')::boolean = false, 'Unknown agent should be rejected';
  r := knowledge.search_knowledge('test-agent-a', '  ', e1::text);
  ASSERT (r->>'ok')::boolean = false, 'Empty question should be rejected';
  r := knowledge.search_knowledge('test-agent-a', 'Hi', '[1, 2, 3]');
  ASSERT (r->>'ok')::boolean = false, 'Query embeddings with the wrong dimensions should be rejected';
  r := knowledge.search_knowledge('test-agent-a', 'Hi', 'not a vector');
  ASSERT (r->>'ok')::boolean = false, 'Invalid query embeddings should be rejected';

  ---------------------------------------------------------------- isolation (row level security)
  -- The staff answer exists (similarity 1 in base B), but agent A must not see it
  r := knowledge.search_knowledge('test-agent-a', 'How many vacation days do staff get?', e3::text);
  ASSERT (r->>'answerable')::boolean = false AND jsonb_array_length(r->'results') = 0,
         'Agent A must not retrieve documents from base B: ' || r::text;
  ASSERT (SELECT top_similarity < 0.5 FROM knowledge.query_log WHERE id = (r->>'query_id')::bigint),
         'Base B must not even be a candidate for agent A';

  r := knowledge.search_knowledge('test-agent-ab', 'How many vacation days do staff get?', e3::text);
  ASSERT (r->>'answerable')::boolean AND r->'results'->0->>'content' LIKE '%fifteen vacation days%',
         'An agent assigned to both bases should find it: ' || r::text;

  -- Searching right after ingesting into B in the same transaction must not widen agent A's access
  PERFORM knowledge.skip_if_unchanged('test-kb-b', 'google_drive', 'file-9', 'Staff Policies', 'hash-9', now());
  r := knowledge.search_knowledge('test-agent-a', 'How many vacation days do staff get?', e3::text);
  ASSERT (r->>'answerable')::boolean = false, 'Ingestion settings must not leak into searches';

  -- Fails closed: with no agent or base declared, plain queries see nothing
  PERFORM set_config('app.agent_id', '', true);
  PERFORM set_config('app.knowledge_base_id', '', true);
  SELECT count(*) INTO n FROM knowledge.chunks;
  ASSERT n = 0, 'Without a declared agent, no chunks should be visible (saw ' || n || ')';
  SELECT count(*) INTO n FROM knowledge.documents;
  ASSERT n = 0, 'Without a declared agent, no documents should be visible';

  PERFORM set_config('app.agent_id', agent_a::text, true);
  ASSERT (SELECT count(*) FROM knowledge.chunks WHERE knowledge_base_id = kb_b_id) = 0,
         'Agent A should see no chunks of base B, even without a WHERE on its own bases';
  ASSERT (SELECT count(*) FROM knowledge.chunks WHERE knowledge_base_id = kb_a_id) = 2,
         'Agent A should see the chunks of base A';
  PERFORM set_config('app.agent_id', '', true);

  -- Ingestion declared for base A cannot write into base B
  PERFORM set_config('app.knowledge_base_id', kb_a_id::text, true);
  BEGIN
    INSERT INTO knowledge.chunks (document_id, knowledge_base_id, chunk_index, content, embedding)
    VALUES (doc_b_id, kb_b_id, 99, 'injected', (e1)::text::vector);
    ASSERT false, 'Writing into another base should be blocked';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;  -- "new row violates row-level security policy"
  END;
  PERFORM set_config('app.knowledge_base_id', '', true);

  ---------------------------------------------------------------- updates and change detection
  r := knowledge.upsert_document('test-kb-a', doc_a || '{"content_hash": "hash-2"}',
         jsonb_build_array(jsonb_build_object('content', 'After an extraction, rest for 24 hours.', 'embedding', e1)));
  ASSERT r->>'action' = 'updated' AND (r->>'version')::int = 2 AND (r->>'document_id')::bigint = doc_a_id,
         'Re-ingesting should update the same document as version 2: ' || r::text;
  PERFORM set_config('app.agent_id', agent_a::text, true);
  ASSERT (SELECT count(*) FROM knowledge.chunks WHERE document_id = doc_a_id) = 1,
         'The old chunks should be replaced, not added to';
  PERFORM set_config('app.agent_id', '', true);

  r := knowledge.skip_if_unchanged('test-kb-a', 'google_drive', 'file-1', 'Aftercare Guide', 'hash-2', '2026-02-01T00:00:00Z');
  ASSERT (r->>'unchanged')::boolean, 'Same content hash should be detected as unchanged';
  r := knowledge.skip_if_unchanged('test-kb-a', 'google_drive', 'file-1', 'Aftercare Guide', 'hash-3', '2026-02-01T00:00:00Z');
  ASSERT (r->>'unchanged')::boolean = false, 'A different hash should need processing';
  r := knowledge.skip_if_unchanged('test-kb-a', 'google_drive', 'file-new', 'New File', 'hash-1', now());
  ASSERT (r->>'unchanged')::boolean = false, 'A new file should need processing';
  r := knowledge.skip_if_unchanged('test-kb-a', 'google_drive', 'file-1', 'Aftercare Guide (2026)', 'hash-2', now());
  ASSERT (r->>'unchanged')::boolean = false, 'A renamed file should be processed again (its title labels every chunk)';

  ---------------------------------------------------------------- sync plan
  -- file-1 is stored with modified_at 2026-02-01 (updated by skip_if_unchanged above)
  r := knowledge.plan_sync('test-kb-a', 'google_drive', '[
    {"source_id": "file-1", "title": "Aftercare Guide", "modified_at": "2026-02-01T00:00:00Z"},
    {"source_id": "file-2", "title": "Insurance FAQ", "modified_at": "2026-02-01T00:00:00Z"}]');
  ASSERT (r->>'ok')::boolean AND jsonb_array_length(r->'to_process') = 1
         AND r->'to_process'->0->>'source_id' = 'file-2' AND jsonb_array_length(r->'to_delete') = 0
         AND (r->>'unchanged')::int = 1, 'Only the new file should be processed: ' || r::text;

  r := knowledge.plan_sync('test-kb-a', 'google_drive',
         '[{"source_id": "file-1", "title": "Aftercare Guide", "modified_at": "2026-03-01T00:00:00Z"}]');
  ASSERT r->'to_process'->0->>'source_id' = 'file-1', 'A modified file should be processed again: ' || r::text;

  r := knowledge.plan_sync('test-kb-a', 'google_drive',
         '[{"source_id": "file-1", "title": "Aftercare Guide (renamed)", "modified_at": "2026-02-01T00:00:00Z"}]');
  ASSERT r->'to_process'->0->>'source_id' = 'file-1', 'A renamed file should be processed again, even with the same date: ' || r::text;

  r := knowledge.plan_sync('test-kb-a', 'google_drive',
         '[{"source_id": "file-2", "title": "Insurance FAQ", "modified_at": "2026-02-01T00:00:00Z"}]');
  ASSERT r->'to_delete'->0->>'source_id' = 'file-1', 'A file missing from the source should be deleted: ' || r::text;

  r := knowledge.plan_sync('test-kb-a', 'google_drive', '[]');
  ASSERT (r->>'ok')::boolean = false, 'An empty listing must not delete every document';

  ---------------------------------------------------------------- deletion
  r := knowledge.delete_document('test-kb-a', 'google_drive', 'file-1');
  ASSERT (r->>'deleted')::boolean, 'The document should be deleted';
  r := knowledge.delete_document('test-kb-a', 'google_drive', 'file-1');
  ASSERT (r->>'ok')::boolean AND (r->>'deleted')::boolean = false, 'Deleting twice should be harmless';

  r := knowledge.search_knowledge('test-agent-a', 'What should I do after an extraction?', e1::text);
  ASSERT (r->>'answerable')::boolean = false, 'A deleted document must never be retrieved: ' || r::text;

  r := knowledge.plan_sync('test-kb-a', 'google_drive',
         '[{"source_id": "file-1", "title": "Aftercare Guide", "modified_at": "2026-02-01T00:00:00Z"}]');
  ASSERT r->'to_process'->0->>'source_id' = 'file-1', 'A file that comes back should be processed again';
  r := knowledge.upsert_document('test-kb-a', doc_a, chunks_a);
  ASSERT r->>'action' = 'added' AND (r->>'version')::int = 3, 'A restored document counts as added: ' || r::text;

  ---------------------------------------------------------------- logs and runs
  r := knowledge.search_knowledge('test-agent-a', 'What should I do after an extraction?', e1::text);
  ASSERT (knowledge.record_answer((r->>'query_id')::bigint, 'Do not eat for two hours.')->>'ok')::boolean,
         'The answer should be stored with its search';
  ASSERT (SELECT answer IS NOT NULL AND jsonb_array_length(results) > 0
          FROM knowledge.query_log WHERE id = (r->>'query_id')::bigint), 'The search should be logged';
  ASSERT (knowledge.record_answer(-1, 'x')->>'ok')::boolean = false, 'Unknown search ids should be rejected';

  r := knowledge.start_ingestion_run('test-kb-a', 'manual');
  ASSERT (r->>'ok')::boolean, 'An ingestion run should start';
  ASSERT (knowledge.finish_ingestion_run((r->>'run_id')::bigint,
            '{"files_seen": 3, "added": 1, "failed": 1, "errors": [{"source_id": "x", "error": "boom"}]}')->>'ok')::boolean,
         'The run should finish';
  ASSERT (SELECT status = 'partial' AND documents_failed = 1 AND jsonb_array_length(errors) = 1
          FROM knowledge.ingestion_runs WHERE id = (r->>'run_id')::bigint), 'Failures should make the run partial';
  ASSERT (knowledge.finish_ingestion_run((r->>'run_id')::bigint, '{}')->>'ok')::boolean = false,
         'A run cannot finish twice';
  ASSERT (knowledge.start_ingestion_run('test-kb-a', 'cron')->>'ok')::boolean = false, 'Unknown triggers are rejected';

  INSERT INTO knowledge.query_log (agent_id, question, answerable, created_at)
  VALUES (agent_a, 'old question', false, now() - interval '100 days');
  r := knowledge.purge_old_logs(90);
  ASSERT (r->>'query_log_deleted')::int >= 1, 'Old searches should be purged';
  ASSERT NOT EXISTS (SELECT FROM knowledge.query_log WHERE question = 'old question'), 'The old search should be gone';

  RAISE NOTICE 'ALL TESTS PASSED';
END $$;

ROLLBACK;
