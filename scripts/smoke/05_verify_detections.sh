#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_smoke_commands
ensure_docker_ready

maybe_start_services kafka flink-jobmanager flink-taskmanager
wait_for_container kafka "Kafka broker"
wait_for_http_service "$FLINK_REST_URL/overview" "Flink REST API"

bash "$SCRIPT_DIR/02_verify_kafka_topics.sh"

if curl -fsS "$ELASTICSEARCH_URL" >/dev/null 2>&1 && curl -fsS "$CONNECT_URL/connectors" >/dev/null 2>&1; then
  bash "$REPO_ROOT/scripts/bootstrap-elasticsearch.sh"
  bash "$REPO_ROOT/scripts/register-kafka-connectors.sh"
  wait_for_connector_running "siem-alerts-sink"
  DETECTIONS_VERIFY_ES=1
else
  DETECTIONS_VERIFY_ES=0
fi

export KAFKA_SCAN_STARTUP_MODE=latest-offset

RULE_FILES=(
  "$REPO_ROOT/flink/sql/detections/04_detect_port_scan_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/05_detect_top_talkers_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/06_detect_possible_exfiltration_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/07_detect_repeated_critical_snort.sql"
  "$REPO_ROOT/flink/sql/detections/08_detect_snort_zeek_correlation.sql"
  "$REPO_ROOT/flink/sql/detections/09_detect_protocol_anomalies_zeek.sql"
)

NAME_FILES=(
  "$REPO_ROOT/flink/sql/smoke/detections/00_phase35_detect_port_scan_name.sql"
  "$REPO_ROOT/flink/sql/smoke/detections/01_phase35_detect_top_talker_name.sql"
  "$REPO_ROOT/flink/sql/smoke/detections/02_phase35_detect_exfiltration_name.sql"
  "$REPO_ROOT/flink/sql/smoke/detections/03_phase35_detect_repeated_critical_name.sql"
  "$REPO_ROOT/flink/sql/smoke/detections/04_phase35_detect_correlation_name.sql"
  "$REPO_ROOT/flink/sql/smoke/detections/05_phase35_detect_protocol_anomaly_name.sql"
)

JOB_NAMES=(
  "phase35-detect-port-scan"
  "phase35-detect-top-talker"
  "phase35-detect-exfiltration"
  "phase35-detect-repeated-critical"
  "phase35-detect-correlation"
  "phase35-detect-protocol-anomaly"
)

EXPECTED_RULE_IDS=(
  "flink.zeek.port_scan"
  "flink.zeek.top_talker"
  "flink.zeek.possible_exfiltration"
  "flink.snort.repeated_critical"
  "flink.snort_zeek.correlation"
  "flink.zeek.protocol_anomaly"
)

cleanup_detection_jobs() {
  for job_name in "${JOB_NAMES[@]}"; do
    cancel_flink_job_by_name "$job_name" >/dev/null 2>&1 || true
  done
}

trap 'cleanup_detection_jobs' EXIT
cleanup_detection_jobs

es_alerts_query='{"query":{"terms":{"rule.id":["flink.zeek.port_scan","flink.zeek.top_talker","flink.zeek.possible_exfiltration","flink.snort.repeated_critical","flink.snort_zeek.correlation","flink.zeek.protocol_anomaly"]}}}'
alerts_before=0

if [ "$DETECTIONS_VERIFY_ES" = "1" ]; then
  alerts_before="$(es_count "siem-alerts" "$es_alerts_query")"
fi

for idx in "${!RULE_FILES[@]}"; do
  job_output="$(mktemp)"
  run_flink_sql_capture \
    "$job_output" \
    "${NAME_FILES[$idx]}" \
    "$REPO_ROOT/flink/sql/detections/00_create_detection_base.sql" \
    "${RULE_FILES[$idx]}" >/dev/null
  rm -f "$job_output"
done

alerts_output="$(mktemp)"
trap 'rm -f "$alerts_output"; cleanup_detection_jobs' EXIT

MSYS_NO_PATHCONV=1 docker exec "$KAFKA_CONTAINER" /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic siem.alerts \
  --max-messages 64 \
  --timeout-ms 45000 >"$alerts_output" 2>&1 &
alerts_consumer_pid=$!
sleep 2

bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$REPO_ROOT/data/test/phase35/detections/zeek_conn_detection_smoke.jsonl"
bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$REPO_ROOT/data/test/phase35/detections/snort_alert_detection_smoke.jsonl"

wait "$alerts_consumer_pid" || true

for rule_id in "${EXPECTED_RULE_IDS[@]}"; do
  if ! grep -Fq "$rule_id" "$alerts_output"; then
    smoke_fail "expected detection rule id not observed on Kafka topic siem.alerts: $rule_id"
  fi
  smoke_pass "Observed detection alert on Kafka: $rule_id"
done

if [ "$DETECTIONS_VERIFY_ES" = "1" ]; then
  wait_for_es_count_delta "siem-alerts" "$es_alerts_query" "$alerts_before" 6 "Elasticsearch detection alerts"
else
  smoke_warn "Elasticsearch and Kafka Connect were not available, so detection indexing was not asserted in this run"
fi

smoke_pass "Detection validation passed"
