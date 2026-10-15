#!/usr/bin/env bash
# Exports the project workflows from the running n8n into n8n/workflows/ (clean, ready to commit).
# Usage: ./scripts/export-workflows.sh
set -euo pipefail
# Git Bash on Windows rewrites paths like /repo/... into C:/...; this keeps them as container paths
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

# file name -> workflow id
declare -A WORKFLOWS=(
  [ingest-sync-google-drive]=Q8vNd2LxR4tYw7Ka
  [ingest-sync-knowledge-base]=H3pZc6Jm9TfB1sXe
  [ingest-apply-document-change]=V5gWq8Rn2KdL7yUa
  [ingest-upload-api]=M1tFx4Ps6BjN9cQh
  [tool-search-knowledge]=S7kQx2Wm5RpL9vNb
  [chat-patient-assistant]=C4pTn8Yq1ZsK6wHd
  [chat-staff-assistant]=C9sFr3Lm7XvB2qJe
  [api-search]=A6hWd1Ns4TkP8yRc
  [daily-maintenance]=D2mKc7Vx9QwL5tGa
)

for name in "${!WORKFLOWS[@]}"; do
  docker compose exec -T n8n n8n export:workflow --id="${WORKFLOWS[$name]}" --pretty --output="/repo/workflows/$name.json"
done

docker compose exec -T n8n node /repo/scripts/clean-export.js
