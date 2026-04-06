#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-5}"
SAVED_OBJECTS_PATH="$REPO_ROOT/dashboards/siem-phase1.ndjson"

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

wait_for_kibana() {
  local elapsed=0

  while true; do
    if curl -fsS "$KIBANA_URL/api/status" >/dev/null 2>&1; then
      log_info "Kibana is ready at $KIBANA_URL"
      return 0
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
      log_error "Kibana did not become ready within ${WAIT_TIMEOUT_SEC}s"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

require_command curl

if [ ! -f "$SAVED_OBJECTS_PATH" ]; then
  log_error "missing saved objects file: $SAVED_OBJECTS_PATH"
  exit 1
fi

wait_for_kibana

curl -fsS -X POST \
  "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  --form "file=@$SAVED_OBJECTS_PATH" >/dev/null

log_info "Imported Kibana saved objects"
