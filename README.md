# SIEM Pipeline

This repository is a reproducible SIEM-style data engineering demo built around Kafka, Flink, Elasticsearch, Kibana, MinIO, and Apache Iceberg.

Implemented phases:

- Phase 1 hot path: `Kafka -> Kafka Connect -> Elasticsearch -> Kibana`
- Phase 2 cold path: `Kafka -> Flink SQL -> Iceberg -> MinIO`
- Phase 3 detections: `Kafka -> Flink SQL -> siem.alerts`
- Phase 3.5 smoke validation: staged infrastructure and pipeline checks
- Phase 4 reproducibility: staged compose profiles, a single demo runner, and server-friendly runbooks
- Phase 5 benchmark validation: Elasticsearch hot-path and PostgreSQL baseline benchmarking

Kafka remains the central event bus for ingest, storage, and alerting.

More detail lives in `docs/architecture.md`, `docs/benchmark.md`, `docs/demo.md`, `docs/cold-path.md`, `docs/flink-detections.md`, `docs/phase1-hot-path.md`, `docs/roadmap.md`, and `docs/validation-smoke-tests.md`.

## Quick Start

For a fresh server or VM, the fastest end-to-end demo flow is:

```bash
cp .env.example .env
bash scripts/demo/run-demo.sh full
```

That command:

- starts the required Docker Compose services
- creates Kafka topics
- bootstraps Elasticsearch templates and Kafka Connect sinks
- bootstraps the Iceberg catalog and table
- starts the cold-path and detection Flink jobs
- replays a small bundled normalized dataset
- prints follow-up verification commands

The demo flow does not require local Python parser dependencies because it replays bundled normalized JSONL files through Kafka.

## Benchmark Quick Start

Phase 5 adds a PostgreSQL comparison baseline and benchmark scripts that are separate from the normal demo flow.

Small benchmark:

```bash
cp .env.example .env
pip install -r benchmark/requirements.txt
bash scripts/benchmark/run_benchmark.sh small
```

Larger benchmark sizes:

```bash
bash scripts/benchmark/run_benchmark.sh medium
bash scripts/benchmark/run_benchmark.sh large
```

Low-resource mode for laptops or WSL:

```bash
BENCHMARK_LOW_RESOURCE=1 bash scripts/benchmark/run_benchmark.sh small
```

## Demo Modes

The Phase 4 demo runner supports staged modes so you do not need the full stack every time:

```bash
bash scripts/demo/run-demo.sh hot-only
bash scripts/demo/run-demo.sh cold-only
bash scripts/demo/run-demo.sh detect-only
bash scripts/demo/run-demo.sh full
```

Mode summary:

- `hot-only`
  - starts Kafka plus the hot path services (`Elasticsearch`, `Kibana`, `Kafka Connect`)
  - replays a tiny event sample into `zeek.conn` and `snort.alert`
- `cold-only`
  - starts Kafka, Flink, MinIO, and the Iceberg REST catalog
  - bootstraps the Iceberg table and writes a tiny sample into cold storage
- `detect-only`
  - starts Kafka and Flink only
  - launches the advanced Phase 3 detections and replays a tiny detection dataset
- `full`
  - starts all services and exercises hot path, cold path, and detections together

Optional strict validation:

```bash
DEMO_ENABLE_SMOKE_TESTS=1 bash scripts/demo/run-demo.sh full
```

## Docker Compose Profiles

The Compose file now supports staged profiles:

- `hot`
  - `elasticsearch`, `kibana`, `connect`
- `cold`
  - `minio`, `minio-init`, `iceberg-rest`
- `detect`
  - `flink-jobmanager`, `flink-taskmanager`
- `benchmark`
  - `postgres`

Examples:

```bash
COMPOSE_PROFILES=hot docker compose up -d --build
COMPOSE_PROFILES=cold,detect docker compose up -d --build
COMPOSE_PROFILES=hot,cold,detect docker compose up -d --build
COMPOSE_PROFILES=hot,benchmark,detect docker compose up -d --build
```

Kafka stays unprofiled because every mode depends on it.

## Recommended Server Specs

For reliable demos on a Linux server:

- full demo
  - minimum: `4 vCPU / 8 GB RAM`
  - recommended: `6 vCPU / 12 GB RAM`
- hot-only or detect-only
  - minimum: `2 vCPU / 4 GB RAM`
- cold-only
  - minimum: `2 vCPU / 4-6 GB RAM`

The defaults in `.env.example` intentionally keep JVM and Flink memory conservative for laptops and smaller VMs.

For Phase 5 benchmark runs:

- minimum server target: `4 vCPU / 8 GB RAM`
- recommended server target: `6 vCPU / 12 GB RAM`
- large benchmark target: `8 vCPU / 16 GB RAM`

Benchmark numbers collected on low-RAM WSL should be treated as approximate only.

## Useful Commands

Full demo:

```bash
bash scripts/demo/run-demo.sh full
```

Hot-only demo:

```bash
bash scripts/demo/run-demo.sh hot-only
```

Strict smoke validation without the full demo runner:

```bash
bash scripts/smoke/run_smoke_tests.sh infra
bash scripts/smoke/run_smoke_tests.sh hot
bash scripts/smoke/run_smoke_tests.sh cold
bash scripts/smoke/run_smoke_tests.sh detect
```

Benchmark helpers:

```bash
bash scripts/benchmark/prepare_benchmark_data.sh small
bash scripts/benchmark/load_elasticsearch.sh small
bash scripts/benchmark/load_postgres.sh small
bash scripts/benchmark/benchmark_queries_elasticsearch.sh small
bash scripts/benchmark/benchmark_queries_postgres.sh small
bash scripts/benchmark/benchmark_concurrent.sh small
bash scripts/benchmark/benchmark_ingest.sh small
```

Stop the stack:

```bash
docker compose down
```

Reset the stack and volumes before a clean rerun:

```bash
DEMO_RESET_STACK=1 DEMO_RESET_VOLUMES=1 bash scripts/demo/run-demo.sh full
```

## Replaying Raw Logs Instead Of Bundled Demo Data

The bundled demo uses normalized JSONL files so it stays lightweight and reproducible.

If you want to replay raw MACCDC-style data through the Python parsers, install parser dependencies first:

```bash
pip install -r parser/requirements.txt
```

Examples:

```bash
python3 parser/replay_to_kafka.py --input data/raw/zeek/conn.log --topic zeek.conn --bootstrap-servers localhost:9092 --limit 1000 --interval-ms 50
python3 parser/replay_snort_to_kafka.py --input-dir data/raw/snort-alert --topic snort.alert --bootstrap-servers localhost:9092 --limit 1000 --interval-ms 50
```

## Repository Layout

```text
.
|-- benchmark/
|-- configs/
|   |-- elasticsearch/
|   |-- flink/
|   |-- kafka/
|   |-- kafka-connect/
|   `-- trino/
|-- dashboards/
|-- data/
|   |-- sample/
|   `-- test/
|-- docker/
|   |-- connect/
|   `-- flink/
|-- docs/
|-- flink/
|   |-- sql/
|   |   |-- cold-path/
|   |   |-- demo/
|   |   |-- detections/
|   |   `-- smoke/
|   `-- usrlib/
|-- parser/
|-- scripts/
|   |-- benchmark/
|   |-- demo/
|   |-- smoke/
|   `-- *.sh
|-- Makefile
|-- .env.example
`-- docker-compose.yml
```

## Verification Shortcuts

After the full demo:

```bash
curl http://localhost:9200/siem-events/_count
curl http://localhost:9200/siem-alerts/_count
bash scripts/verify-cold-path.sh
bash scripts/verify-flink-detections.sh
curl http://localhost:8081/jobs/overview
```

Benchmark results are written to `benchmark/results/<run-id>/`.

## Current Scope

Included now:

- reproducible hot path, cold path, and detection demos
- staged Docker Compose startup via profiles
- smoke-test-based validation helpers
- bundled small demo datasets for quick server validation
- benchmark data preparation, Elasticsearch bulk loading, PostgreSQL baseline loading, query latency checks, and concurrent query benchmarks

Not included yet:

- production HA deployment manifests
- Trino as an active Compose service
- production-grade benchmark orchestration beyond the current scripts
