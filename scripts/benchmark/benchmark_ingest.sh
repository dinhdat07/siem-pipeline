#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

ensure_benchmark_dirs
wait_for_container kafka "Kafka broker" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC"
wait_for_benchmark_elasticsearch
wait_for_benchmark_connect
wait_for_benchmark_flink

bash "$REPO_ROOT/scripts/create-kafka-topics.sh"
bash "$REPO_ROOT/scripts/bootstrap-elasticsearch.sh"
bash "$REPO_ROOT/scripts/register-kafka-connectors.sh"
wait_for_connector_running "siem-events-sink" "$CONNECT_URL" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC"
wait_for_connector_running "siem-alerts-sink" "$CONNECT_URL" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC"

metadata_json="$BENCHMARK_INPUT_DIR/metadata.json"
benchmark_id="$($PYTHON_BIN -c 'import json,sys; print(json.load(open(sys.argv[1]))["benchmark_id"])' "$metadata_json")"
event_count="$($PYTHON_BIN -c 'import json,sys; print(json.load(open(sys.argv[1]))["event_count"])' "$metadata_json")"

es_count_query() {
  local index_name="$1"
  local field_name="$2"
  local value="$3"
  curl -fsS -H "Content-Type: application/json" \
    "$ELASTICSEARCH_URL/$index_name/_count" \
    -d "{\"query\":{\"term\":{\"$field_name\":\"$value\"}}}" | \
    "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("count", 0))'
}

es_count_query_json() {
  local index_name="$1"
  local query_json="$2"
  curl -fsS -H "Content-Type: application/json" \
    "$ELASTICSEARCH_URL/$index_name/_count" \
    -d "$query_json" | \
    "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin).get("count", 0))'
}

wait_for_es_count() {
  local index_name="$1"
  local field_name="$2"
  local value="$3"
  local target="$4"
  local elapsed=0
  local current=0

  while true; do
    current="$(es_count_query "$index_name" "$field_name" "$value" 2>/dev/null || echo 0)"
    if [ "$current" -ge "$target" ]; then
      echo "$current"
      return 0
    fi
    if [ "$elapsed" -ge "$BENCHMARK_WAIT_TIMEOUT_SEC" ]; then
      log_error "timed out waiting for $index_name to reach count $target for $field_name=$value (current=$current)"
      exit 1
    fi
    sleep "$BENCHMARK_WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + BENCHMARK_WAIT_INTERVAL_SEC))
  done
}

wait_for_es_count_json() {
  local index_name="$1"
  local query_json="$2"
  local target="$3"
  local elapsed=0
  local current=0

  while true; do
    current="$(es_count_query_json "$index_name" "$query_json" 2>/dev/null || echo 0)"
    if [ "$current" -ge "$target" ]; then
      echo "$current"
      return 0
    fi
    if [ "$elapsed" -ge "$BENCHMARK_WAIT_TIMEOUT_SEC" ]; then
      log_error "timed out waiting for $index_name query count to reach $target (current=$current)"
      exit 1
    fi
    sleep "$BENCHMARK_WAIT_INTERVAL_SEC"
    elapsed=$((elapsed + BENCHMARK_WAIT_INTERVAL_SEC))
  done
}

before_events="$(es_count_query "siem-events" "benchmark.id.keyword" "$benchmark_id")"
replay_started_ns="$(date +%s%N)"
bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$BENCHMARK_INPUT_DIR/events.zeek.jsonl"
bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" snort.alert "$BENCHMARK_INPUT_DIR/events.snort.jsonl"
after_events_target=$((before_events + event_count))
actual_events="$(wait_for_es_count "siem-events" "benchmark.id.keyword" "$benchmark_id" "$after_events_target")"
replay_finished_ns="$(date +%s%N)"
throughput_ms="$($PYTHON_BIN -c 'import sys; start=int(sys.argv[1]); end=int(sys.argv[2]); print(max((end-start)/1_000_000, 1.0))' "$replay_started_ns" "$replay_finished_ns")"
hot_path_events_per_sec="$($PYTHON_BIN -c 'import sys; rows=float(sys.argv[1]); elapsed_ms=float(sys.argv[2]); print(round(rows/(elapsed_ms/1000.0), 2))' "$event_count" "$throughput_ms")"

LATENCY_JOB_NAME="phase5-benchmark-protocol-anomaly"
cancel_flink_job_by_name "$LATENCY_JOB_NAME" "$FLINK_REST_URL" || true
export KAFKA_SCAN_STARTUP_MODE=latest-offset
bash "$REPO_ROOT/scripts/run-flink-sql.sh" \
  "$REPO_ROOT/flink/sql/benchmark/00_set_protocol_latency_job_name.sql" \
  "$REPO_ROOT/flink/sql/detections/00_create_detection_base.sql" \
  "$REPO_ROOT/flink/sql/detections/09_detect_protocol_anomalies_zeek.sql" >/dev/null
sleep 3

latency_rule_id="flink.zeek.protocol_anomaly"
latency_source_ip="192.168.200.10"
latency_query="{\"query\":{\"bool\":{\"must\":[{\"term\":{\"rule.id\":\"$latency_rule_id\"}},{\"term\":{\"source.ip\":\"$latency_source_ip\"}}]}}}"
latency_before="$(es_count_query_json "siem-alerts" "$latency_query")"
latency_started_ns="$(date +%s%N)"
bash "$REPO_ROOT/scripts/replay-normalized-jsonl.sh" zeek.conn "$REPO_ROOT/data/test/phase35/hot/zeek_conn_hot_smoke.jsonl"
latency_target=$((latency_before + 1))
actual_alerts="$(wait_for_es_count_json "siem-alerts" "$latency_query" "$latency_target")"
latency_finished_ns="$(date +%s%N)"
alert_latency_ms="$($PYTHON_BIN -c 'import sys; start=int(sys.argv[1]); end=int(sys.argv[2]); print(round((end-start)/1_000_000, 3))' "$latency_started_ns" "$latency_finished_ns")"

cancel_flink_job_by_name "$LATENCY_JOB_NAME" "$FLINK_REST_URL" || true

"$PYTHON_BIN" - <<PY > "$BENCHMARK_RUN_DIR/ingest.json"
import json
from pathlib import Path
run_dir = Path(${BENCHMARK_RUN_DIR@Q})
load_es = json.loads((run_dir / 'load-elasticsearch.json').read_text()) if (run_dir / 'load-elasticsearch.json').exists() else {}
load_pg = json.loads((run_dir / 'load-postgres.json').read_text()) if (run_dir / 'load-postgres.json').exists() else {}
payload = {
  'benchmark_id': ${benchmark_id@Q},
  'event_count_replayed': int(${event_count@Q}),
  'hot_path_index_before': int(${before_events@Q}),
  'hot_path_index_after': int(${actual_events@Q}),
  'hot_path_elapsed_ms': float(${throughput_ms@Q}),
  'hot_path_events_per_second': float(${hot_path_events_per_sec@Q}),
  'alert_latency_rule_id': ${latency_rule_id@Q},
  'alert_latency_source_ip': ${latency_source_ip@Q},
  'alert_count_after': int(${actual_alerts@Q}),
  'alert_visibility_latency_ms': float(${alert_latency_ms@Q}),
  'elasticsearch_bulk_load': load_es,
  'postgres_copy_load': load_pg,
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY

log_info "Recorded ingest and alert latency metrics in $BENCHMARK_RUN_DIR/ingest.json"
