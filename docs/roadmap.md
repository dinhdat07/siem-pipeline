# Implementation Roadmap

All five phases are complete. Kafka remains the central event bus throughout.

## Phase Summary

| Phase | Status | Deliverable |
|:-----:|:------:|-------------|
| 1 | ✅ Done | Hot path: Kafka → Connect → Elasticsearch → Kibana |
| 2 | ✅ Done | Cold path: Kafka → Flink → Iceberg → MinIO |
| 3 | ✅ Done | Detections: 6 Flink SQL rule families |
| 3.5 | ✅ Done | Smoke validation: 5-stage integration checks |
| 4 | ✅ Done | Reproducibility: staged profiles, demo runner, bundled data |
| 5 | ✅ Done | Benchmarks: Elasticsearch vs PostgreSQL comparison |

## Phase 1 — Hot Path

- Add Elasticsearch, Kibana, and Kafka Connect to the local stack
- Index normalized events from `zeek.conn` and `snort.alert` into `siem-events-*`
- Index `siem.alerts` into `siem-alerts-*`
- Bootstrap index templates, write aliases, connector configs, and Kibana saved objects

## Phase 2 — Cold Path

- Add MinIO and Iceberg REST catalog
- Use Flink SQL + Iceberg connector to write normalized events into Parquet-backed tables
- Partition by `event_date` and `event_dataset`
- Keep the REST catalog boundary for future multi-node portability

## Phase 3 — Detections

- Six streaming detection families in Flink SQL:
  - Port scan (HOP window, COUNT DISTINCT)
  - Top talkers (TUMBLE window, SUM bytes)
  - Possible exfiltration (HOP window, SUM source bytes)
  - Repeated critical Snort alerts (HOP window, severity filter)
  - Snort-Zeek correlation (interval JOIN on source IP)
  - Protocol/service anomalies (HOP window, unknown service detection)
- Event-time windows, watermarks, and source idleness timeout
- All rule outputs on unified `siem.alerts` schema

## Phase 3.5 — Smoke Validation

- 5-stage smoke test suite: infra, topics, hot path, cold path, detections
- Bundled smoke datasets in `data/test/phase35/`
- Scripts in `scripts/smoke/`

## Phase 4 — Reproducibility

- Docker Compose profiles: `hot`, `cold`, `detect`, `benchmark`
- Single demo entrypoint: `scripts/demo/run-demo.sh`
- Staged modes: `hot-only`, `cold-only`, `detect-only`, `full`
- Bundled normalized demo datasets (no local Python deps needed)
- Conservative memory defaults in `.env.example`

## Phase 5 — Benchmark Validation

- PostgreSQL baseline behind optional `benchmark` Compose profile
- Reproducible data sizing: `small`, `medium`, `large`, `single-1m`
- Elasticsearch and PostgreSQL loaders
- Query latency, concurrent throughput, ingest, and alert-latency benchmarks
- Two suites: `baseline` (ES vs PG) and `showcase` (ES-specific investigation)

## Risks and Design Notes

- Snort timestamps must be UTC-normalized for reliable Elasticsearch time filtering
- Kafka Connect internal topics and DLQ topics are created explicitly (auto-create disabled)
- `siem.alerts` uses a stable schema shared across all detection rules
- Elasticsearch templates and aliases are bootstrapped before indexing starts to prevent incorrect field type inference
- Source idleness timeout is enabled to ensure all rule families emit reliably during staged demos and smoke datasets
