#!/usr/bin/env bash
set -euo pipefail

BENCHMARK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BENCHMARK_SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

load_repo_env "$REPO_ROOT"

BENCHMARK_SIZE="${BENCHMARK_SIZE:-${1:-small}}"
BENCHMARK_DATA_ROOT="${BENCHMARK_DATA_DIR:-$REPO_ROOT/benchmark/generated}"
BENCHMARK_OUTPUT_ROOT="${BENCHMARK_RESULTS_DIR:-$REPO_ROOT/benchmark/results}"
BENCHMARK_INPUT_DIR="${BENCHMARK_INPUT_DIR:-$BENCHMARK_DATA_ROOT/$BENCHMARK_SIZE}"
BENCHMARK_RUN_ID="${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$BENCHMARK_SIZE}"
BENCHMARK_RUN_DIR="${BENCHMARK_RUN_DIR:-$BENCHMARK_OUTPUT_ROOT/$BENCHMARK_RUN_ID}"
BENCHMARK_WAIT_TIMEOUT_SEC="${BENCHMARK_WAIT_TIMEOUT_SEC:-240}"
BENCHMARK_WAIT_INTERVAL_SEC="${BENCHMARK_WAIT_INTERVAL_SEC:-5}"
BENCHMARK_QUERY_ITERATIONS="${BENCHMARK_QUERY_ITERATIONS:-5}"
BENCHMARK_CONCURRENCY_LEVELS="${BENCHMARK_CONCURRENCY_LEVELS:-1,5,10,25}"
BENCHMARK_CONCURRENT_QUERIES_PER_WORKER="${BENCHMARK_CONCURRENT_QUERIES_PER_WORKER:-5}"
ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://localhost:9200}"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
FLINK_REST_URL="${FLINK_REST_URL:-http://localhost:${FLINK_UI_PORT:-8081}}"
POSTGRES_URL="${POSTGRES_URL:-postgresql://${POSTGRES_USER:-siem}:${POSTGRES_PASSWORD:-siem}@${POSTGRES_HOST:-localhost}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-siem_benchmark}}"
PYTHON_BIN="$(resolve_python_bin)"

ensure_benchmark_dirs() {
  mkdir -p "$BENCHMARK_INPUT_DIR" "$BENCHMARK_RUN_DIR"
}

wait_for_postgres() {
  wait_for_container postgres "PostgreSQL" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC"
}

wait_for_benchmark_elasticsearch() {
  wait_for_http "$ELASTICSEARCH_URL" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC" "Elasticsearch"
}

wait_for_benchmark_connect() {
  wait_for_http "$CONNECT_URL/connectors" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC" "Kafka Connect"
}

wait_for_benchmark_flink() {
  wait_for_http "$FLINK_REST_URL/overview" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC" "Flink REST API"
}

benchmark_compose_up() {
  local profiles="$1"
  shift
  local cmd=(docker compose up -d)
  if is_truthy "${BENCHMARK_AUTO_BUILD:-1}"; then
    cmd+=(--build)
  fi
  log_info "Starting benchmark services with COMPOSE_PROFILES=$profiles"
  COMPOSE_PROFILES="$profiles" "${cmd[@]}" "$@"
}

install_benchmark_es_indices() {
  local events_template="$REPO_ROOT/configs/elasticsearch/templates/siem-benchmark-events-template.json"
  local alerts_template="$REPO_ROOT/configs/elasticsearch/templates/siem-benchmark-alerts-template.json"

  curl -fsS -X PUT -H "Content-Type: application/json" \
    "$ELASTICSEARCH_URL/_index_template/siem-benchmark-events-template" \
    --data @"$events_template" >/dev/null
  curl -fsS -X PUT -H "Content-Type: application/json" \
    "$ELASTICSEARCH_URL/_index_template/siem-benchmark-alerts-template" \
    --data @"$alerts_template" >/dev/null
}

write_run_metadata() {
  cat > "$BENCHMARK_RUN_DIR/metadata.json" <<META
{
  "run_id": "$BENCHMARK_RUN_ID",
  "size": "$BENCHMARK_SIZE",
  "generated_input_dir": "$BENCHMARK_INPUT_DIR",
  "results_dir": "$BENCHMARK_RUN_DIR",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
META
}
