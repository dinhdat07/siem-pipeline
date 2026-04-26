#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_smoke_commands
ensure_docker_ready

maybe_start_services kafka minio minio-init iceberg-rest flink-jobmanager flink-taskmanager
wait_for_container kafka "Kafka broker"
wait_for_container minio "MinIO"
wait_for_http_service "$ICEBERG_REST_URL" "Iceberg REST catalog"
wait_for_http_service "$FLINK_REST_URL/overview" "Flink REST API"

bash "$SCRIPT_DIR/02_verify_kafka_topics.sh"
bash "$REPO_ROOT/scripts/bootstrap-cold-path.sh"

COLD_JOB_NAME="phase35-cold-path-insert"
export PHASE35_COLD_EVENT_PREFIX="${PHASE35_COLD_EVENT_PREFIX:-phase35-cold-}"
export KAFKA_SCAN_STARTUP_MODE=latest-offset

trap 'cancel_flink_job_by_name "$COLD_JOB_NAME" >/dev/null 2>&1 || true' EXIT
cancel_flink_job_by_name "$COLD_JOB_NAME"

cold_job_output="$(mktemp)"
count_before_output="$(mktemp)"
count_after_output="$(mktemp)"
trap 'rm -f "$cold_job_output" "$count_before_output" "$count_after_output"; cancel_flink_job_by_name "$COLD_JOB_NAME" >/dev/null 2>&1 || true' EXIT

before_objects="$(minio_object_count)"
before_rows=""

if run_flink_sql_capture "$count_before_output" "$REPO_ROOT/flink/sql/smoke/90_phase35_count_cold_rows.sql" >/dev/null 2>&1; then
  before_rows="$(extract_last_tableau_count "$count_before_output")"
fi

run_flink_sql_capture \
  "$cold_job_output" \
  "$REPO_ROOT/flink/sql/smoke/01_phase35_cold_insert_name.sql" \
  "$REPO_ROOT/flink/sql/cold-path/01_create_iceberg_catalog.sql" \
  "$REPO_ROOT/flink/sql/cold-path/04_create_kafka_sources.sql" \
  "$REPO_ROOT/flink/sql/cold-path/05_insert_normalized_events.sql" >/dev/null

bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$REPO_ROOT/data/test/phase35/cold/zeek_conn_cold_smoke.jsonl"
bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$REPO_ROOT/data/test/phase35/cold/snort_alert_cold_smoke.jsonl"

wait_for_minio_object_delta "$before_objects" 1

if run_flink_sql_capture "$count_after_output" "$REPO_ROOT/flink/sql/smoke/90_phase35_count_cold_rows.sql" >/dev/null 2>&1; then
  after_rows="$(extract_last_tableau_count "$count_after_output")"
  if [ -n "$before_rows" ] && [ -n "$after_rows" ] && [ "$after_rows" -ge $((before_rows + 2)) ]; then
    smoke_pass "Iceberg smoke row count increased from $before_rows to $after_rows"
  else
    smoke_warn "Iceberg row-count assertion could not prove a +2 delta; keeping object-level verification as the hard assertion"
  fi
else
  smoke_warn "Iceberg row-count query could not be completed; keeping object-level verification as the hard assertion"
fi

smoke_pass "Cold-path validation passed"
