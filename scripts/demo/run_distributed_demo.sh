#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

MODE="${1:-full}"
CONTROL_NODE_ENV="${CONTROL_NODE_ENV:-dvm-sgp-02}"
COMMON_ENV_FILE="${COMMON_ENV_FILE:-$REPO_ROOT/deploy/distributed/env/common.env}"
NODE_ENV_FILE="${NODE_ENV_FILE:-$REPO_ROOT/deploy/distributed/env/${CONTROL_NODE_ENV}.env}"

WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"
FLINK_VERIFY_TIMEOUT_SEC="${FLINK_VERIFY_TIMEOUT_SEC:-120}"
KAFKA_SCAN_STARTUP_MODE="${KAFKA_SCAN_STARTUP_MODE:-latest-offset}"

HOT_ZEEK_FILE="${DEMO_HOT_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/hot/zeek_conn_hot_smoke.jsonl}"
HOT_SNORT_FILE="${DEMO_HOT_SNORT_FILE:-$REPO_ROOT/data/test/phase35/hot/snort_alert_hot_smoke.jsonl}"
COLD_ZEEK_FILE="${DEMO_COLD_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/cold/zeek_conn_cold_smoke.jsonl}"
COLD_SNORT_FILE="${DEMO_COLD_SNORT_FILE:-$REPO_ROOT/data/test/phase35/cold/snort_alert_cold_smoke.jsonl}"
DETECT_ZEEK_FILE="${DEMO_DETECT_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/detections/zeek_conn_detection_smoke.jsonl}"
DETECT_SNORT_FILE="${DEMO_DETECT_SNORT_FILE:-$REPO_ROOT/data/test/phase35/detections/snort_alert_detection_smoke.jsonl}"
DEMO_DETECTION_INDEXES="${DEMO_DETECTION_INDEXES:-0,1,2,3,4,5}"

DETECTION_BASE_SQL="$REPO_ROOT/flink/sql/detections/00_create_detection_base.sql"
DETECTION_NAME_FILES=(
  "$REPO_ROOT/flink/sql/demo/detections/00_set_port_scan_job_name.sql"
  "$REPO_ROOT/flink/sql/demo/detections/01_set_top_talker_job_name.sql"
  "$REPO_ROOT/flink/sql/demo/detections/02_set_exfiltration_job_name.sql"
  "$REPO_ROOT/flink/sql/demo/detections/03_set_repeated_critical_job_name.sql"
  "$REPO_ROOT/flink/sql/demo/detections/04_set_correlation_job_name.sql"
  "$REPO_ROOT/flink/sql/demo/detections/05_set_protocol_anomaly_job_name.sql"
)
DETECTION_RULE_FILES=(
  "$REPO_ROOT/flink/sql/detections/04_detect_port_scan_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/05_detect_top_talkers_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/06_detect_possible_exfiltration_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/07_detect_repeated_critical_snort.sql"
  "$REPO_ROOT/flink/sql/detections/08_detect_snort_zeek_correlation.sql"
  "$REPO_ROOT/flink/sql/detections/09_detect_protocol_anomalies_zeek.sql"
)
DETECTION_JOB_NAMES=(
  "phase4-demo-detect-port-scan"
  "phase4-demo-detect-top-talker"
  "phase4-demo-detect-exfiltration"
  "phase4-demo-detect-repeated-critical"
  "phase4-demo-detect-correlation"
  "phase4-demo-detect-protocol-anomaly"
)
DETECTION_RULE_IDS=(
  "flink.zeek.port_scan"
  "flink.zeek.top_talker"
  "flink.zeek.possible_exfiltration"
  "flink.snort.repeated_critical"
  "flink.snort_zeek.correlation"
  "flink.zeek.protocol_anomaly"
)

require_command curl
require_command docker
PYTHON_BIN="$(resolve_python_bin)"

load_optional_env_file "$COMMON_ENV_FILE"
load_optional_env_file "$NODE_ENV_FILE"
export ENV_FILE=/dev/null
export ENV_FILE_OVERRIDE=/dev/null
export KAFKA_SCAN_STARTUP_MODE

KAFKA_CONTAINER="${KAFKA_CONTAINER:-siem-kafka}"
MINIO_CONTAINER="${MINIO_CONTAINER:-siem-minio}"
ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://100.76.241.30:19200}"
CONNECT_URL="${CONNECT_URL:-http://100.123.190.84:18083}"
FLINK_REST_URL="${FLINK_REST_URL:-http://100.76.241.30:18081}"
ICEBERG_REST_BASE="${ICEBERG_REST_URI_HOST:-http://100.76.241.30:18181}"
ICEBERG_NAMESPACE="${ICEBERG_NAMESPACE:-siem}"
ICEBERG_TABLE="${ICEBERG_TABLE:-normalized_events}"

mode_usage() {
  cat <<'USAGE'
usage: bash scripts/demo/run_distributed_demo.sh [hot|cold|detect|full]

This runner is for the 3-node distributed SIEM deployment on the control node.
It uses a sequential demo flow so the current hardware does not oversubscribe Flink slots.
By default it verifies all demo detection rules sequentially; set DEMO_DETECTION_INDEXES
to a comma-separated list such as 0,4,5 if you want to run only selected rules.
USAGE
}

ensure_endpoints() {
  wait_for_http "$ELASTICSEARCH_URL" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Elasticsearch"
  wait_for_http "$CONNECT_URL/connectors" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Kafka Connect"
  wait_for_http "$FLINK_REST_URL/overview" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Flink REST"
  wait_for_http "$ICEBERG_REST_BASE/v1/config" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Iceberg REST"
}

es_count_value() {
  local index_name="$1"
  local query_json="${2:-}"

  if [ -n "$query_json" ]; then
    curl -fsS -H 'Content-Type: application/json' \
      "$ELASTICSEARCH_URL/$index_name/_count" \
      -d "$query_json" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("count", 0))'
  else
    curl -fsS "$ELASTICSEARCH_URL/$index_name/_count" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("count", 0))'
  fi
}

wait_for_es_delta() {
  local index_name="$1"
  local query_json="$2"
  local before_count="$3"
  local expected_delta="$4"
  local label="$5"
  local target_count=$((before_count + expected_delta))
  local elapsed=0
  local current_count=0

  while true; do
    current_count="$(es_count_value "$index_name" "$query_json" 2>/dev/null || echo 0)"
    if [ "$current_count" -ge "$target_count" ]; then
      log_info "$label reached $current_count (expected at least $target_count)"
      return 0
    fi

    if [ "$elapsed" -ge "$FLINK_VERIFY_TIMEOUT_SEC" ]; then
      log_error "$label stayed at $current_count (expected at least $target_count)"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

flink_job_state() {
  local job_name="$1"

  curl -fsS "$FLINK_REST_URL/jobs/overview" | \
    "$PYTHON_BIN" -c 'import json,sys; target=sys.argv[1]; jobs=json.load(sys.stdin).get("jobs", []); print(next((job.get("state", "") for job in jobs if job.get("name") == target), ""))' "$job_name"
}

wait_for_flink_job_state() {
  local job_name="$1"
  local desired_state="$2"
  local timeout_sec="${3:-$WAIT_TIMEOUT_SEC}"
  local elapsed=0
  local current_state=""

  while true; do
    current_state="$(flink_job_state "$job_name")"
    if [ "$current_state" = "$desired_state" ]; then
      log_info "Flink job $job_name is $desired_state"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout_sec" ]; then
      log_error "Flink job $job_name did not reach $desired_state (last state: ${current_state:-missing})"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

flink_free_slots() {
  curl -fsS "$FLINK_REST_URL/taskmanagers" | \
    "$PYTHON_BIN" -c 'import json,sys; data=json.load(sys.stdin); print(sum(tm.get("freeSlots", 0) for tm in data.get("taskmanagers", [])))'
}

wait_for_free_slots() {
  local required_slots="$1"
  local elapsed=0
  local free_slots=0

  while true; do
    free_slots="$(flink_free_slots 2>/dev/null || echo 0)"
    if [ "$free_slots" -ge "$required_slots" ]; then
      log_info "Flink free slots available: $free_slots"
      return 0
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
      log_error "Flink free slots stayed at $free_slots (required: $required_slots)"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

iceberg_total_records() {
  curl -fsS "$ICEBERG_REST_BASE/v1/namespaces/$ICEBERG_NAMESPACE/tables/$ICEBERG_TABLE" | \
    "$PYTHON_BIN" -c 'import json,sys; payload=json.load(sys.stdin); metadata=payload.get("metadata", {}); snapshots=metadata.get("snapshots", []); current=metadata.get("current-snapshot-id"); summary=next((snapshot.get("summary", {}) for snapshot in snapshots if snapshot.get("snapshot-id") == current), {}); print(int(summary.get("total-records", 0)))'
}

wait_for_iceberg_delta() {
  local before_count="$1"
  local expected_delta="$2"
  local target_count=$((before_count + expected_delta))
  local elapsed=0
  local current_count=0

  while true; do
    current_count="$(iceberg_total_records 2>/dev/null || echo 0)"
    if [ "$current_count" -ge "$target_count" ]; then
      log_info "Iceberg total-records reached $current_count (expected at least $target_count)"
      return 0
    fi

    if [ "$elapsed" -ge "$FLINK_VERIFY_TIMEOUT_SEC" ]; then
      log_error "Iceberg total-records stayed at $current_count (expected at least $target_count)"
      exit 1
    fi

    sleep "$WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + WAIT_INTERVAL_SEC))
  done
}

wait_for_connector() {
  wait_for_connector_running "siem-events-sink" "$CONNECT_URL" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC"
  wait_for_connector_running "siem-alerts-sink" "$CONNECT_URL" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC"
}

replay_pair() {
  local zeek_file="$1"
  local snort_file="$2"

  bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$zeek_file"
  bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$snort_file"
}

cancel_demo_jobs() {
  cancel_flink_job_by_name "phase4-demo-cold-path" "$FLINK_REST_URL" || true

  local job_name
  for job_name in "${DETECTION_JOB_NAMES[@]}"; do
    cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL" || true
  done
}

bootstrap_hot() {
  bash "$REPO_ROOT/scripts/create-kafka-topics.sh"
  bash "$REPO_ROOT/scripts/bootstrap-elasticsearch.sh"
  bash "$REPO_ROOT/scripts/register-kafka-connectors.sh"
  wait_for_connector
}

bootstrap_cold() {
  bash "$REPO_ROOT/scripts/create-kafka-topics.sh"
  bash "$REPO_ROOT/scripts/bootstrap-cold-path.sh"
}

run_hot_demo() {
  local before_count after_target expected_delta

  bootstrap_hot
  before_count="$(es_count_value "siem-events")"
  expected_delta=$(( $(wc -l < "$HOT_ZEEK_FILE") + $(wc -l < "$HOT_SNORT_FILE") ))

  log_info "Hot demo: replaying smoke data"
  replay_pair "$HOT_ZEEK_FILE" "$HOT_SNORT_FILE"
  wait_for_es_delta "siem-events" "" "$before_count" "$expected_delta" "siem-events count"
}

submit_cold_job() {
  bash "$REPO_ROOT/scripts/run-flink-sql.sh" \
    "$REPO_ROOT/flink/sql/demo/cold-path/00_set_pipeline_name.sql" \
    "$REPO_ROOT/flink/sql/cold-path/01_create_iceberg_catalog.sql" \
    "$REPO_ROOT/flink/sql/cold-path/04_create_kafka_sources.sql" \
    "$REPO_ROOT/flink/sql/cold-path/05_insert_normalized_events.sql"
}

run_cold_demo() {
  local before_count expected_delta

  bootstrap_cold
  cancel_flink_job_by_name "phase4-demo-cold-path" "$FLINK_REST_URL" || true
  wait_for_free_slots 4

  before_count="$(iceberg_total_records)"
  expected_delta=$(( $(wc -l < "$COLD_ZEEK_FILE") + $(wc -l < "$COLD_SNORT_FILE") ))

  log_info "Cold demo: submitting Flink cold-path job"
  submit_cold_job
  wait_for_flink_job_state "phase4-demo-cold-path" "RUNNING"

  log_info "Cold demo: replaying smoke data"
  replay_pair "$COLD_ZEEK_FILE" "$COLD_SNORT_FILE"
  wait_for_iceberg_delta "$before_count" "$expected_delta"
}

submit_detection_job() {
  local idx="$1"

  bash "$REPO_ROOT/scripts/run-flink-sql.sh" \
    "${DETECTION_NAME_FILES[$idx]}" \
    "$DETECTION_BASE_SQL" \
    "${DETECTION_RULE_FILES[$idx]}"
}

run_detection_job() {
  local idx="$1"
  local job_name="${DETECTION_JOB_NAMES[$idx]}"
  local rule_id="${DETECTION_RULE_IDS[$idx]}"
  local before_count

  before_count="$(es_count_value "siem-alerts" "{\"query\":{\"term\":{\"rule.id\":\"$rule_id\"}}}")"

  cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL" || true
  wait_for_free_slots 4

  log_info "Detection demo: submitting $job_name"
  submit_detection_job "$idx"
  wait_for_flink_job_state "$job_name" "RUNNING"

  log_info "Detection demo: replaying smoke data for $rule_id"
  replay_pair "$DETECT_ZEEK_FILE" "$DETECT_SNORT_FILE"
  wait_for_es_delta "siem-alerts" "{\"query\":{\"term\":{\"rule.id\":\"$rule_id\"}}}" "$before_count" 1 "siem-alerts count for $rule_id"

  cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL" || true
  wait_for_free_slots 4
}

run_detect_demo() {
  local idx

  bootstrap_hot
  cancel_flink_job_by_name "phase4-demo-cold-path" "$FLINK_REST_URL" || true
  IFS=',' read -r -a selected_detection_indexes <<< "$DEMO_DETECTION_INDEXES"
  for idx in "${selected_detection_indexes[@]}"; do
    if [ -z "$idx" ] || [ "$idx" -lt 0 ] || [ "$idx" -ge "${#DETECTION_RULE_FILES[@]}" ]; then
      log_error "Invalid detection index in DEMO_DETECTION_INDEXES: $idx"
      exit 1
    fi
    run_detection_job "$idx"
  done
}

case "$MODE" in
  hot)
    ensure_endpoints
    run_hot_demo
    ;;
  cold)
    ensure_endpoints
    run_cold_demo
    ;;
  detect)
    ensure_endpoints
    run_detect_demo
    ;;
  full)
    ensure_endpoints
    cancel_demo_jobs
    run_hot_demo
    run_cold_demo
    cancel_flink_job_by_name "phase4-demo-cold-path" "$FLINK_REST_URL" || true
    wait_for_free_slots 4
    run_detect_demo
    ;;
  *)
    mode_usage >&2
    exit 1
    ;;
esac

log_info "Distributed demo flow '$MODE' completed successfully"
