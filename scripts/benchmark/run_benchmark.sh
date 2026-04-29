#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/benchmark_lib.sh"

BENCHMARK_SIZE="${1:-small}"
BENCHMARK_INPUT_DIR="${BENCHMARK_INPUT_DIR:-$BENCHMARK_DATA_ROOT/$BENCHMARK_SIZE}"
BENCHMARK_RUN_ID="${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$BENCHMARK_SIZE}"
BENCHMARK_RUN_DIR="${BENCHMARK_RUN_DIR:-$BENCHMARK_OUTPUT_ROOT/$BENCHMARK_RUN_ID}"
export BENCHMARK_SIZE
export BENCHMARK_INPUT_DIR
export BENCHMARK_RUN_ID
export BENCHMARK_RUN_DIR
ensure_benchmark_dirs
write_run_metadata

if is_truthy "${BENCHMARK_LOW_RESOURCE:-0}"; then
  export BENCHMARK_QUERY_ITERATIONS="${BENCHMARK_QUERY_ITERATIONS:-3}"
  export BENCHMARK_CONCURRENCY_LEVELS="${BENCHMARK_CONCURRENCY_LEVELS:-1,5}"
  export BENCHMARK_CONCURRENT_QUERIES_PER_WORKER="${BENCHMARK_CONCURRENT_QUERIES_PER_WORKER:-3}"
  log_warn "BENCHMARK_LOW_RESOURCE=1 enabled: using fewer query iterations and lower concurrency"
fi

if is_truthy "${BENCHMARK_START_STACK:-1}"; then
  benchmark_compose_up "hot,benchmark,detect" kafka elasticsearch connect postgres flink-jobmanager flink-taskmanager
fi

wait_for_container kafka "Kafka broker" "$BENCHMARK_WAIT_TIMEOUT_SEC" "$BENCHMARK_WAIT_INTERVAL_SEC"
wait_for_benchmark_elasticsearch
wait_for_postgres
wait_for_benchmark_connect
wait_for_benchmark_flink

bash "$SCRIPT_DIR/prepare_benchmark_data.sh" "$BENCHMARK_SIZE"
bash "$SCRIPT_DIR/load_elasticsearch.sh" "$BENCHMARK_SIZE"
bash "$SCRIPT_DIR/load_postgres.sh" "$BENCHMARK_SIZE"
bash "$SCRIPT_DIR/benchmark_queries_elasticsearch.sh" "$BENCHMARK_SIZE"
bash "$SCRIPT_DIR/benchmark_queries_postgres.sh" "$BENCHMARK_SIZE"
bash "$SCRIPT_DIR/benchmark_concurrent.sh" "$BENCHMARK_SIZE"
bash "$SCRIPT_DIR/benchmark_ingest.sh" "$BENCHMARK_SIZE"

"$PYTHON_BIN" - <<'PY' > "$BENCHMARK_RUN_DIR/summary.md"
import json
import os
from pathlib import Path
run_dir = Path(os.environ["BENCHMARK_RUN_DIR"])
metadata = json.loads((run_dir / 'metadata.json').read_text())
prepare = json.loads((run_dir / 'prepare-summary.json').read_text())
load_es = json.loads((run_dir / 'load-elasticsearch.json').read_text())
load_pg = json.loads((run_dir / 'load-postgres.json').read_text())
queries_es = json.loads((run_dir / 'queries-elasticsearch.json').read_text())
queries_pg = json.loads((run_dir / 'queries-postgres.json').read_text())
concurrent_es = json.loads((run_dir / 'concurrent-elasticsearch.json').read_text())
concurrent_pg = json.loads((run_dir / 'concurrent-postgres.json').read_text())
ingest = json.loads((run_dir / 'ingest.json').read_text())

def lookup(items, name):
    for item in items:
        if item['query'] == name:
            return item
    return {}

es_top_talkers = lookup(queries_es['queries'], 'top_talkers_by_network_bytes')
pg_top_talkers = lookup(queries_pg['queries'], 'top_talkers_by_network_bytes')
es_message = lookup(queries_es['queries'], 'message_search')
pg_message = lookup(queries_pg['queries'], 'message_search')
print(f"# Benchmark Summary: {metadata['run_id']}\n")
print(f"- benchmark size: `{metadata['size']}`")
print(f"- benchmark input dir: `{metadata['generated_input_dir']}`")
print(f"- events prepared: `{prepare['event_count']}`")
print(f"- alerts prepared: `{prepare['alert_count']}`\n")
print("## Loader Throughput\n")
print(f"- Elasticsearch bulk event throughput: `{load_es['event_rows_per_second']} rows/sec`")
print(f"- Elasticsearch bulk alert throughput: `{load_es['alert_rows_per_second']} rows/sec`")
print(f"- PostgreSQL copy event throughput: `{load_pg['event_rows_per_second']} rows/sec`")
print(f"- PostgreSQL copy alert throughput: `{load_pg['alert_rows_per_second']} rows/sec`\n")
print("## Hot-Path Metrics\n")
print(f"- Elasticsearch hot-path ingest throughput: `{ingest['hot_path_events_per_second']} events/sec`")
print(f"- Approximate alert visibility latency: `{ingest['alert_visibility_latency_ms']} ms`\n")
print("## Query Highlights\n")
print(f"- top talkers p95: `ES {es_top_talkers.get('p95_ms', 'n/a')} ms` vs `PG {pg_top_talkers.get('p95_ms', 'n/a')} ms`")
print(f"- message search p95: `ES {es_message.get('p95_ms', 'n/a')} ms` vs `PG {pg_message.get('p95_ms', 'n/a')} ms`\n")
print("## Concurrent Query Highlights\n")
for es_row, pg_row in zip(concurrent_es['results'], concurrent_pg['results']):
    print(f"- concurrency {es_row['concurrency']}: `ES p95 {es_row['p95_ms']} ms` vs `PG p95 {pg_row['p95_ms']} ms`")
print("\n## Interpretation Notes\n")
print("- PostgreSQL is the SQL comparison baseline, not the serving-layer replacement.")
print("- Bulk loader throughput is not directly equivalent to Kafka-to-Elasticsearch hot-path throughput.")
print("- Alert latency is measured from replay start to alert visibility in Elasticsearch, so it is an approximation.")
print("- Message search uses aligned backend-native full-text predicates with latest-match ordering, so it is more comparable than the earlier ILIKE baseline.")
PY

log_info "Benchmark run complete. Results are in $BENCHMARK_RUN_DIR"
