-- Isolation between knowledge bases, enforced by PostgreSQL itself.
-- The search and ingestion functions declare who is acting for the current transaction:
--   app.agent_id          -> the agent may read the bases assigned to it
--   app.knowledge_base_id -> ingestion may read and write that one base
-- Nothing declared = no rows: access fails closed, even if a query forgets its WHERE.

SET search_path TO knowledge, public;

CREATE OR REPLACE FUNCTION current_agent_id() RETURNS int
LANGUAGE sql STABLE
SET search_path = knowledge, public AS $$
  SELECT nullif(current_setting('app.agent_id', true), '')::int
$$;

CREATE OR REPLACE FUNCTION current_ingestion_knowledge_base_id() RETURNS int
LANGUAGE sql STABLE
SET search_path = knowledge, public AS $$
  SELECT nullif(current_setting('app.knowledge_base_id', true), '')::int
$$;

-- FORCE: the policies also apply to the table owner (superusers always bypass them)
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;
ALTER TABLE chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE chunks FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS agent_reads_assigned_bases ON documents;
CREATE POLICY agent_reads_assigned_bases ON documents FOR SELECT
  USING (knowledge_base_id IN (SELECT knowledge_base_id FROM agent_knowledge_bases
                               WHERE agent_id = current_agent_id()));

DROP POLICY IF EXISTS ingestion_writes_its_base ON documents;
CREATE POLICY ingestion_writes_its_base ON documents FOR ALL
  USING (knowledge_base_id = current_ingestion_knowledge_base_id())
  WITH CHECK (knowledge_base_id = current_ingestion_knowledge_base_id());

DROP POLICY IF EXISTS agent_reads_assigned_bases ON chunks;
CREATE POLICY agent_reads_assigned_bases ON chunks FOR SELECT
  USING (knowledge_base_id IN (SELECT knowledge_base_id FROM agent_knowledge_bases
                               WHERE agent_id = current_agent_id()));

DROP POLICY IF EXISTS ingestion_writes_its_base ON chunks;
CREATE POLICY ingestion_writes_its_base ON chunks FOR ALL
  USING (knowledge_base_id = current_ingestion_knowledge_base_id())
  WITH CHECK (knowledge_base_id = current_ingestion_knowledge_base_id());
