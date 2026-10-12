-- Retrieval for the agents: hybrid search (vectors + full text) fused with Reciprocal Rank Fusion,
-- limited by row level security to the agent's knowledge bases, with an "I don't know" threshold.

SET search_path TO knowledge, public;

-- p_query_embedding: the question embedded with the base's model, as text '[0.1, 0.2, ...]'
CREATE OR REPLACE FUNCTION search_knowledge(p_agent text, p_question text, p_query_embedding text,
                                            p_limit int DEFAULT 5)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  -- Each list contributes its top candidates; k = 60 is the usual RRF constant
  c_candidates constant int := 20;
  c_rrf_k      constant int := 60;
  v_started    timestamptz := clock_timestamp();
  v_agent      agents%ROWTYPE;
  v_embedding  vector;
  v_text_query tsquery;
  v_results    jsonb;
  v_top        real;
  v_answerable boolean;
  v_query_id   bigint;
BEGIN
  SELECT * INTO v_agent FROM agents WHERE slug = p_agent;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Unknown agent.');
  END IF;
  IF coalesce(trim(p_question), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'The question is empty.');
  END IF;
  BEGIN
    v_embedding := p_query_embedding::vector;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'message', 'The query embedding is not a valid vector.');
  END;
  IF vector_dims(v_embedding) <> 768 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'The query embedding must have 768 dimensions.');
  END IF;
  p_limit := least(greatest(coalesce(p_limit, 5), 1), c_candidates);

  -- From here on, row level security only shows this agent's knowledge bases
  PERFORM set_config('app.agent_id', v_agent.id::text, true);
  -- A base declared by ingestion earlier in the same transaction must not widen what the agent sees
  PERFORM set_config('app.knowledge_base_id', '', true);
  -- Keep scanning the vector index until enough rows pass that filter (pgvector >= 0.8)
  PERFORM set_config('hnsw.iterative_scan', 'relaxed_order', true);

  -- Any of the question's words may match (OR); ranking rewards chunks that match more of them
  v_text_query := replace(websearch_to_tsquery('english', p_question)::text, ' & ', ' | ')::tsquery;

  WITH vector_hits AS (
    SELECT id, row_number() OVER (ORDER BY distance, id) AS rank, 1 - distance AS similarity
    FROM (SELECT c.id, c.embedding <=> v_embedding AS distance
          FROM chunks c
          ORDER BY c.embedding <=> v_embedding
          LIMIT c_candidates) v
  ),
  text_hits AS (
    SELECT id, row_number() OVER (ORDER BY text_rank DESC, id) AS rank
    FROM (SELECT c.id, ts_rank_cd(c.search_vector, v_text_query) AS text_rank
          FROM chunks c
          WHERE c.search_vector @@ v_text_query
          ORDER BY text_rank DESC, c.id
          LIMIT c_candidates) t
  ),
  fused AS (
    SELECT id, sum(1.0 / (c_rrf_k + rank)) AS score
    FROM (SELECT id, rank FROM vector_hits UNION ALL SELECT id, rank FROM text_hits) hits
    GROUP BY id
    ORDER BY score DESC, id
    LIMIT p_limit
  )
  SELECT
    (SELECT jsonb_agg(jsonb_build_object(
              'chunk_id', c.id,
              'document_id', d.id,
              'document_title', d.title,
              'section', c.section,
              'content', c.content,
              'source_url', d.source_url,
              'page_start', c.page_start,
              'page_end', c.page_end,
              'similarity', round((1 - (c.embedding <=> v_embedding))::numeric, 4),
              'score', round(f.score, 6))
            ORDER BY f.score DESC, f.id)
     FROM fused f
     JOIN chunks c ON c.id = f.id
     JOIN documents d ON d.id = c.document_id),
    (SELECT max(similarity) FROM vector_hits)
  INTO v_results, v_top;

  v_answerable := v_top IS NOT NULL AND v_top >= v_agent.min_similarity;

  -- Logged even when unanswerable: the near misses are what the threshold is calibrated with
  INSERT INTO query_log (agent_id, question, top_similarity, answerable, results, search_ms)
  VALUES (v_agent.id, p_question, v_top, v_answerable,
          coalesce((SELECT jsonb_agg(jsonb_build_object('chunk_id', r->'chunk_id', 'document_id', r->'document_id',
                                                        'similarity', r->'similarity', 'score', r->'score'))
                    FROM jsonb_array_elements(v_results) r), '[]'),
          (extract(epoch FROM clock_timestamp() - v_started) * 1000)::int)
  RETURNING id INTO v_query_id;

  RETURN jsonb_build_object(
    'ok', true,
    'query_id', v_query_id,
    'answerable', v_answerable,
    'message', CASE WHEN v_answerable
                    THEN 'Answer only from these passages and cite their document titles.'
                    ELSE 'The knowledge base has no relevant information for this question. Say you do not know.'
               END,
    'results', CASE WHEN v_answerable THEN v_results ELSE '[]' END);
END $$;


-- Stores the agent's final answer next to the search that produced it
CREATE OR REPLACE FUNCTION record_answer(p_query_id bigint, p_answer text) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
BEGIN
  UPDATE query_log SET answer = p_answer WHERE id = p_query_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'No search with that id.');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;
