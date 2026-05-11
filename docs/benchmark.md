# Phase 5 Benchmark Validation

Phase 5 evaluates the SIEM pipeline with two goals:

- measure Elasticsearch performance for SIEM-style hot-path search and alert workflows
- compare those results against PostgreSQL as a simpler SQL baseline, without replacing Elasticsearch in the architecture

The benchmark now reports two suites:

- `baseline`
  - a general Elasticsearch-versus-PostgreSQL comparison for common SIEM filters, aggregations, and latest-match text search
- `showcase`
  - a search-and-investigation oriented suite that highlights Elasticsearch fit for multi-field search, faceting, timelines, and pivot workflows

## Scope

Elasticsearch remains the primary hot search and investigation layer.

PostgreSQL is included only as a comparison baseline because it offers:

- a familiar relational model
- straightforward SQL queries
- a useful contrast with Elasticsearch for filtering, aggregations, and message search workloads

This benchmark does **not** claim Elasticsearch is faster for every workload. It is intended to show where Elasticsearch is a better fit for SIEM-style search, filtering, aggregations, and Kibana-driven investigation flows.

## What Gets Measured

### Elasticsearch hot path

- event ingest throughput in events/sec through `Kafka -> Kafka Connect -> Elasticsearch`
- approximate end-to-end alert visibility latency through `Kafka -> Flink -> siem.alerts -> Kafka Connect -> Elasticsearch`
- time-range query latency
- aggregation latency for alert counts and top talkers
- concurrent query behavior

### PostgreSQL baseline

- direct benchmark data load throughput into PostgreSQL
- equivalent SQL query latency for the same logical query categories
- concurrent query behavior under the same benchmark dataset

## Dataset Strategy

The benchmark data is generated reproducibly from the repo's existing normalized JSONL sources:

- `data/sample/...`
- `data/test/phase35/hot/...`
- `data/test/phase35/cold/...`
- `data/test/phase35/detections/...`

The preparation step:

- combines those normalized events
- scales them with deterministic replay multipliers
- adds `benchmark.*` fields and stable `event.id` values
- creates a benchmark-friendly alert corpus from the same logical events

Benchmark sizes:

- `small`
  - multiplier `1`
- `medium`
  - multiplier `10`
- `large`
  - multiplier `50`
- `single-1m`
  - exactly `1,000,000` events for single-node baseline comparison
- `distributed-1m`
  - exactly `1,000,000` events for distributed apples-to-apples comparison
- `distributed-3m`
  - exactly `3,000,000` events for the recommended distributed headline run on the current 3-node cluster

The generated alerts are deterministic synthetic benchmark alerts derived from the normalized events. That keeps the Elasticsearch and PostgreSQL query benchmark corpus identical. The separate alert-latency measurement still uses the actual Flink detection pipeline.

## PostgreSQL Schema Design

PostgreSQL stores the benchmark baseline in:

- `siem_benchmark.events`
- `siem_benchmark.alerts`

Schema design choices:

- promoted relational columns for common filters and aggregations
  - timestamp
  - dataset
  - source IP
  - destination IP
  - severity
  - rule ID and name
  - network bytes
  - message
- a `payload JSONB` column preserves the flexible ECS-like source document

Indexes are added for:

- timestamp
- dataset
- source IP
- destination IP
- severity
- rule ID
- benchmark ID
- `payload` via GIN for flexible JSONB access

Trade-off:

- promoted columns keep the baseline fair for common SIEM filters and group-bys
- JSONB preserves flexibility
- PostgreSQL keeps a simple baseline role even in the showcase suite; it does not add denormalized helper tables or PG-only search extensions beyond benchmark-local full-text support

## Query Categories

### Baseline suite

Both backends are benchmarked for these logical query classes:

- time-range search
- filter by dataset
- filter by source IP
- filter by destination IP
- alerts by severity
- alerts by rule
- top source IP by event count
- top destination IP by event count
- top talkers by total network bytes
- message search

### ES showcase suite

Both backends are also benchmarked for these search-and-investigation oriented query classes:

- multi-field latest hits across `message` and `event.original`
- search facet by destination port
- search facet by source IP
- search timeline histogram over multi-field search results
- IP pivot latest hits

## Concurrent Query Benchmark

The concurrent runner executes the same logical query mix at configurable concurrency levels for both suites:

- default levels: `1, 5, 10, 25`
- per-level output includes
  - average latency
  - p50
  - p95
  - p99
  - min/max

These results should be interpreted as application-observed latency, not low-level storage-engine profiling.

## Alert Latency Methodology

Alert latency is measured as an approximation:

1. submit the Flink protocol-anomaly detection job
2. replay a tiny Zeek anomaly sample into Kafka
3. poll Elasticsearch for the resulting alert document
4. record elapsed wall-clock time from replay start to alert visibility

Limitations:

- this is not exact event-level tracing
- it includes replay, Kafka, Flink, Kafka Connect, and Elasticsearch indexing time together
- it measures alert visibility in Elasticsearch, not only Kafka topic emission

That approximation is still useful because Elasticsearch visibility is what the Phase 1 hot path and Kibana investigation workflow depend on.

## Commands

Install the benchmark Python dependency first:

```bash
pip install -r benchmark/requirements.txt
```

End-to-end runs:

```bash
bash scripts/benchmark/run_benchmark.sh small
bash scripts/benchmark/run_benchmark.sh medium
bash scripts/benchmark/run_benchmark.sh large
```

Distributed showcase runs:

```bash
bash scripts/benchmark/run_benchmark.sh single-1m
bash deploy/distributed/siemctl.sh benchmark distributed-1m
bash deploy/distributed/siemctl.sh benchmark distributed-3m
```

The current 3-node hardware is safest at `1M-3M` events. Treat larger datasets as stress tests because PostgreSQL temp files, Elasticsearch disk watermarks, and swap pressure can dominate results.

After a single-node and distributed run complete, generate an apples-to-apples comparison:

```bash
python3 scripts/benchmark/compare_runs.py \
  --single-run-dir benchmark/results/<single-1m-run> \
  --distributed-run-dir benchmark/results/<distributed-1m-run> \
  --output benchmark/results/single-vs-distributed.md
```

To show Elasticsearch scalability across multiple dataset sizes, generate an ES-only report from two or more completed runs:

```bash
python3 scripts/benchmark/es_scaling_report.py \
  --run-dir benchmark/results/<distributed-1m-run> \
  --run-dir benchmark/results/<distributed-3m-run> \
  --output benchmark/results/es-scalability.md
```

The distributed showcase wrapper now writes that file automatically after it finishes all requested sizes:

```bash
bash scripts/benchmark/run_distributed_showcase.sh distributed-1m distributed-3m
```

To show Elasticsearch scale-out by node count on the existing 3-node cluster, run the ES node benchmark. This keeps the cluster alive and only pins the benchmark indices to `1`, `2`, then `3` ES nodes:

```bash
bash deploy/distributed/siemctl.sh benchmark-es-nodes distributed-1m
```

That command writes:

```bash
benchmark/results/es-node-scalability-distributed-1m.md
```

You can limit the topologies if you only want a partial run:

```bash
BENCHMARK_NODE_COUNTS=1,3 bash scripts/benchmark/run_es_node_scaling.sh distributed-1m
```

Low-resource run:

```bash
BENCHMARK_LOW_RESOURCE=1 bash scripts/benchmark/run_benchmark.sh small
```

Step-by-step run:

```bash
bash scripts/benchmark/prepare_benchmark_data.sh small
bash scripts/benchmark/load_elasticsearch.sh small
bash scripts/benchmark/load_postgres.sh small
bash scripts/benchmark/benchmark_queries_elasticsearch.sh small
bash scripts/benchmark/benchmark_queries_postgres.sh small
bash scripts/benchmark/benchmark_concurrent.sh small
bash scripts/benchmark/benchmark_ingest.sh small
```

## Output Files

Each run writes into `benchmark/results/<run-id>/`.

Key files:

- `prepare-summary.json`
- `load-elasticsearch.json`
- `load-postgres.json`
- `queries-elasticsearch.json`
- `queries-postgres.json`
- `concurrent-elasticsearch.json`
- `concurrent-postgres.json`
- `queries-showcase-elasticsearch.json`
- `queries-showcase-postgres.json`
- `concurrent-showcase-elasticsearch.json`
- `concurrent-showcase-postgres.json`
- `ingest.json`
- `summary.md`
- `es-vs-postgres-showcase.md`
- `benchmark/results/es-scalability.md`

## Recommended Hardware

Use a real Linux server for meaningful numbers.

Recommended benchmark targets:

- small: `4 vCPU / 8 GB RAM`
- medium: `6 vCPU / 12 GB RAM`
- large: `8 vCPU / 16 GB RAM`

Local WSL or memory-limited Docker Desktop runs are useful for smoke-level validation, but not for final benchmark claims.

## How To Interpret Results

Use PostgreSQL as the baseline for:

- simple equality filters
- common group-by queries
- familiar SQL behavior

Use Elasticsearch strengths as the main SIEM story for:

- document-oriented search and filtering at the hot path
- dashboard-oriented aggregations
- search-oriented message and investigation workflows
- direct Kibana integration

Interpret the suites separately:

- `baseline` answers the general comparison question
- `showcase` answers the search-and-investigation fit question

Interpret the ES-only scalability report separately from the ES-vs-PG report:

- `ES ingest scaling` shows whether bulk load and hot-path throughput keep pace as the dataset grows
- `ES search scaling` shows whether p95 search latency grows slower than data volume for SIEM investigation queries
- `ES concurrent search scaling` shows how stable p95 latency remains as both dataset size and user concurrency rise

Interpret the node-scalability report separately again:

- it keeps dataset size fixed and varies only the number of Elasticsearch nodes serving the benchmark indices
- it is the fairest way to show ES scale-out on this cluster without disrupting Kafka, Flink, PostgreSQL, or the side-by-side ecommerce deployment
- `node efficiency` near `1x` means the speedup is close to linear with node-count growth

The benchmark should help explain architectural fit, not just headline speed.
