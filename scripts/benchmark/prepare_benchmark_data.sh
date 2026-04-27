#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

BENCHMARK_SIZE="${1:-$BENCHMARK_SIZE}"
BENCHMARK_INPUT_DIR="${BENCHMARK_INPUT_DIR:-$BENCHMARK_DATA_ROOT/$BENCHMARK_SIZE}"
ensure_benchmark_dirs

log_info "Preparing benchmark data for size '$BENCHMARK_SIZE' into $BENCHMARK_INPUT_DIR"
"$PYTHON_BIN" "$SCRIPT_DIR/benchmark_tool.py" prepare \
  --size "$BENCHMARK_SIZE" \
  --output-dir "$BENCHMARK_INPUT_DIR" \
  --benchmark-id "phase5-$BENCHMARK_SIZE"

cp "$BENCHMARK_INPUT_DIR/prepare-summary.json" "$BENCHMARK_RUN_DIR/prepare-summary.json"
log_info "Prepared benchmark data"
