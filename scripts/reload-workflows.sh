#!/usr/bin/env bash
# Imports every workflow in n8n/workflows/ and publishes them all again, then restarts n8n.
# Importing unpublishes a workflow, so never import one without running this whole script
# (a scheduled workflow left unpublished simply stops running, without any error).
# Usage: ./scripts/reload-workflows.sh
set -euo pipefail
# Git Bash on Windows rewrites paths like /repo/... into C:/...; this keeps them as container paths
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
docker() { if [ "$1" = compose ]; then shift; command docker compose --env-file "$ENV_FILE" "$@"; else command docker "$@"; fi; }

docker compose exec -T n8n n8n import:workflow --separate --input=/repo/workflows

# Sub-workflows first, so they exist when their callers are published
for id in V5gWq8Rn2KdL7yUa H3pZc6Jm9TfB1sXe Q8vNd2LxR4tYw7Ka M1tFx4Ps6BjN9cQh \
          S7kQx2Wm5RpL9vNb C4pTn8Yq1ZsK6wHd C9sFr3Lm7XvB2qJe A6hWd1Ns4TkP8yRc D2mKc7Vx9QwL5tGa; do
  docker compose exec -T n8n n8n publish:workflow --id="$id"
done

# Published workflows are loaded at startup
docker compose restart n8n
