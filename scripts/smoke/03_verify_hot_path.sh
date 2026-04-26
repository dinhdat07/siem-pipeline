#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_smoke_commands
ensure_docker_ready

maybe_start_services kafka elasticsearch connect flink-jobmanager flink-taskmanager
wait_for_container kafka "Kafka broker"
wait_for_http_service "$ELASTICSEARCH_URL" "Elasticsearch"
wait_for_http_service "$CONNECT_URL/connectors" "Kafka Connect"
wait_for_http_service "$FLINK_REST_URL/overview" "Flink REST API"

bash "$SCRIPT_DIR/02_verify_kafka_topics.sh"
bash "$REPO_ROOT/scripts/bootstrap-elasticsearch.sh"
bash "$REPO_ROOT/scripts/register-kafka-connectors.sh"

wait_for_connector_running "siem-events-sink"
wait_for_connector_running "siem-alerts-sink"

HOT_JOB_NAME="phase35-hot-path-protocol-anomaly"
trap 'cancel_flink_job_by_name "$HOT_JOB_NAME" >/dev/null 2>&1 || true' EXIT

cancel_flink_job_by_name "$HOT_JOB_NAME"

export KAFKA_SCAN_STARTUP_MODE=latest-offset

hot_job_output="$(mktemp)"
alerts_output="$(mktemp)"
trap 'rm -f "$hot_job_output" "$alerts_output"; cancel_flink_job_by_name "$HOT_JOB_NAME" >/dev/null 2>&1 || true' EXIT

run_flink_sql_capture \
  "$hot_job_output" \
  "$REPO_ROOT/flink/sql/smoke/00_phase35_hot_protocol_anomaly_name.sql" \
  "$REPO_ROOT/flink/sql/detections/00_create_detection_base.sql" \
  "$REPO_ROOT/flink/sql/detections/09_detect_protocol_anomalies_zeek.sql" >/dev/null

events_query='{"query":{"bool":{"should":[{"term":{"event.original":"phase35-hot-zeek-anomaly-1"}},{"term":{"event.original":"phase35-hot-snort-1"}}],"minimum_should_match":1}}}'
alerts_query='{"query":{"bool":{"must":[{"term":{"rule.id":"flink.zeek.protocol_anomaly"}},{"term":{"source.ip":"192.168.200.10"}}]}}}'

events_before="$(es_count "siem-events" "$events_query")"
alerts_before="$(es_count "siem-alerts" "$alerts_query")"

MSYS_NO_PATHCONV=1 docker exec "$KAFKA_CONTAINER" /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic siem.alerts \
  --max-messages 8 \
  --timeout-ms 30000 >"$alerts_output" 2>&1 &
alerts_consumer_pid=$!
sleep 2

bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$REPO_ROOT/data/test/phase35/hot/zeek_conn_hot_smoke.jsonl"
bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$REPO_ROOT/data/test/phase35/hot/snort_alert_hot_smoke.jsonl"

wait "$alerts_consumer_pid" || true

if ! grep -Fq 'flink.zeek.protocol_anomaly' "$alerts_output"; then
  smoke_fail "expected protocol anomaly alert was not observed on Kafka topic siem.alerts"
fi

if ! grep -Fq '192.168.200.10' "$alerts_output"; then
  smoke_fail "expected hot-path alert source IP was not observed on Kafka topic siem.alerts"
fi

smoke_pass "Flink emitted a smoke-test alert into Kafka"

wait_for_es_count_delta "siem-events" "$events_query" "$events_before" 2 "hot-path event documents"
wait_for_es_count_delta "siem-alerts" "$alerts_query" "$alerts_before" 1 "hot-path alert documents"

smoke_pass "Hot-path validation passed"
