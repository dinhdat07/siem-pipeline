#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-120}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"
CONNECTOR_CONFIG_DIR="${CONNECTOR_CONFIG_DIR:-$REPO_ROOT/configs/kafka-connect}"
GENERATED_CONNECTOR_DIR="${GENERATED_CONNECTOR_DIR:-$REPO_ROOT/configs/kafka-connect/.generated}"

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

render_connector_config() {
  local input_path="$1"
  local output_path="$2"

  python3 - "$input_path" "$output_path" <<'PY'
import os
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-(.*?))?\}")

def repl(match):
    name, default = match.group(1), match.group(2)
    value = os.environ.get(name)
    if value is None or value == "":
        value = default if default is not None else ""
    return value

dst.parent.mkdir(parents=True, exist_ok=True)
dst.write_text(pattern.sub(repl, src.read_text(encoding="utf-8")), encoding="utf-8")
PY
}

require_command curl
require_command python3

wait_for_connect

events_config="$CONNECTOR_CONFIG_DIR/siem-events-sink.json"
snort_events_config="$CONNECTOR_CONFIG_DIR/siem-snort-events-sink.json"
alerts_config="$CONNECTOR_CONFIG_DIR/siem-alerts-sink.json"

if [ -f "$CONNECTOR_CONFIG_DIR/siem-events-sink.json.tpl" ]; then
  events_config="$GENERATED_CONNECTOR_DIR/siem-events-sink.json"
  render_connector_config "$CONNECTOR_CONFIG_DIR/siem-events-sink.json.tpl" "$events_config"
fi

if [ -f "$CONNECTOR_CONFIG_DIR/siem-snort-events-sink.json.tpl" ]; then
  snort_events_config="$GENERATED_CONNECTOR_DIR/siem-snort-events-sink.json"
  render_connector_config "$CONNECTOR_CONFIG_DIR/siem-snort-events-sink.json.tpl" "$snort_events_config"
fi

if [ -f "$CONNECTOR_CONFIG_DIR/siem-alerts-sink.json.tpl" ]; then
  alerts_config="$GENERATED_CONNECTOR_DIR/siem-alerts-sink.json"
  render_connector_config "$CONNECTOR_CONFIG_DIR/siem-alerts-sink.json.tpl" "$alerts_config"
fi

put_connector_config "siem-events-sink" "$events_config"
if [ -f "$snort_events_config" ]; then
  put_connector_config "siem-snort-events-sink" "$snort_events_config"
fi
put_connector_config "siem-alerts-sink" "$alerts_config"

log_info "Registered Kafka Connect Elasticsearch sinks"
