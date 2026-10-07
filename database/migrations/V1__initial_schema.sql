-- Knowledge bases, agents, documents and their embedded chunks.
-- Versioned migration: runs once. Functions and row level security live in database/functions.

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

CREATE SCHEMA IF NOT EXISTS knowledge;
SET search_path TO knowledge, public;

-- A separate set of documents (one per client, team or topic)
CREATE TABLE knowledge_bases (
  id               int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  slug             text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name             text NOT NULL,
  description      text,
  -- Google Drive folder synced into this base (null = only the upload API)
  source_folder_id text UNIQUE,
  -- Embeddings from different models cannot be compared: changing it means re-embedding the base
  embedding_model  text NOT NULL DEFAULT 'gemini-embedding-001',
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agents (
  id             int  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  slug           text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name           text NOT NULL,
  -- Below this cosine similarity the best match is not relevant enough: the agent says it does not know.
  -- Calibrated with the evaluation set.
  min_similarity real NOT NULL DEFAULT 0.6 CHECK (min_similarity BETWEEN 0 AND 1),
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Which knowledge bases each agent may read
CREATE TABLE agent_knowledge_bases (
  agent_id          int NOT NULL REFERENCES agents ON DELETE CASCADE,
  knowledge_base_id int NOT NULL REFERENCES knowledge_bases ON DELETE CASCADE,
  PRIMARY KEY (agent_id, knowledge_base_id)
);

CREATE TABLE documents (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  knowledge_base_id  int    NOT NULL REFERENCES knowledge_bases,
  source             text   NOT NULL CHECK (source IN ('google_drive', 'upload')),
  -- Drive file id, or the id the caller of the upload API chose
  source_id          text   NOT NULL,
  title              text   NOT NULL,
  mime_type          text,
  source_url         text,
  -- sha256 of the extracted text: same hash = nothing to re-embed
  content_hash       text   NOT NULL,
  source_modified_at timestamptz,
  version            int    NOT NULL DEFAULT 1,
  -- Deleted documents keep their row (audit); their chunks are removed so they are never retrieved
  status             text   NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deleted')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  UNIQUE (knowledge_base_id, source, source_id),
  -- Target of the composite foreign key in chunks
  UNIQUE (id, knowledge_base_id)
);

CREATE TABLE chunks (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  document_id       bigint NOT NULL,
  -- Copied from the document to filter (and secure) searches without a join;
  -- the composite foreign key guarantees it always matches the document's base
  knowledge_base_id int    NOT NULL,
  chunk_index       int    NOT NULL CHECK (chunk_index >= 0),
  -- Where the chunk sits in the document, e.g. "Aftercare Guide > Tooth Extraction"
  section           text,
  content           text   NOT NULL CHECK (content <> ''),
  token_count       int,
  embedding         vector(768) NOT NULL,
  search_vector     tsvector GENERATED ALWAYS AS (
                      to_tsvector('english', coalesce(section, '') || ' ' || content)) STORED,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, chunk_index),
  FOREIGN KEY (document_id, knowledge_base_id)
    REFERENCES documents (id, knowledge_base_id) ON DELETE CASCADE
);

CREATE INDEX chunks_embedding_idx ON chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX chunks_search_vector_idx ON chunks USING gin (search_vector);
CREATE INDEX chunks_knowledge_base_idx ON chunks (knowledge_base_id);

-- One row per sync of a knowledge base (or per upload)
CREATE TABLE ingestion_runs (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  knowledge_base_id   int    NOT NULL REFERENCES knowledge_bases,
  trigger             text   NOT NULL CHECK (trigger IN ('schedule', 'manual', 'upload')),
  status              text   NOT NULL DEFAULT 'running'
                             CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
  files_seen          int    NOT NULL DEFAULT 0,
  documents_added     int    NOT NULL DEFAULT 0,
  documents_updated   int    NOT NULL DEFAULT 0,
  documents_unchanged int    NOT NULL DEFAULT 0,
  documents_deleted   int    NOT NULL DEFAULT 0,
  documents_failed    int    NOT NULL DEFAULT 0,
  -- [{source_id, title, error}]
  errors              jsonb  NOT NULL DEFAULT '[]',
  started_at          timestamptz NOT NULL DEFAULT now(),
  finished_at         timestamptz
);

-- Every search, for debugging ("why did it answer that?") and to find new evaluation cases
CREATE TABLE query_log (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agent_id       int    NOT NULL REFERENCES agents,
  question       text   NOT NULL,
  top_similarity real,
  answerable     boolean NOT NULL,
  -- [{chunk_id, document_id, similarity, score}]
  results        jsonb  NOT NULL DEFAULT '[]',
  search_ms      int,
  answer         text,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX query_log_created_at_idx ON query_log (created_at);
