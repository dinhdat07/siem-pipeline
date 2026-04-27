#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

BENCHMARK_SIZE="${1:-$BENCHMARK_SIZE}"
BENCHMARK_INPUT_DIR="${BENCHMARK_INPUT_DIR:-$BENCHMARK_DATA_ROOT/$BENCHMARK_SIZE}"
ensure_benchmark_dirs
wait_for_benchmark_elasticsearch
install_benchmark_es_indices

log_info "Loading benchmark data into Elasticsearch benchmark indices"
"$PYTHON_BIN" "$SCRIPT_DIR/benchmark_tool.py" load-elasticsearch \
  --elasticsearch-url "$ELASTICSEARCH_URL" \
  --events-bulk "$BENCHMARK_INPUT_DIR/events.bulk.ndjson" \
  --alerts-bulk "$BENCHMARK_INPUT_DIR/alerts.bulk.ndjson" \
  --metadata "$BENCHMARK_INPUT_DIR/metadata.json" \
  --output-json "$BENCHMARK_RUN_DIR/load-elasticsearch.json"
