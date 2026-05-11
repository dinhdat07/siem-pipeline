#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://localhost:9200}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-120}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"

EVENTS_TEMPLATE_PATH="$REPO_ROOT/configs/elasticsearch/templates/siem-events-template.json"
ALERTS_TEMPLATE_PATH="$REPO_ROOT/configs/elasticsearch/templates/siem-alerts-template.json"

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

wait_for_elasticsearch() {
  local elapsed=0

  while true; do
    if curl -fsS "$ELASTICSEARCH_URL/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1; then
      log_info "Elasticsearch is ready at $ELASTICSEARCH_URL"
      return 0
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
      log_error "Elasticsearch did not become ready within ${WAIT_TIMEOUT_SEC}s"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

put_json() {
  local url="$1"
  local path="$2"

  curl -fsS -X PUT \
    -H "Content-Type: application/json" \
    "$url" \
    --data @"$path" >/dev/null
}

create_write_alias() {
  local alias_name="$1"
  local index_name="$2"
  local shards="${ELASTICSEARCH_INDEX_SHARDS:-1}"
  local replicas="${ELASTICSEARCH_INDEX_REPLICAS:-0}"

  if curl -fsS "$ELASTICSEARCH_URL/$index_name" >/dev/null 2>&1; then
    log_info "Index already exists: $index_name"
    return 0
  fi

  curl -fsS -X PUT \
    -H "Content-Type: application/json" \
    "$ELASTICSEARCH_URL/$index_name" \
    --data "{
      \"settings\": {
        \"number_of_shards\": $shards,
        \"number_of_replicas\": $replicas
      },
      \"aliases\": {
        \"$alias_name\": {
          \"is_write_index\": true
        }
      }
    }" >/dev/null

  log_info "Created $index_name with write alias $alias_name"
}

require_command curl

wait_for_elasticsearch

put_json "$ELASTICSEARCH_URL/_index_template/siem-events-template" "$EVENTS_TEMPLATE_PATH"
put_json "$ELASTICSEARCH_URL/_index_template/siem-alerts-template" "$ALERTS_TEMPLATE_PATH"

log_info "Installed index templates"

create_write_alias "siem-events" "siem-events-000001"
create_write_alias "siem-alerts" "siem-alerts-000001"
