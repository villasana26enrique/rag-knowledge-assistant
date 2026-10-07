-- Retention: questions can contain personal data, so the logs are not kept forever.

SET search_path TO knowledge, public;

CREATE OR REPLACE FUNCTION purge_old_logs(p_days int) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = knowledge, public AS $$
DECLARE
  v_queries int;
  v_runs    int;
BEGIN
  IF p_days IS NULL OR p_days < 1 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Days must be at least 1.');
  END IF;

  DELETE FROM query_log WHERE created_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_queries = ROW_COUNT;
  DELETE FROM ingestion_runs WHERE started_at < now() - make_interval(days => p_days) AND status <> 'running';
  GET DIAGNOSTICS v_runs = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'query_log_deleted', v_queries, 'ingestion_runs_deleted', v_runs);
END $$;
