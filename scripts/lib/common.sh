#!/usr/bin/env bash

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "required command not found: $cmd"
    exit 1
  fi
}

resolve_python_bin() {
  if [ -n "${PYTHON_BIN:-}" ] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "$PYTHON_BIN"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN=python3
    echo "$PYTHON_BIN"
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN=python
    echo "$PYTHON_BIN"
    return 0
  fi

  log_error "required command not found: python3 or python"
  exit 1
}

load_repo_env() {
  local repo_root="$1"
  local env_file="${ENV_FILE:-$repo_root/.env}"

  if [ -f "$env_file" ]; then
    log_info "Loading environment from $env_file"
    set -a
    # shellcheck disable=SC1090
    . <(tr -d '\r' < "$env_file")
    set +a
  fi
}

load_optional_env_file() {
  local env_file="$1"

  if [ -f "$env_file" ]; then
    log_info "Loading environment from $env_file"
    set -a
    # shellcheck disable=SC1090
    . <(tr -d '\r' < "$env_file")
    set +a
  fi
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_http() {
  local url="$1"
  local timeout_sec="${2:-120}"
  local interval_sec="${3:-3}"
  local name="${4:-service}"
  local elapsed=0

  while true; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log_info "$name is ready at $url"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout_sec" ]; then
      log_error "$name did not become ready within ${timeout_sec}s"
      exit 1
    fi

    sleep "$interval_sec"
    elapsed=$((elapsed + interval_sec))
  done
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
  local timeout_sec="${3:-120}"
  local interval_sec="${4:-3}"
  local elapsed=0
  local state=""

  while true; do
    state="$(container_state "$container_name")"
    if [ "$state" = "healthy" ] || [ "$state" = "running" ]; then
      log_info "$label is $state"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout_sec" ]; then
      log_error "$label did not become ready within ${timeout_sec}s (last state: ${state:-missing})"
      exit 1
    fi

    sleep "$interval_sec"
    elapsed=$((elapsed + interval_sec))
  done
}

wait_for_connector_running() {
  local connector_name="$1"
  local connect_url="${2:-http://localhost:8083}"
  local timeout_sec="${3:-120}"
  local interval_sec="${4:-3}"
  local elapsed=0
  local running=""

  require_command curl
  PYTHON_BIN="$(resolve_python_bin)"

  while true; do
    running="$(
      curl -fsS "$connect_url/connectors/$connector_name/status" 2>/dev/null | \
        "$PYTHON_BIN" -c 'import json,sys; data=json.load(sys.stdin); state=data.get("connector", {}).get("state"); tasks=data.get("tasks", []); ok=state=="RUNNING" and tasks and all(task.get("state")=="RUNNING" for task in tasks); print("1" if ok else "0")' \
        || echo 0
    )"

    if [ "$running" = "1" ]; then
      log_info "connector $connector_name is RUNNING"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout_sec" ]; then
      log_error "connector $connector_name did not reach RUNNING state"
      exit 1
    fi

    sleep "$interval_sec"
    elapsed=$((elapsed + interval_sec))
  done
}

cancel_flink_job_by_name() {
  local job_name="$1"
  local flink_rest_url="${2:-http://localhost:${FLINK_UI_PORT:-8081}}"
  local job_ids

  require_command curl
  PYTHON_BIN="$(resolve_python_bin)"

  job_ids="$(
    curl -fsS "$flink_rest_url/jobs/overview" 2>/dev/null | \
      "$PYTHON_BIN" -c 'import json,sys; target=sys.argv[1]; data=json.load(sys.stdin); [print(job["jid"]) for job in data.get("jobs", []) if job.get("name")==target and job.get("state") not in {"CANCELED","FAILED","FINISHED"}]' "$job_name"
  )"

  if [ -z "$job_ids" ]; then
    return 0
  fi

  while IFS= read -r job_id; do
    [ -n "$job_id" ] || continue
    log_info "Cancelling Flink job $job_name ($job_id)"
    curl -fsS -X POST "$flink_rest_url/jobs/$job_id/cancel" >/dev/null
  done <<<"$job_ids"
}
