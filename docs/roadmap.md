# 5-Phase Implementation Plan

This roadmap keeps Kafka as the central event bus, keeps Flink focused on stream processing and alert generation, and treats Elasticsearch as the hot search layer.

## Risks And Dependency Notes

- Snort timestamps must be UTC-normalized before phase 1 dashboards and Elasticsearch time filtering are reliable.
- Kafka Connect internal topics and DLQ topics must be created explicitly because topic auto-creation is disabled.
- `siem.alerts` needs a stable schema in phase 1 so later Flink rules do not break indexing and dashboards.
- The Elasticsearch sink must bootstrap aliases and templates before indexing starts, otherwise the connector can create the wrong concrete indices.
- Phase 2 depends on phase 1 field stability. Iceberg should consume the same normalized Kafka payloads rather than a different storage-specific schema.

## Phase 1

- Add Elasticsearch, Kibana, and Kafka Connect to the local stack.
- Index normalized events from `zeek.conn` and `snort.alert` into `siem-events-*`.
- Keep `siem.alerts` in Kafka and also index it into `siem-alerts-*`.
- Add index templates, write aliases, connector bootstrap, and Kibana saved objects.
- Keep the MVP simple: single-node services, basic mappings, current simple Flink rules.

## Phase 2

Implemented in the current repo state:

- Add MinIO and Iceberg as the cold path.
- Use Flink SQL plus Iceberg connector to write normalized events from Kafka into Parquet-backed Iceberg tables.
- Partition by event date and dataset.
- Do not remove or bypass Kafka. The hot and cold paths both branch from Kafka.
- Keep the REST-catalog boundary so local development can later move to a multi-node deployment shape.

## Phase 3

Implemented in the current repo state:

- Upgrade Flink from simple filtering to real SIEM detections.
- Implement port scan, top talkers, possible exfiltration, repeated critical Snort alerts, Snort-plus-Zeek correlation, and service/protocol anomalies.
- Keep all rule outputs on the same `siem.alerts` schema introduced in phase 1.
- Use event-time windows, watermarks, and interval joins where they fit the detection logic.

## Phase 4

Implemented in the current repo state:

- Add a single demo runner at `scripts/demo/run-demo.sh`.
- Support staged modes for `hot-only`, `cold-only`, `detect-only`, and `full`.
- Add Compose profiles so the full stack is optional.
- Expand `.env.example` with conservative memory defaults and demo-oriented toggles.
- Add `docs/demo.md` plus an updated architecture diagram and deployment runbook.

## Phase 5

Implemented in the current repo state:

- Add a PostgreSQL benchmark baseline behind the optional `benchmark` Compose profile.
- Add reproducible benchmark data preparation with `small`, `medium`, and `large` sizing.
- Add benchmark loaders for Elasticsearch and PostgreSQL.
- Add query, concurrent, ingest-throughput, and approximate alert-latency benchmark scripts.
- Add benchmark documentation plus result templates under `benchmark/results/`.
