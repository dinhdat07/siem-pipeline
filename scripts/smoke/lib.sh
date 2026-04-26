#!/usr/bin/env bash
set -euo pipefail

SMOKE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

load_repo_env "$REPO_ROOT"

SMOKE_AUTO_START="${SMOKE_AUTO_START:-1}"
SMOKE_WAIT_TIMEOUT_SEC="${SMOKE_WAIT_TIMEOUT_SEC:-90}"
SMOKE_WAIT_INTERVAL_SEC="${SMOKE_WAIT_INTERVAL_SEC:-3}"

ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://localhost:9200}"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
FLINK_REST_URL="${FLINK_REST_URL:-http://localhost:${FLINK_UI_PORT:-8081}}"
ICEBERG_REST_URL="${ICEBERG_REST_URL:-${ICEBERG_REST_URI_HOST:-http://localhost:8181}/v1/config}"

KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka}"
MINIO_CONTAINER="${MINIO_CONTAINER:-minio}"

smoke_pass() {
  echo "[PASS] $*"
}

smoke_warn() {
  echo "[WARN] $*" >&2
}

smoke_fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

require_smoke_commands() {
  require_command docker
  require_command curl
  PYTHON_BIN="$(resolve_python_bin)"
}

ensure_docker_ready() {
  if ! docker info >/dev/null 2>&1; then
    smoke_fail "docker engine is not reachable"
  fi
}

check_compose_config() {
  docker compose config >/dev/null
  smoke_pass "docker compose configuration is valid"
}

maybe_start_services() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  if [ "$SMOKE_AUTO_START" = "1" ]; then
    log_info "Starting services: $*"
    docker compose up -d "$@"
  else
    log_info "SMOKE_AUTO_START=0, expecting services to already be running: $*"
  fi
}

container_state() {
  local container_name="$1"
  docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    "$container_name" 2>/dev/null || true
}

wait_for_container() {
  local container_name="$1"
  local label="$2"
  local timeout_sec="${3:-$SMOKE_WAIT_TIMEOUT_SEC}"
  local interval_sec="${4:-$SMOKE_WAIT_INTERVAL_SEC}"
  local elapsed=0
  local state=""

  while true; do
    state="$(container_state "$container_name")"
    if [ "$state" = "healthy" ] || [ "$state" = "running" ]; then
      smoke_pass "$label is $state"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout_sec" ]; then
      smoke_fail "$label did not become ready within ${timeout_sec}s (last state: ${state:-missing})"
    fi

    sleep "$interval_sec"
    elapsed=$((elapsed + interval_sec))
  done
}

wait_for_http_service() {
  local url="$1"
  local label="$2"
  wait_for_http "$url" "$SMOKE_WAIT_TIMEOUT_SEC" "$SMOKE_WAIT_INTERVAL_SEC" "$label"
  smoke_pass "$label HTTP endpoint is reachable"
}

wait_for_connector_running() {
  local connector_name="$1"
  local elapsed=0
  local running=""

  while true; do
    running="$(
      curl -fsS "$CONNECT_URL/connectors/$connector_name/status" 2>/dev/null | \
        "$PYTHON_BIN" -c 'import json,sys; data=json.load(sys.stdin); state=data.get("connector", {}).get("state"); tasks=data.get("tasks", []); ok=state=="RUNNING" and tasks and all(task.get("state")=="RUNNING" for task in tasks); print("1" if ok else "0")' \
        || echo 0
    )"

    if [ "$running" = "1" ]; then
      smoke_pass "connector $connector_name is RUNNING"
      return 0
    fi

    if [ "$elapsed" -ge "$SMOKE_WAIT_TIMEOUT_SEC" ]; then
      smoke_fail "connector $connector_name did not reach RUNNING state"
    fi

    sleep "$SMOKE_WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + SMOKE_WAIT_INTERVAL_SEC))
  done
}

json_count() {
  "$PYTHON_BIN" -c 'import json,sys; print(int(json.load(sys.stdin).get("count", 0)))'
}

es_count() {
  local index_name="$1"
  local query_json="${2:-}"

  if [ -n "$query_json" ]; then
    curl -fsS \
      -H "Content-Type: application/json" \
      "$ELASTICSEARCH_URL/$index_name/_count" \
      -d "$query_json" | json_count
  else
    curl -fsS "$ELASTICSEARCH_URL/$index_name/_count" | json_count
  fi
}

wait_for_es_count_delta() {
  local index_name="$1"
  local query_json="$2"
  local before_count="$3"
  local expected_delta="$4"
  local label="$5"
  local target_count=$((before_count + expected_delta))
  local elapsed=0
  local current_count=0

  while true; do
    current_count="$(es_count "$index_name" "$query_json" 2>/dev/null || echo 0)"
    if [ "$current_count" -ge "$target_count" ]; then
      smoke_pass "$label count reached $current_count (expected at least $target_count)"
      return 0
    fi

    if [ "$elapsed" -ge "$SMOKE_WAIT_TIMEOUT_SEC" ]; then
      smoke_fail "$label count stayed at $current_count (expected at least $target_count)"
    fi

    sleep "$SMOKE_WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + SMOKE_WAIT_INTERVAL_SEC))
  done
}

run_flink_sql_capture() {
  local output_file="$1"
  shift
  bash "$REPO_ROOT/scripts/run-flink-sql.sh" "$@" | tee "$output_file"
}

extract_last_tableau_count() {
  local output_file="$1"
  "$PYTHON_BIN" - "$output_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
matches = re.findall(r"\+I\[(\d+)\]", text)
if matches:
    print(matches[-1])
PY
}

cancel_flink_job_by_name() {
  local job_name="$1"
  local job_ids

  job_ids="$(
    curl -fsS "$FLINK_REST_URL/jobs/overview" 2>/dev/null | \
      "$PYTHON_BIN" - "$job_name" <<'PY'
import json
import sys

target = sys.argv[1]
data = json.load(sys.stdin)
for job in data.get("jobs", []):
    if job.get("name") == target and job.get("state") not in {"CANCELED", "FAILED", "FINISHED"}:
        print(job["jid"])
PY
  )"

  if [ -z "$job_ids" ]; then
    return 0
  fi

  while IFS= read -r job_id; do
    [ -n "$job_id" ] || continue
    log_info "Cancelling Flink job $job_name ($job_id)"
    curl -fsS -X POST "$FLINK_REST_URL/jobs/$job_id/cancel" >/dev/null
  done <<<"$job_ids"
}

minio_object_count() {
  MSYS_NO_PATHCONV=1 docker exec "$MINIO_CONTAINER" /bin/sh -lc "
    mc alias set local http://127.0.0.1:9000 '${MINIO_ROOT_USER:-admin}' '${MINIO_ROOT_PASSWORD:-password}' >/dev/null &&
    mc ls --recursive 'local/${MINIO_WAREHOUSE_BUCKET:-warehouse}'
  " | wc -l | tr -d ' '
}

wait_for_minio_object_delta() {
  local before_count="$1"
  local expected_delta="$2"
  local target_count=$((before_count + expected_delta))
  local elapsed=0
  local current_count=0

  while true; do
    current_count="$(minio_object_count 2>/dev/null || echo 0)"
    if [ "$current_count" -ge "$target_count" ]; then
      smoke_pass "MinIO object count reached $current_count (expected at least $target_count)"
      return 0
    fi

    if [ "$elapsed" -ge "$SMOKE_WAIT_TIMEOUT_SEC" ]; then
      smoke_fail "MinIO object count stayed at $current_count (expected at least $target_count)"
    fi

    sleep "$SMOKE_WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + SMOKE_WAIT_INTERVAL_SEC))
  done
}
