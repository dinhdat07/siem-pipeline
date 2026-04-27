# Phase 5 Benchmark Validation

Phase 5 evaluates the SIEM pipeline with two goals:

- measure Elasticsearch performance for SIEM-style hot-path search and alert workflows
- compare those results against PostgreSQL as a simpler SQL baseline, without replacing Elasticsearch in the architecture

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
- the benchmark intentionally uses a simple `ILIKE` baseline for message search, because that highlights Elasticsearch's search-oriented strengths more honestly than pretending PostgreSQL is the default full-text serving layer in this project

## Query Categories

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

## Concurrent Query Benchmark

The concurrent runner executes the same logical query mix at configurable concurrency levels:

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
- `ingest.json`
- `summary.md`

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

The benchmark should help explain architectural fit, not just headline speed.
