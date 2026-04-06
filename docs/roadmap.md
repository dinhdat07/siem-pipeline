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

- Add MinIO and Iceberg as the cold path.
- Use Flink SQL plus Iceberg connector to write normalized events from Kafka into Parquet-backed Iceberg tables.
- Partition by event date and dataset.
- Do not remove or bypass Kafka. The hot and cold paths both branch from Kafka.

## Phase 3

- Upgrade Flink from simple filtering to real SIEM detections.
- Implement port scan, top talkers, possible exfiltration, repeated critical Snort alerts, Snort-plus-Zeek correlation, and service/protocol anomalies.
- Keep all rule outputs on the same `siem.alerts` schema introduced in phase 1.

## Phase 4

- Add reproducible bootstrap scripts for the full lab.
- Add scripts for topics, templates, Iceberg tables, Flink job launch, and demo replay verification.
- Add a short architecture diagram in `docs/`.

## Phase 5

- Measure ingest throughput, end-to-end alert latency, Elasticsearch query latency, aggregation latency, and concurrent query behavior.
- Keep benchmarking scripted and repeatable against the local lab dataset and replay workflow.
