# Phase 4 Demo And Deployment

Phase 4 turns the repo into a reproducible end-to-end demo that is easy to run on a Linux server and still workable from Git Bash or WSL.

## Goal

A new user should be able to:

1. clone the repository
2. copy `.env.example` to `.env`
3. run one demo command
4. verify that events, alerts, and optional cold-path data were produced

## Recommended Server Specs

Use these as practical lab targets, not production sizing:

| Mode | Minimum | Recommended |
| --- | --- | --- |
| `hot-only` | 2 vCPU / 4 GB RAM | 4 vCPU / 6 GB RAM |
| `cold-only` | 2 vCPU / 4 GB RAM | 4 vCPU / 6 GB RAM |
| `detect-only` | 2 vCPU / 4 GB RAM | 4 vCPU / 6 GB RAM |
| `full` | 4 vCPU / 8 GB RAM | 6 vCPU / 12 GB RAM |

If the host is memory-constrained, prefer staged modes instead of the full stack.

## One-Command Demo

Full end-to-end demo:

```bash
cp .env.example .env
bash scripts/demo/run-demo.sh full
```

What it does:

- starts the right Docker Compose services
- creates Kafka topics
- bootstraps Elasticsearch templates and Kafka Connect sinks
- bootstraps the Iceberg catalog, namespace, and table
- starts the cold-path and detection Flink jobs
- replays bundled normalized JSONL demo data
- optionally runs smoke tests
- prints follow-up verification commands

## Demo Modes

### Hot Only

```bash
bash scripts/demo/run-demo.sh hot-only
```

Use when you want to show:

- Kafka ingest
- Elasticsearch indexing
- Kibana dashboards and data views

### Cold Only

```bash
bash scripts/demo/run-demo.sh cold-only
```

Use when you want to show:

- Kafka to Flink SQL
- Iceberg table creation
- Parquet-backed cold storage in MinIO

### Detect Only

```bash
bash scripts/demo/run-demo.sh detect-only
```

Use when you want to show:

- Flink detection jobs
- alerts emitted into Kafka topic `siem.alerts`
- detection behavior without the rest of the stack

### Full

```bash
bash scripts/demo/run-demo.sh full
```

Use when you want to show:

- hot path
- cold path
- Flink detections
- all services working together

## Demo Datasets

The demo runner uses the existing tiny normalized datasets already bundled in the repo:

- hot path
  - `data/test/phase35/hot/zeek_conn_hot_smoke.jsonl`
  - `data/test/phase35/hot/snort_alert_hot_smoke.jsonl`
- cold path
  - `data/test/phase35/cold/zeek_conn_cold_smoke.jsonl`
  - `data/test/phase35/cold/snort_alert_cold_smoke.jsonl`
- detections
  - `data/test/phase35/detections/zeek_conn_detection_smoke.jsonl`
  - `data/test/phase35/detections/snort_alert_detection_smoke.jsonl`

This keeps the demo quick and avoids needing local Python dependencies for the basic Phase 4 runbook.

## Optional Strict Validation

Run the same demo plus smoke assertions:

```bash
DEMO_ENABLE_SMOKE_TESTS=1 bash scripts/demo/run-demo.sh full
```

Or run a single stage directly:

```bash
bash scripts/smoke/run_smoke_tests.sh hot
bash scripts/smoke/run_smoke_tests.sh cold
bash scripts/smoke/run_smoke_tests.sh detect
```

## Demo Validation Checklist

Use this after running `run-demo.sh`.

### Common

- [ ] Kafka topics exist
  - `zeek.conn`
  - `snort.alert`
  - `siem.alerts`
- [ ] Flink UI is reachable when the mode includes Flink
- [ ] the replay files were accepted into Kafka without script errors

### Hot Path

- [ ] `siem-events` has documents
- [ ] `siem-alerts` has documents for `full` mode
- [ ] Kibana loads successfully
- [ ] Kibana saved objects were imported

Verification commands:

```bash
curl http://localhost:9200/siem-events/_count
curl http://localhost:9200/siem-alerts/_count
curl http://localhost:8083/connectors
```

### Cold Path

- [ ] Iceberg REST catalog is reachable
- [ ] MinIO warehouse bucket contains Iceberg metadata and Parquet files
- [ ] `normalized_events` receives replayed data

Verification commands:

```bash
curl http://localhost:8181/v1/config
bash scripts/verify-cold-path.sh
```

### Detections

- [ ] Flink jobs are listed
- [ ] alerts appear in Kafka topic `siem.alerts`
- [ ] in `full` mode, alerts also appear in Elasticsearch through Kafka Connect

Verification commands:

```bash
curl http://localhost:8081/jobs/overview
bash scripts/verify-flink-detections.sh
```

If Elasticsearch is not part of the current mode, `scripts/verify-flink-detections.sh` falls back to Kafka-only alert verification.

## Compose Profiles

The Compose file is staged with profiles so the full stack is optional:

- `hot`
  - `elasticsearch`, `kibana`, `connect`
- `cold`
  - `minio`, `minio-init`, `iceberg-rest`
- `detect`
  - `flink-jobmanager`, `flink-taskmanager`

Examples:

```bash
COMPOSE_PROFILES=hot docker compose up -d --build
COMPOSE_PROFILES=cold,detect docker compose up -d --build
COMPOSE_PROFILES=hot,cold,detect docker compose up -d --build
```

## Portable Script Notes

Primary target:

- Linux server with Docker Engine and Bash

Best-effort secondary target:

- Git Bash on Windows
- WSL on Windows

Portability choices already included:

- all orchestration is Bash-based
- replay during demos uses normalized JSONL files and `docker exec` into Kafka, not local Python dependencies
- scripts that pass paths into containers use `MSYS_NO_PATHCONV=1` where needed
- the demo runner uses environment variables instead of hardcoded host-specific assumptions

## Clean Reruns

If you want a clean rerun of the demo on the same machine:

```bash
DEMO_RESET_STACK=1 DEMO_RESET_VOLUMES=1 bash scripts/demo/run-demo.sh full
```

That will stop the existing Compose stack and remove named volumes before replaying the demo.
