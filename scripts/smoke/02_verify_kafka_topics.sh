#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_smoke_commands
ensure_docker_ready

maybe_start_services kafka
wait_for_container kafka "Kafka broker"

WAIT_TIMEOUT_SEC="${SMOKE_KAFKA_TOPIC_TIMEOUT_SEC:-120}" \
  bash "$REPO_ROOT/scripts/create-kafka-topics.sh"

topics_file="$(mktemp)"
trap 'rm -f "$topics_file"' EXIT

MSYS_NO_PATHCONV=1 docker exec "$KAFKA_CONTAINER" /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list >"$topics_file"

for topic_name in zeek.conn snort.alert siem.alerts connect-configs connect-offsets connect-status siem.connect.dlq; do
  if ! grep -Fxq "$topic_name" "$topics_file"; then
    smoke_fail "missing Kafka topic: $topic_name"
  fi
  smoke_pass "Kafka topic exists: $topic_name"
done

smoke_pass "Kafka topic verification passed"
