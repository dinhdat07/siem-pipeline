#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

bash "$SCRIPT_DIR/bootstrap-cold-path.sh"

bash "$SCRIPT_DIR/run-flink-sql.sh" \
  "$REPO_ROOT/flink/sql/cold-path/01_create_iceberg_catalog.sql" \
  "$REPO_ROOT/flink/sql/cold-path/04_create_kafka_sources.sql" \
  "$REPO_ROOT/flink/sql/cold-path/05_insert_normalized_events.sql"
