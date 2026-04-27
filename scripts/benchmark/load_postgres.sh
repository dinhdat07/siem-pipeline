#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

BENCHMARK_SIZE="${1:-$BENCHMARK_SIZE}"
BENCHMARK_INPUT_DIR="${BENCHMARK_INPUT_DIR:-$BENCHMARK_DATA_ROOT/$BENCHMARK_SIZE}"
ensure_benchmark_dirs
wait_for_postgres

log_info "Loading benchmark data into PostgreSQL baseline tables"
"$PYTHON_BIN" "$SCRIPT_DIR/benchmark_tool.py" load-postgres \
  --postgres-dsn "$POSTGRES_URL" \
  --events-jsonl "$BENCHMARK_INPUT_DIR/events.jsonl" \
  --alerts-jsonl "$BENCHMARK_INPUT_DIR/alerts.jsonl" \
  --metadata "$BENCHMARK_INPUT_DIR/metadata.json" \
  --output-json "$BENCHMARK_RUN_DIR/load-postgres.json"
