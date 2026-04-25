#!/usr/bin/env bash

log_info() {
  echo "[INFO] $*"
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
