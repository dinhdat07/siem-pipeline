#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Kafka topics for the local lab environment.
# This script is intended to run from the host and exec into the Kafka container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/configs/kafka/topics.env"
ROOT_ENV_FILE="${ENV_FILE_OVERRIDE:-$REPO_ROOT/.env}"

KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka}"
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin/kafka-topics.sh}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-60}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-2}"

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

require_env_var() {
  local var_name="$1"
  if [ -z "${!var_name:-}" ]; then
    log_error "missing required setting: $var_name in $ENV_FILE"
    exit 1
  fi
}

run_kafka_topics() {
  docker exec "$KAFKA_CONTAINER" "$KAFKA_BIN" --bootstrap-server "$BOOTSTRAP_SERVER" "$@"
}

wait_for_kafka() {
  local elapsed=0

  while true; do
    if run_kafka_topics --list >/dev/null 2>&1; then
      log_info "Kafka is ready in container '$KAFKA_CONTAINER'"
      return 0
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
      log_error "Kafka did not become ready within ${WAIT_TIMEOUT_SEC}s"
      log_error "start the broker first with: docker compose up -d"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

create_topic() {
  local topic_name="$1"
  local partitions="$2"
  local replication_factor="$3"
  shift 3

  log_info "Ensuring topic exists: $topic_name"
  run_kafka_topics \
    --create \
    --if-not-exists \
    --topic "$topic_name" \
    --partitions "$partitions" \
    --replication-factor "$replication_factor" \
    "$@"
}

if [ ! -f "$ENV_FILE" ]; then
  log_error "missing env file: $ENV_FILE"
  exit 1
fi

require_command docker

# Load optional root .env first so topic settings can reference compose values.
if [ -f "$ROOT_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  . <(tr -d '\r' < "$ROOT_ENV_FILE")
  set +a
fi

# shellcheck disable=SC1090
set -a
# Accept both LF and CRLF env files.
. <(tr -d '\r' < "$ENV_FILE")
set +a

require_env_var BOOTSTRAP_SERVER
require_env_var TOPIC_ZEEK_CONN
require_env_var TOPIC_ZEEK_CONN_PARTITIONS
require_env_var TOPIC_ZEEK_CONN_RF
require_env_var TOPIC_SNORT_ALERT
require_env_var TOPIC_SNORT_ALERT_PARTITIONS
require_env_var TOPIC_SNORT_ALERT_RF
require_env_var TOPIC_ALERTS
require_env_var TOPIC_ALERTS_PARTITIONS
require_env_var TOPIC_ALERTS_RF
require_env_var TOPIC_CONNECT_CONFIGS
require_env_var TOPIC_CONNECT_CONFIGS_PARTITIONS
require_env_var TOPIC_CONNECT_CONFIGS_RF
require_env_var TOPIC_CONNECT_OFFSETS
require_env_var TOPIC_CONNECT_OFFSETS_PARTITIONS
require_env_var TOPIC_CONNECT_OFFSETS_RF
require_env_var TOPIC_CONNECT_STATUS
require_env_var TOPIC_CONNECT_STATUS_PARTITIONS
require_env_var TOPIC_CONNECT_STATUS_RF
require_env_var TOPIC_CONNECT_DLQ
require_env_var TOPIC_CONNECT_DLQ_PARTITIONS
require_env_var TOPIC_CONNECT_DLQ_RF

if ! docker container inspect "$KAFKA_CONTAINER" >/dev/null 2>&1; then
  log_error "Kafka container not found: $KAFKA_CONTAINER"
  log_error "start the broker first with: docker compose up -d"
  exit 1
fi

wait_for_kafka

create_topic "$TOPIC_ZEEK_CONN" "$TOPIC_ZEEK_CONN_PARTITIONS" "$TOPIC_ZEEK_CONN_RF"
create_topic "$TOPIC_SNORT_ALERT" "$TOPIC_SNORT_ALERT_PARTITIONS" "$TOPIC_SNORT_ALERT_RF"
create_topic "$TOPIC_ALERTS" "$TOPIC_ALERTS_PARTITIONS" "$TOPIC_ALERTS_RF"
create_topic "$TOPIC_CONNECT_CONFIGS" "$TOPIC_CONNECT_CONFIGS_PARTITIONS" "$TOPIC_CONNECT_CONFIGS_RF" --config cleanup.policy=compact
create_topic "$TOPIC_CONNECT_OFFSETS" "$TOPIC_CONNECT_OFFSETS_PARTITIONS" "$TOPIC_CONNECT_OFFSETS_RF" --config cleanup.policy=compact
create_topic "$TOPIC_CONNECT_STATUS" "$TOPIC_CONNECT_STATUS_PARTITIONS" "$TOPIC_CONNECT_STATUS_RF" --config cleanup.policy=compact
create_topic "$TOPIC_CONNECT_DLQ" "$TOPIC_CONNECT_DLQ_PARTITIONS" "$TOPIC_CONNECT_DLQ_RF"

log_info "Current topics:"
run_kafka_topics --list
