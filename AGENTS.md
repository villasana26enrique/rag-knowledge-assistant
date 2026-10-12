# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in this repository.
Read `README.md` first for what the project does and how it is structured.

## Project in one paragraph

A multi-agent RAG engine. Documents (synced from Google Drive folders or sent to an upload API) are split into
chunks, embedded with Gemini and stored in PostgreSQL + pgvector (schema `knowledge`). Each agent may only read the
knowledge bases assigned to it; PostgreSQL enforces that with row level security. Searches are hybrid (vectors +
full text, fused with Reciprocal Rank Fusion) and return nothing below a similarity threshold, so agents say
"I don't know" instead of guessing. n8n hosts the ingestion workflows, the search tool and the chat agents.

## Conventions

- **Everything technical is in English**: tables, columns, functions, workflow and node names, files, comments,
  commit messages, docs. Messages returned to the LLM are English too.
- **Business rules live in the database**, not in n8n Code nodes or prompts. n8n nodes stay thin:
  call a function, branch on `ok`, pass `message` back.
- Database functions return `jsonb` with `ok` (and `message` when something is wrong) instead of raising errors for
  business cases.
- Every function declares `SET search_path = knowledge, public` (pgvector lives in `public`; n8n connects with the
  default schema).
- Embeddings are `vector(768)` (`gemini-embedding-001` with `outputDimensionality: 768`). Changing the model or the
  dimensions means a new migration and re-embedding every document.

## Row level security (read before touching `documents` or `chunks`)

- n8n connects as **`rag_app`**, which is neither the table owner nor a superuser, so the policies always apply.
  The owner (`POSTGRES_USER`) runs migrations and tests and bypasses them.
- Functions declare who is acting with `set_config(..., true)` (transaction only):
  `app.agent_id` (search: the agent's bases) or `app.knowledge_base_id` (ingestion: one base).
  Each function clears the other setting. Nothing declared = no rows.
- RLS protects against a query that forgets to filter. It does not authenticate the caller: whoever can call
  `search_knowledge` chooses the agent, so the agent name must come from the workflow, never from user input.
- New tables holding knowledge-base data need the same two policies (see `R__row_level_security.sql`) and a test.

## Database changes (Flyway)

- New tables, columns or data: add `database/migrations/V<next>__short_description.sql`.
  **Never modify a versioned migration that has already been applied.**
- Functions and policies: edit or add `database/functions/R__*.sql` (re-runnable: `CREATE OR REPLACE`,
  `DROP POLICY IF EXISTS`); Flyway re-applies them on change.
- Apply: `docker compose run --rm flyway` (also runs on `docker compose up`).
- Run the tests after any database change and keep them green:

  ```bash
  docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < database/tests/knowledge_tests.sql
  ```

  They run in a rolled-back transaction, **as `rag_app`**, and print `ALL TESTS PASSED`. Add a test for new
  behavior. In assertion messages concatenate `r::text`, not `r` (`'text' || jsonb` is parsed as JSON).

## Document processor (`document-processor/`)

- Same shape as the other internal services of these projects: a standard-library HTTP server (`server.py`),
  `GET /health`, JSON errors `{"error": ...}`, runs as `nobody`, not published outside the Compose network.
- `extract.py` (file -> blocks with their heading path), `chunking.py` (blocks -> labeled chunks),
  `server.py` (HTTP + content hash). Keep it deterministic: no model calls, no network, no secrets.
- Pin dependencies in `requirements.txt` (runtime) and `requirements-dev.txt` (tests).
- Tests build their sample files in `tests/samples.py`; no binary fixtures. Run and keep green:
  `docker build --target test document-processor`.
- Changing how text is extracted or chunked does not re-process stored documents by itself (their content hash
  is unchanged): re-ingest the knowledge base when that matters.

## n8n workflow changes

- The JSON files in `n8n/workflows/` are the source of truth for the repository, but n8n runs from its own database.
  After changing a workflow in n8n, run `./scripts/export-workflows.sh` and commit the result.
- Sub-workflows are called **by id**; keep ids stable (import preserves them). New workflows must be added to the id
  map in `scripts/export-workflows.sh` and to the publish list in `scripts/setup-n8n.sh` (sub-workflows first).
- Credential ids are fixed in `n8n/scripts/build-credentials.js` and referenced by the workflows; keep them in sync.
  n8n connects to PostgreSQL as `rag_app`, never as the owner.
- Never hard-code instance data in workflows: Drive folder ids live in `knowledge.knowledge_bases.source_folder_id`
  (set by `setup-n8n.sh` from `DRIVE_FOLDER_<KNOWLEDGE_BASE>` variables), credentials are referenced, never embedded.
- `Ingest: Apply document change` must always end in a result item (`status`: added, updated, unchanged, deleted,
  already_deleted or failed): every risky node routes its error output to `Report failure`, so one bad file never
  stops a sync.
- Run a workflow from the command line while n8n is running (the CLI needs its own task broker port):
  `docker compose exec -T -e N8N_RUNNERS_BROKER_PORT=5690 n8n n8n execute --id=Q8vNd2LxR4tYw7Ka`
- Test with fake documents named `TEST - ...` and remove them afterwards (from Drive and from the database).

## Secrets

- Never commit `.env`. Document every new variable in `.env.example` with a fake value.
- The Google service account key is a file outside the repository; `.env` only has its path. `setup-n8n.sh` reads it
  and hands it to n8n, which stores it encrypted. Never copy the key into the repository, a workflow or a log.
- Before committing, check that no token, API key, password, phone number or email appears in the diff.

## Useful commands

| Task | Command |
|---|---|
| Start everything | `docker compose up -d` |
| Logs | `docker compose logs -f n8n` |
| Apply migrations | `docker compose run --rm flyway` |
| Document processor tests | `docker build --target test document-processor` |
| Set up a fresh n8n (credentials + Drive folders + workflows) | `./scripts/setup-n8n.sh` |
| Export workflows | `./scripts/export-workflows.sh` |
| Sync Drive now | `docker compose exec -T -e N8N_RUNNERS_BROKER_PORT=5690 n8n n8n execute --id=Q8vNd2LxR4tYw7Ka` |
| Database shell (owner) | `docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` |
