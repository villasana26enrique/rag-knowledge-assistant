#!/usr/bin/env bash
# Creates a search API key for an agent. The key is printed once and only its hash is stored.
# Usage: ./scripts/create-api-key.sh patient-assistant "WhatsApp receptionist"
# Revoke: echo "SELECT knowledge.revoke_api_key('<first 12 characters>');" | docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
[ $# -eq 2 ] || { echo "Usage: $0 <agent> <label>" >&2; exit 1; }

echo "SELECT knowledge.create_api_key(:'agent', :'label');" |
  docker compose --env-file "$ENV_FILE" exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -qtA -v agent="$0" -v label="$1"' "$1" "$2"
echo "Store the api_key now (for example in the caller's .env): it cannot be shown again." >&2
