#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

MODE="${1:-full}"
MODE="$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')"

CONTROL_NODE_ENV="${CONTROL_NODE_ENV:-dvm-sgp-02}"
COMMON_ENV_FILE="${COMMON_ENV_FILE:-$REPO_ROOT/deploy/distributed/env/common.env}"
NODE_ENV_FILE="${NODE_ENV_FILE:-$REPO_ROOT/deploy/distributed/env/${CONTROL_NODE_ENV}.env}"
DEMO_PAUSE="${DEMO_PAUSE:-1}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"
FLINK_VERIFY_TIMEOUT_SEC="${FLINK_VERIFY_TIMEOUT_SEC:-120}"
KAFKA_SCAN_STARTUP_MODE="${KAFKA_SCAN_STARTUP_MODE:-latest-offset}"
DEMO_DETECTION_INDEXES="${DEMO_DETECTION_INDEXES:-0,1,2,3,4,5}"
DETECTION_REPLAY_DELAY_SEC="${DETECTION_REPLAY_DELAY_SEC:-5}"
DETECTION_INTER_TOPIC_DELAY_SEC="${DETECTION_INTER_TOPIC_DELAY_SEC:-1}"

HOT_ZEEK_FILE="${DEMO_HOT_ZEEK_FILE:-$REPO_ROOT/data/sample/conn-logs/zeek_conn_sample.jsonl}"
HOT_SNORT_FILE="${DEMO_HOT_SNORT_FILE:-$REPO_ROOT/data/sample/snort-alerts/snort_alerts_sample.jsonl}"
COLD_ZEEK_FILE="${DEMO_COLD_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/cold/zeek_conn_cold_smoke.jsonl}"
COLD_SNORT_FILE="${DEMO_COLD_SNORT_FILE:-$REPO_ROOT/data/test/phase35/cold/snort_alert_cold_smoke.jsonl}"
DETECT_ZEEK_FILE="${DEMO_DETECT_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/detections/zeek_conn_detection_smoke.jsonl}"
DETECT_SNORT_FILE="${DEMO_DETECT_SNORT_FILE:-$REPO_ROOT/data/test/phase35/detections/snort_alert_detection_smoke.jsonl}"

COLD_JOB_NAME="phase4-demo-cold-path"
DETECTION_BASE_SQL="$REPO_ROOT/flink/sql/detections/00_create_detection_base.sql"
DETECTION_LABELS=(
  "Port Scan"
  "Top Talker"
  "Possible Exfiltration"
  "Repeated Critical Snort"
  "Snort + Zeek Correlation"
  "Protocol Anomaly"
)
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
DETECTION_EXPECTED_DELTAS=(
  "1"
  "1"
  "1"
  "1"
  "1"
  "1"
)
DETECTION_REPLAY_ORDERS=(
  "zeek-first"
  "zeek-first"
  "zeek-first"
  "snort-first"
  "correlation"
  "zeek-first"
)

require_command curl
require_command docker
PYTHON_BIN="$(resolve_python_bin)"

load_optional_env_file "$COMMON_ENV_FILE"
load_optional_env_file "$NODE_ENV_FILE"
export ENV_FILE=/dev/null
export ENV_FILE_OVERRIDE=/dev/null
export KAFKA_SCAN_STARTUP_MODE

ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://100.76.241.30:19200}"
CONNECT_URL="${CONNECT_URL:-http://100.123.190.84:18083}"
FLINK_REST_URL="${FLINK_REST_URL:-http://100.76.241.30:18081}"
KIBANA_URL="${KIBANA_URL:-http://100.76.241.30:15601}"
TRINO_URL="${TRINO_URL:-}"
ICEBERG_REST_BASE="${ICEBERG_REST_URI_HOST:-http://100.76.241.30:18181}"
ICEBERG_NAMESPACE="${ICEBERG_NAMESPACE:-siem}"
ICEBERG_TABLE="${ICEBERG_TABLE:-normalized_events}"
MINIO_CONTAINER="${MINIO_CONTAINER:-siem-minio}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-siem-postgres}"
ICEBERG_REST_CONTAINER="${ICEBERG_REST_CONTAINER:-siem-iceberg-rest}"
FLINK_JOBMANAGER_CONTAINER="${FLINK_JOBMANAGER_CONTAINER:-siem-flink-jobmanager}"
POSTGRES_USER="${POSTGRES_USER:-siem}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-password}"
MINIO_WAREHOUSE_BUCKET="${MINIO_WAREHOUSE_BUCKET:-warehouse}"

usage() {
  cat <<'USAGE'
usage: bash scripts/demo/demo.sh [reset|status|hot|cold|detect|full|cleanup]

Guided distributed demo for lecturer presentation.
- reset: clean demo state
- status: show which SIEM components are running on which nodes
- hot: bootstrap + hot-path replay
- cold: bootstrap + cold-path replay + keep cold job RUNNING for UI
- detect: stop cold job if needed, run multiple detection rules sequentially, replay data
- full: reset -> bootstrap -> status -> hot -> cold -> detect
- cleanup: stop demo-owned Flink jobs
USAGE
}

banner() {
  printf '\n========== %s ==========\n' "$1"
}

note() {
  printf '[NOTE] %s\n' "$1"
}

pause_step() {
  if [ "$DEMO_PAUSE" != "1" ] || [ ! -t 0 ]; then
    return 0
  fi
  printf '\nPress Enter to continue... '
  read -r _
}

show_urls() {
  printf '\n%-20s %s\n' "Kibana" "$KIBANA_URL"
  printf '%-20s %s\n' "Flink UI" "$FLINK_REST_URL"
  printf '%-20s %s\n' "MinIO Console" "http://100.76.241.30:19001"
  printf '%-20s %s\n' "ES Health" "$ELASTICSEARCH_URL/_cluster/health?pretty"
  if [ -n "$TRINO_URL" ]; then
    printf '%-20s %s\n' "Trino UI" "$TRINO_URL"
  fi
}

show_stage_urls() {
  local stage="$1"
  note "Useful URLs for stage: $stage"
  show_urls
}

show_cluster_status() {
  banner "CLUSTER STATUS"
  note "Terminal screen: show the deployed SIEM components and the node placement before the data flow demo starts."
  note "Node layout: dvm-sgp-02 runs Kafka, Elasticsearch, Flink JobManager, PostgreSQL, MinIO, Iceberg REST, and Kibana."
  note "Node layout: dvm-sgp-01 and dvm-sgp-03 run Kafka, Elasticsearch, Kafka Connect, and Flink TaskManager."
  printf '\n%-16s %-26s %-48s\n' "Node" "Role Group" "Key Components"
  printf '%-16s %-26s %-48s\n' "dvm-sgp-02" "control" "Kafka, Elasticsearch, JM, PostgreSQL, MinIO, Iceberg REST, Kibana"
  printf '%-16s %-26s %-48s\n' "dvm-sgp-01" "worker" "Kafka, Elasticsearch, Connect, TM"
  printf '%-16s %-26s %-48s\n' "dvm-sgp-03" "worker" "Kafka, Elasticsearch, Connect, TM"
  echo
  bash "$REPO_ROOT/deploy/distributed/siemctl.sh" status
  echo
  curl -fsS "$FLINK_REST_URL/overview" | python3 -m json.tool
  echo
  curl -fsS "$ELASTICSEARCH_URL/_cat/nodes?v"
  echo
  curl -fsS "$CONNECT_URL/connectors?expand=status" | python3 -m json.tool | sed -n '1,120p'
  show_stage_urls "status"
}

ensure_endpoints() {
  wait_for_http "$ELASTICSEARCH_URL" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Elasticsearch"
  wait_for_http "$CONNECT_URL/connectors" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Kafka Connect"
  wait_for_http "$FLINK_REST_URL/overview" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Flink REST"
  wait_for_http "$ICEBERG_REST_BASE/v1/config" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Iceberg REST"
  wait_for_http "$KIBANA_URL/api/status" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Kibana"
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
      log_info "$label reached $current_count"
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
  local elapsed=0
  local current_state=""

  while true; do
    current_state="$(flink_job_state "$job_name")"
    if [ "$current_state" = "$desired_state" ]; then
      log_info "Flink job $job_name is $desired_state"
      return 0
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
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
      log_info "Iceberg total-records reached $current_count"
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

replay_pair() {
  local zeek_file="$1"
  local snort_file="$2"
  bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$zeek_file"
  bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$snort_file"
}

replay_detection_case() {
  local idx="$1"
  local order="${DETECTION_REPLAY_ORDERS[$idx]}"

  case "$order" in
    correlation)
      local correlation_snort_file
      correlation_snort_file="$(mktemp)"
      grep -v '"event.original":"phase35-watermark-flush-snort"' "$DETECT_SNORT_FILE" > "$correlation_snort_file"
      bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$correlation_snort_file"
      sleep "$DETECTION_INTER_TOPIC_DELAY_SEC"
      bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$DETECT_ZEEK_FILE"
      rm -f "$correlation_snort_file"
      ;;
    snort-first)
      bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$DETECT_SNORT_FILE"
      sleep "$DETECTION_INTER_TOPIC_DELAY_SEC"
      bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$DETECT_ZEEK_FILE"
      ;;
    *)
      bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$DETECT_ZEEK_FILE"
      sleep "$DETECTION_INTER_TOPIC_DELAY_SEC"
      bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$DETECT_SNORT_FILE"
      ;;
  esac
}

cleanup_jobs() {
  cancel_flink_job_by_name "$COLD_JOB_NAME" "$FLINK_REST_URL" || true
  local job_name
  for job_name in "${DETECTION_JOB_NAMES[@]}"; do
    cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL" || true
  done
}

reset_demo_state() {
  banner "RESET"
  note "Terminal screen: clear old SIEM demo state so the next run starts from a clean baseline."
  cleanup_jobs
  docker restart "$FLINK_JOBMANAGER_CONTAINER" >/dev/null
  wait_for_http "$FLINK_REST_URL/overview" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Flink REST"

  curl -fsS -X DELETE "$ELASTICSEARCH_URL/siem-events-000001" >/dev/null || true
  curl -fsS -X DELETE "$ELASTICSEARCH_URL/siem-alerts-000001" >/dev/null || true
  curl -fsS -X DELETE "$ELASTICSEARCH_URL/siem-benchmark-events-000001" >/dev/null || true
  curl -fsS -X DELETE "$ELASTICSEARCH_URL/siem-benchmark-alerts-000001" >/dev/null || true

  MSYS_NO_PATHCONV=1 docker exec "$MINIO_CONTAINER" /bin/sh -lc "
    mc alias set local http://127.0.0.1:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null &&
    mc rm -r --force 'local/$MINIO_WAREHOUSE_BUCKET/flink' >/dev/null 2>&1 || true &&
    mc rm -r --force 'local/$MINIO_WAREHOUSE_BUCKET/siem' >/dev/null 2>&1 || true
  "

  docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d postgres <<'SQL'
DROP DATABASE IF EXISTS iceberg_catalog WITH (FORCE);
CREATE DATABASE iceberg_catalog OWNER iceberg;
GRANT ALL PRIVILEGES ON DATABASE iceberg_catalog TO iceberg;
SQL

  docker restart "$ICEBERG_REST_CONTAINER" >/dev/null
  wait_for_http "$ICEBERG_REST_BASE/v1/config" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Iceberg REST"

  note "Reset completed. SIEM demo indices, Iceberg metadata, and demo-owned Flink jobs are clean."
}

bootstrap_demo() {
  banner "BOOTSTRAP"
  note "Terminal screen: initialize Kafka topics, Elasticsearch templates, Kafka Connect sinks, Iceberg catalog objects, and Kibana saved objects."
  bash "$REPO_ROOT/scripts/create-kafka-topics.sh"
  bash "$REPO_ROOT/scripts/bootstrap-hot-path.sh"
  bash "$REPO_ROOT/scripts/bootstrap-cold-path.sh"
  ensure_endpoints
  show_stage_urls "bootstrap"
}

run_hot_stage() {
  local before_count expected_delta
  banner "HOT PATH"
  note "Kibana screen: hot path demonstrates near-real-time ingestion from Kafka into Elasticsearch for fast search and dashboards."
  note "This guided demo uses the richer sample dataset for the hot path so Kibana visualizations populate with more variety."
  before_count="$(es_count_value "siem-events")"
  expected_delta=$(( $(wc -l < "$HOT_ZEEK_FILE") + $(wc -l < "$HOT_SNORT_FILE") ))
  replay_pair "$HOT_ZEEK_FILE" "$HOT_SNORT_FILE"
  wait_for_es_delta "siem-events" "" "$before_count" "$expected_delta" "siem-events count"
  note "Open Kibana dashboards: SIEM Overview and SIEM Alerts. If needed, set the time range to 2012-03-16 07:00 -> 13:00 UTC."
  show_stage_urls "hot"
}

submit_cold_job() {
  bash "$REPO_ROOT/scripts/run-flink-sql.sh" \
    "$REPO_ROOT/flink/sql/demo/cold-path/00_set_pipeline_name.sql" \
    "$REPO_ROOT/flink/sql/cold-path/01_create_iceberg_catalog.sql" \
    "$REPO_ROOT/flink/sql/cold-path/04_create_kafka_sources.sql" \
    "$REPO_ROOT/flink/sql/cold-path/05_insert_normalized_events.sql"
}

run_cold_stage() {
  local before_count expected_delta
  banner "COLD PATH"
  note "Flink UI and MinIO screen: cold path demonstrates streaming delivery into Iceberg metadata and Parquet files for long-term storage."
  cleanup_jobs
  wait_for_free_slots 4
  before_count="$(iceberg_total_records)"
  expected_delta=$(( $(wc -l < "$COLD_ZEEK_FILE") + $(wc -l < "$COLD_SNORT_FILE") ))
  submit_cold_job
  wait_for_flink_job_state "$COLD_JOB_NAME" "RUNNING"
  replay_pair "$COLD_ZEEK_FILE" "$COLD_SNORT_FILE"
  wait_for_iceberg_delta "$before_count" "$expected_delta"
  note "Open Flink UI to show job $COLD_JOB_NAME in RUNNING state, then open the MinIO warehouse bucket to show Iceberg metadata and Parquet files."
  show_stage_urls "cold"
}

stop_cold_stage() {
  banner "SWITCH TO DETECT"
  note "Terminal screen: stop the cold-path job so all four Flink slots are available for the detection stage."
  cancel_flink_job_by_name "$COLD_JOB_NAME" "$FLINK_REST_URL" || true
  wait_for_free_slots 4
}

submit_detection_job() {
  local idx="$1"
  bash "$REPO_ROOT/scripts/run-flink-sql.sh" \
    "${DETECTION_NAME_FILES[$idx]}" \
    "$DETECTION_BASE_SQL" \
    "${DETECTION_RULE_FILES[$idx]}"
}

print_rule_hits() {
  local rule_id="$1"
  curl -fsS -H 'Content-Type: application/json' \
    "$ELASTICSEARCH_URL/siem-alerts/_search?pretty" \
    -d "{\"size\":5,\"sort\":[{\"@timestamp\":\"desc\"}],\"query\":{\"term\":{\"rule.id\":\"$rule_id\"}}}" | sed -n '1,80p'
}

run_detection_case() {
  local idx="$1"
  local label="${DETECTION_LABELS[$idx]}"
  local job_name="${DETECTION_JOB_NAMES[$idx]}"
  local rule_id="${DETECTION_RULE_IDS[$idx]}"
  local expected_delta="${DETECTION_EXPECTED_DELTAS[$idx]}"
  local before_count

  banner "DETECTION: $label"
  note "Kibana Alerts screen: show live alerts for rule.id = $rule_id."
  before_count="$(es_count_value "siem-alerts" "{\"query\":{\"term\":{\"rule.id\":\"$rule_id\"}}}")"
  cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL" || true
  wait_for_free_slots 4
  submit_detection_job "$idx"
  wait_for_flink_job_state "$job_name" "RUNNING"
  sleep "$DETECTION_REPLAY_DELAY_SEC"
  replay_detection_case "$idx"
  wait_for_es_delta "siem-alerts" "{\"query\":{\"term\":{\"rule.id\":\"$rule_id\"}}}" "$before_count" "$expected_delta" "$label alert count"
  note "Open Kibana -> SIEM Alerts and filter by rule.id: \"$rule_id\"."
  print_rule_hits "$rule_id"
  cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL" || true
  wait_for_free_slots 4
}

show_detection_summary() {
  local idx
  local rule_id
  local count

  banner "DETECTION SUMMARY"
  printf '\n%-32s %-8s\n' "Rule ID" "Alerts"
  for idx in "${SELECTED_DETECTION_INDEXES[@]}"; do
    rule_id="${DETECTION_RULE_IDS[$idx]}"
    count="$(es_count_value "siem-alerts" "{\"query\":{\"term\":{\"rule.id\":\"$rule_id\"}}}" 2>/dev/null || echo 0)"
    printf '%-32s %-8s\n' "$rule_id" "$count"
  done
}

run_detect_stage() {
  local idx
  banner "DETECTION"
  note "Kibana Alerts screen: detection path now runs multiple rule families sequentially so alert view stays diverse without oversubscribing four Flink slots."
  cleanup_jobs
  wait_for_free_slots 4
  IFS=',' read -r -a SELECTED_DETECTION_INDEXES <<< "$DEMO_DETECTION_INDEXES"
  for idx in "${SELECTED_DETECTION_INDEXES[@]}"; do
    if [ -z "$idx" ] || [ "$idx" -lt 0 ] || [ "$idx" -ge "${#DETECTION_RULE_FILES[@]}" ]; then
      log_error "Invalid detection index in DEMO_DETECTION_INDEXES: $idx"
      exit 1
    fi
    run_detection_case "$idx"
  done
  show_detection_summary
  show_stage_urls "detect"
}

final_note() {
  banner "DONE"
  note "If the lecturer asks about CANCELED jobs: those are demo jobs stopped intentionally after verification, not failed jobs."
  note "Cleanup command after the presentation: bash scripts/demo/demo.sh cleanup"
}

case "$MODE" in
  reset)
    reset_demo_state
    ;;
  status)
    ensure_endpoints
    show_cluster_status
    final_note
    ;;
  hot)
    ensure_endpoints
    run_hot_stage
    final_note
    ;;
  cold)
    ensure_endpoints
    run_cold_stage
    final_note
    ;;
  detect)
    ensure_endpoints
    stop_cold_stage
    run_detect_stage
    final_note
    ;;
  full)
    reset_demo_state
    bootstrap_demo
    pause_step
    show_cluster_status
    pause_step
    run_hot_stage
    pause_step
    run_cold_stage
    pause_step
    stop_cold_stage
    run_detect_stage
    final_note
    ;;
  cleanup)
    cleanup_jobs
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
