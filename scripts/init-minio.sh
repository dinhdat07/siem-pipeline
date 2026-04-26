#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_repo_env "$REPO_ROOT"
require_command docker

MINIO_CONTAINER="${MINIO_CONTAINER:-minio}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-password}"
MINIO_WAREHOUSE_BUCKET="${MINIO_WAREHOUSE_BUCKET:-warehouse}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-120}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"
elapsed=0

if ! docker container inspect "$MINIO_CONTAINER" >/dev/null 2>&1; then
  log_error "MinIO container not found: $MINIO_CONTAINER"
  log_error "start the stack first with: docker compose up -d --build"
  exit 1
fi

while true; do
  if MSYS_NO_PATHCONV=1 docker exec "$MINIO_CONTAINER" mc ready local >/dev/null 2>&1; then
    break
  fi

  if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
    log_error "MinIO did not become ready within ${WAIT_TIMEOUT_SEC}s"
    exit 1
  fi

  sleep "$WAIT_INTERVAL_SEC"
  elapsed=$((elapsed + WAIT_INTERVAL_SEC))
done

log_info "Ensuring MinIO warehouse bucket exists: $MINIO_WAREHOUSE_BUCKET"
MSYS_NO_PATHCONV=1 docker exec "$MINIO_CONTAINER" /bin/sh -lc "
  mc alias set local http://127.0.0.1:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null &&
  mc mb --ignore-existing 'local/$MINIO_WAREHOUSE_BUCKET' >/dev/null
"
