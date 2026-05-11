# Phase 2 Cold Path

Phase 2 adds long-term storage without changing the existing hot path.

## Goal

Write normalized events from Kafka into Parquet-backed Iceberg tables stored in MinIO, while keeping the setup simple for local use and replaceable for future multi-node deployment.

## Services Added

- `minio`
  - object storage for the Iceberg warehouse
- `minio-init`
  - creates the warehouse bucket during local bootstrap
- `iceberg-rest`
  - REST catalog endpoint used by Flink SQL
  - local default uses a JDBC catalog backed by SQLite inside the container volume
- `docker/flink/Dockerfile`
  - extends the Flink image with the Kafka connector, Iceberg runtime, AWS bundle, and Hadoop client jars

## Flink SQL Layout

Cold-path SQL files live in `flink/sql/cold-path/`:

- `01_create_iceberg_catalog.sql`
  - creates the REST-backed Iceberg catalog
- `02_create_iceberg_namespace.sql`
  - creates the `siem` namespace
- `03_create_iceberg_tables.sql`
  - defines the `normalized_events` Iceberg table
- `04_create_kafka_sources.sql`
  - defines temporary Kafka source tables for `zeek.conn` and `snort.alert`
- `05_insert_normalized_events.sql`
  - inserts both datasets into the Iceberg table with a shared schema
- `90_verify_iceberg_events.sql`
  - optional SQL verification for record counts and Iceberg metadata tables when the Flink cluster has free slots

## Schema Shape

The Iceberg table uses a flattened shared schema instead of engine-specific dotted field names.

Common fields include:

- event time and partition columns
  - `event_timestamp`
  - `event_date`
  - `event_dataset`
  - `event_module`
- ECS-like network and identity fields
  - `source_ip`, `destination_ip`
  - `network_bytes`, `network_packets`
  - `event_original`
- Zeek-specific nullable fields
  - `zeek_conn_uid`, `zeek_conn_service`, `zeek_conn_duration`, `zeek_conn_state`
- Snort-specific nullable fields
  - `rule_id`, `rule_name`, `event_severity`
  - `snort_signature_id`, `snort_ip_ttl`, `snort_tcp_flags_raw`

Why flatten it for the table:

- it stays easy to query from Flink and future Trino
- it avoids awkward handling of dotted field names across engines
- it still preserves the ECS semantics from the Kafka payloads

## Partition Strategy

The table is partitioned by `event_date` and `event_dataset`.

Trade-off:

- this is coarse enough to avoid over-partitioning in a lab
- it is still selective enough for date-bounded investigations and dataset-level pruning
- bucketing is intentionally not enabled yet because the dataset count is small and the MVP should stay simple

## Local Runbook

1. Copy `.env.example` to `.env`.
2. Start the stack:

   ```bash
   docker compose up -d --build
   ```

3. Bootstrap hot and cold resources:

   ```bash
   bash scripts/bootstrap-hot-path.sh
   bash scripts/bootstrap-cold-path.sh
   ```

4. Replay sample events into Kafka.
5. Start the cold-path insert job:

   ```bash
   bash scripts/run-flink-sql.sh \
     flink/sql/cold-path/01_create_iceberg_catalog.sql \
     flink/sql/cold-path/04_create_kafka_sources.sql \
     flink/sql/cold-path/05_insert_normalized_events.sql
   ```

6. Verify objects and table metadata:

   ```bash
   bash scripts/verify-cold-path.sh
   ```

## Verification

The default verification helper checks both storage layers without submitting a new Flink batch job:

- MinIO object listing confirms Parquet data and Iceberg metadata files exist
- Iceberg REST metadata confirms current snapshot state, total records, and data-file counts

Optional deeper verification with Flink SQL:

```bash
VERIFY_COLD_PATH_USE_FLINK_SQL=1 bash scripts/verify-cold-path.sh
```

Use the SQL mode only when the cluster has free slots. In `full` demo mode, the streaming jobs can occupy all local slots, so metadata-based verification is the more reliable default.

Additional manual checks:

```bash
curl http://localhost:8181/v1/config
curl http://localhost:8081/jobs
```

## Scaling Notes

For a future multi-node deployment:

- keep the REST catalog contract, but replace SQLite with PostgreSQL or MySQL
- keep the Iceberg warehouse URI pattern, but move from local MinIO to shared S3-compatible or cloud object storage
- keep the table schema, but add columns through Iceberg schema evolution instead of forking per-storage schemas
- move Flink checkpoints to durable shared storage
- use the placeholder Trino catalog config in `configs/trino/catalog/iceberg.properties.example` when Phase 4 or later adds query services
