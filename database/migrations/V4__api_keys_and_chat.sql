-- Search API keys per agent, chat memory for the chat agents, and conversations in the query log.

SET search_path TO knowledge, public;

-- The key identifies the agent: callers cannot choose which agent they search as.
-- Only a hash is stored; the key itself is shown once, when it is created.
CREATE TABLE agent_api_keys (
  id           int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agent_id     int  NOT NULL REFERENCES agents ON DELETE CASCADE,
  label        text NOT NULL,
  key_hash     text NOT NULL UNIQUE,
  -- First characters of the key, to recognize it in lists without revealing it
  key_prefix   text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);

-- Chat memory, written by n8n's "Postgres Chat Memory" node (it expects id, session_id and message);
-- created_at is ours, for retention.
-- Its own schema: the node always runs CREATE TABLE IF NOT EXISTS, which needs CREATE on the schema.
-- rag_app gets that right here only, never on "knowledge".
CREATE SCHEMA chat_memory;
CREATE TABLE chat_memory.chat_history (
  id         serial       PRIMARY KEY,
  session_id varchar(255) NOT NULL,
  message    jsonb        NOT NULL,
  created_at timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX chat_history_session_idx ON chat_memory.chat_history (session_id, id);
CREATE INDEX chat_history_created_at_idx ON chat_memory.chat_history (created_at);

-- Which conversation a search belongs to, so the final answer can be stored next to it
ALTER TABLE query_log ADD COLUMN session_id text;
CREATE INDEX query_log_session_idx ON query_log (session_id, id);
