#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

ensure_benchmark_dirs
wait_for_postgres

"$PYTHON_BIN" "$SCRIPT_DIR/benchmark_tool.py" benchmark-queries \
  --backend postgres \
  --suite baseline \
  --metadata "$BENCHMARK_INPUT_DIR/metadata.json" \
  --output-json "$BENCHMARK_RUN_DIR/queries-postgres.json" \
  --iterations "$BENCHMARK_QUERY_ITERATIONS" \
  --postgres-dsn "$POSTGRES_URL"

"$PYTHON_BIN" "$SCRIPT_DIR/benchmark_tool.py" benchmark-queries \
  --backend postgres \
  --suite showcase \
  --metadata "$BENCHMARK_INPUT_DIR/metadata.json" \
  --output-json "$BENCHMARK_RUN_DIR/queries-showcase-postgres.json" \
  --iterations "$BENCHMARK_QUERY_ITERATIONS" \
  --postgres-dsn "$POSTGRES_URL"
