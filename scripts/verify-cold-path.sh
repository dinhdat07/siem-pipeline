#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_repo_env "$REPO_ROOT"
require_command docker
require_command curl

MINIO_CONTAINER="${MINIO_CONTAINER:-minio}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-password}"
MINIO_WAREHOUSE_BUCKET="${MINIO_WAREHOUSE_BUCKET:-warehouse}"
ICEBERG_REST_URL="${ICEBERG_REST_URL:-${ICEBERG_REST_URI_HOST:-http://localhost:8181}/v1/config}"

wait_for_http "$ICEBERG_REST_URL" 180 3 "Iceberg REST catalog"

log_info "Listing Iceberg warehouse objects from MinIO"
MSYS_NO_PATHCONV=1 docker exec "$MINIO_CONTAINER" /bin/sh -lc "
  mc alias set local http://127.0.0.1:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null &&
  mc ls --recursive 'local/$MINIO_WAREHOUSE_BUCKET'
"

log_info "Querying Iceberg snapshots and record counts"
bash "$SCRIPT_DIR/run-flink-sql.sh" "$REPO_ROOT/flink/sql/cold-path/90_verify_iceberg_events.sql"
