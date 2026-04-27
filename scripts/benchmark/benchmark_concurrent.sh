#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

ensure_benchmark_dirs
wait_for_benchmark_elasticsearch
wait_for_postgres

"$PYTHON_BIN" "$SCRIPT_DIR/benchmark_tool.py" benchmark-concurrent \
  --backend elasticsearch \
  --metadata "$BENCHMARK_INPUT_DIR/metadata.json" \
  --output-json "$BENCHMARK_RUN_DIR/concurrent-elasticsearch.json" \
  --levels "$BENCHMARK_CONCURRENCY_LEVELS" \
  --queries-per-worker "$BENCHMARK_CONCURRENT_QUERIES_PER_WORKER" \
  --elasticsearch-url "$ELASTICSEARCH_URL"

"$PYTHON_BIN" "$SCRIPT_DIR/benchmark_tool.py" benchmark-concurrent \
  --backend postgres \
  --metadata "$BENCHMARK_INPUT_DIR/metadata.json" \
  --output-json "$BENCHMARK_RUN_DIR/concurrent-postgres.json" \
  --levels "$BENCHMARK_CONCURRENCY_LEVELS" \
  --queries-per-worker "$BENCHMARK_CONCURRENT_QUERIES_PER_WORKER" \
  --postgres-dsn "$POSTGRES_URL"
