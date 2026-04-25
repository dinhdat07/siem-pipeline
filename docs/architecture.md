# Architecture

The lab now has two downstream storage paths that branch from the same Kafka event bus:

- hot path: `Kafka -> Kafka Connect -> Elasticsearch -> Kibana`
- cold path: `Kafka -> Flink SQL -> Iceberg -> MinIO`

## End-To-End Flow

```text
Raw Zeek logs ---> Python parser/replay ----> zeek.conn -----\
                                                              \
Raw Snort logs --> Python parser/replay ----> snort.alert ----> Kafka ----> Kafka Connect ----> Elasticsearch ----> Kibana
                                                              /   |
Flink SQL rules <--------------------------------------------/    +----> Flink SQL sink ----> Iceberg REST catalog ----> MinIO
   |                                                                                               |
   +----> siem.alerts -----------------------------------------------------------------------------+----> future Trino
```

## Why This Shape

- Kafka stays central so replay, alerting, hot search, and cold retention all consume the same normalized events.
- The hot path stays untouched. Elasticsearch is still the fast investigation layer and not the event-system boundary.
- The cold path uses an Iceberg REST catalog instead of wiring Flink directly to a filesystem-only catalog. That keeps the catalog interface portable when moving to a larger deployment.
- MinIO provides S3-compatible storage locally while preserving the same object-storage pattern that a multi-node deployment would use later.

## Cold-Path Components

- `minio`
  - S3-compatible object storage for the Iceberg warehouse
  - exposed locally on `9000` plus console on `9001`
- `iceberg-rest`
  - local REST catalog service using the official Iceberg REST fixture image
  - backed by a JDBC catalog URI, with SQLite for the local lab by default
  - can later point at PostgreSQL or MySQL without changing Flink SQL catalog usage
- `flink-jobmanager` and `flink-taskmanager`
  - custom image includes Kafka, Iceberg, AWS, and Hadoop runtime jars
  - SQL jobs read Kafka topics and write Parquet-backed Iceberg tables

## Data Model

The cold path lands all normalized raw events into one Iceberg table:

- namespace: `siem`
- table: `normalized_events`
- format: Iceberg table format v2
- file format: Parquet
- shared columns capture the common ECS-like fields used in both datasets
- nullable dataset-specific columns keep important Zeek and Snort details without forcing separate tables

This keeps the MVP simple while staying extensible for future datasets.

## Partition Strategy

The table is partitioned by:

- `event_date`
- `event_dataset`

Why this partitioning:

- `event_date` keeps time pruning straightforward for long-term retention and investigations.
- `event_dataset` separates the small set of normalized dataset families without creating a large partition explosion.
- the design avoids hourly partitions or bucketing in the MVP because those would add complexity and small-file risk before they are needed.

## Multi-Node Readiness

The local stack is intentionally simple, but the boundaries are chosen so they can scale later:

- replace the default SQLite JDBC URI behind `iceberg-rest` with PostgreSQL or MySQL
- point `S3_ENDPOINT_INTERNAL` at external object storage instead of the local MinIO container
- increase Flink task slots, taskmanagers, and Kafka partitions from `.env`
- move Flink checkpoint storage to durable shared storage for a real multi-node deployment
- enable Trino using the REST catalog placeholder config in `configs/trino/catalog/iceberg.properties.example`
