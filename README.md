# RAG Knowledge Assistant

> **Work in progress.** The database layer (schema, ingestion and search functions, row level security, tests) is
> done; document processing, ingestion workflows, the chat agents and the evaluation report come next.

A retrieval-augmented generation (RAG) engine that serves **several agents from one knowledge store**. Each agent
answers **only from the documents it is allowed to read**, **cites its sources**, and says **"I don't know"** when
the answer is not in them. Documents stay where the company already keeps them (a Google Drive folder) and are
synced incrementally.

Built with **n8n**, **Google Gemini**, **PostgreSQL + pgvector** and **Flyway**, packaged with Docker Compose.

> **Demo data.** The documents belong to Maple Grove Dental Studio, the fictional clinic of
> [whatsapp-ai-receptionist](https://github.com/villasana26enrique/whatsapp-ai-receptionist). Everything is made up.

## Demo setup: one clinic, two knowledge bases, two agents

| Knowledge base | Contents | Read by |
|---|---|---|
| `patient-handbook` | Aftercare, insurance and payments, cancellation policy, new patient FAQ, emergencies | Patient assistant, Staff assistant |
| `staff-handbook` | Time off, shifts, sterilization protocol, onboarding | Staff assistant |

A patient asking how many vacation days the staff get is told the assistant does not know — the answer exists,
but not in a base the patient assistant can read.

## Design decisions

- **Isolation enforced by PostgreSQL.** n8n connects with an unprivileged role; row level security only returns
  chunks of the bases assigned to the agent. A query that forgets its filter returns nothing, not someone else's data.
- **Hybrid search.** Vector similarity understands meaning ("my tooth hurts after the extraction"); full-text search
  catches exact terms ("Delta Dental PPO"). Both lists are fused with Reciprocal Rank Fusion, in SQL.
- **"I don't know" is a feature.** Below a similarity threshold the search returns no passages and tells the agent
  to say so. The threshold is calibrated with the evaluation set, not guessed.
- **Incremental, atomic ingestion.** Only new or changed files are embedded (modified date, then content hash);
  files removed from the source are removed from the index; a document's chunks are replaced in one transaction,
  so searches never see half a document.
- **Every search is logged** with its candidates and scores, for debugging and to find new evaluation cases.

## Database

Schema `knowledge`: `knowledge_bases`, `agents`, `agent_knowledge_bases`, `documents`, `chunks`
(`vector(768)` + generated `tsvector`, HNSW and GIN indexes), `ingestion_runs`, `query_log`.

| Function | Purpose |
|---|---|
| `plan_sync` | Compare a source listing with the stored documents: what to process, what to delete |
| `skip_if_unchanged` | Same content hash: skip the embeddings |
| `upsert_document` | Store a document and replace its chunks atomically |
| `delete_document` | Remove a document from the index (the row is kept for audit) |
| `search_knowledge` | Hybrid search for an agent, with threshold and logging |
| `start_ingestion_run` / `finish_ingestion_run` | Record each sync |
| `record_answer`, `purge_old_logs` | Answer logging and retention |

## Getting started

```bash
cp .env.example .env        # fill in every value
docker compose up -d        # PostgreSQL + Flyway migrations + n8n (http://localhost:5679)
```

### Tests

```bash
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < database/tests/knowledge_tests.sql
```

They run as the application role inside a rolled-back transaction and print `ALL TESTS PASSED`. Covered:
ingestion and validation, updates and versioning, change detection, sync planning (including the guard against an
empty listing), deletion and restore, hybrid ranking, the "I don't know" threshold, isolation between bases
(searches, plain queries and writes), logging, ingestion runs and retention.

## License

MIT
