#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_repo_env "$REPO_ROOT"
require_command curl

ICEBERG_REST_URL="${ICEBERG_REST_URL:-${ICEBERG_REST_URI_HOST:-http://localhost:8181}/v1/config}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"

bash "$SCRIPT_DIR/init-minio.sh"
wait_for_http "$ICEBERG_REST_URL" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Iceberg REST catalog"

bash "$SCRIPT_DIR/run-flink-sql.sh" \
  "$REPO_ROOT/flink/sql/cold-path/01_create_iceberg_catalog.sql" \
  "$REPO_ROOT/flink/sql/cold-path/02_create_iceberg_namespace.sql" \
  "$REPO_ROOT/flink/sql/cold-path/03_create_iceberg_tables.sql"

log_info "Phase 2 cold path catalog and tables are ready"
