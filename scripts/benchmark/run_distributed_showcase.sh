#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export SIEM_CLUSTER_MODE="${SIEM_CLUSTER_MODE:-distributed}"
export BENCHMARK_START_STACK="${BENCHMARK_START_STACK:-0}"
export BENCHMARK_AUTO_BUILD="${BENCHMARK_AUTO_BUILD:-0}"
export BENCHMARK_ES_SHARDS="${BENCHMARK_ES_SHARDS:-3}"
export BENCHMARK_ES_REPLICAS="${BENCHMARK_ES_REPLICAS:-1}"
export BENCHMARK_ES_BULK_CHUNK_BYTES="${BENCHMARK_ES_BULK_CHUNK_BYTES:-16777216}"
export BENCHMARK_QUERY_ITERATIONS="${BENCHMARK_QUERY_ITERATIONS:-5}"
export BENCHMARK_CONCURRENCY_LEVELS="${BENCHMARK_CONCURRENCY_LEVELS:-1,5,10,25}"
export BENCHMARK_CONCURRENT_QUERIES_PER_WORKER="${BENCHMARK_CONCURRENT_QUERIES_PER_WORKER:-5}"
export KAFKA_TOPICS_ENV_FILE="${KAFKA_TOPICS_ENV_FILE:-deploy/distributed/configs/kafka/topics.env}"
export CONNECTOR_CONFIG_DIR="${CONNECTOR_CONFIG_DIR:-deploy/distributed/configs/kafka-connect}"
export POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-siem-postgres}"

if [ "$#" -gt 0 ]; then
  sizes=("$@")
else
  sizes=(distributed-1m distributed-3m)
fi

latest_runs=()

for size in "${sizes[@]}"; do
  echo "[INFO] Running distributed benchmark size: $size"
  BENCHMARK_RUN_ID="${BENCHMARK_RUN_ID_PREFIX:-$(date -u +%Y%m%dT%H%M%SZ)}-$size" \
    bash "$SCRIPT_DIR/run_benchmark.sh" "$size"
  latest_run="$REPO_ROOT/benchmark/results/${BENCHMARK_RUN_ID_PREFIX:-$(date -u +%Y%m%dT%H%M%SZ)}-$size"
  # The run id above may use a new second if no prefix was supplied; locate the newest matching run instead.
  latest_run="$(find "$REPO_ROOT/benchmark/results" -maxdepth 1 -type d -name "*-$size" -printf '%T@ %p\n' | sort -nr | awk 'NR==1 {print $2}')"
  if [ -n "$latest_run" ]; then
    python3 "$SCRIPT_DIR/compare_runs.py" --run-dir "$latest_run" --output "$latest_run/es-vs-postgres-showcase.md"
    echo "[INFO] Wrote $latest_run/es-vs-postgres-showcase.md"
    latest_runs+=("$latest_run")
  fi
done

if [ "${#latest_runs[@]}" -gt 0 ]; then
  report_args=()
  for run_dir in "${latest_runs[@]}"; do
    report_args+=(--run-dir "$run_dir")
  done
  python3 "$SCRIPT_DIR/es_scaling_report.py" "${report_args[@]}" \
    --output "$REPO_ROOT/benchmark/results/es-scalability.md"
  echo "[INFO] Wrote $REPO_ROOT/benchmark/results/es-scalability.md"
fi
