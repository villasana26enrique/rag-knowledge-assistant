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
