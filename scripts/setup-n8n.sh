#!/usr/bin/env bash
# Sets up a fresh n8n with everything this project needs: credentials (from .env), the Drive folder of each
# knowledge base, workflows and publishing.
# Usage: docker compose up -d && ./scripts/setup-n8n.sh
set -euo pipefail
# Git Bash on Windows rewrites paths like /repo/... into C:/...; this keeps them as container paths
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

# ENV_FILE / COMPOSE_PROJECT_NAME allow targeting another environment (e.g. a throwaway test stack)
ENV_FILE="${ENV_FILE:-.env}"
set -a; source "$ENV_FILE"; set +a
docker() { if [ "$1" = compose ]; then shift; command docker compose --env-file "$ENV_FILE" "$@"; else command docker "$@"; fi; }

# The service account key stays in its file outside the repository; it is read here and handed to n8n,
# which stores it encrypted with N8N_ENCRYPTION_KEY
if [ -n "${GOOGLE_SERVICE_ACCOUNT_KEY_FILE:-}" ]; then
  GOOGLE_SERVICE_ACCOUNT_JSON="$(cat "$GOOGLE_SERVICE_ACCOUNT_KEY_FILE")"
  export GOOGLE_SERVICE_ACCOUNT_JSON
fi

# Secrets go to this one command only; they are never stored in the n8n container's environment
docker compose exec -T \
  -e POSTGRES_DB -e RAG_APP_PASSWORD -e GOOGLE_SERVICE_ACCOUNT_JSON -e GEMINI_API_KEY -e INGEST_API_KEY \
  n8n sh -c 'node /repo/scripts/build-credentials.js \
    && n8n import:credentials --input=/tmp/credentials-to-import.json \
    ; rm -f /tmp/credentials-to-import.json'

# DRIVE_FOLDER_PATIENT_HANDBOOK=<id> -> knowledge base "patient-handbook" syncs that folder
for variable in $(compgen -v | grep '^DRIVE_FOLDER_' || true); do
  slug=$(echo "${variable#DRIVE_FOLDER_}" | tr 'A-Z_' 'a-z-')
  echo "UPDATE knowledge.knowledge_bases SET source_folder_id = :'folder' WHERE slug = :'slug' RETURNING 'linked ' || slug;" |
    docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -qtA -v slug="$0" -v folder="$1"' \
      "$slug" "${!variable}"
done

ENV_FILE="$ENV_FILE" ./scripts/reload-workflows.sh
echo "Done. Open n8n, create the owner account, and run 'Ingest: Sync Google Drive' (or wait 15 minutes)."
echo "Search API keys: ./scripts/create-api-key.sh <agent> <label>"
