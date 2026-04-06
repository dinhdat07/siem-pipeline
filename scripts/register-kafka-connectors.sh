#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-120}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"

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

wait_for_connect() {
  local elapsed=0

  while true; do
    if curl -fsS "$CONNECT_URL/connectors" >/dev/null 2>&1; then
      log_info "Kafka Connect is ready at $CONNECT_URL"
      return 0
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
      log_error "Kafka Connect did not become ready within ${WAIT_TIMEOUT_SEC}s"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

put_connector_config() {
  local name="$1"
  local path="$2"

  log_info "Upserting connector: $name"
  curl -fsS -X PUT \
    -H "Content-Type: application/json" \
    "$CONNECT_URL/connectors/$name/config" \
    --data @"$path" >/dev/null
}

require_command curl

wait_for_connect

put_connector_config "siem-events-sink" "$REPO_ROOT/configs/kafka-connect/siem-events-sink.json"
put_connector_config "siem-alerts-sink" "$REPO_ROOT/configs/kafka-connect/siem-alerts-sink.json"

log_info "Registered Kafka Connect Elasticsearch sinks"
