-- rag_app: the unprivileged role n8n connects with. It is not the table owner and not a superuser,
-- so row level security always applies to it. The password comes from RAG_APP_PASSWORD (.env).

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rag_app') THEN
    EXECUTE format('CREATE ROLE rag_app LOGIN PASSWORD %L', '${rag_app_password}');
  ELSE
    EXECUTE format('ALTER ROLE rag_app LOGIN PASSWORD %L', '${rag_app_password}');
  END IF;
END $$;

GRANT USAGE ON SCHEMA knowledge TO rag_app;
GRANT SELECT ON knowledge.knowledge_bases, knowledge.agents, knowledge.agent_knowledge_bases TO rag_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON knowledge.documents, knowledge.chunks TO rag_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON knowledge.ingestion_runs, knowledge.query_log TO rag_app;
-- Chat memory: n8n's memory node needs CREATE on its schema (it runs CREATE TABLE IF NOT EXISTS)
GRANT USAGE, CREATE ON SCHEMA chat_memory TO rag_app;
GRANT SELECT, INSERT, DELETE ON chat_memory.chat_history TO rag_app;
GRANT USAGE ON SEQUENCE chat_memory.chat_history_id_seq TO rag_app;
-- Checking a key: read the hashes and record when a key was last used, nothing else
GRANT SELECT, UPDATE (last_used_at) ON knowledge.agent_api_keys TO rag_app;
