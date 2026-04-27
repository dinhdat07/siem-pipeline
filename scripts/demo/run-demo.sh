#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/common.sh"

load_repo_env "$REPO_ROOT"
load_optional_env_file "$REPO_ROOT/configs/flink/detection-thresholds.env"

MODE="${1:-${DEMO_MODE:-full}}"
MODE="$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')"

DEMO_START_STACK="${DEMO_START_STACK:-1}"
DEMO_AUTO_BUILD="${DEMO_AUTO_BUILD:-1}"
DEMO_RESET_STACK="${DEMO_RESET_STACK:-0}"
DEMO_RESET_VOLUMES="${DEMO_RESET_VOLUMES:-0}"
DEMO_RESET_JOBS="${DEMO_RESET_JOBS:-1}"
DEMO_IMPORT_KIBANA="${DEMO_IMPORT_KIBANA:-1}"
DEMO_ENABLE_SMOKE_TESTS="${DEMO_ENABLE_SMOKE_TESTS:-0}"
DEMO_WAIT_TIMEOUT_SEC="${DEMO_WAIT_TIMEOUT_SEC:-240}"
DEMO_WAIT_INTERVAL_SEC="${DEMO_WAIT_INTERVAL_SEC:-5}"
DEMO_POST_JOB_SUBMIT_SLEEP_SEC="${DEMO_POST_JOB_SUBMIT_SLEEP_SEC:-8}"
DEMO_POST_REPLAY_SLEEP_SEC="${DEMO_POST_REPLAY_SLEEP_SEC:-10}"
DEMO_KAFKA_SCAN_STARTUP_MODE="${DEMO_KAFKA_SCAN_STARTUP_MODE:-latest-offset}"

HOT_ZEEK_FILE="${DEMO_HOT_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/hot/zeek_conn_hot_smoke.jsonl}"
HOT_SNORT_FILE="${DEMO_HOT_SNORT_FILE:-$REPO_ROOT/data/test/phase35/hot/snort_alert_hot_smoke.jsonl}"
COLD_ZEEK_FILE="${DEMO_COLD_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/cold/zeek_conn_cold_smoke.jsonl}"
COLD_SNORT_FILE="${DEMO_COLD_SNORT_FILE:-$REPO_ROOT/data/test/phase35/cold/snort_alert_cold_smoke.jsonl}"
DETECT_ZEEK_FILE="${DEMO_DETECT_ZEEK_FILE:-$REPO_ROOT/data/test/phase35/detections/zeek_conn_detection_smoke.jsonl}"
DETECT_SNORT_FILE="${DEMO_DETECT_SNORT_FILE:-$REPO_ROOT/data/test/phase35/detections/snort_alert_detection_smoke.jsonl}"

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-http://localhost:9200}"
KIBANA_URL="${KIBANA_URL:-http://localhost:${KIBANA_PORT:-5601}}"
FLINK_REST_URL="${FLINK_REST_URL:-http://localhost:${FLINK_UI_PORT:-8081}}"
ICEBERG_REST_URL="${ICEBERG_REST_URL:-${ICEBERG_REST_URI_HOST:-http://localhost:8181}/v1/config}"
MINIO_BUCKET="${MINIO_WAREHOUSE_BUCKET:-warehouse}"

require_command docker
require_command curl

demo_usage() {
  cat <<USAGE
usage: $0 [hot-only|cold-only|detect-only|full]

Examples:
  bash scripts/demo/run-demo.sh full
  bash scripts/demo/run-demo.sh hot-only
  DEMO_ENABLE_SMOKE_TESTS=1 bash scripts/demo/run-demo.sh detect-only
USAGE
}

mode_to_stage() {
  case "$1" in
    hot|hot-only)
      echo hot
      ;;
    cold|cold-only)
      echo cold
      ;;
    detect|detect-only)
      echo detect
      ;;
    full)
      echo full
      ;;
    *)
      return 1
      ;;
  esac
}

mode_to_profiles() {
  case "$1" in
    hot|hot-only)
      echo hot
      ;;
    cold|cold-only)
      echo cold,detect
      ;;
    detect|detect-only)
      echo detect
      ;;
    full)
      echo hot,cold,detect
      ;;
    *)
      return 1
      ;;
  esac
}

start_mode_stack() {
  local profiles="$1"
  local compose_cmd=(docker compose up -d)

  if is_truthy "$DEMO_AUTO_BUILD"; then
    compose_cmd+=(--build)
  fi

  if is_truthy "$DEMO_RESET_STACK"; then
    local down_cmd=(docker compose down --remove-orphans)
    if is_truthy "$DEMO_RESET_VOLUMES"; then
      down_cmd+=(-v)
    fi
    log_info "Resetting compose stack before demo"
    "${down_cmd[@]}"
  fi

  log_info "Starting demo stack with compose profiles: ${profiles:-<none>}"
  COMPOSE_PROFILES="$profiles" "${compose_cmd[@]}"
}

wait_for_mode_services() {
  local stage="$1"

  wait_for_container kafka "Kafka broker" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC"

  case "$stage" in
    hot)
      wait_for_http "$ELASTICSEARCH_URL" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Elasticsearch"
      wait_for_http "$CONNECT_URL/connectors" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Kafka Connect"
      wait_for_http "$KIBANA_URL/api/status" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Kibana"
      ;;
    cold)
      wait_for_container minio "MinIO" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC"
      wait_for_http "$ICEBERG_REST_URL" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Iceberg REST catalog"
      wait_for_http "$FLINK_REST_URL/overview" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Flink REST API"
      ;;
    detect)
      wait_for_http "$FLINK_REST_URL/overview" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Flink REST API"
      ;;
    full)
      wait_for_http "$ELASTICSEARCH_URL" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Elasticsearch"
      wait_for_http "$CONNECT_URL/connectors" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Kafka Connect"
      wait_for_http "$KIBANA_URL/api/status" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Kibana"
      wait_for_container minio "MinIO" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC"
      wait_for_http "$ICEBERG_REST_URL" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Iceberg REST catalog"
      wait_for_http "$FLINK_REST_URL/overview" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC" "Flink REST API"
      ;;
  esac
}

bootstrap_hot_path() {
  bash "$REPO_ROOT/scripts/create-kafka-topics.sh"
  bash "$REPO_ROOT/scripts/bootstrap-elasticsearch.sh"
  bash "$REPO_ROOT/scripts/register-kafka-connectors.sh"
  wait_for_connector_running "siem-events-sink" "$CONNECT_URL" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC"
  wait_for_connector_running "siem-alerts-sink" "$CONNECT_URL" "$DEMO_WAIT_TIMEOUT_SEC" "$DEMO_WAIT_INTERVAL_SEC"

  if is_truthy "$DEMO_IMPORT_KIBANA"; then
    bash "$REPO_ROOT/scripts/import-kibana-saved-objects.sh"
  fi
}

bootstrap_cold_path() {
  bash "$REPO_ROOT/scripts/create-kafka-topics.sh"
  bash "$REPO_ROOT/scripts/bootstrap-cold-path.sh"
}

submit_cold_path_job() {
  local job_name="phase4-demo-cold-path"

  if is_truthy "$DEMO_RESET_JOBS"; then
    cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL"
  fi

  export KAFKA_SCAN_STARTUP_MODE="$DEMO_KAFKA_SCAN_STARTUP_MODE"

  bash "$REPO_ROOT/scripts/run-flink-sql.sh" \
    "$REPO_ROOT/flink/sql/demo/cold-path/00_set_pipeline_name.sql" \
    "$REPO_ROOT/flink/sql/cold-path/01_create_iceberg_catalog.sql" \
    "$REPO_ROOT/flink/sql/cold-path/04_create_kafka_sources.sql" \
    "$REPO_ROOT/flink/sql/cold-path/05_insert_normalized_events.sql"
}

submit_detection_jobs() {
  local base_sql="$REPO_ROOT/flink/sql/detections/00_create_detection_base.sql"
  local name_files=(
    "$REPO_ROOT/flink/sql/demo/detections/00_set_port_scan_job_name.sql"
    "$REPO_ROOT/flink/sql/demo/detections/01_set_top_talker_job_name.sql"
    "$REPO_ROOT/flink/sql/demo/detections/02_set_exfiltration_job_name.sql"
    "$REPO_ROOT/flink/sql/demo/detections/03_set_repeated_critical_job_name.sql"
    "$REPO_ROOT/flink/sql/demo/detections/04_set_correlation_job_name.sql"
    "$REPO_ROOT/flink/sql/demo/detections/05_set_protocol_anomaly_job_name.sql"
  )
  local rule_files=(
    "$REPO_ROOT/flink/sql/detections/04_detect_port_scan_zeek.sql"
    "$REPO_ROOT/flink/sql/detections/05_detect_top_talkers_zeek.sql"
    "$REPO_ROOT/flink/sql/detections/06_detect_possible_exfiltration_zeek.sql"
    "$REPO_ROOT/flink/sql/detections/07_detect_repeated_critical_snort.sql"
    "$REPO_ROOT/flink/sql/detections/08_detect_snort_zeek_correlation.sql"
    "$REPO_ROOT/flink/sql/detections/09_detect_protocol_anomalies_zeek.sql"
  )
  local job_names=(
    phase4-demo-detect-port-scan
    phase4-demo-detect-top-talker
    phase4-demo-detect-exfiltration
    phase4-demo-detect-repeated-critical
    phase4-demo-detect-correlation
    phase4-demo-detect-protocol-anomaly
  )
  local idx

  if is_truthy "$DEMO_RESET_JOBS"; then
    for job_name in "${job_names[@]}"; do
      cancel_flink_job_by_name "$job_name" "$FLINK_REST_URL"
    done
  fi

  export KAFKA_SCAN_STARTUP_MODE="$DEMO_KAFKA_SCAN_STARTUP_MODE"

  for idx in "${!rule_files[@]}"; do
    log_info "Submitting demo detection job: $(basename "${rule_files[$idx]}")"
    bash "$REPO_ROOT/scripts/run-flink-sql.sh" \
      "${name_files[$idx]}" \
      "$base_sql" \
      "${rule_files[$idx]}"
  done
}

replay_pair() {
  local label="$1"
  local zeek_file="$2"
  local snort_file="$3"

  log_info "Replaying ${label} Zeek events from $zeek_file"
  bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$zeek_file"
  log_info "Replaying ${label} Snort events from $snort_file"
  bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$snort_file"
}

print_demo_summary() {
  local stage="$1"

  echo
  echo "Demo mode '$stage' is up. Useful checks:"
  echo "- Kafka topics: docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list"

  if [ "$stage" = "hot" ] || [ "$stage" = "full" ]; then
    echo "- Elasticsearch event count: curl $ELASTICSEARCH_URL/siem-events/_count"
    echo "- Kibana: $KIBANA_URL"
  fi

  if [ "$stage" = "full" ]; then
    echo "- Elasticsearch alert count: curl $ELASTICSEARCH_URL/siem-alerts/_count"
  fi

  if [ "$stage" = "cold" ] || [ "$stage" = "full" ]; then
    echo "- Iceberg/MinIO verification: bash scripts/verify-cold-path.sh"
    echo "- MinIO console: http://localhost:${MINIO_CONSOLE_PORT:-9001}"
    echo "- Iceberg bucket listing: docker exec minio mc ls --recursive local/$MINIO_BUCKET"
  fi

  if [ "$stage" = "detect" ] || [ "$stage" = "full" ]; then
    echo "- Kafka alerts: bash scripts/verify-flink-detections.sh"
    echo "- Flink jobs: curl $FLINK_REST_URL/jobs/overview"
  fi

  echo
  echo "Small demo datasets used:"
  case "$stage" in
    hot)
      echo "- $HOT_ZEEK_FILE"
      echo "- $HOT_SNORT_FILE"
      ;;
    cold)
      echo "- $COLD_ZEEK_FILE"
      echo "- $COLD_SNORT_FILE"
      ;;
    detect)
      echo "- $DETECT_ZEEK_FILE"
      echo "- $DETECT_SNORT_FILE"
      ;;
    full)
      echo "- $HOT_ZEEK_FILE"
      echo "- $HOT_SNORT_FILE"
      echo "- $COLD_ZEEK_FILE"
      echo "- $COLD_SNORT_FILE"
      echo "- $DETECT_ZEEK_FILE"
      echo "- $DETECT_SNORT_FILE"
      ;;
  esac
}

STAGE="$(mode_to_stage "$MODE" || true)"
PROFILES="$(mode_to_profiles "$MODE" || true)"

if [ -z "$STAGE" ] || [ -z "$PROFILES" ]; then
  demo_usage >&2
  exit 1
fi

log_info "Validating docker compose configuration"
docker compose config >/dev/null

if is_truthy "$DEMO_START_STACK"; then
  start_mode_stack "$PROFILES"
else
  log_info "DEMO_START_STACK=0, expecting the required services to already be running"
fi

wait_for_mode_services "$STAGE"

case "$STAGE" in
  hot)
    bootstrap_hot_path
    replay_pair "hot demo" "$HOT_ZEEK_FILE" "$HOT_SNORT_FILE"
    ;;
  cold)
    bootstrap_cold_path
    submit_cold_path_job
    sleep "$DEMO_POST_JOB_SUBMIT_SLEEP_SEC"
    replay_pair "cold demo" "$COLD_ZEEK_FILE" "$COLD_SNORT_FILE"
    ;;
  detect)
    bash "$REPO_ROOT/scripts/create-kafka-topics.sh"
    submit_detection_jobs
    sleep "$DEMO_POST_JOB_SUBMIT_SLEEP_SEC"
    replay_pair "detection demo" "$DETECT_ZEEK_FILE" "$DETECT_SNORT_FILE"
    ;;
  full)
    bootstrap_hot_path
    bootstrap_cold_path
    submit_cold_path_job
    submit_detection_jobs
    sleep "$DEMO_POST_JOB_SUBMIT_SLEEP_SEC"
    replay_pair "hot demo" "$HOT_ZEEK_FILE" "$HOT_SNORT_FILE"
    replay_pair "cold demo" "$COLD_ZEEK_FILE" "$COLD_SNORT_FILE"
    replay_pair "detection demo" "$DETECT_ZEEK_FILE" "$DETECT_SNORT_FILE"
    ;;
  *)
    demo_usage >&2
    exit 1
    ;;
 esac

if [ "$DEMO_POST_REPLAY_SLEEP_SEC" -gt 0 ] 2>/dev/null; then
  log_info "Waiting ${DEMO_POST_REPLAY_SLEEP_SEC}s for sinks and jobs to consume replayed data"
  sleep "$DEMO_POST_REPLAY_SLEEP_SEC"
fi

if is_truthy "$DEMO_ENABLE_SMOKE_TESTS"; then
  log_info "Running smoke validation for stage '$STAGE'"
  bash "$REPO_ROOT/scripts/smoke/run_smoke_tests.sh" "$STAGE"
fi

print_demo_summary "$STAGE"
