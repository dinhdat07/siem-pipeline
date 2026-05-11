#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

DISTRIBUTED_COMMON_ENV="$REPO_ROOT/deploy/distributed/env/common.env"
CONTROL_NODE_ENV_NAME="${CONTROL_NODE_ENV_NAME:-${SIEM_CONTROL_NODE:-dvm-sgp-02}}"
CONTROL_NODE_ENV_FILE="$REPO_ROOT/deploy/distributed/env/${CONTROL_NODE_ENV_NAME}.env"

if [ -f "$DISTRIBUTED_COMMON_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$DISTRIBUTED_COMMON_ENV"
  if [ -f "$CONTROL_NODE_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONTROL_NODE_ENV_FILE"
  fi
  set +a
fi

BENCHMARK_SIZE="${1:-${BENCHMARK_SIZE:-distributed-1m}}"
BENCHMARK_INPUT_DIR="${BENCHMARK_INPUT_DIR:-$BENCHMARK_DATA_ROOT/$BENCHMARK_SIZE}"
NODE_COUNTS_CSV="${BENCHMARK_NODE_COUNTS:-1,2,3}"
REPORT_OUTPUT="${BENCHMARK_NODE_SCALING_REPORT:-$REPO_ROOT/benchmark/results/es-node-scalability-${BENCHMARK_SIZE}.md}"
BENCHMARK_ES_SHARDS="${BENCHMARK_ES_SHARDS:-3}"
BENCHMARK_ES_REPLICAS_DEFAULT="${BENCHMARK_ES_REPLICAS:-1}"
export BENCHMARK_SIZE BENCHMARK_INPUT_DIR BENCHMARK_ES_SHARDS

readarray -t ES_NODE_NAMES < <(
  for env_file in \
    "$REPO_ROOT/deploy/distributed/env/dvm-sgp-02.env" \
    "$REPO_ROOT/deploy/distributed/env/dvm-sgp-01.env" \
    "$REPO_ROOT/deploy/distributed/env/dvm-sgp-03.env"; do
    [ -f "$env_file" ] || continue
    sed -n 's/^ELASTICSEARCH_NODE_NAME=//p' "$env_file"
  done
)

if [ "${#ES_NODE_NAMES[@]}" -eq 0 ]; then
  log_error "Could not resolve Elasticsearch node names from deploy/distributed/env/*.env"
  exit 1
fi

ensure_benchmark_dirs
wait_for_benchmark_elasticsearch

cluster_nodes="$(
  curl -fsS "$ELASTICSEARCH_URL/_cat/nodes?h=name" | tr -d '\r'
)"
for expected in "${ES_NODE_NAMES[@]}"; do
  if ! grep -qx "$expected" <<<"$cluster_nodes"; then
    log_error "Expected Elasticsearch node '$expected' is not present in cluster"
    exit 1
  fi
done

log_info "Preparing benchmark data once for size '$BENCHMARK_SIZE'"
bash "$SCRIPT_DIR/prepare_benchmark_data.sh" "$BENCHMARK_SIZE"

run_dirs=()
IFS=',' read -r -a NODE_COUNTS <<<"$NODE_COUNTS_CSV"
for node_count in "${NODE_COUNTS[@]}"; do
  node_count="${node_count// /}"
  [ -n "$node_count" ] || continue
  if ! [[ "$node_count" =~ ^[0-9]+$ ]]; then
    log_error "Invalid node count in BENCHMARK_NODE_COUNTS: $node_count"
    exit 1
  fi
  if [ "$node_count" -lt 1 ] || [ "$node_count" -gt "${#ES_NODE_NAMES[@]}" ]; then
    log_error "Node count $node_count is out of range for ${#ES_NODE_NAMES[@]} available ES nodes"
    exit 1
  fi

  target_nodes=("${ES_NODE_NAMES[@]:0:$node_count}")
  target_nodes_csv="$(IFS=,; echo "${target_nodes[*]}")"
  BENCHMARK_RUN_ID="${BENCHMARK_RUN_ID_PREFIX:-$(date -u +%Y%m%dT%H%M%SZ)}-${BENCHMARK_SIZE}-esnodes${node_count}"
  BENCHMARK_RUN_DIR="${BENCHMARK_OUTPUT_ROOT}/${BENCHMARK_RUN_ID}"
  export BENCHMARK_RUN_ID BENCHMARK_RUN_DIR
  export BENCHMARK_TOPOLOGY="es-node-scalability"
  export BENCHMARK_NODE_COUNT="$node_count"
  export BENCHMARK_TARGET_NODES="$target_nodes_csv"
  export BENCHMARK_NOTES="Benchmark indices are pinned to a subset of Elasticsearch nodes inside the existing 3-node SIEM cluster."
  export BENCHMARK_ES_INCLUDE_NODE_NAMES="$target_nodes_csv"
  if [ "$node_count" -le 1 ]; then
    export BENCHMARK_ES_REPLICAS=0
  else
    export BENCHMARK_ES_REPLICAS="$BENCHMARK_ES_REPLICAS_DEFAULT"
  fi

  mkdir -p "$BENCHMARK_RUN_DIR"
  write_run_metadata

  log_info "Running ES node benchmark with $node_count node(s): $target_nodes_csv (replicas=$BENCHMARK_ES_REPLICAS)"
  bash "$SCRIPT_DIR/load_elasticsearch.sh" "$BENCHMARK_SIZE"
  wait_for_benchmark_indices_ready
  bash "$SCRIPT_DIR/benchmark_queries_elasticsearch.sh" "$BENCHMARK_SIZE"
  bash "$SCRIPT_DIR/benchmark_concurrent_elasticsearch.sh" "$BENCHMARK_SIZE"

  run_dirs+=("$BENCHMARK_RUN_DIR")
done

report_args=()
for run_dir in "${run_dirs[@]}"; do
  report_args+=(--run-dir "$run_dir")
done

python3 "$SCRIPT_DIR/es_node_scaling_report.py" "${report_args[@]}" --output "$REPORT_OUTPUT"
log_info "Wrote $REPORT_OUTPUT"
